//! TDD tests for daemon lifecycle helpers (Task 25). All side effects are
//! confined to injectable operations or paths under /tmp/opencode.

const std = @import("std");
const bb = @import("libbb_zig");
const life = bb.daemon.lifecycle;
const io = bb.io;

const Recorder = struct {
    fork_ret: i32 = 0,
    setsid_ret: i32 = 0,
    chdir_ret: i32 = 0,
    devnull_fd: i32 = 9,
    calls: usize = 0,
    chdir_path: []const u8 = "",
    dup_pairs: [8][2]i32 = undefined,
    n_dups: usize = 0,
    closed: [8]i32 = undefined,
    n_closed: usize = 0,

    fn reset(self: *Recorder, fork_ret: i32) void {
        self.* = .{ .fork_ret = fork_ret };
    }
};

var rec: Recorder = undefined;

fn fakeFork() i32 {
    rec.calls += 1;
    return rec.fork_ret;
}
fn fakeSetsid() i32 {
    rec.calls += 1;
    return rec.setsid_ret;
}
fn fakeChdir(path: []const u8) i32 {
    rec.calls += 1;
    rec.chdir_path = path;
    return rec.chdir_ret;
}
fn fakeOpenDevnull() i32 {
    rec.calls += 1;
    return rec.devnull_fd;
}
fn fakeDup2(from: i32, to: i32) i32 {
    if (rec.n_dups < rec.dup_pairs.len) {
        rec.dup_pairs[rec.n_dups] = .{ from, to };
        rec.n_dups += 1;
    }
    return to;
}
fn fakeClose(fd: i32) void {
    if (rec.n_closed < rec.closed.len) {
        rec.closed[rec.n_closed] = fd;
        rec.n_closed += 1;
    }
}

fn ops() life.Ops {
    return .{
        .fork = fakeFork,
        .setsid = fakeSetsid,
        .chdir = fakeChdir,
        .open_devnull = fakeOpenDevnull,
        .dup2 = fakeDup2,
        .close = fakeClose,
    };
}

test "daemonize parent returns immediately without setsid" {
    rec.reset(4242);
    const r = try life.daemonize(.{}, ops());
    try std.testing.expect(r.is_parent);
    try std.testing.expectEqual(@as(i32, 4242), r.pid);
    try std.testing.expectEqual(@as(usize, 0), rec.n_dups);
    try std.testing.expectEqual(@as(usize, 0), rec.n_closed);
}

test "daemonize child calls setsid and sanitizes stdio" {
    rec.reset(0);
    const r = try life.daemonize(.{ .devnull_stdio = true }, ops());
    try std.testing.expect(!r.is_parent);
    try std.testing.expectEqual(@as(usize, 3), rec.n_dups);
    try std.testing.expectEqual(@as(i32, 9), rec.dup_pairs[0][0]);
    try std.testing.expectEqual(@as(i32, 0), rec.dup_pairs[0][1]);
    try std.testing.expectEqual(@as(i32, 1), rec.dup_pairs[1][1]);
    try std.testing.expectEqual(@as(i32, 2), rec.dup_pairs[2][1]);
}

test "daemonize chdir_root passes the literal root path" {
    rec.reset(1);
    _ = try life.daemonize(.{ .chdir_root = true }, ops());
    try std.testing.expectEqualStrings("/", rec.chdir_path);
}

test "daemonize maps fork and setsid failures to distinct errors" {
    rec.reset(-1);
    try std.testing.expectError(error.ForkFailed, life.daemonize(.{}, ops()));
    rec.reset(0);
    rec.setsid_ret = -1;
    try std.testing.expectError(error.SetsidFailed, life.daemonize(.{}, ops()));
    rec.reset(0);
    rec.chdir_ret = -1;
    try std.testing.expectError(error.ChdirFailed, life.daemonize(.{ .chdir_root = true }, ops()));
}

test "daemonize only_sanitize never forks" {
    rec.reset(77);
    const r = try life.daemonize(.{ .only_sanitize = true }, ops());
    try std.testing.expect(!r.is_parent);
    try std.testing.expectEqualStrings("", rec.chdir_path);
}

test "formatPidfile produces pid with trailing newline and rejects small buffers" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1234\n", try life.formatPidfile(1234, &buf));
    try std.testing.expectError(error.NoSpaceLeft, life.formatPidfile(1234, buf[0..4]));
}

test "writePidfile writes under /tmp/opencode and removePidfile deletes it" {
    const path = "/tmp/opencode/bb-daemon-test.pid";
    defer io.unlink(path) catch {};
    try std.testing.expect(try life.writePidfile(path, 4321));
    const fd = try io.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer io.close(fd) catch {};
    var buf: [32]u8 = undefined;
    const n = try io.read(fd, &buf);
    try std.testing.expectEqualStrings("4321\n", buf[0..n]);
    try life.removePidfile(path);
    try std.testing.expect(!io.isRegular(path));
}

test "writePidfile rejects an empty path" {
    try std.testing.expectError(error.InvalidPath, life.writePidfile("", 1));
}

test "SignalSet validates, counts and round-trips names" {
    var set = life.SignalSet{};
    try set.add(1); // SIGHUP
    try set.add(15); // SIGTERM
    try set.add(64);
    try std.testing.expect(set.contains(1));
    try std.testing.expect(set.contains(15));
    try std.testing.expect(!set.contains(2));
    try std.testing.expectEqual(@as(usize, 3), set.count());
    try set.remove(15);
    try std.testing.expect(!set.contains(15));
    try std.testing.expectError(error.InvalidSignal, set.add(0));
    try std.testing.expectError(error.InvalidSignal, set.add(65));

    const names = [_][]const u8{ "HUP", "SIGTERM", "USR1" };
    const named = try life.SignalSet.fromNames(&names);
    try std.testing.expect(named.contains(1));
    try std.testing.expect(named.contains(15));
    try std.testing.expect(named.contains(10));
}

test "SignalSet.fromNames rejects an unknown signal name" {
    const names = [_][]const u8{"NOTASIGNAL"};
    try std.testing.expectError(error.UnknownSignal, life.SignalSet.fromNames(&names));
}

test "SignalState records the last caught signal" {
    var state = life.SignalState{};
    state.record(15);
    try std.testing.expectEqual(@as(u8, 15), state.got);
    state.clear();
    try std.testing.expectEqual(@as(u8, 0), state.got);
}

test "planRotation respects size threshold and keep count" {
    const off = life.planRotation(.{ .max_size = 100, .keep = 0 }, 99);
    try std.testing.expect(!off.rotate);
    const purge = life.planRotation(.{ .max_size = 100, .keep = 0 }, 100);
    try std.testing.expect(purge.rotate);
    try std.testing.expect(purge.delete_oldest);
    const keep3 = life.planRotation(.{ .max_size = 100, .keep = 3 }, 101);
    try std.testing.expect(keep3.rotate);
    try std.testing.expectEqual(@as(usize, 2), keep3.shifts);
    const disabled = life.planRotation(.{ .max_size = 0, .keep = 3 }, 1_000_000);
    try std.testing.expect(!disabled.rotate);
}

test "rotateFiles shifts suffixes inside /tmp/opencode only" {
    const a = std.testing.allocator;
    const base = "/tmp/opencode/bb-daemon-rotate.log";
    defer {
        io.unlink(base) catch {};
        io.unlink("/tmp/opencode/bb-daemon-rotate.log.1") catch {};
        io.unlink("/tmp/opencode/bb-daemon-rotate.log.2") catch {};
    }
    const one = try life.rotationName(a, base, 1);
    defer a.free(one);
    const two = try life.rotationName(a, base, 2);
    defer a.free(two);

    _ = try life.writePidfile(base, 11);
    _ = try life.writePidfile(one, 22);
    try life.rotateFiles(a, base, 2);
    // base is renamed to .1; .1 to .2; the oldest suffix is discarded.
    try std.testing.expect(io.isRegular(one));
    try std.testing.expect(io.isRegular(two));
    try std.testing.expect(!io.isRegular(base));
}

fn alwaysFalse() bool {
    return false;
}
fn alwaysTrue() bool {
    return true;
}

test "privileged requirements declare a capability and enforce the check" {
    const denied = life.Requirement{
        .capability = .root,
        .reason = "test",
        .check = alwaysFalse,
    };
    try std.testing.expectError(error.InsufficientPrivileges, life.checkRequirement(denied));
    const allowed = life.Requirement{
        .capability = .root,
        .reason = "test",
        .check = alwaysTrue,
    };
    try life.checkRequirement(allowed);
    try std.testing.expectEqual(life.Capability.root, denied.capability);
}

test "hasCapability matches the effective uid" {
    const is_root = bb.process.geteuid() == 0;
    try std.testing.expectEqual(is_root, life.hasCapability(.root));
}
