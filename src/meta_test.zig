const std = @import("std");
const linux = std.os.linux;
const applets = @import("applets.zig");
const main = @import("main.zig");

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

fn invoke(args: []const []const u8) Result {
    // Implemented applets and stubs write directly to fds 1/2. Redirect those
    // fds while the applet runs so their output cannot corrupt the `zig build
    // test` runner's stdio protocol; our Capture writers still collect the
    // meta-CLI output.
    const saved_out: linux.fd_t = @intCast(linux.dup(1));
    const saved_err: linux.fd_t = @intCast(linux.dup(2));
    const devnull: linux.fd_t = @intCast(linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0));
    _ = linux.dup2(devnull, 1);
    _ = linux.dup2(devnull, 2);
    defer {
        _ = linux.dup2(saved_out, 1);
        _ = linux.dup2(saved_err, 2);
        _ = linux.close(devnull);
        _ = linux.close(saved_out);
        _ = linux.close(saved_err);
    }

    var out: std.ArrayList(u8) = .empty;
    var err: std.ArrayList(u8) = .empty;
    const code = main.run(std.testing.allocator, args, Capture{ .list = &out }, Capture{ .list = &err });
    return .{
        .code = code,
        .out = out.toOwnedSlice(std.testing.allocator) catch unreachable,
        .err = err.toOwnedSlice(std.testing.allocator) catch unreachable,
    };
}

fn freeResult(r: Result) void {
    std.testing.allocator.free(r.out);
    std.testing.allocator.free(r.err);
}

test "list has no internal helper names" {
    const names = try applets.appletNames(std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 411), names.len);
    for (names) |n| try std.testing.expect(!std.mem.eql(u8, n, "tls_aes"));
    var has_bracket = false;
    var has_busybox = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "[")) has_bracket = true;
        if (std.mem.eql(u8, n, "busybox")) has_busybox = true;
    }
    try std.testing.expect(has_bracket);
    // Reference gates the busybox applet on FEATURE_SH_STANDALONE, which is
    // disabled in the committed defconfig.
    if (!@import("config").CONFIG_FEATURE_SH_STANDALONE)
        try std.testing.expect(!has_busybox);
}

test "version is 1.39.0 banner only" {
    const r = invoke(&.{ "busybox", "--version" });
    defer freeResult(r);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.startsWith(u8, r.out, "BusyBox v1.39.0"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.out, 1, "multi-call binary"));
    try std.testing.expect(std.mem.endsWith(u8, r.out, "\n"));
}

test "list-full format has no leading slash" {
    const full = try applets.appletNamesFull(std.testing.allocator);
    defer std.testing.allocator.free(full);
    try std.testing.expectEqual(@as(usize, 411), full.len);
    try std.testing.expectEqualStrings("usr/bin/[", full[0]);
    var has_cat = false;
    for (full) |f| {
        try std.testing.expect(!std.mem.startsWith(u8, f, "/"));
        if (std.mem.eql(u8, f, "bin/cat")) has_cat = true;
    }
    try std.testing.expect(has_cat);
}

test "list and list-full are aligned by applet name" {
    const names = try applets.appletNames(std.testing.allocator);
    defer std.testing.allocator.free(names);
    const full = try applets.appletNamesFull(std.testing.allocator);
    defer std.testing.allocator.free(full);
    try std.testing.expectEqual(names.len, full.len);
    for (names, full) |name, f| {
        try std.testing.expect(std.mem.endsWith(u8, f, name));
        try std.testing.expect(f.len > name.len or std.mem.eql(u8, name, f));
    }
}

test "no-args output contains the multi-call banner" {
    const r = invoke(&.{"busybox"});
    defer freeResult(r);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.startsWith(u8, r.out, "BusyBox v1.39.0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, r.out, 1, " multi-call binary."));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Currently defined functions:") != null);
}

test "POSIX special cases are not intercepted as meta help" {
    const names = [_][]const u8{ "test", "true", "false", "echo", "[", "[[" };
    for (names) |name| {
        const r = invoke(&.{ "busybox", name, "--help" });
        defer freeResult(r);
        try std.testing.expect(!std.mem.containsAtLeast(u8, r.out, 1, " multi-call binary."));
        try std.testing.expect(!std.mem.containsAtLeast(u8, r.out, 1, "Currently defined functions:"));
        try std.testing.expect(!std.mem.containsAtLeast(u8, r.out, 1, "Usage: busybox"));
    }
}

test "special-case applets keep their own exit status" {
    const cases = [_]struct { name: []const u8, code: u8 }{
        .{ .name = "true", .code = 0 },
        .{ .name = "false", .code = 1 },
        .{ .name = "echo", .code = 0 },
    };
    for (cases) |c| {
        const r = invoke(&.{ "busybox", c.name, "--help" });
        defer freeResult(r);
        try std.testing.expectEqual(c.code, r.code);
    }
}

test "--help with an applet prints usage and does not run it" {
    const r = invoke(&.{ "busybox", "--help", "cat" });
    defer freeResult(r);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.startsWith(u8, r.out, "BusyBox v1.39.0"));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Usage: cat") != null);
}
