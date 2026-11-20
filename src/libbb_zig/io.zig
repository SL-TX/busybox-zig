//! File and stream I/O helpers ported from busybox libbb.

const std = @import("std");
const linux = std.os.linux;
const process = @import("process.zig");

pub const fd_t = linux.fd_t;
pub const mode_t = linux.mode_t;
pub const O = linux.O;
pub const Stat = linux.Statx;
const max_path = 4096;

fn pathZ(path: []const u8, buf: *[max_path:0]u8) ! [*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn check(rc: anytype) !void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        process.errno = @intFromEnum(e);
        return error.SyscallFailed;
    }
}

pub fn open(path: []const u8, flags: O, mode: mode_t) !fd_t {
    var buf: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &buf);
    const rc = linux.open(p, flags, mode);
    try check(rc);
    return @intCast(rc);
}

pub fn close(fd: fd_t) !void {
    try check(linux.close(fd));
}

pub fn read(fd: fd_t, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    try check(rc);
    return @intCast(rc);
}

pub fn write(fd: fd_t, buf: []const u8) !usize {
    const rc = linux.write(fd, buf.ptr, buf.len);
    try check(rc);
    return @intCast(rc);
}

pub fn writeAll(fd: fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        done += try write(fd, bytes[done..]);
    }
}

pub fn lseek(fd: fd_t, offset: i64, whence: u32) !u64 {
    const rc = linux.lseek(fd, offset, whence);
    const signed: i64 = @bitCast(rc);
    if (signed < 0 and signed > -4096) {
        process.errno = @intCast(-signed);
        return error.SyscallFailed;
    }
    return rc;
}

fn fillStat(dirfd: fd_t, path_z: [*:0]const u8, flags: u32) !Stat {
    var stx: Stat = undefined;
    try check(linux.statx(dirfd, path_z, flags, .BASIC_STATS, &stx));
    return stx;
}

pub fn stat(path: []const u8) !Stat {
    var buf: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &buf);
    return fillStat(linux.AT.FDCWD, p, 0);
}

pub fn lstat(path: []const u8) !Stat {
    var buf: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &buf);
    return fillStat(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW);
}

pub fn fstat(fd: fd_t) !Stat {
    return fillStat(fd, "", linux.AT.EMPTY_PATH);
}

pub fn access(path: []const u8, mode: mode_t) !void {
    var buf: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &buf);
    try check(linux.access(p, mode));
}

pub fn unlink(path: []const u8) !void {
    var buf: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &buf);
    try check(linux.unlink(p));
}

pub fn rename(old: []const u8, new: []const u8) !void {
    var a: [max_path:0]u8 = undefined;
    var b: [max_path:0]u8 = undefined;
    const o = try pathZ(old, &a);
    const n = try pathZ(new, &b);
    try check(linux.rename(o, n));
}

pub fn mkdir(path: []const u8, mode: mode_t) !void {
    var buf: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &buf);
    try check(linux.mkdir(p, mode));
}

pub fn rmdir(path: []const u8) !void {
    var buf: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &buf);
    try check(linux.rmdir(p));
}

pub fn isDir(path: []const u8) bool {
    const st = stat(path) catch return false;
    return (st.mode & linux.S.IFMT) == linux.S.IFDIR;
}

pub fn isRegular(path: []const u8) bool {
    const st = stat(path) catch return false;
    return (st.mode & linux.S.IFMT) == linux.S.IFREG;
}

// --- formatted output -------------------------------------------------------

pub fn print(fd: fd_t, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try writeAll(fd, s);
}

pub fn printErr(comptime fmt: []const u8, args: anytype) void {
    print(2, fmt, args) catch {};
}

/// perror-like: prefix with the program name and the last errno description.
pub fn perror(msg: []const u8) void {
    const e: linux.E = @enumFromInt(process.errno);
    printErr("busybox: {s}: {s}\n", .{ msg, @errorName(errorFor(e)) });
}

fn errorFor(e: linux.E) anyerror {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .EXIST => error.PathAlreadyExists,
        else => error.Unexpected,
    };
}

pub fn warn(msg: []const u8) void {
    printErr("busybox: {s}\n", .{msg});
}

pub fn die(msg: []const u8) noreturn {
    warn(msg);
    std.process.exit(1);
}
