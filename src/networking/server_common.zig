//! Shared helpers for the Task 13c network-server applets.
//!
//! Everything here mirrors the small libbb surface used by the client wave:
//! exact getopt32 diagnostics, `bb_show_usage()` on parse errors, numeric
//! option validation with the reference's "invalid number '...'" wording and
//! the `<prog>: ` prefix on diagnostics.

const std = @import("std");
const n = @import("netcommon.zig");
const bb = @import("libbb_zig");
const linux = std.os.linux;

pub const LongOpt = n.LongOpt;

/// Validate a numeric option the way getopt32's `+` modifier does: any
/// non-digit causes `bb_strtou` to fail and the applet dies with
/// "<prog>: invalid number '<text>'".
pub fn parseNum(text: []const u8) u32 {
    if (text.len == 0) n.plainDie("invalid number '{s}'", .{text});
    for (text) |c| if (c < '0' or c > '9') n.plainDie("invalid number '{s}'", .{text});
    return std.fmt.parseInt(u32, text, 10) catch n.plainDie("invalid number '{s}'", .{text});
}

/// Optional form: `-a` with no attached value uses `def`, `-aMSEC` parses MSEC.
pub fn parseNumOpt(text: ?[]const u8, def: u32) u32 {
    return if (text) |t| parseNum(t) else def;
}

pub fn opts(name: []const u8, args: []const []const u8, os: []const u8, longopts: []const LongOpt) n.Options {
    return n.opts(name, args, os, longopts);
}

/// `bb_error_msg("bad address '%s'")` + usage-free exit used by socket servers.
pub fn badAddress(text: []const u8) noreturn {
    n.plainDie("bad address '{s}'", .{text});
}

pub fn errorMsg(err: c_int, comptime fmt: []const u8, args: anytype) void {
    n.errorMsg(err, fmt, args);
}

/// Create a TCP socket bound to a numeric IPv4 address, returning the errno on
/// failure. The caller prints `bind: <strerror>` to match the reference.
pub fn bindTcp(ip: []const u8, port: u16) c_int {
    const fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(fd) != .SUCCESS) return @intFromEnum(linux.errno(fd));
    const sockaddr = @import("libbb_zig").socket.sockaddr_in(ip, port);
    var reuse: c_int = 1;
    _ = linux.setsockopt(@intCast(fd), linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));
    const rc = linux.bind(@intCast(fd), @ptrCast(&sockaddr), @sizeOf(linux.sockaddr.in));
    if (linux.errno(rc) != .SUCCESS) {
        const e = @intFromEnum(linux.errno(rc));
        _ = linux.close(@intCast(fd));
        return e;
    }
    _ = linux.close(@intCast(fd));
    return 0;
}

pub fn strerror(err: c_int) []const u8 {
    return bb.messages.strerror(err);
}

/// `bb_lookup_port()` semantics: a numeric string is a port; anything else is
/// an (unresolvable) service name and produces "bad port '<text>'".
pub fn lookupPort(text: []const u8) u16 {
    var numeric = text.len != 0;
    for (text) |c| if (c < '0' or c > '9') { numeric = false; break; };
    if (!numeric) n.plainDie("bad port '{s}'", .{text});
    return @truncate(parseNum(text));
}

/// `xhost2sockaddr()` with numeric hosts only (no resolver in this port).
pub fn numericHost(text: []const u8) void {
    if (@import("libbb_zig").socket.inet_pton(text) == null) badAddress(text);
}
