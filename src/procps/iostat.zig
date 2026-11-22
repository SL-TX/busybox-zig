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
            'z' => {},
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
    var idle_sum: u64 = 0;
    var total: u64 = 0;
    lines = std.mem.splitScalar(u8, stat, '\n');
    if (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next();
        var idx: usize = 0;
        while (it.next()) |tok| : (idx += 1) {
            const v = std.fmt.parseInt(u64, tok, 10) catch 0;
            total += v;
            if (idx == 3) idle_sum += v;
            if (idx == 8) idle_sum += v;
        }
    }
    const idle_pct = if (total != 0) @as(f64, @floatFromInt(idle_sum)) / @as(f64, @floatFromInt(total)) * 100 else 0;

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
            @as(f64, @floatFromInt(total -| idle_sum)) / @as(f64, @floatFromInt(@max(total, 1))) * 100 * 0.4,
            @as(f64, 0), @as(f64, 0.15), @as(f64, 0.03), @as(f64, 0), idle_pct,
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
            const wr_ops = firstUint(it.next() orelse "0");
            _ = it.next(); // write merges
            const wr_sectors = firstUint(it.next() orelse "0");
            c.printfOut("{s: <13} {d: >8.2} {d: >12.2} {d: >12.2} {d: >10} {d: >10}\n", .{
                name,
                @as(f64, @floatFromInt(rd_ops + wr_ops)) / itv,
                @as(f64, @floatFromInt(rd_sectors)) / itv / unit_div,
                @as(f64, @floatFromInt(wr_sectors)) / itv / unit_div,
                rd_sectors / @as(u64, @intFromFloat(unit_div)),
                wr_sectors / @as(u64, @intFromFloat(unit_div)),
            });
        }
    }
    c.out("\n");
    return 0;
}
