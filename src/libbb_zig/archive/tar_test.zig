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

test "tar handles long names via USTAR prefix and GNU longname records" {
    const prefix_name = "aaaaaaaaaa/bbbbbbbbbb/cccccccccc/dddddddddd/eeeeeeeeee.txt";
    const long_name = "very/long/" ++ "abcdefghij" ++ "/another/" ++ "0123456789" ++ "/final-file-name.txt";
    var entries = std.ArrayList(tar.Entry).empty;
    defer entries.deinit(std.testing.allocator);
    try entries.append(std.testing.allocator, .{ .name = prefix_name, .data = "p", .typeflag = '0' });
    try entries.append(std.testing.allocator, .{ .name = long_name, .data = "l", .typeflag = '0' });
    const archive = try tar.build(std.testing.allocator, entries.items);
    defer std.testing.allocator.free(archive);
    const parsed = try tar.parse(std.testing.allocator, archive);
    defer tar.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings(prefix_name, parsed[0].name);
    try std.testing.expectEqualStrings(long_name, parsed[1].name);
    try std.testing.expectEqualStrings("l", parsed[1].data);
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
