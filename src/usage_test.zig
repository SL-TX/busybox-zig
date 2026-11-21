//! Task 4 tests: exact per-applet usage text and `--help` interception.

const std = @import("std");
const linux = std.os.linux;
const main = @import("main.zig");
const meta = @import("generated/meta.zig");
const usage = @import("generated/usage.zig");

const Capture = struct {
    list: *std.ArrayList(u8),

    pub fn writeAll(self: Capture, bytes: []const u8) void {
        self.list.appendSlice(std.testing.allocator, bytes) catch {};
    }
};

const Result = struct {
    code: u8,
    out: []u8,
    err: []u8,
};

fn readCaptured(fd: linux.fd_t) ![]u8 {
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (n == 0) break;
        try list.appendSlice(std.testing.allocator, buf[0..n]);
    }
    return list.toOwnedSlice(std.testing.allocator);
}

fn invoke(args: []const []const u8) Result {
    // The meta-CLI writes through the Capture writers; implemented applets and
    // stubs write directly to fds 1/2. Redirect the fds to scratch files so
    // both kinds of output are captured and the test runner's stdio survives.
    const out_path = "/tmp/opencode/bb-usage-stdout.txt";
    const err_path = "/tmp/opencode/bb-usage-stderr.txt";
    const out_fd: linux.fd_t = @intCast(linux.open(
        out_path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
        0o600,
    ));
    const err_fd: linux.fd_t = @intCast(linux.open(
        err_path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
        0o600,
    ));
    const saved_out: linux.fd_t = @intCast(linux.dup(1));
    const saved_err: linux.fd_t = @intCast(linux.dup(2));
    _ = linux.dup2(out_fd, 1);
    _ = linux.dup2(err_fd, 2);
    defer {
        _ = linux.dup2(saved_out, 1);
        _ = linux.dup2(saved_err, 2);
        _ = linux.close(out_fd);
        _ = linux.close(err_fd);
        _ = linux.close(saved_out);
        _ = linux.close(saved_err);
    }

    var meta_out: std.ArrayList(u8) = .empty;
    var meta_err: std.ArrayList(u8) = .empty;
    defer meta_out.deinit(std.testing.allocator);
    defer meta_err.deinit(std.testing.allocator);
    const code = main.run(std.testing.allocator, args, Capture{ .list = &meta_out }, Capture{ .list = &meta_err });
    const fd_out = readCaptured(out_fd) catch unreachable;
    const fd_err = readCaptured(err_fd) catch unreachable;
    defer std.testing.allocator.free(fd_out);
    defer std.testing.allocator.free(fd_err);
    return .{
        .code = code,
        .out = std.mem.concat(std.testing.allocator, u8, &.{ meta_out.items, fd_out }) catch unreachable,
        .err = std.mem.concat(std.testing.allocator, u8, &.{ meta_err.items, fd_err }) catch unreachable,
    };
}

fn freeResult(r: Result) void {
    std.testing.allocator.free(r.out);
    std.testing.allocator.free(r.err);
}

fn goldenPath(name: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "tests/parity/usage/{s}.txt", .{name});
}

fn readGolden(name: []const u8) ![]u8 {
    const path = try goldenPath(name);
    defer std.testing.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        @as(std.Io.Limit, @enumFromInt(1 << 20)),
    );
}

fn expectedHelp(name: []const u8) ![]u8 {
    const body = try readGolden(name);
    defer std.testing.allocator.free(body);
    return std.mem.concat(std.testing.allocator, u8, &.{ meta.first_line, body });
}

test "cat --help matches reference golden" {
    const golden = try readGolden("cat");
    defer std.testing.allocator.free(golden);
    try std.testing.expectEqualStrings(golden, usage.usageFor("cat").?);
}

test "busybox --help APPLET emits the composed reference text" {
    for ([_][]const u8{ "cat", "ls", "sh", "getopt", "[" }) |name| {
        const r = invoke(&.{ "busybox", "--help", name });
        defer freeResult(r);
        const expected = try expectedHelp(name);
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqual(@as(u8, 0), r.code);
        try std.testing.expectEqualStrings(expected, r.out);
        try std.testing.expectEqual(@as(usize, 0), r.err.len);
    }
}

test "APPLET --help via the multicall form emits the same text" {
    for ([_][]const u8{ "cat", "ls", "grep" }) |name| {
        const r = invoke(&.{ "busybox", name, "--help" });
        defer freeResult(r);
        const expected = try expectedHelp(name);
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqual(@as(u8, 0), r.code);
        try std.testing.expectEqualStrings(expected, r.out);
    }
}

test "test --help is a normal argument, not help" {
    // POSIX: "test --help" is no different from "test --foo". The applet is a
    // stub in this build, so only assert that the meta help was not printed.
    const r = invoke(&.{ "busybox", "test", "--help" });
    defer freeResult(r);
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.out, 1, " multi-call binary."));
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.out, 1, "Usage: test"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.err, 1, " multi-call binary."));
}

test "echo --help prints the literal argument" {
    const r = invoke(&.{ "busybox", "echo", "--help" });
    defer freeResult(r);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("--help\n", r.out);
}

test "special-case applets keep their own exit status" {
    const cases = [_]struct { name: []const u8, code: u8 }{
        .{ .name = "true", .code = 0 },
        .{ .name = "false", .code = 1 },
    };
    for (cases) |c| {
        const r = invoke(&.{ "busybox", c.name, "--help" });
        defer freeResult(r);
        try std.testing.expectEqual(c.code, r.code);
    }
}

test "usageFor covers source-fallback and no-help applets too" {
    for ([_][]const u8{ "tc", "ar", "unit", "bash", "test", "echo", "busybox" }) |name| {
        const body = usage.usageFor(name) orelse {
            std.debug.print("missing usageFor for {s}\n", .{name});
            return error.MissingUsage;
        };
        // `busybox` reuses the no-args help, which has no leading blank line;
        // every other body starts with the blank line after the banner.
        try std.testing.expect(body.len > 0);
    }
    try std.testing.expect(usage.usageFor("no_such_applet_xyz") == null);
}
