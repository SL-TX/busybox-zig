const std = @import("std");
const ps = @import("procps");

test "parseProcStat extracts pid, comm, state, ppid and cpu ticks" {
    const line = "123 (my proc) S 1 2 3 4 5 0 10 0 2 0 100 50 0 0 20 0 1";
    const s = ps.parseProcStat(line).?;
    try std.testing.expectEqual(@as(i32, 123), s.pid);
    try std.testing.expectEqualStrings("my proc", s.comm);
    try std.testing.expectEqual(@as(u8, 'S'), s.state);
    try std.testing.expectEqual(@as(i32, 1), s.ppid);
    try std.testing.expectEqual(@as(u64, 100), s.utime);
    try std.testing.expectEqual(@as(u64, 50), s.stime);
}

test "formatPsRow prints unsigned pids without a leading plus sign" {
    var buf: [256]u8 = undefined;
    const row = try ps.formatPsRow(1, 0, 'S', "init", &buf);
    try std.testing.expectEqualStrings("    1     0 S    init\n", row);
}

test "parseProcStat rejects malformed lines" {
    try std.testing.expect(ps.parseProcStat("no-parentheses here") == null);
}

test "parseProcCmdline joins NUL-separated arguments" {
    const raw = "sleep\x0010\x00";
    const joined = ps.parseProcCmdline(raw);
    try std.testing.expectEqualStrings("sleep 10", joined);
}

test "matchesProcName compares the basename of the command" {
    try std.testing.expect(ps.matchesProcName("/usr/bin/sleep 10", "sleep"));
    try std.testing.expect(!ps.matchesProcName("mysleep 10", "sleep"));
}

test "parseSignal accepts numbers, names and SIG-prefixed names" {
    try std.testing.expectEqual(std.os.linux.SIG.KILL, try ps.parseSignal("9"));
    try std.testing.expectEqual(std.os.linux.SIG.TERM, try ps.parseSignal("TERM"));
    try std.testing.expectEqual(std.os.linux.SIG.TERM, try ps.parseSignal("SIGTERM"));
    try std.testing.expectError(error.InvalidSignal, ps.parseSignal("BOGUS"));
}

test "parseMemInfo reads the fields free needs" {
    const data = "MemTotal:       16384256 kB\nMemFree:         1234567 kB\nMemAvailable:    4567890 kB\nBuffers:          100000 kB\nCached:          2000000 kB\nSwapTotal:       1000000 kB\nSwapFree:         900000 kB\n";
    const m = try ps.parseMemInfo(data);
    try std.testing.expectEqual(@as(u64, 16384256), m.total);
    try std.testing.expectEqual(@as(u64, 1234567), m.free);
    try std.testing.expectEqual(@as(u64, 1000000), m.swap_total);
    try std.testing.expectEqual(@as(u64, 900000), m.swap_free);
}
