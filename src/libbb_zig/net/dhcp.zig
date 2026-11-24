//! DHCP/BOOTP packet parsing and construction helpers (busybox udhcp wire format).

const std = @import("std");

pub const DhcpError = error{
    ShortPacket,
    BadMagic,
    BadOption,
};

pub const magic_cookie = [_]u8{ 0x63, 0x82, 0x53, 0x63 };
pub const bootstrap_len = 236;
pub const max_options = 128;

pub const MessageType = enum(u8) {
    discover = 1,
    offer = 2,
    request = 3,
    decline = 4,
    ack = 5,
    nak = 6,
    release = 7,
    inform = 8,
};

pub const Option = struct { code: u8, data: []const u8 };

pub const Packet = struct {
    op: u8,
    htype: u8,
    hlen: u8,
    hops: u8,
    xid: u32,
    secs: u16,
    flags: u16,
    ciaddr: [4]u8,
    yiaddr: [4]u8,
    siaddr: [4]u8,
    giaddr: [4]u8,
    chaddr: [16]u8,
    options: [max_options]Option = undefined,
    option_count: usize = 0,

    pub fn messageType(self: Packet) ?MessageType {
        if (self.option(53)) |data| {
            if (data.len == 1 and data[0] >= 1 and data[0] <= 8)
                return @enumFromInt(data[0]);
        }
        return null;
    }

    pub fn option(self: Packet, code: u8) ?[]const u8 {
        for (self.options[0..self.option_count]) |o| {
            if (o.code == code) return o.data;
        }
        return null;
    }

    pub fn ipOption(self: Packet, code: u8) ?[4]u8 {
        const d = self.option(code) orelse return null;
        if (d.len < 4) return null;
        return d[0..4].*;
    }

    pub fn u32Option(self: Packet, code: u8) ?u32 {
        const d = self.option(code) orelse return null;
        if (d.len < 4) return null;
        return std.mem.readInt(u32, d[0..4], .big);
    }
};

/// Parse a DHCP packet. Option data slices point into `data`; the caller must
/// keep `data` alive for as long as the returned Packet is used.
pub fn parsePacket(data: []const u8) DhcpError!Packet {
    if (data.len < bootstrap_len + 4) return error.ShortPacket;
    if (!std.mem.eql(u8, data[236..240], &magic_cookie)) return error.BadMagic;

    var packet = Packet{
        .op = data[0],
        .htype = data[1],
        .hlen = data[2],
        .hops = data[3],
        .xid = std.mem.readInt(u32, data[4..8], .big),
        .secs = std.mem.readInt(u16, data[8..10], .big),
        .flags = std.mem.readInt(u16, data[10..12], .big),
        .ciaddr = data[12..16].*,
        .yiaddr = data[16..20].*,
        .siaddr = data[20..24].*,
        .giaddr = data[24..28].*,
        .chaddr = data[28..44].*,
    };

    var pos: usize = 240;
    while (pos < data.len and packet.option_count < max_options) {
        const code = data[pos];
        pos += 1;
        if (code == 0) continue; // pad
        if (code == 0xff) break; // end
        if (pos >= data.len) return error.BadOption;
        const len = data[pos];
        pos += 1;
        if (pos + len > data.len) return error.BadOption;
        packet.options[packet.option_count] = .{ .code = code, .data = data[pos .. pos + len] };
        packet.option_count += 1;
        pos += len;
    }
    return packet;
}

/// Build a DHCP packet. `extra` options are appended after option 53.
pub fn buildPacket(
    allocator: std.mem.Allocator,
    msg_type: MessageType,
    xid: u32,
    chaddr: [16]u8,
    extra: []const Option,
) ![]u8 {
    var total: usize = bootstrap_len + 4 + 3 + 1;
    for (extra) |o| {
        if (o.data.len > 255) continue;
        total += 2 + o.data.len;
    }
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    out[0] = 1; // BOOTREQUEST
    out[1] = 1; // Ethernet
    out[2] = 6; // hardware address length
    std.mem.writeInt(u32, out[4..8], xid, .big);
    @memcpy(out[28..44], &chaddr);
    @memcpy(out[236..240], &magic_cookie);
    var pos: usize = 240;
    out[pos] = 53;
    out[pos + 1] = 1;
    out[pos + 2] = @intFromEnum(msg_type);
    pos += 3;
    for (extra) |o| {
        if (o.data.len > 255) continue;
        out[pos] = o.code;
        out[pos + 1] = @intCast(o.data.len);
        pos += 2;
        @memcpy(out[pos .. pos + o.data.len], o.data);
        pos += o.data.len;
    }
    out[pos] = 0xff;
    return out;
}

pub fn u32OptionBytes(allocator: std.mem.Allocator, code: u8, value: u32) !Option {
    const bytes = try allocator.alloc(u8, 4);
    std.mem.writeInt(u32, bytes[0..4], value, .big);
    return .{ .code = code, .data = bytes };
}
