//! Tests for libbb filesystem helpers: makeDirectory, removeFile, findMountPoint.

const std = @import("std");
const bb = @import("libbb_zig");
const linux = std.os.linux;

const base = "/tmp/opencode/bb-file-test";

fn zpath(path: []const u8, buf: *[512:0]u8) ! [*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn mkdir(path: []const u8) void {
    var z: [512:0]u8 = undefined;
    const p = zpath(path, &z) catch return;
    _ = linux.mkdir(p, 0o755);
}

fn writeFile(path: []const u8, content: []const u8) void {
    var z: [512:0]u8 = undefined;
    const p = zpath(path, &z) catch return;
    const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    _ = linux.write(fd, content.ptr, content.len);
}

fn exists(path: []const u8) bool {
    var z: [512:0]u8 = undefined;
    const p = zpath(path, &z) catch return false;
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, 0, .BASIC_STATS, &st);
    return linux.errno(rc) == .SUCCESS;
}

fn clean() void {
    bb.file.removeFile(base, .{ .force = true, .recurse = true }) catch {};
}

test "makeDirectory creates nested parents and is idempotent" {
    clean();
    defer clean();

    const nested = base ++ "/a/b/c";
    try bb.file.makeDirectory(nested, 0o755);
    try std.testing.expect(exists(nested));
    try std.testing.expect(exists(base ++ "/a/b"));
    // Calling it again on an existing dir must succeed.
    try bb.file.makeDirectory(nested, 0o755);
}

test "makeDirectory honours an explicit mode on the final component" {
    clean();
    defer clean();

    const dir = base ++ "/mode";
    try bb.file.makeDirectory(dir, 0o700);
    var z: [512:0]u8 = undefined;
    const p = try zpath(dir, &z);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, 0, .BASIC_STATS, &st);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.mode & 0o7777)));
}

test "removeFile unlinks a regular file and force ignores ENOENT" {
    clean();
    defer clean();

    mkdir(base);
    const f = base ++ "/one.txt";
    writeFile(f, "hello");
    try std.testing.expect(exists(f));
    try bb.file.removeFile(f, .{ .force = true });
    try std.testing.expect(!exists(f));
    // Force makes a second removal a no-op.
    try bb.file.removeFile(f, .{ .force = true });
}

test "removeFile refuses a directory without recurse" {
    clean();
    defer clean();

    mkdir(base);
    const d = base ++ "/sub";
    mkdir(d);
    try std.testing.expectError(error.IsDirectory, bb.file.removeFile(d, .{ .force = true }));
}

test "removeFile recursively removes a tree" {
    clean();

    mkdir(base);
    mkdir(base ++ "/sub");
    writeFile(base ++ "/top.txt", "top");
    writeFile(base ++ "/sub/deep.txt", "deep");
    try std.testing.expect(exists(base ++ "/sub/deep.txt"));

    try bb.file.removeFile(base, .{ .force = true, .recurse = true });
    try std.testing.expect(!exists(base));
}

test "findMountPoint returns the longest matching mount prefix" {
    const mp = bb.file.findMountPoint("/proc/self/status");
    try std.testing.expect(mp != null);
    try std.testing.expectEqualStrings("/proc", mp.?);
}

test "findMountPoint returns null for a path with no matching mount" {
    const mp = bb.file.findMountPoint("/definitely-not-a-mount-xyz/file");
    try std.testing.expect(mp == null);
}
