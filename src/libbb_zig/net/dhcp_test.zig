const std = @import("std");
const dhcp = @import("libbb_zig").dhcp;
const a = std.testing.allocator;

fn chaddr() [16]u8 {
    var out: [16]u8 = undefined;
    @memset(&out, 0);
    out[0] = 0x00;
    out[1] = 0x11;
    out[2] = 0x22;
    out[3] = 0x33;
    out[4] = 0x44;
    out[5] = 0x55;
    return out;
}

test "DHCP build/parse discover packet" {
    const hostname = "bb-client";
    const extra = [_]dhcp.Option{
        .{ .code = 12, .data = hostname },
        .{ .code = 55, .data = &[_]u8{ 1, 3, 6, 15 } },
    };
    const bytes = try dhcp.buildPacket(a, .discover, 0x11223344, chaddr(), &extra);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, dhcp.bootstrap_len), 236);

    const pkt = try dhcp.parsePacket(bytes);
    try std.testing.expectEqual(@as(u8, 1), pkt.op);
    try std.testing.expectEqual(@as(u8, 1), pkt.htype);
    try std.testing.expectEqual(@as(u8, 6), pkt.hlen);
    try std.testing.expectEqual(@as(u32, 0x11223344), pkt.xid);
    try std.testing.expectEqualSlices(u8, &chaddr(), &pkt.chaddr);
    try std.testing.expectEqual(dhcp.MessageType.discover, pkt.messageType().?);
    try std.testing.expectEqualStrings(hostname, pkt.option(12).?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 6, 15 }, pkt.option(55).?);
    try std.testing.expect(pkt.option(3) == null);
}

test "DHCP offer/ack options" {
    const lease = try dhcp.u32OptionBytes(a, 51, 3600);
    defer a.free(lease.data);
    const router = dhcp.Option{ .code = 3, .data = &[_]u8{ 192, 168, 1, 1 } };
    const mask = dhcp.Option{ .code = 1, .data = &[_]u8{ 255, 255, 255, 0 } };
    const dns = dhcp.Option{ .code = 6, .data = &[_]u8{ 8, 8, 8, 8 } };
    const extra = [_]dhcp.Option{ lease, router, mask, dns };
    const bytes = try dhcp.buildPacket(a, .offer, 7, chaddr(), &extra);
    defer a.free(bytes);

    // Fill in the "your IP" field like a server would.
    @memcpy(bytes[16..20], &[_]u8{ 192, 168, 1, 42 });
    const pkt = try dhcp.parsePacket(bytes);
    try std.testing.expectEqual(dhcp.MessageType.offer, pkt.messageType().?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 42 }, &pkt.yiaddr);
    try std.testing.expectEqual(@as(u32, 3600), pkt.u32Option(51).?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &pkt.ipOption(3).?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 0 }, &pkt.ipOption(1).?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 8, 8, 8 }, &pkt.ipOption(6).?);
}

test "DHCP NAK and malformed packets" {
    const bytes = try dhcp.buildPacket(a, .nak, 99, chaddr(), &.{});
    defer a.free(bytes);
    const pkt = try dhcp.parsePacket(bytes);
    try std.testing.expectEqual(dhcp.MessageType.nak, pkt.messageType().?);

    var bad = try a.dupe(u8, bytes);
    defer a.free(bad);
    bad[236] = 0;
    try std.testing.expectError(error.BadMagic, dhcp.parsePacket(bad));

    try std.testing.expectError(error.ShortPacket, dhcp.parsePacket(bad[0..100]));
}
