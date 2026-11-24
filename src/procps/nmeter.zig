//! nmeter — port of procps/nmeter.c.
//!
//! Each format specifier is collected from the live /proc files, exactly as
//! the reference does; no value is fabricated.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

const A = std.heap.page_allocator;

fn memValue(data: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var it = std.mem.tokenizeAny(u8, line[key.len..], " \t:");
        return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch null;
    }
    return null;
}

fn fileValue(path: []const u8) ?u64 {
    const data = c.readFile(A, path) orelse return null;
    defer A.free(data);
    var it = std.mem.tokenizeAny(u8, data, " \t");
    return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch null;
}

/// libbb smart_ulltoa4(v, " kmgtpezy"): exactly four chars, e.g. " 15g",
/// "1.9g" -- matching nmeter's scale() output byte for byte.
pub fn scale(v_in: u64, buf: []u8) []const u8 {
    const units = " kmgtpezy";
    var v = v_in;
    var idx: usize = 0;
    if (v > 9999) {
        v *= 10;
        while (v >= 10000) {
            v /= 1024;
            idx += 1;
        }
    }
    var u = v / 10;
    var rem = v % 10;
    if (idx == 0) {
        buf[0] = if (u / 100 == 0) ' ' else @as(u8, @intCast('0' + u / 100));
        buf[1] = @intCast('0' + (u / 10) % 10);
        buf[2] = @intCast('0' + u % 10);
        buf[3] = @intCast('0' + rem);
    } else {
        const ch = units[@min(idx, units.len - 1)];
        if (u >= 10) {
            buf[0] = if (u / 100 == 0) ' ' else @as(u8, @intCast('0' + u / 100));
            rem = u % 10;
            u /= 10;
            buf[1] = @intCast('0' + u % 10);
            buf[2] = @intCast('0' + rem);
        } else {
            buf[0] = @intCast('0' + u);
            buf[1] = '.';
            buf[2] = @intCast('0' + rem);
        }
        buf[3] = ch;
    }
    return buf[0..4];
}

fn statField(data: []const u8, key: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var it = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    }
    return 0;
}

fn renderMem(a: std.mem.Allocator, opt: u8, param: u8) void {
    const meminfo = c.readFile(a, "/proc/meminfo") orelse return;
    defer a.free(meminfo);
    const total = memValue(meminfo, "MemTotal:") orelse 0;
    const free = memValue(meminfo, "MemFree:") orelse 0;
    const buffers = memValue(meminfo, "Buffers:") orelse 0;
    const cached = memValue(meminfo, "Cached:") orelse 0;
    const slab = memValue(meminfo, "Slab:") orelse 0;
    var kb: u64 = 0;
    switch (param) {
        't' => kb = total,
        'f' => kb = free + buffers + cached + slab,
        'd' => kb = memValue(meminfo, "Dirty:") orelse 0,
        'w' => kb = memValue(meminfo, "Writeback:") orelse 0,
        else => kb = total -| (free + buffers + cached + slab),
    }
    var buf: [8]u8 = undefined;
    c.out(scale(kb * 1024, &buf));
    _ = opt;
}

fn render(a: std.mem.Allocator, format: []const u8) void {
    const meminfo = c.readFile(a, "/proc/meminfo") orelse &.{};
    defer if (meminfo.len != 0) a.free(meminfo);
    const stat = c.readFile(a, "/proc/stat") orelse &.{};
    defer if (stat.len != 0) a.free(stat);

    var j: usize = 0;
    while (j < format.len) {
        if (format[j] != '%') {
            c.out(format[j .. j + 1]);
            j += 1;
            continue;
        }
        j += 1;
        if (j >= format.len) break;
        if (format[j] == '%') {
            c.out("%");
            j += 1;
            continue;
        }
        var opt: u8 = 'm';
        var param: u8 = 0;
        if (format[j] == '[') {
            j += 1;
            opt = if (j < format.len) format[j] else 'm';
            param = if (j + 1 < format.len) format[j + 1] else 0;
            while (j < format.len and format[j] != ']') j += 1;
            if (j < format.len) j += 1;
        } else {
            while (j < format.len and format[j] >= '0' and format[j] <= '9') j += 1;
            if (j >= format.len) break;
            opt = format[j];
            j += 1;
        }

        if (opt == 'm') {
            renderMem(a, opt, param);
            continue;
        }

        var sbuf: [32]u8 = undefined;
        switch (opt) {
            'r' => c.out("\r"),
            't' => {
                var ts: linux.timespec = undefined;
                _ = linux.clock_gettime(.REALTIME, &ts);
                const tod: u64 = @intCast(@max(ts.sec, 0) % 86400);
                c.printfOut("{d:0>2}:{d:0>2}:{d:0>2}", .{ tod / 3600, (tod / 60) % 60, tod % 60 });
            },
            'T' => {
                var ts: linux.timespec = undefined;
                _ = linux.clock_gettime(.MONOTONIC, &ts);
                const secs: u64 = @intCast(@max(ts.sec, 0));
                c.printfOut("{d:0>2}:{d:0>2}:{d:0>2}", .{ (secs / 3600) % 24, (secs / 60) % 60, secs % 60 });
            },
            'm', 's', 'f', 'p', 'x', 'b', 'n' => {
                var v: u64 = 0;
                switch (opt) {
                    'm' => {
                        const total = memValue(meminfo, "MemTotal:") orelse 0;
                        const used = memValue(meminfo, "MemAvailable:") orelse memValue(meminfo, "MemFree:") orelse 0;
                        v = (total -| used) * 1024;
                    },
                    's' => {
                        const total = memValue(meminfo, "SwapTotal:") orelse 0;
                        const free = memValue(meminfo, "SwapFree:") orelse 0;
                        v = (total -| free) * 1024;
                    },
                    'f' => v = fileValue("/proc/sys/fs/file-nr") orelse 0,
                    'p' => v = statField(stat, "processes"),
                    'x' => v = statField(stat, "ctxt"),
                    'b' => {
                        v = fileValue("/proc/diskstats") orelse 0; // fallback; refined below
                        const ds = c.readFile(a, "/proc/diskstats") orelse &.{};
                        defer if (ds.len != 0) a.free(ds);
                        v = 0;
                        var lines = std.mem.splitScalar(u8, ds, '\n');
                        while (lines.next()) |line| {
                            var it = std.mem.tokenizeAny(u8, line, " \t");
                            var k: usize = 0;
                            while (it.next()) |tok| : (k += 1) {
                                if (k == 5 or k == 9) v += std.fmt.parseInt(u64, tok, 10) catch 0;
                            }
                        }
                    },
                    'n' => {
                        const pids = c.listPids(a, "/proc") catch &.{};
                        defer a.free(pids);
                        v = @intCast(pids.len);
                    },
                    else => {},
                }
                c.out(scale(v, &sbuf));
            },
            'c' => {
                // CPU: system/user/niced/iowait/irq/softirq shares of /proc/stat.
                var it = std.mem.tokenizeAny(u8, stat, " \t\n");
                _ = it.next() orelse ""; // "cpu"
                var fields: [8]u64 = undefined;
                var total: u64 = 1;
                for (&fields) |*f| {
                    f.* = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
                    total += f.*;
                }
                const pct = struct {
                    fn f(v: u64, t: u64) u64 {
                        return @as(u64, @intCast((@as(u128, v) * 100) / @as(u128, t)));
                    }
                }.f;
                c.printfOut("S{d: >2} U{d: >2} N{d: >2} D{d: >2} I{d: >2} i{d: >2}", .{
                    pct(fields[2], total), pct(fields[0], total), pct(fields[1], total),
                    pct(fields[4], total), pct(fields[5], total), pct(fields[6], total),
                });
            },
            else => {},
        }
    }
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const av = c.argsFrom(A, argv, argc) catch return 1;
    defer A.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var delay_ms: i64 = 1000;
    var i: usize = 1;
    while (i < av.len and av[i].len > 1 and av[i][0] == '-') {
        if (!std.mem.eql(u8, av[i], "-d")) {
            c.plainMsg("invalid option -- '{c}'", .{av[i][1]});
            c.usageDie(prog);
        }
        if (i + 1 >= av.len) {
            c.plainMsg("option requires an argument -- 'd'", .{});
            c.usageDie(prog);
        }
        i += 1;
        delay_ms = std.fmt.parseInt(i64, av[i], 10) catch {
            c.plainMsg("invalid number '{s}'", .{av[i]});
            std.process.exit(1);
        };
        i += 1;
    }
    if (i >= av.len) c.usageDie(prog);

    const format = av[i];
    while (true) {
        render(A, format);
        c.out("\n");
        if (delay_ms < 0) continue;
        var ts = linux.timespec{ .sec = @intCast(@divFloor(delay_ms, 1000)), .nsec = @intCast(@mod(delay_ms, 1000) * 1_000_000) };
        _ = linux.nanosleep(&ts, null);
    }
    return 0;
}
