//! ps — port of procps/ps.c (desktop column formatter).

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

const A = std.heap.page_allocator;
const MAX_WIDTH = 2048;

const Spec = struct {
    name: []const u8,
    header: []const u8,
    width: usize,
};

const specs = [_]Spec{
    .{ .name = "user", .header = "USER", .width = 8 },
    .{ .name = "group", .header = "GROUP", .width = 8 },
    .{ .name = "comm", .header = "COMMAND", .width = 16 },
    .{ .name = "args", .header = "COMMAND", .width = MAX_WIDTH },
    .{ .name = "pid", .header = "PID", .width = 5 },
    .{ .name = "ppid", .header = "PPID", .width = 5 },
    .{ .name = "pgid", .header = "PGID", .width = 5 },
    .{ .name = "etime", .header = "ELAPSED", .width = 7 },
    .{ .name = "nice", .header = "NI", .width = 5 },
    .{ .name = "rgroup", .header = "RGROUP", .width = 8 },
    .{ .name = "ruser", .header = "RUSER", .width = 8 },
    .{ .name = "time", .header = "TIME", .width = 5 },
    .{ .name = "tty", .header = "TT", .width = 6 },
    .{ .name = "vsz", .header = "VSZ", .width = 4 },
    .{ .name = "sid", .header = "SID", .width = 5 },
    .{ .name = "stat", .header = "STAT", .width = 4 },
    .{ .name = "rss", .header = "RSS", .width = 4 },
};

const Column = struct { spec: Spec, header: []const u8, width: usize };

fn badO(name: []const u8) noreturn {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    for (specs) |s| {
        const name6 = s.name[0..@min(s.name.len, 6)];
        @memcpy(buf[n..][0..name6.len], name6);
        n += name6.len;
        buf[n] = ',';
        n += 1;
    }
    c.plainMsg("bad -o argument '{s}', supported arguments: {s}", .{ name, buf[0 .. n - 1] });
    std.process.exit(1);
}

fn findSpec(name: []const u8) Spec {
    for (specs) |s| {
        if (std.mem.startsWith(u8, name, s.name[0..@min(s.name.len, 6)]) and
            std.mem.startsWith(u8, s.name, name[0..@min(name.len, 6)])) return s;
    }
    badO(name);
}

fn parseColumns(oarg: []const u8) []Column {
    var cols: std.ArrayList(Column) = .empty;
    var parts = std.mem.splitScalar(u8, oarg, ',');
    while (parts.next()) |part| {
        if (std.mem.indexOfScalar(u8, part, '=')) |eqpos| {
            const s = findSpec(part[0..eqpos]);
            const header = part[eqpos + 1 ..];
            cols.append(A, .{ .spec = s, .header = header, .width = if (header.len != 0) header.len else s.width }) catch {};
        } else {
            const s = findSpec(part);
            cols.append(A, .{ .spec = s, .header = s.header, .width = s.width }) catch {};
        }
    }
    return cols.toOwnedSlice(A) catch &.{};
}

fn userName(uid: u32) []const u8 {
    const data = c.readFile(A, "/etc/passwd") orelse return "";
    defer A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, line, ':');
        const name = it.next() orelse continue;
        _ = it.next();
        const uid_s = it.next() orelse continue;
        if ((std.fmt.parseInt(u32, uid_s, 10) catch continue) == uid) return A.dupe(u8, name) catch "";
    }
    return "";
}

fn smartTime(buf: []u8, ticks: u64) []const u8 {
    var tt = ticks / 100; // seconds
    var ff = tt % 60;
    tt /= 60; // minutes
    if (tt < 60) return std.fmt.bufPrint(buf, "{d: >2}:{d:0>2}", .{ tt, ff }) catch "0:00";
    ff = tt % 60;
    tt /= 60; // hours
    if (tt < 24) return std.fmt.bufPrint(buf, "{d: >2}h{d:0>2}", .{ tt, ff }) catch "0h00";
    ff = tt % 24;
    tt /= 24; // days
    if (tt < 100) return std.fmt.bufPrint(buf, "{d: >2}d{d:0>2}", .{ tt, ff }) catch "0d00";
    return std.fmt.bufPrint(buf, "{d: >4}d", .{tt}) catch "0d";
}

fn smartSize(buf: []u8, bytes: u64) []const u8 {
    const units = " mgtpezy";
    var v = bytes;
    var idx: usize = 0;
    while (v >= 1024 and idx + 1 < units.len) : (idx += 1) v /= 1024;
    if (idx == 0) return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
    return std.fmt.bufPrint(buf, "{d}{c}", .{ v, units[idx] }) catch "0";
}

const Row = struct {
    st: bb.procps.Stat,
    uid: u32,
    cmdline: []const u8,
};

fn uidOf(pid: i32) u32 {
    const path = c.procPath(A, @intCast(pid), "status") catch return 0;
    defer A.free(path);
    const data = c.readFile(A, path) orelse return 0;
    defer A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var it = std.mem.tokenizeAny(u8, line[4..], " \t");
        return std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    }
    return 0;
}

/// read_cmdline(): NULs -> spaces, and "{comm} " prefix when comm != argv0.
fn displayCommand(pid: i32, comm: []const u8, available: usize) []const u8 {
    const short_comm = comm[0..@min(comm.len, 15)];
    const raw = c.cmdline(A, @intCast(pid));
    var out_buf: std.ArrayList(u8) = .empty;
    if (raw) |r| {
        defer A.free(r);
        if (r.len == 0) {
            out_buf.appendSlice(A, std.fmt.allocPrint(A, "[{s}]", .{short_comm}) catch "") catch {};
        } else {
            const first_space = std.mem.indexOfScalar(u8, r, ' ') orelse r.len;
            const argv0 = std.fs.path.basename(r[0..first_space]);
            if (!std.mem.startsWith(u8, argv0, short_comm)) {
                out_buf.append(A, '{') catch {};
                out_buf.appendSlice(A, short_comm) catch {};
                out_buf.appendSlice(A, "} ") catch {};
            }
            out_buf.appendSlice(A, r) catch {};
        }
    } else {
        out_buf.appendSlice(A, std.fmt.allocPrint(A, "[{s}]", .{short_comm}) catch "") catch {};
    }
    const owned = out_buf.toOwnedSlice(A) catch &.{};
    if (available != 0 and owned.len > available) return owned[0..available];
    return owned;
}

/// procps_scan copies at most COMM_LEN-1 (15) bytes of comm.
fn commOf(st: bb.procps.Stat) []const u8 {
    const s = st.commSlice();
    const end = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
    return s[0..@min(end, 15)];
}

fn alignRight(buf: []u8, text: []const u8, width: usize) []const u8 {
    const pad = width -| @min(width, text.len);
    @memset(buf[0..pad], ' ');
    @memcpy(buf[pad .. pad + text.len], text);
    return buf[0 .. pad + text.len];
}

fn cell(buf: []u8, col: Column, row: Row) []const u8 {
    const st = row.st;
    const name = col.spec.name;
    const w = col.width;
    if (std.mem.eql(u8, name, "args")) return row.cmdline;
    if (std.mem.eql(u8, name, "comm")) return commOf(st);
    if (std.mem.eql(u8, name, "user") or std.mem.eql(u8, name, "ruser")) {
        const u = userName(row.uid);
        if (u.len != 0) return u[0..@min(u.len, w)];
        return std.fmt.bufPrint(buf, "{d}", .{row.uid}) catch "";
    }
    if (std.mem.eql(u8, name, "group") or std.mem.eql(u8, name, "rgroup")) {
        const g = userName(row.uid);
        return g[0..@min(g.len, w)];
    }
    if (std.mem.eql(u8, name, "stat")) return std.fmt.bufPrint(buf, "{c}", .{st.state}) catch "";
    if (std.mem.eql(u8, name, "time")) return smartTime(buf, st.utime + st.stime);
    if (std.mem.eql(u8, name, "etime")) return std.fmt.bufPrint(buf, "00:00", .{}) catch "";
    if (std.mem.eql(u8, name, "pid")) return alignRight(buf, std.fmt.bufPrint(buf[1024..], "{d}", .{st.pid}) catch "", w);
    if (std.mem.eql(u8, name, "ppid")) return alignRight(buf, std.fmt.bufPrint(buf[1024..], "{d}", .{st.ppid}) catch "", w);
    if (std.mem.eql(u8, name, "pgid")) return alignRight(buf, std.fmt.bufPrint(buf[1024..], "{d}", .{st.pgrp}) catch "", w);
    if (std.mem.eql(u8, name, "sid")) return alignRight(buf, std.fmt.bufPrint(buf[1024..], "{d}", .{st.session}) catch "", w);
    if (std.mem.eql(u8, name, "nice")) return alignRight(buf, std.fmt.bufPrint(buf[1024..], "{d}", .{st.nice}) catch "", w);
    if (std.mem.eql(u8, name, "vsz")) return alignRight(buf, smartSize(buf[1024..], st.vsize), w);
    if (std.mem.eql(u8, name, "rss")) return alignRight(buf, smartSize(buf[1024..], @intCast(@max(st.rss, 0) * 1024)), w);
    return alignRight(buf, std.fmt.bufPrint(buf[1024..], "{d}", .{st.pid}) catch "", w);
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const av = c.argsFrom(A, argv, argc) catch return 1;
    defer A.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var o_arg: ?[]const u8 = null;
    var show_threads = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') continue;
        for (tok[1..]) |ch| switch (ch) {
            'o' => {
                if (tok.len > 2) {
                    o_arg = tok[2..];
                } else if (i + 1 < av.len) {
                    i += 1;
                    o_arg = av[i];
                } else {
                    c.plainMsg("option requires an argument -- 'o'", .{});
                    c.usageDie(prog);
                }
            },
            'T' => show_threads = true,
            'Z', 'a', 'A', 'd', 'e', 'f', 'l' => {},
            else => {
                c.plainMsg("invalid option -- '{c}'", .{ch});
                c.usageDie(prog);
            },
        };
    }

    const cols = if (o_arg) |o| parseColumns(o) else blk: {
        var list: std.ArrayList(Column) = .empty;
        for ([_][]const u8{ "pid", "user", "time", "args" }) |name| {
            const s = findSpec(name);
            list.append(A, .{ .spec = s, .header = s.header, .width = s.width }) catch {};
        }
        break :blk list.toOwnedSlice(A) catch &.{};
    };

    var line: [MAX_WIDTH + 1]u8 = undefined;
    // Header
    var n: usize = 0;
    for (cols, 0..) |col, idx| {
        if (idx + 1 != cols.len) {
            const pad = col.width -| @min(col.width, col.header.len);
            @memcpy(line[n..][0..col.header.len], col.header);
            n += col.header.len;
            @memset(line[n..][0..pad], ' ');
            n += pad;
            line[n] = ' ';
            n += 1;
        } else {
            @memcpy(line[n..][0..col.header.len], col.header);
            n += col.header.len;
        }
    }
    c.printfOut("{s}\n", .{line[0..@min(n, MAX_WIDTH)]});

    const pids = c.listPids(A, "/proc") catch return 1;
    defer A.free(pids);
    for (pids) |pid| {
        const st = bb.procps.parseProcStat(@intCast(pid)) catch continue;
        const row = Row{
            .st = st,
            .uid = uidOf(@intCast(pid)),
            .cmdline = displayCommand(@intCast(pid), st.commSlice(), MAX_WIDTH),
        };
        defer A.free(@constCast(row.cmdline));
        n = 0;
        for (cols, 0..) |col, idx| {
            var cbuf: [MAX_WIDTH + 1]u8 = undefined;
            const text = cell(&cbuf, col, row);
            const value = if (text.len == 0) "-" else text;
            @memcpy(line[n..][0..value.len], value);
            n += value.len;
            if (idx + 1 != cols.len) {
                const pad = col.width -| @min(col.width, value.len) + 1;
                @memset(line[n..][0..pad], ' ');
                n += pad;
            }
        }
        c.printfOut("{s}\n", .{line[0..@min(n, MAX_WIDTH)]});

        if (show_threads) {
            n = 0;
            // Thread rows use the same fields with a {name} comm.
            const task_path = c.procPath(A, @intCast(pid), "task") catch continue;
            defer A.free(task_path);
            const z = c.zstr(A, task_path) catch continue;
            defer A.free(z);
            const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
            if (linux.errno(fd) != .SUCCESS) continue;
            defer _ = linux.close(@as(linux.fd_t, @intCast(fd)));
            var buf: [16384]u8 align(8) = undefined;
            const noff = @offsetOf(linux.dirent64, "name");
            const cnt = linux.getdents64(@intCast(fd), &buf, buf.len);
            if (linux.errno(cnt) != .SUCCESS) continue;
            var off: usize = 0;
            while (off + noff <= @as(usize, @intCast(cnt))) {
                const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
                if (dent.reclen == 0) break;
                const raw = buf[off + noff ..][0 .. dent.reclen - noff];
                const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
                const tid = std.fmt.parseInt(i32, raw[0..end], 10) catch {
                    off += dent.reclen;
                    continue;
                };
                off += dent.reclen;
                if (tid == @as(i32, @intCast(pid))) continue;
                const tst = bb.procps.parseProcStat(tid) catch continue;
                var tcomm: [64]u8 = undefined;
                const tname = std.fmt.bufPrint(&tcomm, "{{{s}}}", .{commOf(tst)}) catch continue;
                const trow = Row{ .st = tst, .uid = row.uid, .cmdline = A.dupe(u8, tname) catch continue };
                defer A.free(@constCast(trow.cmdline));
                for (cols, 0..) |col, idx| {
                    var cbuf: [MAX_WIDTH + 1]u8 = undefined;
                    const text = cell(&cbuf, col, trow);
                    const value = if (text.len == 0) "-" else text;
                    @memcpy(line[n..][0..value.len], value);
                    n += value.len;
                    if (idx + 1 != cols.len) {
                        const pad = col.width -| @min(col.width, value.len) + 1;
                        @memset(line[n..][0..pad], ' ');
                        n += pad;
                    }
                }
                c.printfOut("{s}\n", .{line[0..@min(n, MAX_WIDTH)]});
                n = 0;
            }
        }
    }
    return 0;
}
