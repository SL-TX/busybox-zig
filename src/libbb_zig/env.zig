//! Process environment access for applets.
//! main() installs the map handed to it by Zig's startup; applets read through
//! get() so helpers stay testable with a synthetic map.

const std = @import("std");

pub var map: ?*std.process.Environ.Map = null;

pub fn get(name: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(name);
}
