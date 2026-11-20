//! Memory and process primitives ported from busybox libbb.
//! Thin wrappers over Linux syscalls; `errno` mirrors the C global so other
//! modules can read the last failing syscall's error number.

const std = @import("std");
const linux = std.os.linux;

pub const pid_t = linux.pid_t;
pub const uid_t = linux.uid_t;
pub const gid_t = linux.gid_t;
pub const fd_t = linux.fd_t;

/// C-style errno, exported so every module shares the same value.
pub var errno: c_int = 0;
/// Globals normally provided by getopt; owned here for cross-module access.
pub var optarg: ?[*:0]const u8 = null;
pub var optind: c_int = 1;

fn check(rc: anytype) !void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        errno = @intFromEnum(e);
        return error.SyscallFailed;
    }
}

// --- memory -----------------------------------------------------------------

pub fn malloc(size: usize) ![]u8 {
    return std.heap.page_allocator.alloc(u8, size);
}

pub fn calloc(n: usize, size: usize) ![]u8 {
    const total = std.math.mul(usize, n, size) catch return error.OutOfMemory;
    const p = try malloc(total);
    @memset(p, 0);
    return p;
}

pub fn realloc(p: []u8, size: usize) ![]u8 {
    return std.heap.page_allocator.realloc(p, size);
}

pub fn free(p: []u8) void {
    std.heap.page_allocator.free(p);
}

// --- identity ---------------------------------------------------------------

pub fn getpid() pid_t {
    return linux.getpid();
}
pub fn getppid() pid_t {
    return linux.getppid();
}
pub fn getuid() uid_t {
    return linux.getuid();
}
pub fn geteuid() uid_t {
    return linux.geteuid();
}
pub fn getgid() gid_t {
    return linux.getgid();
}
pub fn getegid() gid_t {
    return linux.getegid();
}

pub fn getgroups(size: usize, list: ?[*]gid_t) !usize {
    const rc = linux.getgroups(size, list);
    try check(rc);
    return @intCast(rc);
}

// --- descriptors ------------------------------------------------------------

pub fn pipe(fds: *[2]fd_t) !void {
    try check(linux.pipe(fds));
}

pub fn close(fd: fd_t) !void {
    try check(linux.close(fd));
}

pub fn dup2(old: fd_t, new: fd_t) !fd_t {
    const rc = linux.dup2(old, new);
    try check(rc);
    return @intCast(rc);
}

// --- process control --------------------------------------------------------

pub fn fork() !pid_t {
    const rc = linux.fork();
    try check(rc);
    return @intCast(rc);
}

pub fn waitpid(pid: pid_t, status: *i32, flags: u32) !pid_t {
    const rc = linux.waitpid(pid, status, flags);
    try check(rc);
    return @intCast(rc);
}

pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) !noreturn {
    const rc = linux.execve(path, argv, envp);
    try check(rc);
    return error.ExecveFailed;
}

pub fn kill(pid: pid_t, sig: linux.SIG) !void {
    try std.posix.kill(pid, sig);
}

pub fn signal(sig: linux.SIG, handler: ?*const fn (linux.SIG) callconv(.c) void) !void {
    var act = linux.Sigaction{
        .handler = .{ .handler = @ptrCast(handler) },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    try check(linux.sigaction(sig, &act, null));
}

pub fn setuid(uid: uid_t) !void {
    try check(linux.setuid(uid));
}

pub fn setgid(gid: gid_t) !void {
    try check(linux.setgid(gid));
}

pub fn chdir(path: [*:0]const u8) !void {
    try check(linux.chdir(path));
}

pub fn setsid() !pid_t {
    const rc = linux.setsid();
    try check(rc);
    return @intCast(rc);
}
