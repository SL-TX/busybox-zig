//! Tests for the .deb (ar container + control.tar) helper.

const std = @import("std");
const dpkg = @import("libbb_zig").archive.dpkg;
const tar = @import("libbb_zig").archive.tar;
const xz = @import("libbb_zig").compression.xz;
const bzip2 = @import("libbb_zig").compression.bzip2;

fn controlTar(allocator: std.mem.Allocator, control: []const u8) ![]u8 {
    var entries = [_]tar.Entry{.{ .name = "./control", .data = control, .mode = 0o100644 }};
    return tar.build(allocator, &entries);
}

test "ar round trip including GNU long member names" {
    const long_name = "a-very-long-member-name-that-exceeds-the-sixteen-byte-ar-limit.txt";
    const members = [_]dpkg.Member{
        .{ .name = "debian-binary", .data = "2.0\n" },
        .{ .name = long_name, .data = "long contents" },
    };
    const archive = try dpkg.buildAr(std.testing.allocator, &members);
    defer std.testing.allocator.free(archive);
    const parsed = try dpkg.parseAr(std.testing.allocator, archive);
    defer dpkg.freeMembers(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("debian-binary", parsed[0].name);
    try std.testing.expectEqualStrings("2.0\n", parsed[0].data);
    try std.testing.expectEqualStrings(long_name, parsed[1].name);
    try std.testing.expectEqualStrings("long contents", parsed[1].data);
}

test "parse a .deb control file and data members" {
    const control = "Package: parity-test\nVersion: 1.2-3\nArchitecture: all\nDepends: libc6 (>= 2.31)\nDescription: a test package\n a longer description\n";
    const ctrl = try controlTar(std.testing.allocator, control);
    defer std.testing.allocator.free(ctrl);
    var data_entries = [_]tar.Entry{.{ .name = "./usr/share/hello", .data = "hi", .mode = 0o100644 }};
    const data = try tar.build(std.testing.allocator, &data_entries);
    defer std.testing.allocator.free(data);
    const deb = try dpkg.buildDeb(std.testing.allocator, ctrl, data);
    defer std.testing.allocator.free(deb);

    const parsed = try dpkg.parseDeb(std.testing.allocator, deb);
    defer dpkg.freeDeb(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.members.len);
    try std.testing.expectEqualStrings("parity-test", parsed.control.package);
    try std.testing.expectEqualStrings("1.2-3", parsed.control.version);
    try std.testing.expectEqualStrings("all", parsed.control.architecture);
    try std.testing.expectEqualStrings("libc6 (>= 2.31)", parsed.control.depends);
    try std.testing.expectEqualStrings("a test package\n a longer description", parsed.control.description);
    const files = try dpkg.dataEntries(std.testing.allocator, parsed);
    defer tar.freeEntries(std.testing.allocator, files);
    try std.testing.expectEqualStrings("hi", files[0].data);
}

test "parseDeb decodes xz and bzip2 compressed tar members" {
    const control = "Package: compressed\nVersion: 1.0\nArchitecture: all\n";
    const ctrl = try controlTar(std.testing.allocator, control);
    defer std.testing.allocator.free(ctrl);
    var data_entries = [_]tar.Entry{.{ .name = "./usr/bin/tool", .data = "binary", .mode = 0o100755 }};
    const data = try tar.build(std.testing.allocator, &data_entries);
    defer std.testing.allocator.free(data);

    const ctrl_xz = try xz.compress(std.testing.allocator, ctrl);
    defer std.testing.allocator.free(ctrl_xz);
    const deb_xz = try dpkg.buildAr(std.testing.allocator, &.{
        .{ .name = "debian-binary", .data = "2.0\n" },
        .{ .name = "control.tar.xz", .data = ctrl_xz },
        .{ .name = "data.tar", .data = data },
    });
    defer std.testing.allocator.free(deb_xz);
    const parsed_xz = try dpkg.parseDeb(std.testing.allocator, deb_xz);
    defer dpkg.freeDeb(std.testing.allocator, parsed_xz);
    try std.testing.expectEqualStrings("compressed", parsed_xz.control.package);
    try std.testing.expectEqualStrings("1.0", parsed_xz.control.version);
    const files_xz = try dpkg.dataEntries(std.testing.allocator, parsed_xz);
    defer tar.freeEntries(std.testing.allocator, files_xz);
    try std.testing.expectEqualStrings("binary", files_xz[0].data);

    const ctrl_bz2 = try bzip2.compress(std.testing.allocator, ctrl, 9);
    defer std.testing.allocator.free(ctrl_bz2);
    const deb_bz2 = try dpkg.buildAr(std.testing.allocator, &.{
        .{ .name = "debian-binary", .data = "2.0\n" },
        .{ .name = "control.tar.bz2", .data = ctrl_bz2 },
        .{ .name = "data.tar", .data = data },
    });
    defer std.testing.allocator.free(deb_bz2);
    const parsed_bz2 = try dpkg.parseDeb(std.testing.allocator, deb_bz2);
    defer dpkg.freeDeb(std.testing.allocator, parsed_bz2);
    try std.testing.expectEqualStrings("compressed", parsed_bz2.control.package);
}

test "ar rejects bad magic, trailer and truncation" {
    const members = [_]dpkg.Member{.{ .name = "x", .data = "y" }};
    const archive = try dpkg.buildAr(std.testing.allocator, &members);
    defer std.testing.allocator.free(archive);
    const bad = try std.testing.allocator.dupe(u8, archive);
    defer std.testing.allocator.free(bad);
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, dpkg.parseAr(std.testing.allocator, bad));
    bad[0] = '!';
    bad[8 + 58] = 'X'; // header trailer must be "`\n"
    try std.testing.expectError(error.CorruptHeader, dpkg.parseAr(std.testing.allocator, bad));
    try std.testing.expectError(error.Truncated, dpkg.parseAr(std.testing.allocator, archive[0..20]));
}
