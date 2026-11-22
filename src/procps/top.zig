//! top — port of procps/top.c (batch and pty screen rendering).

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

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
    const cpu = cpuLine(stat_data);
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
            info.bufferram / 1024, @as(u64, 0), if (batch) "cached" else "cache", suffix,
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
            c.printfOut("{d: >5} {d: >5} root     {c}   {d: >5} {d: >4} {d: >3} {d: >4} {s}{s}\n", .{
                @as(u32, @intCast(pid)), @as(u32, @bitCast(st.ppid)), st.state,
                @as(u64, 0), @as(u64, 0), @as(u64, 0), @as(u64, 0), cmd, suffix,
            });
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
                    c.printfOut("{d: >5} {d: >5} root     {c}   {d: >5} {d: >4} {d: >3} {d: >4} {s}{s}\n", .{
                        @as(u32, @intCast(tid)), @as(u32, @bitCast(st.ppid)), tst.state,
                        @as(u64, 0), @as(u64, 0), @as(u64, 0), @as(u64, 0), tname, suffix,
                    });
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
