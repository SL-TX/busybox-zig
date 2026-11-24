//! klogd helpers (Task 25): console log level, facility masks and the
//! `<priority>facility` prefix used by /proc/kmsg records.

const std = @import("std");
const lifecycle = @import("lifecycle.zig");
const syslog = @import("syslog.zig");

pub const openKernelLog_requires = lifecycle.Requirement{
    .capability = .root,
    .reason = "reading /proc/kmsg requires root or CAP_SYSLOG",
};

/// Reference klogd uses xatou_range(opt_c, 1, 8): a decimal number in 1..8
/// only. Level 0 disables console output and named priorities map to 0 (e.g.
/// "emerg"), so names and 0 are rejected rather than silently disabling it.
pub fn parseConsoleLevel(text: []const u8) error{InvalidLevel}!u8 {
    const level = std.fmt.parseInt(u8, text, 10) catch return error.InvalidLevel;
    if (level < 1 or level > 8) return error.InvalidLevel;
    return level;
}

pub fn parseFacilityMask(text: []const u8) error{InvalidFacility}!u32 {
    var mask: u32 = 0;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        const facility = syslog.facilityByName(part) orelse return error.InvalidFacility;
        mask |= @as(u32, 1) << @as(u5, @intCast(@intFromEnum(facility)));
    }
    return mask;
}

pub const KernelMessage = struct {
    priority: u8,
    facility: u8,
    payload: []const u8,
};

pub fn parseKernelLine(line: []const u8) error{MalformedMessage}!KernelMessage {
    if (line.len < 4 or line[0] != '<') return error.MalformedMessage;
    const close = std.mem.indexOfScalar(u8, line, '>') orelse return error.MalformedMessage;
    const value = std.fmt.parseInt(u16, line[1..close], 10) catch return error.MalformedMessage;
    if (value > 255) return error.MalformedMessage;
    return .{
        .priority = @intCast(value & 7),
        .facility = @intCast(value >> 3),
        .payload = line[close + 1 ..],
    };
}

/// Open the kernel log device. The requirement is explicit and checked at
/// runtime; callers in unprivileged environments receive a clear error.
pub fn openKernelLog() !std.os.linux.fd_t {
    try lifecycle.checkRequirement(openKernelLog_requires);
    const io = @import("../io.zig");
    return io.open("/proc/kmsg", .{ .ACCMODE = .RDONLY }, 0);
}
