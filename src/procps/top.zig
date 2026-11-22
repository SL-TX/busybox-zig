//! top — port of procps/top.c (batch and pty screen rendering).

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

/// Values shown in one top process row, derived from real /proc fields.
pub const RowValues = struct {
    uid: u32,
    rss_kb: u64,
    rss_pct: u64, // percent * 10, i.e. the numerator of "%3u.%c"
    cpu_pct: u64, // percent * 10, i.e. the numerator of "%3u.%c"
    cpu_index: i64, // last_seen_on_cpu (stat field 39)
};

/// /proc/PID/stat field 39 (zero-based token 36 after the comm) is the
/// processor the task was last seen on; top displays it in the CPU column.
pub fn cpuIndexOf(pid: i32) i64 {
    const path = c.procPath(std.heap.page_allocator, pid, "stat") catch return 0;
    defer std.heap.page_allocator.free(path);
    const data = c.readFile(std.heap.page_allocator, path) orelse return 0;
    defer std.heap.page_allocator.free(data);
    const close = std.mem.lastIndexOfScalar(u8, data, ')') orelse return 0;
    var it = std.mem.tokenizeAny(u8, data[close + 1 ..], " \t");
    var idx: usize = 0;
    while (it.next()) |tok| : (idx += 1) {
        if (idx == 36) return std.fmt.parseInt(i64, tok, 10) catch 0;
    }
    return 0;
}

/// CPU percentages use tenths of a percent before SANITIZE, matching the
/// reference's UPSCALE=1000 path with FEATURE_TOP_DECIMALS enabled.
/// top.c uses a 100 ms initial sample, then computes %CPU from the tick
/// delta over that interval (not from the since-boot cumulative counters).
pub fn pcpuFromDelta(curr: u64, prev: u64, total_delta: u64) u64 {
    if (total_delta == 0) return 0;
    return @min((curr -| prev) * 1000 / total_delta, 999);
}

pub fn rowValues(st: bb.procps.Stat, uid: u32, total_mem_kb: u64, cpu_total: u64, cpu_index: i64) RowValues {
    const rss_kb: u64 = @intCast(@as(u64, @intCast(@max(st.rss, 0))) * 4);
    const rss_pct: u64 = if (total_mem_kb != 0)
        @intCast((@as(u128, rss_kb) * 1000) / @as(u128, total_mem_kb))
    else
        0;
    const cpu_pct: u64 = if (cpu_total != 0)
        @intCast((@as(u128, st.utime + st.stime) * 1000) / @as(u128, cpu_total))
    else
        0;
    return .{ .uid = uid, .rss_kb = rss_kb, .rss_pct = @min(rss_pct, 999), .cpu_pct = @min(cpu_pct, 999), .cpu_index = cpu_index };
}

/// The six numeric columns after COMMAND, exactly as top.c prints them:
/// RSS (compact 5 chars), %RSS as "%3u.%c", CPU as "%3d", %CPU as "%3u.%c".
pub fn formatColumns(buf: []u8, v: RowValues, rss5: []const u8) []const u8 {
    const first = std.fmt.bufPrint(buf, "{s: >5}{d: >3}.{d} ", .{
        rss5, v.rss_pct / 10, v.rss_pct % 10,
    }) catch return "";
    var cpu_buf: [16]u8 = undefined;
    const cpu_text = std.fmt.bufPrint(&cpu_buf, "{d}", .{v.cpu_index}) catch "0";
    var n = first.len;
    const pad = 3 -| @min(3, cpu_text.len);
    @memset(buf[n .. n + pad], ' ');
    n += pad;
    @memcpy(buf[n .. n + cpu_text.len], cpu_text);
    n += cpu_text.len;
    const tail = std.fmt.bufPrint(buf[n..], "{d: >3}.{d}", .{ v.cpu_pct / 10, v.cpu_pct % 10 }) catch "";
    return buf[0 .. n + tail.len];
}

/// top.c shrinks the USER field so the "PID PPID USER" prefix is exactly 20
/// columns wide, even when PIDs are seven digits.
fn pidPpidUser(buf: []u8, pid: u32, ppid: u32, user: []const u8) []const u8 {
    var tmp: [32]u8 = undefined;
    const head = std.fmt.bufPrint(&tmp, "{d: >5} {d: >5} ", .{ pid, ppid }) catch "";
    const width = 20 -| head.len;
    @memcpy(buf[0..head.len], head);
    const n = @min(user.len, width);
    @memcpy(buf[head.len .. head.len + n], user[0..n]);
    @memset(buf[head.len + n .. 20], ' ');
    return buf[0..20];
}

/// libbb smart_ulltoa5(): exactly five characters, e.g. "  329", " 329m".
pub fn smartSize5(v_in: u64, buf: []u8) []const u8 {
    const units = " mgtpezy";
    var v = v_in;
    var idx: usize = 0;
    if (v > 99999) {
        v *= 10;
        while (v >= 100000) {
            v /= 1024;
            idx += 1;
        }
    }
    const whole = v / 10;
    const frac = v % 10;
    if (idx == 0) {
        var n: usize = 0;
        while (n < 4) : (n += 1) buf[n] = ' ';
        var tbuf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&tbuf, "{d}", .{v_in}) catch "0";
        const start = 5 - @min(text.len, 5);
        @memcpy(buf[start .. start + text.len], text);
        return buf[0..5];
    }
    if (whole >= 10) {
        var t: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&t, "{d}", .{whole}) catch "0";
        var n: usize = 0;
        while (n < 4 - s.len) : (n += 1) buf[n] = ' ';
        @memcpy(buf[4 - s.len .. 4], s);
    } else {
        buf[0] = @as(u8, @intCast('0' + whole));
        buf[1] = '.';
        buf[2] = @as(u8, @intCast('0' + frac));
        buf[3] = ' ';
    }
    buf[4] = units[@min(idx, units.len - 1)];
    return buf[0..5];
}

fn parsePositive(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn cpuLine(data: []const u8) [10]u64 {
    var result: [10]u64 = std.mem.zeroes([10]u64);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu ")) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next();
        var i: usize = 0;
        while (it.next()) |tok| : (i += 1) {
            if (i >= result.len) break;
            result[i] = std.fmt.parseInt(u64, tok, 10) catch 0;
        }
        break;
    }
    return result;
}

fn loadLine(data: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "cpu ")) continue;
        if (std.mem.indexOfScalar(u8, line, ' ') == null) continue;
        return line;
    }
    return "0.00 0.00 0.00 1/1 1";
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var batch = false;
    var show_threads = false;
    var mem_mode = false;
    var count: ?i64 = null;
    var delay_ms: i64 = 3000;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        for (tok[1..]) |ch| switch (ch) {
            'b' => batch = true,
            'H' => show_threads = true,
            'm' => mem_mode = true,
            'n' => {
                var value = tok[2..];
                if (value.len == 0) {
                    if (i + 1 >= av.len) {
                        c.plainMsg("option requires an argument -- 'n'", .{});
                        c.usageDie(prog);
                    }
                    i += 1;
                    value = av[i];
                }
                count = std.fmt.parseInt(i64, value, 10) catch {
                    c.plainMsg("invalid number '{s}'", .{value});
                    std.process.exit(1);
                };
            },
            'd' => {
                var value = tok[2..];
                if (value.len == 0) {
                    if (i + 1 >= av.len) {
                        c.plainMsg("option requires an argument -- 'd'", .{});
                        c.usageDie(prog);
                    }
                    i += 1;
                    value = av[i];
                }
                const secs = std.fmt.parseFloat(f64, value) catch {
                    c.plainMsg("invalid number '{s}'", .{value});
                    std.process.exit(1);
                };
                delay_ms = @intFromFloat(secs * 1000);
            },
            else => {
                c.plainMsg("invalid option -- '{c}'", .{ch});
                c.usageDie(prog);
            },
        };
    }
    if (count == null) count = -1;

    // The reference top puts the terminal in raw mode so a single 'q' is
    // delivered without waiting for a newline.
    const term = bb.term.termios;
    if (term.isatty(0)) {
        var tio = term.Termios.get(0) catch null;
        if (tio) |*t| {
            // Byte-at-a-time input without echo, but keep OPOST so the pty
            // still translates '\n' to '\r\n' like the reference does.
            t.lflag.ICANON = false;
            t.lflag.ECHO = false;
            t.apply(0) catch {};
        }
    }

    const info = c.sysinfo();
    const stat_data = c.readFile(a, "/proc/stat") orelse return 1;
    defer a.free(stat_data);
    var cpu = cpuLine(stat_data);
    var cpu_total: u64 = 1;
    for (cpu) |v| cpu_total += v;
    const total_mem_kb: u64 = info.totalram / 1024;

    // top.c takes one throwaway sample, sleeps 100 ms, then reports deltas.
    var prev_ticks = std.AutoHashMap(i32, u64).init(a);
    defer prev_ticks.deinit();
    const sample_pids = c.listPids(a, "/proc") catch &.{};
    defer if (sample_pids.len != 0) a.free(sample_pids);
    for (sample_pids) |spid| {
        if (bb.procps.parseProcStat(@intCast(spid)) catch null) |sst| {
            prev_ticks.put(spid, sst.utime + sst.stime) catch {};
        }
    }
    const prev_cpu_total = cpu_total;
    var nap = linux.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = linux.nanosleep(&nap, null);
    if (c.readFile(a, "/proc/stat")) |stat2| {
        defer a.free(stat2);
        cpu = cpuLine(stat2);
        cpu_total = 1;
        for (cpu) |v| cpu_total += v;
    }

    const load_data = c.readFile(a, "/proc/loadavg") orelse return 1;
    defer a.free(load_data);
    const load = loadLine(load_data);
    const total = cpu[0] + cpu[1] + cpu[2] + cpu[3] + cpu[4] + cpu[5] + cpu[6] + cpu[7];
    const idle = cpu[3] + cpu[4];
    const pct = struct {
        fn f(v: u64, t: u64) f64 {
            return @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(@max(t, 1))) * 100;
        }
    }.f;

    if (mem_mode) {
        const mi = c.readFile(a, "/proc/meminfo") orelse return 1;
        defer a.free(mi);
        const value = struct {
            fn f(data: []const u8, key: []const u8) u64 {
                var lines = std.mem.splitScalar(u8, data, '\n');
                while (lines.next()) |line| {
                    if (!std.mem.startsWith(u8, line, key)) continue;
                    var it = std.mem.tokenizeAny(u8, line[key.len..], " \t:");
                    return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
                }
                return 0;
            }
        }.f;
        c.printfOut("Mem total:{d} anon:{d} map:{d} free:{d}\n", .{
            value(mi, "MemTotal"), value(mi, "AnonPages"), value(mi, "Mapped"), value(mi, "MemFree"),
        });
        c.printfOut(" slab:{d} buf:{d} cache:{d} dirty:{d} write:{d}\n", .{
            value(mi, "Slab"), value(mi, "Buffers"), value(mi, "Cached"), value(mi, "Dirty"), value(mi, "Writeback"),
        });
        c.printfOut("Swap total:{d} free:{d}\n", .{ value(mi, "SwapTotal"), value(mi, "SwapFree") });
        c.out("  PID^^^VSZ^VSZRW   RSS (SHR) DIRTY (SHR) STACK COMMAND\n");
        return 0;
    }

    const pids = c.listPids(a, "/proc") catch return 1;
    defer a.free(pids);
    var iteration: i64 = 0;
    while (count.? < 0 or iteration < count.?) : (iteration += 1) {
        const suffix: []const u8 = if (batch) "" else "\x1b[K";
        const home: []const u8 = if (batch) "" else "\x1b[H";
        c.printfOut("{s}Mem: {d}K used, {d}K free, {d}K shrd, {d}K buff, {d}K {s}{s}\n", .{
            home, (info.totalram -| info.freeram) / 1024, info.freeram / 1024, info.sharedram / 1024,
            info.bufferram / 1024, @as(u64, 0), "cached", suffix,
        });
        c.printfOut("CPU:  {d:.1}% usr  {d:.1}% sys  {d:.1}% nic  {d:.1}% idle  {d:.1}% io  {d:.1}% irq  {d:.1}% sirq{s}\n", .{
            pct(cpu[0], total), pct(cpu[2], total), pct(cpu[1], total),
            pct(idle, total), pct(cpu[4], total), pct(cpu[5], total), pct(cpu[6], total), suffix,
        });
        c.printfOut("Load average: {s}{s}\n", .{ load, suffix });
        if (batch) {
            c.out("  PID  PPID USER     STAT   RSS %RSS CPU %CPU COMMAND\n");
        } else {
            c.out("\x1b[7m  PID  PPID USER     STAT   RSS %RSS CPU %CPU COMMAND\x1b[m\x1b[K\n");
        }
        for (pids) |pid| {
            const st = bb.procps.parseProcStat(@intCast(pid)) catch continue;
            const cmd = c.cmdline(a, @intCast(pid)) orelse st.commSlice();
            defer if (cmd.ptr != st.commSlice().ptr) a.free(@constCast(cmd));
            var vals = rowValues(st, c.procUid(@intCast(pid)), total_mem_kb, cpu_total, cpuIndexOf(@intCast(pid)));
            const pt = prev_ticks.get(pid) orelse (st.utime + st.stime);
            vals.cpu_pct = pcpuFromDelta(st.utime + st.stime, pt, cpu_total -| prev_cpu_total);
            const uname = c.userName(a, vals.uid);
            defer if (uname.len != 0) a.free(@constCast(uname));
            const user = if (uname.len != 0) uname[0..@min(uname.len, 8)] else "0";
            var rss_buf: [16]u8 = undefined;
            var col_buf: [64]u8 = undefined;
            var ppu_buf: [32]u8 = undefined;
            const ppu = pidPpidUser(&ppu_buf, @intCast(pid), @as(u32, @bitCast(st.ppid)), user);
            const cols = formatColumns(&col_buf, vals, smartSize5(vals.rss_kb, &rss_buf));
            c.printfOut("{s} {c}    {s} {s}{s}\n", .{ ppu, st.state, cols, cmd, suffix });
            if (show_threads) {
                const task_path = c.procPath(a, @intCast(pid), "task") catch continue;
                defer a.free(task_path);
                const tz = c.zstr(a, task_path) catch continue;
                defer a.free(tz);
                const tfd = linux.open(tz.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
                if (linux.errno(tfd) != .SUCCESS) continue;
                const tfd_t: linux.fd_t = @intCast(tfd);
                defer _ = linux.close(tfd_t);
                var dbuf: [8192]u8 align(8) = undefined;
                const noff = @offsetOf(linux.dirent64, "name");
                const dn = linux.getdents64(tfd_t, &dbuf, dbuf.len);
                if (linux.errno(dn) != .SUCCESS) continue;
                var off: usize = 0;
                while (off + noff <= @as(usize, @intCast(dn))) {
                    const dent: *const linux.dirent64 = @ptrCast(@alignCast(dbuf[off..].ptr));
                    if (dent.reclen == 0) break;
                    const raw = dbuf[off + noff ..][0 .. dent.reclen - noff];
                    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
                    const tid = std.fmt.parseInt(i32, raw[0..end], 10) catch {
                        off += dent.reclen;
                        continue;
                    };
                    off += dent.reclen;
                    if (tid == @as(i32, @intCast(pid))) continue;
                    const tst = bb.procps.parseProcStat(tid) catch continue;
                    var tname_buf: [64]u8 = undefined;
                    const tcomm = tst.commSlice();
                    const tname = std.fmt.bufPrint(&tname_buf, "{{{s}}}", .{tcomm[0..@min(tcomm.len, 15)]}) catch continue;
                    const tvals = rowValues(tst, vals.uid, total_mem_kb, cpu_total, cpuIndexOf(tid));
                    var trss_buf: [16]u8 = undefined;
                    var tcol_buf: [64]u8 = undefined;
                    const tcols = formatColumns(&tcol_buf, tvals, smartSize5(tvals.rss_kb, &trss_buf));
                    var tppu_buf: [32]u8 = undefined;
                    const tppu = pidPpidUser(&tppu_buf, @intCast(tid), @as(u32, @bitCast(st.ppid)), user);
                    c.printfOut("{s} {c}    {s} {s}{s}\n", .{ tppu, tst.state, tcols, tname, suffix });
                }
            }
        }
        c.out("\n");
        if (count.? < 0) {
            if (!batch) {
                var pfd = [_]linux.pollfd{.{ .fd = 0, .events = linux.POLL.IN, .revents = 0 }};
                const rc = linux.poll(&pfd, 1, @intCast(@max(-1, @min(delay_ms, 2_147_483_647))));
                if (linux.errno(rc) == .SUCCESS and (pfd[0].revents & linux.POLL.IN) != 0) {
                    var key: [16]u8 = undefined;
                    const n = linux.read(0, &key, key.len);
                    if (linux.errno(n) == .SUCCESS and n > 0) {
                        if (key[0] == 'q' or key[0] == 'Q' or key[0] == 3) break;
                    }
                }
            }
        }
    }
    return 0;
}
