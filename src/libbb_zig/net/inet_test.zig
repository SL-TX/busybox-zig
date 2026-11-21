const std = @import("std");
const inet = @import("libbb_zig").socket.inet;

test "inet parse/format IPv4" {
    const ip = inet.parseV4("192.168.1.10").?;
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 10 }, ip);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("192.168.1.10", inet.formatV4(ip, &buf));
    try std.testing.expect(inet.parseV4("1.2.3") == null);
    try std.testing.expect(inet.parseV4("1.2.3.4.5") == null);
    try std.testing.expect(inet.parseV4("256.0.0.1") == null);
    try std.testing.expect(inet.parseV4("01.02.03.04") != null);
}

test "inet parse/format IPv6" {
    const full = inet.parseV6("2001:0db8:0000:0000:0000:0000:0000:0001").?;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2001:db8::1", inet.formatV6(full, &buf));

    const loop = inet.parseV6("::1").?;
    try std.testing.expectEqualStrings("::1", inet.formatV6(loop, &buf));
    try std.testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, loop);

    const mapped = inet.parseV6("::ffff:192.0.2.1").?;
    try std.testing.expectEqualStrings("::ffff:c000:201", inet.formatV6(mapped, &buf));

    const mid = inet.parseV6("1::2").?;
    try std.testing.expectEqualStrings("1::2", inet.formatV6(mid, &buf));

    try std.testing.expect(inet.parseV6("1::2::3") == null);
    try std.testing.expect(inet.parseV6("1:2:3:4:5:6:7") == null);
    try std.testing.expect(inet.parseV6("gggg::1") == null);
}

test "inet generic parse" {
    try std.testing.expectEqual(inet.Ip{ .v4 = .{ 10, 0, 0, 1 } }, inet.parse("10.0.0.1").?);
    try std.testing.expectEqual(inet.Ip{ .v6 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } }, inet.parse("::1").?);
    try std.testing.expect(inet.parse("not-an-ip") == null);
}

test "inet checksum" {
    // RFC 1071 example.
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try std.testing.expectEqual(@as(u16, 0x220d), inet.cksum(&data));
    // A checksummed block sums to 0xffff.
    var block = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x00, 0x00, 0x00, 0x00 };
    block[6] = 0;
    block[7] = 0;
    const c = inet.cksum(&block);
    block[6] = @truncate(c >> 8);
    block[7] = @truncate(c);
    // With the checksum inserted, recomputing yields 0xffff (normalized 0).
    const total = inet.cksum(&block);
    try std.testing.expect(total == 0 or total == 0xffff);
}
