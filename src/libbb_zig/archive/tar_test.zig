//! Tests for the tar (USTAR/GNU/PAX) helper.

const std = @import("std");
const tar = @import("libbb_zig").archive.tar;

test "tar round trip with regular files, symlink and permissions" {
    var entries = std.ArrayList(tar.Entry).empty;
    defer entries.deinit(std.testing.allocator);
    try entries.append(std.testing.allocator, .{
        .name = "dir/file.txt",
        .data = "contents",
        .mode = 0o100644,
        .typeflag = '0',
    });
    try entries.append(std.testing.allocator, .{
        .name = "dir/link.txt",
        .linkname = "file.txt",
        .mode = 0o120777,
        .typeflag = '2',
    });
    try entries.append(std.testing.allocator, .{
        .name = "dir",
        .mode = 0o040755,
        .typeflag = '5',
    });

    const archive = try tar.build(std.testing.allocator, entries.items);
    defer std.testing.allocator.free(archive);
    const parsed = try tar.parse(std.testing.allocator, archive);
    defer tar.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("dir/file.txt", parsed[0].name);
    try std.testing.expectEqualStrings("contents", parsed[0].data);
    try std.testing.expectEqual(@as(u32, 0o100644), parsed[0].mode);
    try std.testing.expectEqualStrings("file.txt", parsed[1].linkname);
    try std.testing.expectEqual(@as(u8, '2'), parsed[1].typeflag);
    try std.testing.expectEqual(@as(u32, 0o040755), parsed[2].mode);
}

test "tar splits the USTAR prefix for a 122-byte name" {
    // The only slash sits at offset 120, beyond the 100-byte name field:
    // prefix = 120 bytes, basename = 1 byte.
    var name_buf: [122]u8 = undefined;
    @memset(name_buf[0..120], 'a');
    name_buf[120] = '/';
    name_buf[121] = 'b';
    const name = &name_buf;

    var entries = [_]tar.Entry{.{ .name = name, .data = "prefixed", .typeflag = '0' }};
    const archive = try tar.build(std.testing.allocator, &entries);
    defer std.testing.allocator.free(archive);
    try std.testing.expectEqual(@as(u8, '0'), archive[156]); // no GNU 'L' record
    try std.testing.expectEqualSlices(u8, name[0..120], archive[345 .. 345 + 120]);
    try std.testing.expectEqualStrings("b", archive[0..1]);

    const parsed = try tar.parse(std.testing.allocator, archive);
    defer tar.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualSlices(u8, name, parsed[0].name);
    try std.testing.expectEqualStrings("prefixed", parsed[0].data);
}

test "tar emits a GNU longname record when no USTAR split fits" {
    var name_buf: [130]u8 = undefined;
    @memset(&name_buf, 'x'); // single component, no slash
    const name = &name_buf;
    var entries = [_]tar.Entry{.{ .name = name, .data = "long", .typeflag = '0' }};
    const archive = try tar.build(std.testing.allocator, &entries);
    defer std.testing.allocator.free(archive);
    try std.testing.expectEqual(@as(u8, 'L'), archive[156]); // GNU longname header

    const parsed = try tar.parse(std.testing.allocator, archive);
    defer tar.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualSlices(u8, name, parsed[0].name);
    try std.testing.expectEqualStrings("long", parsed[0].data);
}

test "tar honours a PAX path record" {
    const pax_path = "pax/directory/very-long-name.txt";
    var rec_buf: [256]u8 = undefined;
    var len: usize = pax_path.len + 7;
    var rec: []const u8 = undefined;
    while (true) {
        rec = try std.fmt.bufPrint(&rec_buf, "{d} path={s}\n", .{ len, pax_path });
        if (rec.len == len) break;
        len = rec.len;
    }
    const pax = try tar.build(std.testing.allocator, &.{
        .{ .name = "PaxHeaders", .data = rec, .typeflag = 'x' },
    });
    defer std.testing.allocator.free(pax);
    const plain = try tar.build(std.testing.allocator, &.{
        .{ .name = "short.txt", .data = "pax payload", .typeflag = '0' },
    });
    defer std.testing.allocator.free(plain);

    const joined = try std.testing.allocator.alloc(u8, 1024 + plain.len);
    defer std.testing.allocator.free(joined);
    @memcpy(joined[0..1024], pax[0..1024]);
    @memcpy(joined[1024..], plain);

    const parsed = try tar.parse(std.testing.allocator, joined);
    defer tar.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings(pax_path, parsed[0].name);
    try std.testing.expectEqualStrings("pax payload", parsed[0].data);
}

test "tar rejects malformed PAX records without panicking" {
    // "1 " declares a one-byte record but has no content after the space;
    // slicing used to start past the end and abort the process.
    const archive = try tar.build(std.testing.allocator, &.{
        .{ .name = "pax", .data = "1 ", .typeflag = 'x' },
    });
    defer std.testing.allocator.free(archive);
    try std.testing.expectError(error.CorruptHeader, tar.parse(std.testing.allocator, archive));
}

test "tar preserves GNU sparse extent metadata" {
    var entries = std.ArrayList(tar.Entry).empty;
    defer entries.deinit(std.testing.allocator);
    try entries.append(std.testing.allocator, .{
        .name = "sparse.img",
        .data = "ABCD",
        .typeflag = 'S',
        .realsize = 0x10000,
        .sparse = &.{.{ .offset = 0, .length = 4 }},
    });
    const archive = try tar.build(std.testing.allocator, entries.items);
    defer std.testing.allocator.free(archive);
    const parsed = try tar.parse(std.testing.allocator, archive);
    defer tar.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(u8, 'S'), parsed[0].typeflag);
    try std.testing.expectEqual(@as(u64, 0x10000), parsed[0].realsize);
    try std.testing.expectEqual(@as(usize, 1), parsed[0].sparse.len);
    try std.testing.expectEqual(@as(u64, 0), parsed[0].sparse[0].offset);
    try std.testing.expectEqual(@as(u64, 4), parsed[0].sparse[0].length);
}

test "tar rejects corrupt headers and truncated archives" {
    var entries = [_]tar.Entry{.{ .name = "a", .data = "payload", .typeflag = '0' }};
    const archive = try tar.build(std.testing.allocator, &entries);
    defer std.testing.allocator.free(archive);

    const bad = try std.testing.allocator.dupe(u8, archive);
    defer std.testing.allocator.free(bad);
    bad[148] ^= 0xff; // checksum digit
    const rejected = tar.parse(std.testing.allocator, bad) catch |err| err;
    try std.testing.expectEqual(error.CorruptHeader, rejected);

    try std.testing.expectError(error.Truncated, tar.parse(std.testing.allocator, archive[0..100]));
    try std.testing.expectError(error.Truncated, tar.parse(std.testing.allocator, archive[0..600]));
}

test "tar round trip through a real file under /tmp/opencode" {
    const path = "/tmp/opencode/task19-fixtures/roundtrip.tar";
    var entries = [_]tar.Entry{.{ .name = "file", .data = "real file contents", .mode = 0o100600, .typeflag = '0' }};
    const archive = try tar.build(std.testing.allocator, &entries);
    defer std.testing.allocator.free(archive);
    const f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, archive);
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    const parsed = try tar.parse(std.testing.allocator, content);
    defer tar.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqualStrings("real file contents", parsed[0].data);
}
