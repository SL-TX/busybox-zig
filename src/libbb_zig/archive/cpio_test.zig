//! Tests for the cpio "newc" helper.

const std = @import("std");
const cpio = @import("libbb_zig").archive.cpio;

test "cpio newc round trip with files, symlink and permissions" {
    var entries = std.ArrayList(cpio.Entry).empty;
    defer entries.deinit(std.testing.allocator);
    try entries.append(std.testing.allocator, .{ .name = "a.txt", .data = "hello cpio", .mode = 0o100644 });
    try entries.append(std.testing.allocator, .{ .name = "dir/b.txt", .data = "second", .mode = 0o100600 });
    try entries.append(std.testing.allocator, .{ .name = "dir/link", .data = "", .mode = 0o120777, .nlink = 1 });

    const archive = try cpio.build(std.testing.allocator, entries.items);
    defer std.testing.allocator.free(archive);
    const parsed = try cpio.parse(std.testing.allocator, archive);
    defer cpio.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("a.txt", parsed[0].name);
    try std.testing.expectEqualStrings("hello cpio", parsed[0].data);
    try std.testing.expectEqual(@as(u32, 0o100644), parsed[0].mode);
    try std.testing.expectEqualStrings("dir/b.txt", parsed[1].name);
    try std.testing.expectEqual(@as(u32, 0o120777), parsed[2].mode);
}

test "cpio round trip with a long name" {
    const name = "very/deep/" ++ "abcdefghij" ++ "/another-dir/" ++ "file-with-a-long-name.txt";
    var entries = [_]cpio.Entry{.{ .name = name, .data = "payload" }};
    const archive = try cpio.build(std.testing.allocator, &entries);
    defer std.testing.allocator.free(archive);
    const parsed = try cpio.parse(std.testing.allocator, archive);
    defer cpio.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings(name, parsed[0].name);
}

test "cpio rejects corrupt magic and truncated archives" {
    var entries = [_]cpio.Entry{.{ .name = "f", .data = "data" }};
    const archive = try cpio.build(std.testing.allocator, &entries);
    defer std.testing.allocator.free(archive);
    const bad = try std.testing.allocator.dupe(u8, archive);
    defer std.testing.allocator.free(bad);
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, cpio.parse(std.testing.allocator, bad));
    try std.testing.expectError(error.Truncated, cpio.parse(std.testing.allocator, archive[0..50]));
    try std.testing.expectError(error.Truncated, cpio.parse(std.testing.allocator, archive[0 .. archive.len - 20]));
}

test "cpio round trip through a real file under /tmp/opencode" {
    const path = "/tmp/opencode/task19-fixtures/roundtrip.cpio";
    var entries = [_]cpio.Entry{.{ .name = "data.bin", .data = &.{ 0, 1, 2, 3, 255 } }};
    const archive = try cpio.build(std.testing.allocator, &entries);
    defer std.testing.allocator.free(archive);
    const f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, archive);
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    const parsed = try cpio.parse(std.testing.allocator, content);
    defer cpio.freeEntries(std.testing.allocator, parsed);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 255 }, parsed[0].data);
}
