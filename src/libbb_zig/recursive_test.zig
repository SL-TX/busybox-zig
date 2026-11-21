//! Tests for the recursive directory walker.

const std = @import("std");
const bb = @import("libbb_zig");
const linux = std.os.linux;

const base = "/tmp/opencode/bb-recursive-test";
const Action = bb.recursive.Action;

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

fn writeFile(path: []const u8) void {
    var z: [512:0]u8 = undefined;
    const p = zpath(path, &z) catch return;
    const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    _ = linux.close(@intCast(rc));
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

fn setup() void {
    clean();
    mkdir(base);
    mkdir(base ++ "/sub");
    mkdir(base ++ "/sub/deeper");
    writeFile(base ++ "/a.txt");
    writeFile(base ++ "/sub/b.txt");
    writeFile(base ++ "/sub/deeper/c.txt");
}

const CollectCtx = struct {
    a: std.mem.Allocator,
    files: std.ArrayList([]const u8) = .empty,
    dirs: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *CollectCtx) void {
        for (self.files.items) |p| self.a.free(p);
        for (self.dirs.items) |p| self.a.free(p);
        self.files.deinit(self.a);
        self.dirs.deinit(self.a);
    }
};

fn collect(path: []const u8, is_dir: bool, ctx: ?*anyopaque) Action {
    const c: *CollectCtx = @ptrCast(@alignCast(ctx.?));
    const dst = if (is_dir) &c.dirs else &c.files;
    dst.append(c.a, c.a.dupe(u8, path) catch return .abort) catch return .abort;
    return .ok;
}

test "recursiveAction visits every file and directory" {
    setup();
    defer clean();

    var ctx = CollectCtx{ .a = std.testing.allocator };
    defer ctx.deinit();

    try bb.recursive.recursiveAction(base, .{ .allocator = std.testing.allocator }, .{ .func = collect, .ctx = &ctx });

    try std.testing.expectEqual(@as(usize, 3), ctx.files.items.len);
    try std.testing.expectEqual(@as(usize, 3), ctx.dirs.items.len); // base, sub, deeper
    var found = false;
    for (ctx.files.items) |p| {
        if (std.mem.endsWith(u8, p, "c.txt")) found = true;
    }
    try std.testing.expect(found);
}

const SkipCtx = struct { seen: usize = 0 };

fn skipSub(path: []const u8, is_dir: bool, ctx: ?*anyopaque) Action {
    const c: *SkipCtx = @ptrCast(@alignCast(ctx.?));
    c.seen += 1;
    if (is_dir and std.mem.endsWith(u8, path, "/sub")) return .skip_dir;
    return .ok;
}

test "recursiveAction skip_dir prevents descent" {
    setup();
    defer clean();

    var ctx = SkipCtx{};
    try bb.recursive.recursiveAction(base, .{ .allocator = std.testing.allocator }, .{ .func = skipSub, .ctx = &ctx });
    // base + sub (skipped) + a.txt = 3 callbacks; deeper and its file are not visited.
    try std.testing.expectEqual(@as(usize, 3), ctx.seen);
}

const AbortCtx = struct { seen: usize = 0 };

fn abortEarly(path: []const u8, is_dir: bool, ctx: ?*anyopaque) Action {
    _ = path;
    _ = is_dir;
    const c: *AbortCtx = @ptrCast(@alignCast(ctx.?));
    c.seen += 1;
    return .abort;
}

test "recursiveAction abort stops traversal" {
    setup();
    defer clean();

    var ctx = AbortCtx{};
    try bb.recursive.recursiveAction(base, .{ .allocator = std.testing.allocator }, .{ .func = abortEarly, .ctx = &ctx });
    try std.testing.expectEqual(@as(usize, 1), ctx.seen);
}

const OrderCtx = struct { a: std.mem.Allocator, names: std.ArrayList([]const u8) = .empty };

fn orderCb(path: []const u8, is_dir: bool, ctx: ?*anyopaque) Action {
    _ = is_dir;
    const c: *OrderCtx = @ptrCast(@alignCast(ctx.?));
    const name = std.fs.path.basename(path);
    c.names.append(c.a, c.a.dupe(u8, name) catch return .abort) catch return .abort;
    return .ok;
}

test "recursiveAction depth_first visits children before their parent" {
    setup();
    defer clean();

    var ctx = OrderCtx{ .a = std.testing.allocator };
    defer {
        for (ctx.names.items) |n| std.testing.allocator.free(n);
        ctx.names.deinit(std.testing.allocator);
    }
    try bb.recursive.recursiveAction(base, .{ .allocator = std.testing.allocator, .depth_first = true }, .{ .func = orderCb, .ctx = &ctx });
    // In depth-first mode 'sub' must appear after at least one of its children.
    var sub_idx: usize = 0;
    var child_idx: usize = std.math.maxInt(usize);
    for (ctx.names.items, 0..) |n, i| {
        if (std.mem.eql(u8, n, "sub")) sub_idx = i;
        if (std.mem.eql(u8, n, "b.txt")) child_idx = i;
    }
    try std.testing.expect(child_idx < sub_idx);
}
