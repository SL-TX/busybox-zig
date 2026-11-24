//! Shared helpers for the Task 17 procps wave.
//!
//! Thin wiring around the Task 9/12/15 libbb helpers: program name, exact
//! `bb_show_usage()` diagnostics, getopt32, signal lookup, /proc scanning and
//! the small formatting routines the procps applets share. No C and no
//! external command delegation; every /proc file is read with raw syscalls.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const Allocator = std.mem.Allocator;
pub const pid_t = linux.pid_t;

pub fn setName(argv0: []const u8) void {
    bb.env.setProgramName(std.fs.path.basename(argv0));
}

pub fn out(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(1, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn errOut(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn printfOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    out(s);
}

pub fn printfErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    errOut(s);
}

pub fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

pub fn opts(name: []const u8, av: []const []const u8, optstring: []const u8, longs: []const bb.getopt.LongOpt) bb.getopt.Options {
    return bb.getopt.getopt32(av, optstring, longs) catch usageDie(name);
}

pub fn argsFrom(allocator: Allocator, argv: [*][*:0]const u8, argc: c_int) ![][]const u8 {
    return bb.getopt.argsToSlices(allocator, argv, @intCast(argc));
}

pub fn zstr(a: Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn plainMsg(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

pub fn errorMsg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

pub fn errorMsgAndDie(errnum: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    bb.messages.errorMsgAndDie(errnum, fmt, args);
}

/// `<prog>: <msg>\n` followed by exit(1), for bb_error_msg_and_die() paths.
pub fn plainMsgAndDie(comptime fmt: []const u8, args: anytype) noreturn {
    plainMsg(fmt, args);
    std.process.exit(1);
}

pub fn strerror(errnum: c_int) []const u8 {
    return bb.messages.strerror(errnum);
}

// ------------------------------------------------------------------ /proc I/O

pub fn openRead(path: []const u8) ?linux.fd_t {
    const z = zstr(std.heap.page_allocator, path) catch return null;
    defer std.heap.page_allocator.free(z);
    const rc = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn readFile(a: Allocator, path: []const u8) ?[]u8 {
    const fd = openRead(path) orelse return null;
    defer _ = linux.close(fd);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        result.appendSlice(a, buf[0..n]) catch return null;
    }
    return result.toOwnedSlice(a) catch null;
}

pub fn readLink(path: []const u8, buf: []u8) ?[]const u8 {
    const z = zstr(std.heap.page_allocator, path) catch return null;
    defer std.heap.page_allocator.free(z);
    const n = linux.readlink(z.ptr, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return buf[0..n];
}

pub fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Direct child PIDs of `root` (numeric directory names), in readdir order.
pub fn listPids(a: Allocator, root: []const u8) ![]pid_t {
    const z = try zstr(a, root);
    defer a.free(z);
    const rc = linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList(pid_t) = .empty;
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
            if (!allDigits(name)) continue;
            const pid = std.fmt.parseInt(pid_t, name, 10) catch continue;
            try list.append(a, pid);
        }
    }
    return list.toOwnedSlice(a);
}

pub fn procPath(a: Allocator, pid: pid_t, tail: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "/proc/{d}/{s}", .{ pid, tail });
}

/// NUL-separated cmdline rendered with spaces, trimmed at the end.
pub fn cmdline(a: Allocator, pid: pid_t) ?[]const u8 {
    const path = procPath(a, pid, "cmdline") catch return null;
    defer a.free(path);
    const raw = readFile(a, path) orelse return null;
    defer a.free(raw);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    for (raw) |c| result.append(a, if (c == 0) ' ' else c) catch return null;
    const owned = result.toOwnedSlice(a) catch return null;
    return std.mem.trimEnd(u8, owned, " ");
}

pub fn commFromStat(a: Allocator, pid: pid_t) ?[]u8 {
    const path = procPath(a, pid, "stat") catch return null;
    defer a.free(path);
    const raw = readFile(a, path) orelse return null;
    defer a.free(raw);
    const open = std.mem.indexOfScalar(u8, raw, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return null;
    if (close <= open) return null;
    return a.dupe(u8, raw[open + 1 .. close]) catch null;
}

// ------------------------------------------------------------------- signals

pub fn getSignum(name: []const u8) ?c_int {
    return bb.signals_more.signalByName(name) catch null;
}

pub fn signame(sig: c_int, buf: []u8) []const u8 {
    return bb.signals_more.signalName(sig, buf);
}

/// Exact `print_signames()` output used by kill -l, killall -l, pkill -l.
pub fn printSignames() void {
    const names = [_][]const u8{
        "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL",
        "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD",
        "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ",
        "VTALRM", "PROF", "WINCH", "POLL", "PWR", "SYS",
    };
    for (names, 0..) |name, i| printfOut("{d: >2}) {s}\n", .{ i + 1, name });
    printfOut("{d: >2}) {s}\n", .{ 34, "RTMIN" });
    printfOut("{d: >2}) {s}\n", .{ 64, "RTMAX" });
}

// ---------------------------------------------------------- memory/formatting

pub const MemInfo = struct {
    total: u64 = 0,
    free: u64 = 0,
    available: u64 = 0,
    buffers: u64 = 0,
    cached: u64 = 0,
    reclaimable: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
    seen_available: bool = false,
};

fn memValue(line: []const u8, key: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const rest = line[key.len..];
    if (rest.len == 0 or rest[0] != ':') return null;
    var it = std.mem.tokenizeAny(u8, rest[1..], " \t");
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, tok, 10) catch null;
}

pub fn parseMemInfo(data: []const u8) MemInfo {
    var m = MemInfo{};
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (memValue(line, "Cached")) |v| {
            m.cached = v;
            seen += 1;
        }
        if (memValue(line, "MemAvailable")) |v| {
            m.available = v;
            seen += 1;
        }
        if (memValue(line, "SReclaimable")) |v| {
            m.reclaimable = v;
            seen += 1;
        }
        if (seen >= 3) break;
    }
    m.seen_available = seen >= 3;
    // The other fields come from sysinfo(), but parsing them here makes the
    // parser independently testable and supplies a fallback for /proc-only
    // applets such as vmstat and smemcap.
    lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (memValue(line, "MemTotal")) |v| m.total = v else if (memValue(line, "MemFree")) |v| m.free = v else if (memValue(line, "Buffers")) |v| m.buffers = v else if (memValue(line, "SwapTotal")) |v| m.swap_total = v else if (memValue(line, "SwapFree")) |v| m.swap_free = v;
    }
    return m;
}

/// BusyBox make_human_readable_str(val, block_size, display_unit).
pub fn humanReadable(val_in: u64, block_size: u64, display_unit: u64, buf: []u8) []const u8 {
    if (val_in == 0) return "0";
    const unit_chars = "\x00KMGTPEZY";
    var val: u128 = val_in;
    if (block_size > 1) val *= block_size;
    var frac: u32 = 0;
    var u: usize = 0;
    var fmt_kind: enum { plain, frac } = .plain;
    if (display_unit != 0) {
        val += display_unit / 2;
        val /= display_unit;
    } else {
        while (val >= 1024) {
            fmt_kind = .frac;
            u += 1;
            frac = @intCast(((@as(u128, val) % 1024) * 10 + 512) / 1024);
            val /= 1024;
            if (u >= unit_chars.len - 1) break;
        }
        if (frac >= 10) {
            val += 1;
            frac = 0;
        }
        if (block_size == 0) {
            if (frac >= 5) val += 1;
            fmt_kind = .plain;
        }
    }
    if (fmt_kind == .frac) {
        return std.fmt.bufPrint(buf, "{d}.{d}{c}", .{ val, frac, unit_chars[@min(u, unit_chars.len - 1)] }) catch "0";
    }
    if (u != 0 and display_unit == 0 and block_size != 0) {
        return std.fmt.bufPrint(buf, "{d}{c}", .{ val, unit_chars[@min(u, unit_chars.len - 1)] }) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{val}) catch "0";
}

pub fn sysinfo() linux.Sysinfo {
    var info: linux.Sysinfo = undefined;
    _ = linux.sysinfo(&info);
    return info;
}

/// Real uid of a process from /proc/PID/status.
pub fn procUid(pid: pid_t) u32 {
    const path = procPath(std.heap.page_allocator, pid, "status") catch return 0;
    defer std.heap.page_allocator.free(path);
    const data = readFile(std.heap.page_allocator, path) orelse return 0;
    defer std.heap.page_allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var it = std.mem.tokenizeAny(u8, line[4..], " \t");
        return std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    }
    return 0;
}

/// Login name for a uid from /etc/passwd, truncated by the caller's width.
pub fn userName(a: Allocator, uid: u32) []const u8 {
    const data = readFile(a, "/etc/passwd") orelse return "";
    defer a.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, line, ':');
        const name = it.next() orelse continue;
        _ = it.next();
        const uid_s = it.next() orelse continue;
        if ((std.fmt.parseInt(u32, uid_s, 10) catch continue) == uid) return a.dupe(u8, name) catch "";
    }
    return "";
}

/// (dev_major, dev_minor, inode) of a path, using statx so it works without
/// libc. Returns null when the path cannot be stat'ed.
pub const FileId = struct { dev_major: u32, dev_minor: u32, inode: u64 };

pub fn fileId(path: []const u8) ?FileId {
    const z = zstr(std.heap.page_allocator, path) catch return null;
    defer std.heap.page_allocator.free(z);
    var buf: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z.ptr, 0, linux.STATX.BASIC_STATS, &buf);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .dev_major = buf.dev_major, .dev_minor = buf.dev_minor, .inode = buf.ino };
}

/// PIDs whose comm, argv[0] or exe matches `name` (Task 15 helper).
pub fn findPidByName(name: []const u8) []pid_t {
    return bb.procps.findPidByName(name) catch &.{};
}

pub fn freePids(list: []pid_t) void {
    if (list.len != 0) bb.procps.freePidList(list, std.heap.page_allocator);
}
