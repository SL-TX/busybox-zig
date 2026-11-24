//! Tests for the extra process helpers (spawn, daemonisation, task comm).

const std = @import("std");
const bb = @import("libbb_zig");
const linux = std.os.linux;
const pm = bb.process_more;
const proc = bb.process;

fn readFile(path: []const u8) ![]u8 {
    const fd = try bb.io.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer bb.io.close(fd) catch {};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try bb.io.read(fd, &buf);
        if (n == 0) break;
        try out.appendSlice(std.testing.allocator, buf[0..n]);
    }
    return out.toOwnedSlice(std.testing.allocator);
}

const EnvKey = "BB_T9_ENV";
const EnvValue = "visible-to-child";

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

test "spawn passes the installed environment to the child" {
    var m = std.process.Environ.Map.init(std.testing.allocator);
    defer m.deinit();
    try m.put(EnvKey, EnvValue);
    const previous = bb.env.map;
    defer bb.env.map = previous;
    bb.env.map = &m;

    const out_path = "/tmp/opencode/bb-env-spawn-child.txt";
    defer bb.file.removeFile(out_path, .{ .force = true }) catch {};
    bb.file.removeFile(out_path, .{ .force = true }) catch {};

    const script = try std.fmt.allocPrint(std.testing.allocator, "printf %s \"${s}\" > {s}", .{ EnvKey, out_path });
    defer std.testing.allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script };
    try std.testing.expectEqual(@as(u8, 0), try pm.spawnAndWait(&argv));

    const got = try readFile(out_path);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(EnvValue, got);
}

test "execv passes the installed environment to the child" {
    var m = std.process.Environ.Map.init(std.testing.allocator);
    defer m.deinit();
    try m.put(EnvKey, EnvValue);
    const previous = bb.env.map;
    defer bb.env.map = previous;
    bb.env.map = &m;

    const out_path = "/tmp/opencode/bb-env-execv-child.txt";
    defer bb.file.removeFile(out_path, .{ .force = true }) catch {};
    bb.file.removeFile(out_path, .{ .force = true }) catch {};

    const script_z = try std.fmt.allocPrintSentinel(std.testing.allocator, "printf %s \"${s}\" > {s}", .{ EnvKey, out_path }, 0);
    defer std.testing.allocator.free(script_z);
    const arg0: [*:0]const u8 = "/bin/sh";
    const arg1: [*:0]const u8 = "-c";
    const argv = [_:null]?[*:0]const u8{ arg0, arg1, script_z, null };

    const pid = try proc.fork();
    if (pid == 0) {
        proc.execv("/bin/sh", &argv) catch linux.exit(112);
        linux.exit(113);
    }
    try std.testing.expectEqual(@as(u8, 0), try pm.wait4pid(pid));

    const got = try readFile(out_path);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(EnvValue, got);
}
