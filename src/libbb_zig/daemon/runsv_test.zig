//! TDD tests for runit service-directory helpers (Task 25).
//! Only a directory under /tmp/opencode is created; no real service is run.

const std = @import("std");
const bb = @import("libbb_zig");
const runsv = bb.daemon.runsv;
const io = bb.io;

const BASE = "/tmp/opencode/bb-runsv-service";
const LOG = BASE ++ "/log";

fn touch(path: []const u8) !void {
    const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    try io.close(fd);
}

test "parseStatus decodes state and control flags" {
    const st = try runsv.parseStatus("finish, paused, got TERM, want down\n");
    try std.testing.expectEqual(runsv.ServiceState.finish, st.state);
    try std.testing.expect(st.ctrl.paused);
    try std.testing.expect(st.ctrl.got_term);
    try std.testing.expect(st.ctrl.want_down);
    try std.testing.expect(!st.ctrl.want_exit);
}

test "parseStatus accepts a bare state and rejects unknown words" {
    const down = try runsv.parseStatus("down\n");
    try std.testing.expectEqual(runsv.ServiceState.down, down.state);
    try std.testing.expect(!down.ctrl.paused);
    try std.testing.expectError(error.MalformedStatus, runsv.parseStatus("sideways"));
    try std.testing.expectError(error.MalformedStatus, runsv.parseStatus(""));
}

test "formatStatus round-trips with parseStatus" {
    var buf: [128]u8 = undefined;
    const text = try runsv.formatStatus(.{
        .state = .run,
        .ctrl = .{ .paused = true, .want_exit = true },
    }, &buf);
    try std.testing.expectEqualStrings("run, paused, want exit\n", text);
    const back = try runsv.parseStatus(text);
    try std.testing.expectEqual(runsv.ServiceState.run, back.state);
    try std.testing.expect(back.ctrl.paused);
    try std.testing.expect(back.ctrl.want_exit);
}

test "scanServiceDir discovers run, finish, down and the log runner" {
    io.mkdir(BASE, 0o755) catch {};
    io.mkdir(LOG, 0o755) catch {};
    defer {
        io.unlink(BASE ++ "/run") catch {};
        io.unlink(BASE ++ "/finish") catch {};
        io.unlink(BASE ++ "/check") catch {};
        io.unlink(BASE ++ "/down") catch {};
        io.unlink(LOG ++ "/run") catch {};
        io.rmdir(LOG) catch {};
        io.rmdir(BASE) catch {};
    }
    try touch(BASE ++ "/run");
    try touch(BASE ++ "/finish");
    try touch(BASE ++ "/check");
    try touch(BASE ++ "/down");
    try touch(LOG ++ "/run");

    const service = try runsv.scanServiceDir(std.testing.allocator, BASE);
    defer std.testing.allocator.free(service.path);
    try std.testing.expect(service.files.run);
    try std.testing.expect(service.files.finish);
    try std.testing.expect(service.files.check);
    try std.testing.expect(service.files.down);
    try std.testing.expect(service.files.log_run);
}

test "scanServiceDir reports a missing directory" {
    try std.testing.expectError(error.NotDir, runsv.scanServiceDir(std.testing.allocator, "/tmp/opencode/bb-runsv-missing"));
}
