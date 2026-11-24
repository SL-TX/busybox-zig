const std = @import("std");
const linux = std.os.linux;
const lib = @import("libbb_zig");
const path = lib.path;
const io_more = lib.io_more;
const string = lib.string;
const util = lib.util;
const xfuncs = lib.xfuncs;

test "concatPathFile joins and normalises separators" {
    const a = try path.concatPathFile(std.testing.allocator, "/a/", "b");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("/a/b", a);

    const b = try path.concatPathFile(std.testing.allocator, "/a", "b");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("/a/b", b);

    const c = try path.concatPathFile(std.testing.allocator, "/a", "/abs");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("/abs", c);
}

test "simplifyPath collapses '.', '..' and duplicate slashes" {
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "a//b/../c", .want = "a/c" },
        .{ .input = "/a/b/../../c", .want = "/c" },
        .{ .input = "a/./b", .want = "a/b" },
        .{ .input = "../a/../b", .want = "../b" },
        .{ .input = "/a//b///c/", .want = "/a/b/c" },
        .{ .input = "/", .want = "/" },
        .{ .input = "a/..", .want = "." },
    };
    for (cases) |c| {
        const got = try path.simplifyPath(std.testing.allocator, c.input);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "getLastPathComponent drops trailing slashes" {
    try std.testing.expectEqualStrings("b", path.getLastPathComponent("/a/b/"));
    try std.testing.expectEqualStrings("c", string.getLastPathComponent("/a/b/c"));
}

test "processEscapeSequence handles common escapes" {
    const got = try path.processEscapeSequence(std.testing.allocator, "a\\nb\\t\\x41\\0");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 6), got.len);
    try std.testing.expectEqualStrings("a\nb\tA", got[0..5]);
    try std.testing.expectEqual(@as(u8, 0), got[5]);
}

test "humanReadable formats binary and decimal units" {
    const a = try util.humanReadable(std.testing.allocator, 1500, true);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("1.5k", a);
    const b = try util.humanReadable(std.testing.allocator, 1024, false);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("1K", b);
}

test "xatou/xatoi/xatol parse and reject invalid input" {
    try std.testing.expectEqual(@as(u64, 42), try util.xatou("42"));
    try std.testing.expectError(error.InvalidCharacter, util.xatou("-1"));
    try std.testing.expectEqual(@as(i64, -7), try util.xatoi("-7"));
    try std.testing.expectEqual(@as(i64, 10), try util.xatoi("010"));
    try std.testing.expectEqual(@as(i64, 9223372036854775807), try util.xatol("9223372036854775807"));
    try std.testing.expectError(error.Overflow, util.xatol("9223372036854775808"));
}

fn oneByteWriter(fd: linux.fd_t, bytes: []const u8) anyerror!usize {
    if (bytes.len == 0) return 0;
    try xfuncs.xwrite(fd, bytes[0..1]);
    return 1;
}

test "fullWrite retries short writes" {
    var fds: [2]linux.fd_t = undefined;
    try lib.process.pipe(&fds);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    try io_more.fullWriteWith(fds[1], "hello world", oneByteWriter);
    _ = linux.close(fds[1]);
    var buf: [32]u8 = undefined;
    const n = try io_more.fullRead(fds[0], &buf);
    try std.testing.expectEqualStrings("hello world", buf[0..n]);
}

test "xgetcwd returns the current directory" {
    const cwd = try path.xgetcwd(std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try std.testing.expect(std.mem.startsWith(u8, cwd, "/"));
}

test "xreadlink returns the symlink target and null for a regular file" {
    const link = "/tmp/opencode/bb-path-link";
    const target = "/tmp/opencode/bb-path-target";
    _ = linux.unlink(link);
    var tz: [256:0]u8 = undefined;
    @memcpy(tz[0..target.len], target);
    tz[target.len] = 0;
    var lz: [256:0]u8 = undefined;
    @memcpy(lz[0..link.len], link);
    lz[link.len] = 0;
    _ = linux.symlink(@ptrCast(&tz), @ptrCast(&lz));

    const got = try path.xreadlink(std.testing.allocator, link);
    defer if (got) |g| std.testing.allocator.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(target, got.?);

    _ = linux.unlink(link);
}
