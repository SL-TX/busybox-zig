const std = @import("std");
const linux = std.os.linux;
const fo = @import("coreutils");

fn zpath(path: []const u8, buf: *[512:0]u8) []const u8 {
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return path;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var zb: [512:0]u8 = undefined;
    _ = zpath(path, &zb);
    const rc = linux.open(@ptrCast(&zb), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < data.len) done += linux.write(fd, data.ptr + done, data.len - done);
}

fn readFile(path: []const u8, buf: []u8) ![]const u8 {
    var zb: [512:0]u8 = undefined;
    _ = zpath(path, &zb);
    const rc = linux.open(@ptrCast(&zb), .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    return buf[0..n];
}

test "copyFile copies all bytes" {
    const src = "/tmp/opencode/bb-fileops-src.txt";
    const dst = "/tmp/opencode/bb-fileops-dst.txt";
    try writeFile(src, "payload");
    try fo.copyFile(src, dst);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("payload", try readFile(dst, &buf));
    try fo.removePath(src);
    try fo.removePath(dst);
}

test "mkdirP creates nested directories" {
    const dir = "/tmp/opencode/bb-fileops-a/b/c";
    try fo.mkdirP(dir);
    try std.testing.expect(fo.pathIsDir(dir));
    _ = linux.rmdir("/tmp/opencode/bb-fileops-a/b/c");
    _ = linux.rmdir("/tmp/opencode/bb-fileops-a/b");
    _ = linux.rmdir("/tmp/opencode/bb-fileops-a");
}

test "renamePath moves a file" {
    const src = "/tmp/opencode/bb-fileops-mv-src.txt";
    const dst = "/tmp/opencode/bb-fileops-mv-dst.txt";
    try writeFile(src, "moved");
    try fo.renamePath(src, dst);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("moved", try readFile(dst, &buf));
    try fo.removePath(dst);
}
