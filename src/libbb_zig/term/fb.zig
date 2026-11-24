//! Linux framebuffer ioctl helpers used by console-tools applets.
//! Structures mirror <linux/fb.h> byte for byte (x86-64 kernel ABI).

const std = @import("std");
const linux = std.os.linux;
const io = @import("../io.zig");

pub const FBIOGET_VSCREENINFO: u32 = 0x4600;
pub const FBIOPUT_VSCREENINFO: u32 = 0x4601;
pub const FBIOGET_FSCREENINFO: u32 = 0x4602;
pub const FBIOPAN_DISPLAY: u32 = 0x4606;
pub const FBIOBLANK: u32 = 0x4611;

pub const FB_BLANK_UNBLANK: c_int = 0;
pub const FB_BLANK_NORMAL: c_int = 1;

pub const Error = error{ NotFramebuffer, IoctlFailed };

pub const Bitfield = extern struct {
    offset: u32 = 0,
    length: u32 = 0,
    msb_right: u32 = 0,
};

pub const VarScreenInfo = extern struct {
    xres: u32 = 0,
    yres: u32 = 0,
    xres_virtual: u32 = 0,
    yres_virtual: u32 = 0,
    xoffset: u32 = 0,
    yoffset: u32 = 0,
    bits_per_pixel: u32 = 0,
    grayscale: u32 = 0,
    red: Bitfield = .{},
    green: Bitfield = .{},
    blue: Bitfield = .{},
    transp: Bitfield = .{},
    nonstd: u32 = 0,
    activate: u32 = 0,
    height: u32 = 0,
    width: u32 = 0,
    accel_flags: u32 = 0,
    pixclock: u32 = 0,
    left_margin: u32 = 0,
    right_margin: u32 = 0,
    upper_margin: u32 = 0,
    lower_margin: u32 = 0,
    hsync_len: u32 = 0,
    vsync_len: u32 = 0,
    sync: u32 = 0,
    vmode: u32 = 0,
    rotate: u32 = 0,
    colorspace: u32 = 0,
    reserved: [4]u32 = std.mem.zeroes([4]u32),
};

pub const FixScreenInfo = extern struct {
    id: [16]u8 = std.mem.zeroes([16]u8),
    smem_start: usize = 0,
    smem_len: u32 = 0,
    type: u32 = 0,
    type_aux: u32 = 0,
    visual: u32 = 0,
    xpanstep: u16 = 0,
    ypanstep: u16 = 0,
    ywrapstep: u16 = 0,
    line_length: u32 = 0,
    mmio_start: usize = 0,
    mmio_len: u32 = 0,
    accel: u32 = 0,
    capabilities: u16 = 0,
    reserved: [2]u16 = std.mem.zeroes([2]u16),
};

pub const Fb = struct {
    fd: linux.fd_t,

    /// Open a framebuffer device and verify it answers FBIOGET_VSCREENINFO.
    pub fn open(path: []const u8) Error!Fb {
        const fd = io.open(path, .{ .ACCMODE = .RDWR }, 0) catch return Error.NotFramebuffer;
        errdefer io.close(fd) catch {};
        var info: VarScreenInfo = undefined;
        const rc = linux.ioctl(fd, FBIOGET_VSCREENINFO, @intFromPtr(&info));
        if (linux.errno(rc) != .SUCCESS) return Error.NotFramebuffer;
        return .{ .fd = fd };
    }

    pub fn openDefault() Error!Fb {
        return open("/dev/fb0");
    }

    pub fn getVarInfo(self: *const Fb) Error!VarScreenInfo {
        var info: VarScreenInfo = undefined;
        const rc = linux.ioctl(self.fd, FBIOGET_VSCREENINFO, @intFromPtr(&info));
        if (linux.errno(rc) != .SUCCESS) return Error.NotFramebuffer;
        return info;
    }

    pub fn getFixInfo(self: *const Fb) Error!FixScreenInfo {
        var info: FixScreenInfo = undefined;
        const rc = linux.ioctl(self.fd, FBIOGET_FSCREENINFO, @intFromPtr(&info));
        if (linux.errno(rc) != .SUCCESS) return Error.NotFramebuffer;
        return info;
    }

    pub fn putVarInfo(self: *const Fb, info: *const VarScreenInfo) Error!void {
        const rc = linux.ioctl(self.fd, FBIOPUT_VSCREENINFO, @intFromPtr(info));
        if (linux.errno(rc) != .SUCCESS) return error.IoctlFailed;
    }

    pub fn pan(self: *const Fb, info: *const VarScreenInfo) Error!void {
        const rc = linux.ioctl(self.fd, FBIOPAN_DISPLAY, @intFromPtr(info));
        if (linux.errno(rc) != .SUCCESS) return error.IoctlFailed;
    }

    pub fn blank(self: *const Fb, mode: c_int) Error!void {
        const rc = linux.ioctl(self.fd, FBIOBLANK, @bitCast(@as(i64, mode)));
        if (linux.errno(rc) != .SUCCESS) return Error.NotFramebuffer;
    }

    pub fn close(self: *Fb) void {
        io.close(self.fd) catch {};
        self.fd = -1;
    }
};
