//! Tests for framebuffer ioctl wrappers (Task 15).
//! The host has no /dev/fb0; tests use a regular temp file and verify that the
//! helpers detect it rather than fabricating a framebuffer.

const std = @import("std");
const bb = @import("libbb_zig");
const fb = bb.term.fb;
const io = bb.io;

const FAKE = "/tmp/opencode/bb-fake-fb";

test "Fb.open rejects a path that is not a framebuffer" {
    const fd = try io.open(FAKE, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    io.close(fd) catch {};
    defer io.unlink(FAKE) catch {};

    var device = fb.Fb.open(FAKE) catch |e| {
        try std.testing.expectEqual(fb.Error.NotFramebuffer, e);
        return;
    };
    device.close();
    try std.testing.expect(false);
}

test "getVarInfo and blank reject non-framebuffer descriptors" {
    const fd = try io.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer io.close(fd) catch {};
    var device = fb.Fb{ .fd = fd };
    _ = device.getVarInfo() catch |e| {
        try std.testing.expectEqual(fb.Error.NotFramebuffer, e);
        return;
    };
    try std.testing.expect(false);
}

test "blank rejects non-framebuffer descriptors" {
    const fd = try io.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer io.close(fd) catch {};
    var device = fb.Fb{ .fd = fd };
    _ = device.blank(1) catch |e| {
        try std.testing.expectEqual(fb.Error.NotFramebuffer, e);
        return;
    };
    try std.testing.expect(false);
}

test "fix-info queries and mode-setting helpers reject non-framebuffers" {
    const fd = try io.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer io.close(fd) catch {};
    var device = fb.Fb{ .fd = fd };
    var info: fb.VarScreenInfo = std.mem.zeroes(fb.VarScreenInfo);
    if (device.getFixInfo()) |_| {
        try std.testing.expect(false);
    } else |e| try std.testing.expectEqual(fb.Error.NotFramebuffer, e);
    if (device.putVarInfo(&info)) |_| {
        try std.testing.expect(false);
    } else |e| try std.testing.expectEqual(error.IoctlFailed, e);
    if (device.pan(&info)) |_| {
        try std.testing.expect(false);
    } else |e| try std.testing.expectEqual(error.IoctlFailed, e);
}

test "openDefault reports the absence of /dev/fb0 without crashing" {
    var device = fb.Fb.openDefault() catch |e| {
        try std.testing.expectEqual(fb.Error.NotFramebuffer, e);
        return;
    };
    defer device.close();
    try std.testing.expect(device.fd >= 0);
}

test "framebuffer ioctl numbers and struct sizes match the kernel ABI" {
    try std.testing.expectEqual(@as(u32, 0x4600), fb.FBIOGET_VSCREENINFO);
    try std.testing.expectEqual(@as(u32, 0x4601), fb.FBIOPUT_VSCREENINFO);
    try std.testing.expectEqual(@as(u32, 0x4602), fb.FBIOGET_FSCREENINFO);
    try std.testing.expectEqual(@as(u32, 0x4611), fb.FBIOBLANK);
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(fb.VarScreenInfo));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(fb.FixScreenInfo));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(fb.Bitfield));

    var info: fb.VarScreenInfo = std.mem.zeroes(fb.VarScreenInfo);
    info.xres = 800;
    info.yres = 600;
    info.bits_per_pixel = 32;
    try std.testing.expectEqual(@as(u32, 800), info.xres);
    try std.testing.expectEqual(@as(u32, 32), info.bits_per_pixel);
}
