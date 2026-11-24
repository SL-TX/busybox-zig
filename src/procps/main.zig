//! procps applet implementations (ps, top, kill, killall, free).
//! Everything is read from /proc; no libc is linked.

const std = @import("std");
const linux = std.os.linux;

pub const init = struct {
    pub fn init() void {}
};

fn out(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}

fn errOut(bytes: []const u8) void {
    _ = linux.write(2, bytes.ptr, bytes.len);
}

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const a = std.heap.page_allocator;
    const result = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| result[i] = std.mem.span(argv[i]);
    return result;
}

fn zstr(a: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    const owned = try std.mem.concatWithSentinel(a, u8, &.{s}, 0);
    return owned.ptr;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

// ------------------------------------------------------------------ parsing

pub const ProcStat = struct {
    pid: i32,
    comm: []const u8,
    state: u8,
    ppid: i32,
    utime: u64,
    stime: u64,
};

pub fn parseProcStat(line: []const u8) ?ProcStat {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close <= open + 1) return null;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, line[0..open], " "), 10) catch return null;
    const comm = line[open + 1 .. close];

    var it = std.mem.tokenizeAny(u8, line[close + 1 ..], " \t");
    const state = it.next() orelse return null;
    if (state.len != 1) return null;
    const ppid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;

    var utime: u64 = 0;
    var stime: u64 = 0;
    var idx: usize = 2; // pgrp follows ppid; utime is index 11, stime 12
    while (it.next()) |tok| : (idx += 1) {
        if (idx == 11) utime = std.fmt.parseInt(u64, tok, 10) catch return null;
        if (idx == 12) stime = std.fmt.parseInt(u64, tok, 10) catch return null;
    }
    return .{ .pid = pid, .comm = comm, .state = state[0], .ppid = ppid, .utime = utime, .stime = stime };
}

// Single-threaded applets only: the result is a view into this buffer.
var cmdline_buf: [8192]u8 = undefined;

pub fn parseProcCmdline(raw: []const u8) []const u8 {
    const n = @min(raw.len, cmdline_buf.len);
    for (raw[0..n], 0..) |c, i| cmdline_buf[i] = if (c == 0) ' ' else c;
    return std.mem.trimEnd(u8, cmdline_buf[0..n], " ");
}

pub fn matchesProcName(cmdline: []const u8, name: []const u8) bool {
    const joined = parseProcCmdline(cmdline);
    var it = std.mem.tokenizeAny(u8, joined, " \t");
    const first = it.next() orelse return false;
    return eq(std.fs.path.basename(first), name);
}

pub fn parseSignal(s: []const u8) !linux.SIG {
    if (allDigits(s)) {
        const n = std.fmt.parseInt(u32, s, 10) catch return error.InvalidSignal;
        if (n > 64) return error.InvalidSignal;
        return @enumFromInt(n);
    }
    var name = s;
    if (std.mem.startsWith(u8, name, "SIG")) name = name[3..];
    const table = [_]struct { name: []const u8, sig: linux.SIG }{
        .{ .name = "HUP", .sig = .HUP },
        .{ .name = "INT", .sig = .INT },
        .{ .name = "QUIT", .sig = .QUIT },
        .{ .name = "ILL", .sig = .ILL },
        .{ .name = "TERM", .sig = .TERM },
        .{ .name = "KILL", .sig = .KILL },
        .{ .name = "STOP", .sig = .STOP },
        .{ .name = "CONT", .sig = .CONT },
        .{ .name = "USR1", .sig = .USR1 },
        .{ .name = "USR2", .sig = .USR2 },
    };
    for (table) |entry| if (eq(name, entry.name)) return entry.sig;
    return error.InvalidSignal;
}

pub const MemInfo = struct {
    total: u64,
    free: u64,
    available: u64,
    buffers: u64,
    cached: u64,
    swap_total: u64,
    swap_free: u64,
};

pub fn parseMemInfo(data: []const u8) !MemInfo {
    var m = MemInfo{ .total = 0, .free = 0, .available = 0, .buffers = 0, .cached = 0, .swap_total = 0, .swap_free = 0 };
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const value = std.fmt.parseInt(u64, rest[0..end], 10) catch continue;
        if (eq(key, "MemTotal")) m.total = value else if (eq(key, "MemFree")) m.free = value else if (eq(key, "MemAvailable")) m.available = value else if (eq(key, "Buffers")) m.buffers = value else if (eq(key, "Cached")) m.cached = value else if (eq(key, "SwapTotal")) m.swap_total = value else if (eq(key, "SwapFree")) m.swap_free = value;
    }
    return m;
}

// ----------------------------------------------------------------- /proc I/O

fn readFile(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    const p = zstr(a, path) catch return null;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var result: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        result.appendSlice(a, buf[0..n]) catch return null;
    }
    return result.toOwnedSlice(a) catch null;
}

fn listProcessDirs(a: std.mem.Allocator) ![][]const u8 {
    const rc = linux.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var buf: [16384]u8 align(8) = undefined;
    const name_off = @offsetOf(linux.dirent64, "name");
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + name_off <= n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const raw = buf[off + name_off ..][0 .. dent.reclen - name_off];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const name = raw[0..end];
            off += dent.reclen;
            if (name.len == 0 or !allDigits(name)) continue;
            try list.append(a, try a.dupe(u8, name));
        }
    }
    return list.toOwnedSlice(a);
}

const Row = struct { stat: ProcStat, command: []const u8 };

fn collectRows(a: std.mem.Allocator) ![]Row {
    const dirs = try listProcessDirs(a);
    defer {
        for (dirs) |d| a.free(d);
        a.free(dirs);
    }
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(a);
    for (dirs) |pid| {
        const stat_path = try std.fmt.allocPrint(a, "/proc/{s}/stat", .{pid});
        defer a.free(stat_path);
        const stat_data = readFile(a, stat_path) orelse continue;
        defer a.free(stat_data);
        const stat = parseProcStat(stat_data) orelse continue;

        const cmd_path = try std.fmt.allocPrint(a, "/proc/{s}/cmdline", .{pid});
        defer a.free(cmd_path);
        const cmd_data = readFile(a, cmd_path);
        defer if (cmd_data) |d| a.free(d);
        const command = if (cmd_data) |d|
            try a.dupe(u8, parseProcCmdline(d))
        else
            try a.dupe(u8, stat.comm);
        try rows.append(a, .{ .stat = stat, .command = command });
    }
    return rows.toOwnedSlice(a);
}

fn freeRows(a: std.mem.Allocator, rows: []Row) void {
    for (rows) |r| a.free(r.command);
    a.free(rows);
}

// ------------------------------------------------------------------- applets

pub fn formatPsRow(pid: i32, ppid: i32, state: u8, command: []const u8, buf: []u8) ![]const u8 {
    // Cast to unsigned: Zig renders positive signed integers with a leading '+'
    // under right-alignment, which ps must not print.
    return std.fmt.bufPrint(buf, "{d: >5} {d: >5} {c}    {s}\n", .{
        @as(u32, @intCast(pid)), @as(u32, @intCast(ppid)), state, command,
    });
}

pub const ps_main = @import("ps.zig").main;

// Task 17 procps wave: one source file per applet, re-exported here so the
// registered `procps` module keeps a single public namespace.

pub const top_main = @import("top.zig").main;
pub const kill_main = @import("kill.zig").main;
pub const killall_main = @import("killall.zig").main;
pub const killall5_main = @import("killall5.zig").main;
pub const free_main = @import("free.zig").main;
pub const fuser_main = @import("fuser.zig").main;
pub const iostat_main = @import("iostat.zig").main;
pub const lsof_main = @import("lsof.zig").main;
pub const mpstat_main = @import("mpstat.zig").main;
pub const nmeter_main = @import("nmeter.zig").main;
pub const pgrep_main = @import("pgrep.zig").main;
pub const pidof_main = @import("pidof.zig").main;
pub const pkill_main = @import("pkill.zig").main;
pub const pmap_main = @import("pmap.zig").main;
pub const powertop_main = @import("powertop.zig").main;
pub const pstree_main = @import("pstree.zig").main;
pub const pwdx_main = @import("pwdx.zig").main;
pub const smemcap_main = @import("smemcap.zig").main;
pub const sysctl_main = @import("sysctl.zig").main;
pub const uptime_main = @import("uptime.zig").main;
pub const vmstat_main = @import("vmstat.zig").main;
pub const watch_main = @import("watch.zig").main;

// Exposed for the unit tests that verify non-trivial computed values.
pub const formatTime = @import("ps.zig").formatTime;
pub const rowValues = @import("top.zig").rowValues;
pub const nmeterScale = @import("nmeter.zig").scale;
pub const iostatCpuPercents = @import("iostat.zig").cpuPercents;
pub const mpstatParseIrqCounts = @import("mpstat.zig").parseIrqCounts;
pub const topFormatColumns = @import("top.zig").formatColumns;
pub const topRowValues = @import("top.zig").rowValues;
pub const topSmartSize5 = @import("top.zig").smartSize5;
