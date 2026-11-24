//! Terminal attribute helpers ported from busybox's cfmakeraw/tcgetattr use.
//!
//! `Termios` is a plain value type wrapping the Linux kernel termios layout,
//! so applets can inspect and mutate flags directly before applying them.

const std = @import("std");
const linux = std.os.linux;

pub const TCGETS: u32 = 0x5401;
pub const TCSETS: u32 = 0x5402;
pub const TCSETSW: u32 = 0x5403;
pub const TCSETSF: u32 = 0x5404;
pub const TIOCGWINSZ: u32 = 0x5413;
pub const TIOCSWINSZ: u32 = 0x5414;
pub const TIOCSCTTY: u32 = 0x540E;

pub const Error = error{ NotATerminal, SetFailed, UnsupportedBaud };

fn defaultCc() [linux.NCCS]linux.cc_t {
    var cc: [linux.NCCS]linux.cc_t = std.mem.zeroes([linux.NCCS]linux.cc_t);
    const defaults = [_]struct { idx: usize, value: linux.cc_t }{
        .{ .idx = 0, .value = 3 }, // VINTR   ^C
        .{ .idx = 1, .value = 28 }, // VQUIT   ^\
        .{ .idx = 2, .value = 127 }, // VERASE  DEL
        .{ .idx = 3, .value = 21 }, // VKILL   ^U
        .{ .idx = 4, .value = 4 }, // VEOF    ^D
        .{ .idx = 5, .value = 0 }, // VTIME
        .{ .idx = 6, .value = 1 }, // VMIN
        .{ .idx = 8, .value = 17 }, // VSTART  ^Q
        .{ .idx = 9, .value = 19 }, // VSTOP   ^S
        .{ .idx = 10, .value = 26 }, // VSUSP   ^Z
        .{ .idx = 11, .value = 0 }, // VEOL
        .{ .idx = 14, .value = 23 }, // VWERASE ^W
        .{ .idx = 15, .value = 22 }, // VLNEXT  ^V
    };
    for (defaults) |d| {
        if (d.idx < cc.len) cc[d.idx] = d.value;
    }
    return cc;
}

pub const Termios = struct {
    iflag: linux.tc_iflag_t = .{},
    oflag: linux.tc_oflag_t = .{},
    cflag: linux.tc_cflag_t = .{},
    lflag: linux.tc_lflag_t = .{},
    line: linux.cc_t = 0,
    cc: [linux.NCCS]linux.cc_t = defaultCc(),
    ispeed: linux.speed_t = .B0,
    ospeed: linux.speed_t = .B0,

    pub fn fromLinux(kernel: linux.termios) Termios {
        return .{
            .iflag = kernel.iflag,
            .oflag = kernel.oflag,
            .cflag = kernel.cflag,
            .lflag = kernel.lflag,
            .line = kernel.line,
            .cc = kernel.cc,
            .ispeed = kernel.ispeed,
            .ospeed = kernel.ospeed,
        };
    }

    pub fn toLinux(self: *const Termios) linux.termios {
        return .{
            .iflag = self.iflag,
            .oflag = self.oflag,
            .cflag = self.cflag,
            .lflag = self.lflag,
            .line = self.line,
            .cc = self.cc,
            .ispeed = self.ispeed,
            .ospeed = self.ospeed,
        };
    }

    pub fn get(fd: linux.fd_t) Error!Termios {
        var kernel: linux.termios = undefined;
        const rc = linux.ioctl(fd, TCGETS, @intFromPtr(&kernel));
        if (linux.errno(rc) != .SUCCESS) return Error.NotATerminal;
        return fromLinux(kernel);
    }

    /// Apply with one of TCSETS / TCSETSW / TCSETSF.
    pub fn set(self: *const Termios, fd: linux.fd_t, action: u32) Error!void {
        var kernel = self.toLinux();
        const rc = linux.ioctl(fd, action, @intFromPtr(&kernel));
        if (linux.errno(rc) != .SUCCESS) return Error.SetFailed;
    }

    pub fn apply(self: *const Termios, fd: linux.fd_t) Error!void {
        try self.set(fd, TCSETS);
    }

    /// glibc cfmakeraw(): byte-at-a-time, no echo, no signal/flow processing.
    pub fn makeRaw(self: *Termios) void {
        self.iflag.IGNBRK = false;
        self.iflag.BRKINT = false;
        self.iflag.PARMRK = false;
        self.iflag.ISTRIP = false;
        self.iflag.INLCR = false;
        self.iflag.IGNCR = false;
        self.iflag.ICRNL = false;
        self.iflag.IXON = false;
        self.oflag.OPOST = false;
        self.lflag.ECHO = false;
        self.lflag.ECHONL = false;
        self.lflag.ICANON = false;
        self.lflag.ISIG = false;
        self.lflag.IEXTEN = false;
        self.cflag.CSIZE = .CS8;
        self.cflag.PARENB = false;
    }

    /// A complete raw configuration, usable on a freshly opened pty slave.
    pub fn raw() Termios {
        var t = Termios{};
        t.cflag.CREAD = true;
        t.makeRaw();
        return t;
    }

    /// A conventional canonical configuration (echo + line editing + signals).
    pub fn sane() Termios {
        var t = Termios{};
        t.iflag.ICRNL = true;
        t.iflag.IXON = true;
        t.oflag.OPOST = true;
        t.oflag.ONLCR = true;
        t.cflag = .{ .CSIZE = .CS8, .CREAD = true, .HUPCL = true, .CLOCAL = true };
        t.lflag = .{
            .ISIG = true,
            .ICANON = true,
            .ECHO = true,
            .ECHOE = true,
            .ECHOK = true,
            .ECHOCTL = true,
            .ECHOKE = true,
            .IEXTEN = true,
        };
        return t;
    }

    const baud_bits = [_]struct { baud: u32, bits: u32 }{
        .{ .baud = 0, .bits = 0x0000000 },
        .{ .baud = 50, .bits = 0x0000001 },
        .{ .baud = 75, .bits = 0x0000002 },
        .{ .baud = 110, .bits = 0x0000003 },
        .{ .baud = 134, .bits = 0x0000004 },
        .{ .baud = 150, .bits = 0x0000005 },
        .{ .baud = 200, .bits = 0x0000006 },
        .{ .baud = 300, .bits = 0x0000007 },
        .{ .baud = 600, .bits = 0x0000008 },
        .{ .baud = 1200, .bits = 0x0000009 },
        .{ .baud = 1800, .bits = 0x000000a },
        .{ .baud = 2400, .bits = 0x000000b },
        .{ .baud = 4800, .bits = 0x000000c },
        .{ .baud = 9600, .bits = 0x000000d },
        .{ .baud = 19200, .bits = 0x000000e },
        .{ .baud = 38400, .bits = 0x000000f },
    };

    /// Speed as reported in the low cflag bits (standard baud rates).
    pub fn speed(self: *const Termios) u32 {
        const bits: u32 = @as(u32, @bitCast(self.cflag)) & 0xf;
        for (baud_bits) |entry| {
            if (entry.bits == bits) return entry.baud;
        }
        return 0;
    }

    pub fn setSpeed(self: *Termios, baud: u32) Error!void {
        for (baud_bits) |entry| {
            if (entry.baud != baud) continue;
            const bits: linux.tcflag_t = @intCast(entry.bits);
            const cflag_bits: u32 = @bitCast(self.cflag);
            self.cflag = @bitCast((cflag_bits & ~@as(u32, 0xf)) | bits);
            return;
        }
        return Error.UnsupportedBaud;
    }
};

pub fn isatty(fd: linux.fd_t) bool {
    _ = Termios.get(fd) catch return false;
    return true;
}

pub const WindowSize = extern struct {
    row: u16 = 0,
    col: u16 = 0,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub fn getWindowSize(fd: linux.fd_t) Error!WindowSize {
    var ws: WindowSize = .{};
    const rc = linux.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS) return Error.NotATerminal;
    return ws;
}

pub fn setWindowSize(fd: linux.fd_t, ws: *const WindowSize) Error!void {
    const rc = linux.ioctl(fd, TIOCSWINSZ, @intFromPtr(ws));
    if (linux.errno(rc) != .SUCCESS) return Error.SetFailed;
}

/// Task 25 — save/restore guard for editors and daemons that switch a
/// terminal into raw mode. Restoring is idempotent and never panics.
pub const Saved = struct {
    fd: linux.fd_t,
    original: Termios,
    active: bool = false,

    pub fn init(fd: linux.fd_t) Error!Saved {
        return .{ .fd = fd, .original = try Termios.get(fd) };
    }

    pub fn enterRaw(self: *Saved) Error!void {
        var raw = self.original;
        raw.makeRaw();
        try raw.apply(self.fd);
        self.active = true;
    }

    pub fn restore(self: *Saved) void {
        if (!self.active) return;
        self.original.apply(self.fd) catch {};
        self.active = false;
    }
};
