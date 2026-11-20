const std = @import("std");
const u = @import("libbb_zig").util;

const linux = std.os.linux;
const base = "/tmp/opencode/bb-util-tree";

fn mkdir(path: []const u8) void {
    var z: [256:0]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    _ = linux.mkdir(@ptrCast(&z), 0o755);
}

fn writeFile(path: []const u8) void {
    var z: [256:0]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = linux.open(@ptrCast(&z), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = linux.close(@intCast(fd));
}

const CollectCtx = struct {
    paths: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
};

fn collect(path: []const u8, is_dir: bool, ctx: ?*anyopaque) u.Action {
    const c: *CollectCtx = @ptrCast(@alignCast(ctx.?));
    const suffix = if (is_dir) "/" else "";
    c.paths.append(c.allocator, std.fmt.allocPrint(c.allocator, "{s}{s}", .{ path, suffix }) catch return .abort) catch return .abort;
    return .continue_walk;
}

test "recursiveAction visits every entry" {
    _ = linux.rmdir(base ++ "/sub");
    _ = linux.unlink(base ++ "/a.txt");
    _ = linux.unlink(base ++ "/sub/b.txt");
    _ = linux.rmdir(base);

    mkdir(base);
    mkdir(base ++ "/sub");
    writeFile(base ++ "/a.txt");
    writeFile(base ++ "/sub/b.txt");

    var ctx = CollectCtx{ .paths = .empty, .allocator = std.testing.allocator };
    defer {
        for (ctx.paths.items) |p| std.testing.allocator.free(p);
        ctx.paths.deinit(std.testing.allocator);
    }
    try u.recursiveAction(std.testing.allocator, base, collect, &ctx);

    var found_a = false;
    var found_b = false;
    for (ctx.paths.items) |p| {
        if (std.mem.endsWith(u8, p, "a.txt")) found_a = true;
        if (std.mem.endsWith(u8, p, "b.txt")) found_b = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);

    _ = linux.unlink(base ++ "/sub/b.txt");
    _ = linux.unlink(base ++ "/a.txt");
    _ = linux.rmdir(base ++ "/sub");
    _ = linux.rmdir(base);
}

test "getopt32 parses flags and arguments" {
    const argv = [_][]const u8{ "prog", "-n", "5", "-e", "file" };
    const res = try u.getopt32(std.testing.allocator, &argv, "n:e");
    defer std.testing.allocator.free(res.args);
    // 'e' is the second flag char -> bit 1
    try std.testing.expect(res.flags & (@as(u64, 1) << 1) != 0);
    try std.testing.expectEqualStrings("5", res.optarg.?);
    try std.testing.expectEqual(@as(usize, 1), res.args.len);
    try std.testing.expectEqualStrings("file", res.args[0]);
}

test "is_directory and executable" {
    try std.testing.expect(u.is_directory("/tmp"));
    try std.testing.expect(!u.is_directory("/etc/passwd"));
    try std.testing.expect(u.executable("/bin/sh"));
    try std.testing.expect(!u.executable("/etc/passwd"));
}

test "find_mount_point finds the longest matching mount" {
    const mp = u.find_mount_point(std.testing.allocator, "/proc/self/status") catch null;
    defer if (mp) |m| std.testing.allocator.free(m);
    try std.testing.expect(mp != null);
    try std.testing.expectEqualStrings("/proc", mp.?);
}
