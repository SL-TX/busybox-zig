//! utmp/wtmp support ported from busybox libbb/utmp.c.
//! The on-disk format is glibc's 32-bit-time `struct utmp` (384 bytes),
//! which is what Linux uses on x86-64. Helpers take an explicit file path so
//! tests never touch the real /var/run/utmp.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");

pub const UtType = enum(i16) {
    empty = 0,
    run_lvl = 1,
    boot_time = 2,
    new_time = 3,
    old_time = 4,
    init_process = 5,
    login_process = 6,
    user_process = 7,
    dead_process = 8,
    accounting = 9,
};

pub const ExitStatus = extern struct {
    e_termination: i16,
    e_exit: i16,
};

pub const TimeVal32 = extern struct {
    tv_sec: u32,
    tv_usec: i32,
};

/// Binary layout of a glibc `struct utmp` record (384 bytes on x86-64).
pub const NativeUt = extern struct {
    ut_type: i16,
    ut_pid: i32,
    ut_line: [32]u8,
    ut_id: [4]u8,
    ut_user: [32]u8,
    ut_host: [256]u8,
    ut_exit: ExitStatus,
    ut_session: i32,
    ut_tv: TimeVal32,
    ut_addr_v6: [4]i32,
    reserved: [20]u8,
};

comptime {
    if (@sizeOf(NativeUt) != 384) @compileError("unexpected struct utmp layout");
}

/// Strip a leading "/dev/" prefix from a terminal name.
pub fn skipDevPfx(tty: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tty, "/dev/")) tty[5..] else tty;
}

fn safeCopy(dst: []u8, src: []const u8) void {
    @memset(dst, 0);
    const n = @min(dst.len - 1, src.len);
    @memcpy(dst[0..n], src[0..n]);
}

pub const EntryArgs = struct {
    pid: linux.pid_t,
    new_type: UtType,
    tty: []const u8,
    user: ?[]const u8,
    host: ?[]const u8,
    tv_sec: i64,
};

/// Build one utmp record, inventing the 4-byte ut_id the way BusyBox does:
/// "tty1" -> "1", "pts/12" -> "p/12".
pub fn makeEntry(args: EntryArgs) NativeUt {
    var e = std.mem.zeroes(NativeUt);
    e.ut_pid = args.pid;
    e.ut_type = @intFromEnum(args.new_type);

    const tty = skipDevPfx(args.tty);
    safeCopy(&e.ut_line, tty);
    if (args.user) |u| safeCopy(&e.ut_user, u);
    if (args.host) |h| safeCopy(&e.ut_host, h);

    e.ut_tv.tv_sec = @truncate(@as(u64, @bitCast(args.tv_sec)));
    e.ut_tv.tv_usec = 0;

    var id: [4]u8 = .{ 0, 0, 0, 0 };
    var idx: usize = 0;
    if (tty.len > 0 and tty[0] == 'p') {
        id[0] = 'p';
        idx = 1;
    }
    const tail = if (tty.len > 3) tty[3..] else tty;
    const n = @min(tail.len, id.len - idx);
    @memcpy(id[idx .. idx + n], tail[0..n]);
    e.ut_id = id;
    return e;
}

/// Append one record to `path`, creating it if needed.
pub fn appendEntry(path: []const u8, entry: NativeUt) !void {
    const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o664);
    defer io.close(fd) catch {};
    try io.writeAll(fd, std.mem.asBytes(&entry));
}

/// Read all complete records from `path`.
pub fn readEntries(a: std.mem.Allocator, path: []const u8) ![]NativeUt {
    const fd = try io.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer io.close(fd) catch {};

    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try io.read(fd, &buf);
        if (n == 0) break;
        try raw.appendSlice(a, buf[0..n]);
    }
    defer raw.deinit(a);

    const rec_size = @sizeOf(NativeUt);
    const count = raw.items.len / rec_size;
    const out = try a.alloc(NativeUt, count);
    for (0..count) |i| {
        const src = raw.items[i * rec_size ..][0..rec_size];
        @memcpy(std.mem.asBytes(&out[i]), src);
    }
    return out;
}

/// BusyBox-style write_new_utmp(): append a fresh record.
pub fn writeNewUtmp(path: []const u8, pid: linux.pid_t, new_type: UtType, tty: []const u8, user: ?[]const u8, host: ?[]const u8) !void {
    const sec: i64 = @intCast(std.time.timestamp());
    try appendEntry(path, makeEntry(.{
        .pid = pid,
        .new_type = new_type,
        .tty = tty,
        .user = user,
        .host = host,
        .tv_sec = sec,
    }));
}

/// BusyBox-style update_utmp(): update the first matching live record, or
/// append a new one when none exists (except for DEAD_PROCESS).
pub fn updateUtmp(a: std.mem.Allocator, path: []const u8, pid: linux.pid_t, new_type: UtType, tty: ?[]const u8, user: ?[]const u8, host: ?[]const u8) !void {
    const entries = readEntries(a, path) catch @as([]NativeUt, &.{});
    // A zero-length slice may be the static fallback, which must not be freed.
    defer if (entries.len != 0) a.free(entries);

    const sec: i64 = @intCast(std.time.timestamp());
    for (entries) |old| {
        if (old.ut_pid == pid and old.ut_id[0] != 0) {
            var e = old;
            e.ut_type = @intFromEnum(new_type);
            if (tty) |t| safeCopy(&e.ut_line, skipDevPfx(t));
            if (user) |u| safeCopy(&e.ut_user, u);
            if (host) |h| safeCopy(&e.ut_host, h);
            e.ut_tv.tv_sec = @truncate(@as(u64, @bitCast(sec)));
            try appendEntry(path, e); // pututxline semantics: overwrite by id
            return;
        }
    }
    if (new_type != .dead_process) {
        try writeNewUtmp(path, pid, new_type, tty orelse "", user, host);
    }
}

pub fn updateUtmpDeadProcess(a: std.mem.Allocator, path: []const u8, pid: linux.pid_t) !void {
    try updateUtmp(a, path, pid, .dead_process, null, null, null);
}
