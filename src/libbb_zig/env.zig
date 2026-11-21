//! Process environment access for applets.
//! main() installs the map handed to it by Zig's startup; applets read through
//! get() so helpers stay testable with a synthetic map.

const std = @import("std");

pub var map: ?*std.process.Environ.Map = null;

pub fn get(name: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(name);
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
