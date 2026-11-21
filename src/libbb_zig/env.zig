//! Process environment access for applets.
//! main() installs the map handed to it by Zig's startup; applets read through
//! get() so helpers stay testable with a synthetic map.

const std = @import("std");

pub var map: ?*std.process.Environ.Map = null;

pub fn get(name: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(name);
}

/// Build a NUL-terminated `envp` ("KEY=VALUE" strings) from the installed
/// startup environment map. The caller owns every allocation; use freeEnvp()
/// to release it. With no map installed, returns a vector holding only the
/// terminating null pointer.
pub fn buildEnvp(a: std.mem.Allocator) ![]?[*:0]const u8 {
    const m = map orelse return blk: {
        const empty = try a.alloc(?[*:0]const u8, 1);
        empty[0] = null;
        break :blk empty;
    };
    const count = m.count();
    const out = try a.alloc(?[*:0]const u8, count + 1);
    errdefer a.free(out);
    const keys = m.keys();
    const values = m.values();
    for (keys, values, 0..) |k, v, i| {
        out[i] = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ k, v }, 0);
    }
    out[count] = null;
    return out;
}

/// Release a vector produced by buildEnvp().
pub fn freeEnvp(a: std.mem.Allocator, envp: []?[*:0]const u8) void {
    for (envp) |entry| {
        if (entry) |e| a.free(@constCast(std.mem.span(e)));
    }
    a.free(@constCast(envp));
}

/// Coerce a buildEnvp() vector into the pointer type execve() expects.
pub fn envpPtr(envp: []?[*:0]const u8) [*:null]const ?[*:0]const u8 {
    return @ptrCast(envp.ptr);
}

/// The applet name used as the prefix of every diagnostic message. The
/// storage lives in messages.zig (which never imports this module), so there
/// is no import cycle and tests can override it directly there.
pub fn getProgramName() []const u8 {
    return @import("messages.zig").program_name;
}

pub fn setProgramName(name: []const u8) void {
    @import("messages.zig").program_name = name;
}
