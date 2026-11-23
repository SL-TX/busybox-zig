//! TDD tests for klogd helpers (Task 25).

const std = @import("std");
const bb = @import("libbb_zig");
const klog = bb.daemon.klog;
const syslog = bb.daemon.syslog;

test "parseConsoleLevel accepts names and numeric levels" {
    try std.testing.expectEqual(@as(u8, 0), try klog.parseConsoleLevel("emerg"));
    try std.testing.expectEqual(@as(u8, 3), try klog.parseConsoleLevel("err"));
    try std.testing.expectEqual(@as(u8, 8), try klog.parseConsoleLevel("8"));
    try std.testing.expectError(error.InvalidLevel, klog.parseConsoleLevel("bogus"));
    try std.testing.expectError(error.InvalidLevel, klog.parseConsoleLevel("9"));
    try std.testing.expectError(error.InvalidLevel, klog.parseConsoleLevel(""));
}

test "parseFacilityMask maps comma separated names into a bitmask" {
    const mask = try klog.parseFacilityMask("kern,daemon,local0");
    try std.testing.expect((mask & (@as(u32, 1) << @intFromEnum(syslog.Facility.kern))) != 0);
    try std.testing.expect((mask & (@as(u32, 1) << @intFromEnum(syslog.Facility.local0))) != 0);
    try std.testing.expect((mask & (@as(u32, 1) << @intFromEnum(syslog.Facility.mail))) == 0);
    try std.testing.expectError(error.InvalidFacility, klog.parseFacilityMask("kern,bogus"));
}

test "parseKernelLine decodes the priority prefix" {
    const msg = try klog.parseKernelLine("<3>test message\n");
    try std.testing.expectEqual(@as(u8, 3), msg.priority);
    try std.testing.expectEqual(@as(u8, 0), msg.facility);
    try std.testing.expectEqualStrings("test message\n", msg.payload);

    const local = try klog.parseKernelLine("<134>local0 notice");
    try std.testing.expectEqual(@as(u8, 6), local.priority);
    try std.testing.expectEqual(@as(u8, 16), local.facility);
    try std.testing.expectEqualStrings("local0 notice", local.payload);
}

test "parseKernelLine rejects malformed prefixes" {
    try std.testing.expectError(error.MalformedMessage, klog.parseKernelLine("no prefix"));
    try std.testing.expectError(error.MalformedMessage, klog.parseKernelLine("<abc>text"));
    try std.testing.expectError(error.MalformedMessage, klog.parseKernelLine("<999>text"));
    try std.testing.expectError(error.MalformedMessage, klog.parseKernelLine(""));
}

test "kernel log access declares its privileged requirement" {
    const req = klog.openKernelLog_requires;
    try std.testing.expectEqual(bb.daemon.lifecycle.Capability.root, req.capability);
    try std.testing.expect(req.reason.len > 0);
}
