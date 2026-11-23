//! Console device detection and VT activation, ported from
//! busybox libbb/get_console.c. Pure ioctl wrappers; no real VT is opened in
//! unit tests.

const std = @import("std");
const linux = std.os.linux;
const io = @import("../io.zig");
const proc = @import("../process.zig");

pub const KDGKBTYPE: u32 = 0x4B33; // get keyboard type (linux/kd.h)
pub const VT_ACTIVATE: u32 = 0x5606;
pub const VT_WAITACTIVE: u32 = 0x5607;
// Task 25 — TIOCSCTTY is used by init/getty when adopting a controlling tty.
pub const TIOCSCTTY: u32 = 0x540E;

pub const DEV_CONSOLE = "/dev/console";
pub const CURRENT_VC = "/dev/tty0";
pub const CURRENT_TTY = "/dev/tty";

pub const Error = error{ NoConsole, NotConsole, NotSessionLeader };

pub const Console = struct {
    fd: linux.fd_t,
    owns_fd: bool = true,

    /// True when the descriptor accepts the KDGKBTYPE console ioctl.
    pub fn isConsole(fd: linux.fd_t) bool {
        var arg: u8 = 0;
        const rc = linux.ioctl(fd, KDGKBTYPE, @intFromPtr(&arg));
        return linux.errno(rc) == .SUCCESS;
    }

    /// Try /dev/console, /dev/tty0, /dev/tty and finally the standard fds.
    pub fn open() !Console {
        const paths = [_][]const u8{ DEV_CONSOLE, CURRENT_VC, CURRENT_TTY };
        const fds = [_]linux.fd_t{ 2, 1, 0 };
        return openWith(&paths, &fds);
    }

    /// Injectable version of open(); useful for tests and Embedded users.
    pub fn openWith(paths: []const []const u8, fallback_fds: []const linux.fd_t) !Console {
        for (paths) |path| {
            if (openOne(path)) |fd| {
                if (isConsole(fd)) return .{ .fd = fd, .owns_fd = true };
                io.close(fd) catch {};
                // Busybox retries the std fd associated with this name.
                continue;
            } else |_| {}
        }
        for (fallback_fds) |fd| {
            if (fd >= 0 and isConsole(fd)) return .{ .fd = fd, .owns_fd = false };
        }
        return Error.NoConsole;
    }

    pub fn makeActive(fd: linux.fd_t, vt_num: c_int) Error!void {
        const arg: usize = @bitCast(@as(i64, vt_num));
        if (linux.errno(linux.ioctl(fd, VT_ACTIVATE, arg)) != .SUCCESS) return Error.NotConsole;
        if (linux.errno(linux.ioctl(fd, VT_WAITACTIVE, arg)) != .SUCCESS) return Error.NotConsole;
    }

    pub fn activate(self: *const Console, vt_num: c_int) Error!void {
        try makeActive(self.fd, vt_num);
    }

    pub fn close(self: *Console) void {
        if (self.owns_fd) io.close(self.fd) catch {};
        self.fd = -1;
    }
};

/// Adopt `fd` as the controlling terminal (TIOCSCTTY). A caller that is not a
/// session leader gets an explicit error instead of a silent failure.
pub fn acquireControllingTerminal(fd: linux.fd_t) Error!void {
    const rc = linux.ioctl(fd, TIOCSCTTY, 0);
    const e = linux.errno(rc);
    if (e == .PERM) return error.NotSessionLeader;
    if (e != .SUCCESS) return error.NotConsole;
}

fn openOne(path: []const u8) !linux.fd_t {
    const modes = [_]io.O{
        .{ .ACCMODE = .RDWR },
        .{ .ACCMODE = .RDONLY },
        .{ .ACCMODE = .WRONLY },
    };
    var last_error: anyerror = error.OpenFailed;
    for (modes) |flags| {
        const fd = io.open(path, flags, 0) catch |e| {
            last_error = e;
            if (proc.errno == @backingInt(linux.E.ACCES)) continue;
            break;
        };
        return fd;
    }
    return last_error;
}
