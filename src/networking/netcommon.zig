//! Shared helpers for the networking applet implementations.
//!
//! Mirrors the small libbb surface used by the modutils/util-linux waves:
//! program-name wiring, exact `bb_show_usage()` error paths, getopt32 with an
//! automatic usage exit, and diagnostics with the `<prog>: ` prefix.

const std = @import("std");
pub const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const A = std.heap.page_allocator;
pub const Options = bb.getopt.Options;
pub const LongOpt = bb.getopt.LongOpt;

pub fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return bb.getopt.argsToSlices(A, argv, @intCast(argc)) catch &.{};
}

pub fn setProg(argv: [*][*:0]const u8) void {
    bb.env.setProgramName(std.fs.path.basename(std.mem.span(argv[0])));
}

pub fn out(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(1, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn errout(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn put(comptime fmt: []const u8, args: anytype) void {
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    out(s);
}

pub fn eput(comptime fmt: []const u8, args: anytype) void {
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    errout(s);
}

pub fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

/// getopt32 wrapper: on any parse error getopt32 has already printed the
/// `<prog>: invalid option ...` line; finish with the exact banner + usage.
pub fn opts(name: []const u8, av: []const []const u8, os: []const u8, longopts: []const LongOpt) Options {
    return bb.getopt.getopt32(av, os, longopts) catch usageDie(name);
}

pub fn msg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

pub fn plain(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

pub fn plainDie(comptime fmt: []const u8, args: anytype) noreturn {
    plain(fmt, args);
    std.process.exit(1);
}

pub fn errorDie(errnum: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    bb.messages.errorMsgAndDie(errnum, fmt, args);
}

// ---------------------------------------------------------------- IP helpers

/// Parse a dotted-quad IPv4 address into a host-order integer.
pub fn ipToInt(text: []const u8) ?u32 {
    const net = @import("libbb_zig").socket.inet_pton(text) orelse return null;
    return @byteSwap(net);
}

pub fn intToIp(ip: u32, buf: []u8) []const u8 {
    // `ip` is a host-order integer (e.g. 192.168.1.100 -> 0xC0A80164).
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        @as(u8, @truncate(ip >> 24)),
        @as(u8, @truncate(ip >> 16)),
        @as(u8, @truncate(ip >> 8)),
        @as(u8, @truncate(ip)),
    }) catch "";
}
