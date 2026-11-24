//! CRC-32 (ISO-HDLC, the variant used by BusyBox's crc32 applet).

const std = @import("std");

pub const Context = std.hash.Crc32;

pub fn init() Context {
    return Context.init();
}

pub fn update(ctx: Context, bytes: []const u8) Context {
    var c = ctx;
    c.update(bytes);
    return c;
}

pub fn final(ctx: Context) u32 {
    return ctx.final();
}

pub fn checksum(bytes: []const u8) u32 {
    return Context.hash(bytes);
}
