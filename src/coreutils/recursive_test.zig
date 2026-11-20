const std = @import("std");
const cu = @import("coreutils");
const linux = std.os.linux;

const root = "/tmp/opencode/bb-recursive";

fn mkdir(path: []const u8) void {
    var z: [256:0]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    _ = linux.mkdir(@ptrCast(&z), 0o755);
}

fn writeFile(path: []const u8, data: []const u8) void {
    var z: [256:0]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = linux.open(@ptrCast(&z), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = linux.write(@intCast(fd), data.ptr, data.len);
    _ = linux.close(@intCast(fd));
}

fn exists(path: []const u8) bool {
    var z: [256:0]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = linux.open(@ptrCast(&z), .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

fn cleanup() void {
    _ = linux.unlink(root ++ "/sub/b.txt");
    _ = linux.unlink(root ++ "/a.txt");
    _ = linux.rmdir(root ++ "/sub");
    _ = linux.rmdir(root);
    _ = linux.unlink(root ++ "-copy/sub/b.txt");
    _ = linux.unlink(root ++ "-copy/a.txt");
    _ = linux.rmdir(root ++ "-copy/sub");
    _ = linux.rmdir(root ++ "-copy");
}

test "copyDirRecursive copies whole tree" {
    cleanup();
    mkdir(root);
    mkdir(root ++ "/sub");
    writeFile(root ++ "/a.txt", "A");
    writeFile(root ++ "/sub/b.txt", "B");

    try cu.copyDirRecursive(std.testing.allocator, root, root ++ "-copy");
    try std.testing.expect(exists(root ++ "-copy/a.txt"));
    try std.testing.expect(exists(root ++ "-copy/sub/b.txt"));
    cleanup();
}

test "removeRecursive removes whole tree" {
    cleanup();
    mkdir(root);
    mkdir(root ++ "/sub");
    writeFile(root ++ "/a.txt", "A");
    writeFile(root ++ "/sub/b.txt", "B");

    try cu.removeRecursive(std.testing.allocator, root);
    try std.testing.expect(!exists(root));
}
