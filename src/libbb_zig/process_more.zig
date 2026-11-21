//! Extra process helpers ported from busybox libbb/vfork_daemon_rexec.c.
//!
//! `vfork`, `spawn`, `spawnAndWait`, daemonisation and task-name helpers used
//! by applets that need to launch or background other programs.

const std = @import("std");
const linux = std.os.linux;
const proc = @import("process.zig");
const env = @import("env.zig");

pub const pid_t = linux.pid_t;

pub const vfork = proc.vfork;

fn zargv(a: std.mem.Allocator, argv: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const list = try a.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| list[i] = try std.fmt.allocPrintSentinel(a, "{s}", .{arg}, 0);
    list[argv.len] = null;
    return @ptrCast(list.ptr);
}

/// Fork and exec `argv[0]` directly. argv[0] must contain a path separator
/// (BusyBox's PATH search relies on libc environ, unavailable in this
/// libc-free build). Returns the child pid to the parent.
pub fn spawn(argv: []const []const u8) !pid_t {
    if (argv.len == 0) return error.InvalidArgument;
    const a = std.heap.page_allocator;
    const pathz = try std.fmt.allocPrintSentinel(a, "{s}", .{argv[0]}, 0);
    const zargs = try zargv(a, argv);
    // Children inherit the environment installed by main(), just as a
    // BusyBox-spawned program inherits environ.
    const envp = try env.buildEnvp(a);
    defer env.freeEnvp(a, envp);

    const pid = try proc.fork();
    if (pid == 0) {
        _ = linux.execve(pathz, zargs, env.envpPtr(envp));
        linux.exit(111);
    }
    return pid;
}

/// Translate a wait status into the 8-bit exit code BusyBox applets return.
pub fn wait4pid(pid: pid_t) !u8 {
    var status: i32 = 0;
    _ = try proc.wait4(pid, &status, 0);
    if ((status & 0x7f) == 0) return @intCast((status >> 8) & 0xff);
    return @intCast((status & 0x7f) | 0x80);
}

/// Spawn a process, wait for it, and return its exit status.
pub fn spawnAndWait(argv: []const []const u8) !u8 {
    const pid = try spawn(argv);
    return wait4pid(pid);
}

pub const DaemonOptions = struct {
    /// chdir("/") before detaching.
    chdir_root: bool = false,
    /// Redirect stdin/stdout/stderr to /dev/null in the child.
    redirect_stdio: bool = true,
};

const pr_set_name: c_int = 15;
const pr_get_name: c_int = 16;

/// Detach a child process from the controlling terminal. The parent returns
/// the child's pid; the (new session leader) child returns 0. A plain fork is
/// used internally because the child continues to run Zig code after the
/// call, which is unsafe with shared-stack vfork semantics.
pub fn vforkDaemon(opts: DaemonOptions) !pid_t {
    if (opts.chdir_root) try proc.chdirPath("/");

    var fd: linux.fd_t = -1;
    if (opts.redirect_stdio) {
        const rc = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(rc) == .SUCCESS) {
            fd = @intCast(rc);
        } else {
            const rc2 = linux.open("/", .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(rc2) == .SUCCESS) fd = @intCast(rc2);
        }
    }

    const pid = try proc.fork();
    if (pid != 0) return pid;

    _ = try proc.setsid();
    if (fd >= 0) {
        _ = linux.dup2(fd, 0);
        _ = linux.dup2(fd, 1);
        _ = linux.dup2(fd, 2);
        if (fd > 2) _ = linux.close(fd);
    }
    return 0;
}

/// Set the kernel task name (visible in /proc/self/comm, capped at 15 chars).
pub fn setTaskComm(name: []const u8) void {
    var buf: [16:0]u8 = undefined;
    const n = @min(name.len, 15);
    @memcpy(buf[0..n], name[0..n]);
    buf[n] = 0;
    _ = proc.prctl(pr_set_name, @intFromPtr(&buf), 0, 0, 0) catch {};
}

/// True when the current task name matches the BusyBox binary name.
pub fn reExecedComm() bool {
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    _ = proc.prctl(pr_get_name, @intFromPtr(&buf), 0, 0, 0) catch return false;
    return std.mem.startsWith(u8, std.mem.sliceTo(&buf, 0), "busybox");
}
