//! Pseudo-terminal helper ported from busybox libbb/getpty.c.
//!
//! Uses the modern /dev/ptmx + TIOCGPTN interface: the kernel allocates a
//! /dev/pts/N slave with safe ownership when ptmx is opened. No libc calls
//! (grantpt/unlockpt/ptsname) are needed.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");

pub const TIOCSPTLCK: u32 = 0x40045431;
pub const TIOCGPTN: u32 = 0x80045430;
pub const GETPTY_BUFSIZE: usize = 16;

/// Open /dev/ptmx, unlock the slave and write its path into `line`.
/// Returns the master fd, matching busybox's xgetpty(char *line).
pub fn xgetpty(line: []u8) !linux.fd_t {
    if (line.len < 2) return error.NameTooLong;
    const master = try io.open("/dev/ptmx", .{ .ACCMODE = .RDWR }, 0);
    errdefer io.close(master) catch {};

    // unlockpt(): clear the optional slave lock flag.
    var unlocked: c_int = 0;
    _ = linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlocked));

    var minor: c_uint = 0;
    const rc = linux.ioctl(master, TIOCGPTN, @intFromPtr(&minor));
    if (linux.errno(rc) != .SUCCESS) return error.PtyUnavailable;
    const name = std.fmt.bufPrint(line, "/dev/pts/{d}", .{minor}) catch return error.NameTooLong;
    if (name.len + 1 >= line.len) return error.NameTooLong;
    line[name.len] = 0;
    return master;
}

/// Owns a master pty fd and the name of its slave.
pub const Pty = struct {
    master: linux.fd_t = -1,
    name_buf: [GETPTY_BUFSIZE:0]u8 = std.mem.zeroes([GETPTY_BUFSIZE:0]u8),
    name_len: usize = 0,

    pub fn open() !Pty {
        var self = Pty{};
        self.master = try xgetpty(self.name_buf[0 .. self.name_buf.len - 1]);
        self.name_len = std.mem.indexOfScalar(u8, &self.name_buf, 0) orelse return error.PtyUnavailable;
        return self;
    }

    pub fn name(self: *const Pty) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn openSlave(self: *const Pty) !linux.fd_t {
        return io.open(self.name(), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    }

    pub fn close(self: *Pty) void {
        if (self.master >= 0) io.close(self.master) catch {};
        self.master = -1;
    }
};
