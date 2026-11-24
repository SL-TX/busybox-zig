//! Tests for mtab parsing/erasing using a temp file instead of /etc/mtab.

const std = @import("std");
const bb = @import("libbb_zig");

const path = "/tmp/opencode/bb-mtab-test.txt";

const sample =
    "tmpfs /tmp tmpfs rw,nosuid 0 0\n" ++
    "/dev/sda1 / ext4 rw 0 1\n" ++
    "none /proc proc rw 0 0\n" ++
    "mydev /mnt/mydev ext4 rw 0 0\n";

fn cleanup() void {
    bb.file.removeFile(path, .{ .force = true }) catch {};
}

fn writeSample() !void {
    cleanup();
    const fd = try bb.io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer bb.io.close(fd) catch {};
    try bb.io.writeAll(fd, sample);
}

test "readMountTable parses mtab lines" {
    try writeSample();
    defer cleanup();

    const entries = try bb.mtab.readMountTable(std.testing.allocator, path);
    defer bb.mtab.freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("tmpfs", entries[0].fsname);
    try std.testing.expectEqualStrings("/tmp", entries[0].dir);
    try std.testing.expectEqualStrings("rw,nosuid", entries[0].opts);
    try std.testing.expectEqual(@as(i32, 0), entries[0].freq);
    try std.testing.expectEqual(@as(i32, 1), entries[1].passno);
}

test "eraseMtab removes entries by device name or mount point" {
    try writeSample();
    defer cleanup();

    try bb.mtab.eraseMtab(std.testing.allocator, path, "/mnt/mydev");
    const entries = try bb.mtab.readMountTable(std.testing.allocator, path);
    defer bb.mtab.freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    for (entries) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.fsname, "mydev"));
    }
}
