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

// Fix round 1: direct tests for values that were previously fabricated.
test "top rowValues derives RSS, %RSS and %CPU from proc fields" {
    var st: @import("libbb_zig").procps.Stat = .{};
    st.rss = 80000; // pages -> 320000 KB
    st.utime = 600;
    st.stime = 400;
    const v = ps.topRowValues(st, 1000, 16_000_000, 100_000, 7);
    try std.testing.expectEqual(@as(u32, 1000), v.uid);
    try std.testing.expectEqual(@as(u64, 320000), v.rss_kb);
    try std.testing.expectEqual(@as(u64, 20), v.rss_pct); // 2.0%
    try std.testing.expectEqual(@as(u64, 10), v.cpu_pct); // 1.0%
    try std.testing.expectEqual(@as(i64, 7), v.cpu_index);

    var cols: [64]u8 = undefined;
    var rss: [16]u8 = undefined;
    const text = ps.topFormatColumns(&cols, v, ps.topSmartSize5(v.rss_kb, &rss));
    // The processor index (7) must sit between %RSS and %CPU, and %CPU must
    // keep its decimal point; a hardcoded 0 in either column fails this test.
    try std.testing.expect(std.mem.indexOf(u8, text, "  2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  7") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1.0") != null);
}

test "mpstat parses distinct per-CPU interrupt counters" {
    const line = "   1:          12          0          3        120";
    var counts: [8]u64 = undefined;
    const total = ps.mpstatParseIrqCounts(line, 4, &counts);
    try std.testing.expectEqual(@as(u64, 12), counts[0]);
    try std.testing.expectEqual(@as(u64, 0), counts[1]);
    try std.testing.expectEqual(@as(u64, 3), counts[2]);
    try std.testing.expectEqual(@as(u64, 120), counts[3]);
    try std.testing.expectEqual(@as(u64, 135), total);
}

test "iostat derives distinct CPU percentages from synthetic stat data" {
    const data = "cpu  100 20 50 700 30 5 15 10 0\ncpu0 10 2 5 70 3 0 1 1 0\n";
    const p = ps.iostatCpuPercents(data);
    try std.testing.expect(p.user > 9.0 and p.user < 11.0);   // 100/930
    try std.testing.expect(p.idle > 70.0 and p.idle < 77.0);  // 700/930
    try std.testing.expect(p.system > 7.0 and p.system < 9.0); // (50+5+15)/930
    try std.testing.expect(p.nice > 1.0 and p.nice < 3.0);
}

test "ps elapsed time formats days, hours and minutes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(" 5d03", ps.formatTime(&buf, 5 * 86400 + 3 * 3600));
    try std.testing.expectEqualStrings(" 2h05", ps.formatTime(&buf, 2 * 3600 + 5 * 60));
    try std.testing.expectEqualStrings("12:34", ps.formatTime(&buf, 12 * 60 + 34));
}

test "nmeter scale produces unit-suffixed four-character fields" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings(" 15g", ps.nmeterScale(16113332 * 1024, &buf));
    try std.testing.expectEqualStrings("900m", ps.nmeterScale(900 * 1024 * 1024, &buf));
    try std.testing.expectEqualStrings("2176", ps.nmeterScale(2176, &buf));
}

test "parseMemInfo reads the fields free needs" {
    const data = "MemTotal:       16384256 kB\nMemFree:         1234567 kB\nMemAvailable:    4567890 kB\nBuffers:          100000 kB\nCached:          2000000 kB\nSwapTotal:       1000000 kB\nSwapFree:         900000 kB\n";
    const m = try ps.parseMemInfo(data);
    try std.testing.expectEqual(@as(u64, 16384256), m.total);
    try std.testing.expectEqual(@as(u64, 1234567), m.free);
    try std.testing.expectEqual(@as(u64, 1000000), m.swap_total);
    try std.testing.expectEqual(@as(u64, 900000), m.swap_free);
}
