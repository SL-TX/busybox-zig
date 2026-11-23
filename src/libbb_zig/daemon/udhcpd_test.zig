//! TDD tests for udhcpd.conf parsing helpers (Task 25).

const std = @import("std");
const bb = @import("libbb_zig");
const udhcpd = bb.daemon.udhcpd;

fn freeSettings(a: std.mem.Allocator, settings: []udhcpd.Setting) void {
    for (settings) |s| {
        a.free(s.key);
        a.free(s.value);
        if (s.extra) |extra| a.free(extra);
    }
    a.free(settings);
}

test "parseIPv4 validates dotted quads without using sockets" {
    try std.testing.expectEqual(@as(u32, 0xc0a80014), try udhcpd.parseIPv4("192.168.0.20"));
    try std.testing.expectError(error.InvalidIP, udhcpd.parseIPv4("192.168.0"));
    try std.testing.expectError(error.InvalidIP, udhcpd.parseIPv4("192.168.0.999"));
    try std.testing.expectError(error.InvalidIP, udhcpd.parseIPv4("1.2.3.4.5"));
}

test "parseUdhcpdConf reads typed settings" {
    const a = std.testing.allocator;
    const text =
        "start 192.168.0.20\n" ++
        "end 192.168.0.254\n" ++
        "interface eth0\n" ++
        "max_leases 235\n" ++
        "option subnet 255.255.255.0\n" ++
        "option router 192.168.0.1\n" ++
        "static_lease 00:11:22:33:44:55 192.168.0.10\n";
    const settings = try udhcpd.parseUdhcpdConf(a, text);
    defer freeSettings(a, settings);
    try std.testing.expectEqual(@as(usize, 7), settings.len);
    try std.testing.expectEqual(udhcpd.Kind.ip, settings[0].kind);
    try std.testing.expectEqual(@as(u32, 0xc0a80014), settings[0].ip);
    try std.testing.expectEqual(udhcpd.Kind.string, settings[2].kind);
    try std.testing.expectEqualStrings("eth0", settings[2].value);
    try std.testing.expectEqual(udhcpd.Kind.number, settings[3].kind);
    try std.testing.expectEqual(@as(u32, 235), settings[3].number);
    try std.testing.expectEqual(udhcpd.Kind.option, settings[4].kind);
    try std.testing.expectEqualStrings("subnet", settings[4].value);
    try std.testing.expectEqual(udhcpd.Kind.static_lease, settings[6].kind);
}

test "parseUdhcpdConf rejects unknown keywords and bad values" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownKeyword, udhcpd.parseUdhcpdConf(a, "bogus 1\n"));
    try std.testing.expectError(error.InvalidIP, udhcpd.parseUdhcpdConf(a, "start 1.2.3\n"));
    try std.testing.expectError(error.InvalidNumber, udhcpd.parseUdhcpdConf(a, "max_leases nope\n"));
    try std.testing.expectError(error.TooFewTokens, udhcpd.parseUdhcpdConf(a, "interface\n"));
}

test "defaults match the busybox udhcpd configuration" {
    const defaults = udhcpd.defaults();
    try std.testing.expectEqualStrings("192.168.0.20", defaults.start_ip);
    try std.testing.expectEqualStrings("192.168.0.254", defaults.end_ip);
    try std.testing.expectEqualStrings("eth0", defaults.interface);
    try std.testing.expectEqual(@as(u32, 235), defaults.max_leases);
    try std.testing.expectEqual(@as(u32, 7200), defaults.auto_time);
}
