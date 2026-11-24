//! iostat — port of procps/iostat.c (first report).

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

fn date(buf: []u8) []const u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const secs: u64 = @intCast(@max(ts.sec, 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>2}/{d:0>2}/{d:0>2}", .{
        md.month.numeric(), md.day_index + 1, yd.year % 100,
    }) catch "01/01/70";
}

fn timeOfDay(buf: []u8) []const u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const secs: u64 = @intCast(@max(ts.sec, 0));
    const tod = secs % 86400;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ tod / 3600, (tod / 60) % 60, tod % 60 }) catch "00:00:00";
}

pub const CpuPcts = struct {
    user: f64,
    nice: f64,
    system: f64,
    iowait: f64,
    steal: f64,
    idle: f64,
};

/// iostat.c:get_cpu_statistics() sums fields 0..7 into GLOBAL_UPTIME and
/// computes each column as (curr - prev) / itv * 100. On the first report prev
/// is zero and itv is that sum, so each column is a plain fraction.
pub fn cpuPercents(data: []const u8) CpuPcts {
    var fields: [9]u64 = std.mem.zeroes([9]u64);
    var total: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu ")) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next();
        var idx: usize = 0;
        while (it.next()) |tok| : (idx += 1) {
            if (idx >= fields.len) break;
            fields[idx] = std.fmt.parseInt(u64, tok, 10) catch 0;
            if (idx < 8) total += fields[idx];
        }
        break;
    }
    const pct = struct {
        fn f(v: u64, t: u64) f64 {
            return @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(@max(t, 1))) * 100;
        }
    }.f;
    return .{
        .user = pct(fields[0], total),
        .nice = pct(fields[1], total),
        .system = pct(fields[2] + fields[5] + fields[6], total),
        .iowait = pct(fields[4], total),
        .steal = pct(fields[7], total),
        .idle = pct(fields[3], total),
    };
}

fn fullUint(s: ?[]const u8) ?u64 {
    const text = s orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn firstUint(s: []const u8) u64 {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const tok = it.next() orelse return 0;
    return std.fmt.parseInt(u64, tok, 10) catch 0;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var cpu = false;
    var disk = false;
    var stamp = false;
    var omit_zero = false;
    var unit_str: []const u8 = "Blk";
    var unit_div: f64 = 1;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        for (tok[1..]) |ch| switch (ch) {
            'c' => cpu = true,
            'd' => disk = true,
            't' => stamp = true,
            'z' => omit_zero = true,
            'k' => {
                unit_str = " kB";
                unit_div = 2;
            },
            'm' => {
                unit_str = " MB";
                unit_div = 2048;
            },
            else => {
                c.plainMsg("invalid option -- '{c}'", .{ch});
                c.usageDie(prog);
            },
        };
    }
    if (!cpu and !disk) {
        cpu = true;
        disk = true;
    }

    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    const release = std.mem.sliceTo(&uts.release, 0);
    const machine = std.mem.sliceTo(&uts.machine, 0);
    const host_raw = c.readFile(a, "/proc/sys/kernel/hostname") orelse &.{};
    defer if (host_raw.len != 0) a.free(host_raw);
    const host = std.mem.trimEnd(u8, host_raw, "\n");
    var date_buf: [32]u8 = undefined;
    const stat = c.readFile(a, "/proc/stat") orelse return 1;
    defer a.free(stat);
    var ncpu: usize = 0;
    var lines = std.mem.splitScalar(u8, stat, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "cpu")) ncpu += 1;
    }
    const pcts = cpuPercents(stat);
    const user_pct = pcts.user;
    const nice_pct = pcts.nice;
    const system_pct = pcts.system;
    const iowait_pct = pcts.iowait;
    const steal_pct = pcts.steal;
    const idle_pct = pcts.idle;

    c.printfOut("{s} {s} ({s}) \t{s} \t_{s}_\t({d} CPU)\n\n", .{
        std.mem.sliceTo(&uts.sysname, 0), release, std.mem.trimEnd(u8, host, "\n"),
        date(&date_buf), machine, ncpu -| 1,
    });

    if (stamp) {
        var tbuf: [32]u8 = undefined;
        c.printfOut("{s} {s}\n", .{ date(&date_buf), timeOfDay(&tbuf) });
    }

    if (cpu) {
        c.out("avg-cpu:  %user   %nice %system %iowait  %steal   %idle\n");
        c.printfOut("        {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2}\n", .{
            user_pct, nice_pct, system_pct, iowait_pct, steal_pct, idle_pct,
        });
        if (disk) c.out("\n");
    }

    if (disk) {
        c.printfOut("Device:{s: >15}{s: >6}{s}/s{s: >6}{s}/s{s: >6}{s}{s: >6}{s}\n", .{
            "tps", unit_str, "_read", unit_str, "_wrtn",
            unit_str, "_read", unit_str, "_wrtn",
        });
        const diskstats = c.readFile(a, "/proc/diskstats") orelse return 1;
        defer a.free(diskstats);
        // iostat.c reads /proc/diskstats with `char buf[128]` and fgets(), so a
        // line longer than 127 bytes is split into several "records". Reproduce
        // that chunking: it is observable in the device list on this host.
        const info = c.sysinfo();
        const itv: f64 = @floatFromInt(@max(info.uptime, 1));
        var off: usize = 0;
        while (off < diskstats.len) {
            var end = @min(off + 127, diskstats.len);
            if (std.mem.indexOfScalar(u8, diskstats[off..end], '\n')) |p| end = off + p + 1;
            const chunk = diskstats[off..end];
            off = end;
            var it = std.mem.tokenizeAny(u8, chunk, " \t\n");
            _ = it.next() orelse continue; // major
            _ = it.next() orelse continue; // minor
            const full_name = it.next() orelse continue;
            const name = full_name[0..@min(full_name.len, 12)];
            if (name.len >= 4 and std.mem.eql(u8, name[0..3], "sd") and name[3] >= '0' and name[3] <= '9') continue;
            const rd_ops = firstUint(it.next() orelse "0");
            _ = it.next(); // read merges
            const rd_sectors = firstUint(it.next() orelse "0");
            _ = it.next(); // read time
            var wr_ops = firstUint(it.next() orelse "0");
            _ = it.next(); // write merges
            const wr_sectors = fullUint(it.next());
            // iostat.c falls back when its sscanf gets fewer than six fields:
            // wr_ops becomes rd_sectors, so short (128-byte-chunk) records are
            // never treated as idle by -z.
            const full = wr_sectors != null;
            if (!full) wr_ops = rd_sectors;
            const wr_sec = wr_sectors orelse rd_sectors;
            if (omit_zero and full and rd_ops == 0 and wr_ops == 0) continue;
            c.printfOut("{s: <13} {d: >8.2} {d: >12.2} {d: >12.2} {d: >10} {d: >10}\n", .{
                name,
                @as(f64, @floatFromInt(rd_ops + wr_ops)) / itv,
                @as(f64, @floatFromInt(rd_sectors)) / itv / unit_div,
                @as(f64, @floatFromInt(wr_sec)) / itv / unit_div,
                rd_sectors / @as(u64, @intFromFloat(unit_div)),
                wr_sec / @as(u64, @intFromFloat(unit_div)),
            });
        }
    }
    c.out("\n");
    return 0;
}
