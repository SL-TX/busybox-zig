//! Tests for the /proc parsers and PID lookup helpers (Task 15).
//! Synthetic /proc trees live under /tmp/opencode; no real services are used.

const std = @import("std");
const bb = @import("libbb_zig");
const procps = bb.procps;
const io = bb.io;
const linux = std.os.linux;

const ROOT = "/tmp/opencode/bb-procps-fake";

fn mkdir(path: []const u8) !void {
    try bb.file.makeDirectory(path, 0o755);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer io.close(fd) catch {};
    try io.writeAll(fd, data);
}

fn statLine(pid: u32, comm: []const u8, state: u8, ppid: u32, utime: u64, stime: u64, vsize: u64, rss: u64) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "{d} ({s}) {c} {d} 100 100 0 -1 4194560 12 3 4 5 {d} {d} 0 0 20 0 1 0 100 {d} {d}\n", .{ pid, comm, state, ppid, utime, stime, vsize, rss });
}

/// Build a synthetic /proc tree with a few enumerable pids.
fn makeFakeProc() !void {
    removeFakeProc();
    try mkdir(ROOT);
    const specs = [_]struct { pid: u32, comm: []const u8, state: u8, ppid: u32 }{
        .{ .pid = 100, .comm = "sh", .state = 'S', .ppid = 1 },
        .{ .pid = 101, .comm = "crazy_long_name", .state = 'R', .ppid = 100 },
        .{ .pid = 102, .comm = "getty", .state = 'S', .ppid = 1 },
        .{ .pid = 103, .comm = "target-tool", .state = 'Z', .ppid = 1 },
        .{ .pid = 104, .comm = "not-a-pid-dir", .state = 'S', .ppid = 0 },
        .{ .pid = 105, .comm = "exact15charname", .state = 'S', .ppid = 1 },
    };
    for (specs) |s| {
        const dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/{d}", .{ ROOT, s.pid });
        defer std.testing.allocator.free(dir);
        try mkdir(dir);
        const line = try statLine(s.pid, s.comm, s.state, s.ppid, 10 + s.pid, 5, 4096 * 1024, 64);
        defer std.testing.allocator.free(line);
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/stat", .{dir});
        defer std.testing.allocator.free(path);
        try writeFile(path, line);
    }
    // A non-numeric entry must be skipped by the directory walker.
    try mkdir(ROOT ++ "/self");
    try writeFile(ROOT ++ "/self/stat", "self (ignored) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 20 0 1 0 1 0 0\n");

    // argv0/argv1 for the truncated-name and basename matching cases.
    try writeFile(ROOT ++ "/101/cmdline", "/usr/bin/script\x00crazy_long_name.sh\x00arg\x00");
    try writeFile(ROOT ++ "/102/cmdline", "/usr/bin/target\x00\x00");
    try writeFile(ROOT ++ "/103/cmdline", "/bin/unrelated\x00\x00");
    // exe symlink resolution (busybox uses it as a last resort).
    io.unlink(ROOT ++ "/103/exe") catch {};
    try io.symlink("/usr/bin/symtarget", ROOT ++ "/103/exe");
    try writeFile(ROOT ++ "/104/stat", "bad stat line\n");
}

fn removeFakeProc() void {
    const names = [_][]const u8{ "100", "101", "102", "103", "104", "105", "self" };
    for (names) |name| {
        var path_buf: [256]u8 = undefined;
        const dir = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ROOT, name }) catch continue;
        const files = [_][]const u8{ "stat", "status", "cmdline", "exe" };
        for (files) |file| {
            var fbuf: [280]u8 = undefined;
            const fp = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ dir, file }) catch continue;
            io.unlink(fp) catch {};
        }
        io.rmdir(dir) catch {};
    }
    io.rmdir(ROOT) catch {};
}

test "parseProcStatData handles commas, spaces and parentheses in comm" {
    const data = "1234 (my (weird) name) R 1 100 100 0 -1 0 10 2 3 4 77 88 1 2 20 -5 3 0 999 4096000 512 5 6 7 8 9 10 11 12 13 14\n";
    var st = try procps.parseProcStatData(data);
    try std.testing.expectEqual(@as(i32, 1234), st.pid);
    try std.testing.expectEqualStrings("my (weird) name", st.commSlice());
    try std.testing.expectEqual(@as(u8, 'R'), st.state);
    try std.testing.expectEqual(@as(i32, 1), st.ppid);
    try std.testing.expectEqual(@as(i32, 100), st.pgrp);
    try std.testing.expectEqual(@as(i32, 100), st.session);
    try std.testing.expectEqual(@as(i32, -1), st.tpgid);
    try std.testing.expectEqual(@as(u64, 77), st.utime);
    try std.testing.expectEqual(@as(u64, 88), st.stime);
    try std.testing.expectEqual(@as(i64, -5), st.nice);
    try std.testing.expectEqual(@as(u64, 999), st.starttime);
    try std.testing.expectEqual(@as(u64, 4096000), st.vsize);
    try std.testing.expectEqual(@as(i64, 512), st.rss);
}

test "parseProcStatData rejects malformed input" {
    _ = procps.parseProcStatData("no comm here at all\n") catch |e| {
        try std.testing.expectEqual(procps.Error.MalformedProcStat, e);
        return;
    };
    try std.testing.expect(false);
}

test "parseProcStatIn reads a synthetic /proc/PID/stat" {
    try makeFakeProc();
    defer removeFakeProc();
    var st = try procps.parseProcStatIn(ROOT, 101);
    try std.testing.expectEqual(@as(i32, 101), st.pid);
    try std.testing.expectEqualStrings("crazy_long_name", st.commSlice());
    try std.testing.expectEqual(@as(u8, 'R'), st.state);
    try std.testing.expectEqual(@as(u64, 111), st.utime);
    try std.testing.expectEqual(@as(u64, 4096 * 1024), st.vsize);
}

test "parseProcStatusIn reads the fields applets need" {
    try makeFakeProc();
    defer removeFakeProc();
    try writeFile(ROOT ++ "/100/status", "Name:\tsh\nState:\tS (sleeping)\nTgid:\t100\nPid:\t100\nPPid:\t1\n" ++
        "Uid:\t1000\t1000\t1000\t1000\nGid:\t100\t100\t100\t100\n" ++
        "VmPeak:\t2048 kB\nVmSize:\t1024 kB\nVmRSS:\t64 kB\nThreads:\t2\n");
    var s = try procps.parseProcStatusIn(ROOT, 100);
    try std.testing.expectEqual(@as(i32, 100), s.pid);
    try std.testing.expectEqual(@as(i32, 100), s.tgid);
    try std.testing.expectEqual(@as(i32, 1), s.ppid);
    try std.testing.expectEqualStrings("sh", s.nameSlice());
    try std.testing.expectEqual(@as(u32, 1000), s.uid);
    try std.testing.expectEqual(@as(u32, 1000), s.euid);
    try std.testing.expectEqual(@as(u64, 2048), s.vmpeak_kb);
    try std.testing.expectEqual(@as(u64, 1024), s.vmsize_kb);
    try std.testing.expectEqual(@as(u64, 64), s.vmrss_kb);
    try std.testing.expectEqual(@as(u64, 2), s.threads);
}

test "findPidByNameIn matches comm, basename(argv0), argv1 and exe" {
    try makeFakeProc();
    defer removeFakeProc();
    const a = std.testing.allocator;

    const exact = try procps.findPidByNameIn(ROOT, "sh", a);
    defer procps.freePidList(exact, a);
    try std.testing.expectEqualSlices(i32, &[_]i32{100}, exact);

    // comm is truncated to 15 chars; argv[1] basename identifies the script.
    const truncated = try procps.findPidByNameIn(ROOT, "crazy_long_name.sh", a);
    defer procps.freePidList(truncated, a);
    try std.testing.expectEqualSlices(i32, &[_]i32{101}, truncated);

    // A non-matching comm can still match basename(argv[0]).
    const argv0 = try procps.findPidByNameIn(ROOT, "target", a);
    defer procps.freePidList(argv0, a);
    try std.testing.expectEqualSlices(i32, &[_]i32{102}, argv0);

    // /proc/PID/exe is used as the last resort, with or without a path.
    const exe = try procps.findPidByNameIn(ROOT, "symtarget", a);
    defer procps.freePidList(exe, a);
    try std.testing.expectEqualSlices(i32, &[_]i32{103}, exe);
    const exe_path = try procps.findPidByNameIn(ROOT, "/usr/bin/symtarget", a);
    defer procps.freePidList(exe_path, a);
    try std.testing.expectEqualSlices(i32, &[_]i32{103}, exe_path);

    const none = try procps.findPidByNameIn(ROOT, "no-such-process", a);
    defer procps.freePidList(none, a);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "findPidByNameIn rejects a 15-char comm without argv[1] (upstream)" {
    try makeFakeProc();
    defer removeFakeProc();
    const a = std.testing.allocator;
    // find_pid_by_name.c:40-70: a 15-char comm is treated as truncated;
    // without basename(argv[1]) == procName it must not match, even when
    // the comm text equals the requested name exactly.
    const list = try procps.findPidByNameIn(ROOT, "exact15charname", a);
    defer procps.freePidList(list, a);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "parseProcStatus reads the real /proc and pidlistReverse reverses" {
    var s = try procps.parseProcStatus(linux.getpid());
    try std.testing.expectEqual(@as(i32, @intCast(linux.getpid())), s.pid);
    try std.testing.expect(s.nameSlice().len > 0);
    var list = [_]i32{ 1, 2, 3, 4 };
    const reversed = procps.pidlistReverse(&list);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 4, 3, 2, 1 }, reversed);
}

test "parseProcStat works against the real /proc" {
    const pid = linux.getpid();
    var st = try procps.parseProcStat(pid);
    try std.testing.expectEqual(@as(i32, @intCast(pid)), st.pid);
    try std.testing.expect(st.commSlice().len > 0);
    try std.testing.expect(st.state != 0);

    const found = try procps.findPidByName(st.commSlice());
    defer procps.freePidList(found, std.heap.page_allocator);
    var saw_self = false;
    for (found) |p| {
        if (p == @as(i32, @intCast(pid))) saw_self = true;
    }
    try std.testing.expect(saw_self);
}
