//! The `x*` family of helpers from busybox libbb: allocation, open and I/O
//! wrappers that either succeed or terminate the process with a diagnostic.
//! Error-returning variants use Zig's error unions so callers can opt out.

const std = @import("std");
const linux = std.os.linux;
const messages = @import("messages.zig");
const process = @import("process.zig");

fn pathZ(path: []const u8, buf: *[4096:0]u8) ! [*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

/// Allocate `n` bytes. `xmalloc(0)` returns a valid (freeable) empty slice.
pub fn xmalloc(allocator: std.mem.Allocator, n: usize) ![]u8 {
    return allocator.alloc(u8, n);
}

/// Zero-initialising variant of xmalloc.
pub fn xmallocz(allocator: std.mem.Allocator, n: usize) ![]u8 {
    const p = try allocator.alloc(u8, n);
    @memset(p, 0);
    return p;
}

pub fn xrealloc(allocator: std.mem.Allocator, p: []u8, n: usize) ![]u8 {
    return allocator.realloc(p, n);
}

/// Duplicate a length-delimited slice into freshly allocated memory.
pub fn xstrdup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return allocator.dupe(u8, s);
}

/// Open a path; on syscall failure print a perror-style message and exit 1.
pub fn xopen(path: []const u8, flags: std.posix.O, mode: std.posix.mode_t) !std.posix.fd_t {
    var buf: [4096:0]u8 = undefined;
    const p = pathZ(path, &buf) catch |e| return e;
    const rc = linux.openat(linux.AT.FDCWD, p, flags, mode);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        const errnum: c_int = @intFromEnum(e);
        process.errno = errnum;
        messages.errorMsgAndDie(errnum, "cannot open '{s}'", .{path});
    }
    return @intCast(rc);
}

/// Read once from `fd`. A syscall failure is reported through `process.errno`.
pub fn xread(fd: std.posix.fd_t, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        process.errno = @intFromEnum(e);
        return error.SyscallFailed;
    }
    return @intCast(rc);
}

/// Write every byte of `buf` to `fd`, handling short writes and EINTR.
pub fn xwrite(fd: std.posix.fd_t, buf: []const u8) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.write(fd, buf.ptr + done, buf.len - done);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) {
            process.errno = @intFromEnum(e);
            return error.SyscallFailed;
        }
        done += @intCast(rc);
    }
}

pub fn xclose(fd: std.posix.fd_t) !void {
    const rc = linux.close(fd);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        process.errno = @intFromEnum(e);
        return error.SyscallFailed;
    }
}
