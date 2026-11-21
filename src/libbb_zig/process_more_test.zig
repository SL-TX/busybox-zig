//! Tests for the extra process helpers (spawn, daemonisation, task comm).

const std = @import("std");
const bb = @import("libbb_zig");
const linux = std.os.linux;
const pm = bb.process_more;
const proc = bb.process;

test "vfork returns a child pid and the parent can reap it" {
    const pid = try pm.vfork();
    if (pid == 0) {
        linux.exit(0);
    }
    try std.testing.expect(pid > 0);
    var status: i32 = 0;
    const waited = try proc.waitpid(pid, &status, 0);
    try std.testing.expectEqual(pid, waited);
}

test "spawnAndWait reports the child exit code" {
    const ok = [_][]const u8{"/bin/true"};
    try std.testing.expectEqual(@as(u8, 0), try pm.spawnAndWait(&ok));
    const fail = [_][]const u8{"/bin/false"};
    try std.testing.expectEqual(@as(u8, 1), try pm.spawnAndWait(&fail));
}

test "vforkDaemon detaches a child which the parent can wait for" {
    const pid = try pm.vforkDaemon(.{ .redirect_stdio = false });
    if (pid == 0) {
        linux.exit(0);
    }
    try std.testing.expect(pid > 0);
    var status: i32 = 0;
    const waited = try proc.waitpid(pid, &status, 0);
    try std.testing.expectEqual(pid, waited);
}

test "setTaskComm sets a short process name" {
    defer pm.setTaskComm("busybox");
    pm.setTaskComm("bb-test");
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    const pr_get_name: c_uint = 16;
    const rc = linux.prctl(pr_get_name, @intFromPtr(&buf), 0, 0, 0);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);
    try std.testing.expectEqualStrings("bb-test", std.mem.sliceTo(&buf, 0));
}

test "wait4pid decodes wait status" {
    const pid = try proc.fork();
    if (pid == 0) linux.exit(42);
    try std.testing.expectEqual(@as(u8, 42), try pm.wait4pid(pid));
}
