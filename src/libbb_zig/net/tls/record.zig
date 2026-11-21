//! TLS record layer and handshake message framing (TLS 1.0-1.2 layout).

const std = @import("std");

pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

pub const header_len = 5;
pub const version_tls12: u16 = 0x0303;

pub const Record = struct {
    content_type: ContentType,
    version: u16,
    fragment: []const u8,
};

pub fn serialize(allocator: std.mem.Allocator, content_type: ContentType, version: u16, fragment: []const u8) ![]u8 {
    if (fragment.len > 0xffff) return error.FragmentTooLarge;
    const out = try allocator.alloc(u8, header_len + fragment.len);
    out[0] = @intFromEnum(content_type);
    std.mem.writeInt(u16, out[1..3], version, .big);
    std.mem.writeInt(u16, out[3..5], @intCast(fragment.len), .big);
    @memcpy(out[header_len..], fragment);
    return out;
}

pub fn parse(data: []const u8) !Record {
    if (data.len < header_len) return error.ShortRecord;
    const ct = std.mem.readInt(u8, data[0..1], .big);
    const content_type: ContentType = @enumFromInt(ct);
    const version = std.mem.readInt(u16, data[1..3], .big);
    const len = std.mem.readInt(u16, data[3..5], .big);
    if (data.len < header_len + len) return error.ShortRecord;
    return .{
        .content_type = content_type,
        .version = version,
        .fragment = data[header_len .. header_len + len],
    };
}

/// Wrap a handshake message body in its 4-byte type/length header.
pub fn makeHandshake(allocator: std.mem.Allocator, msg_type: u8, body: []const u8) ![]u8 {
    if (body.len > 0xffffff) return error.FragmentTooLarge;
    const out = try allocator.alloc(u8, 4 + body.len);
    out[0] = msg_type;
    out[1] = @truncate(body.len >> 16);
    out[2] = @truncate(body.len >> 8);
    out[3] = @truncate(body.len);
    @memcpy(out[4..], body);
    return out;
}

pub const Handshake = struct {
    msg_type: u8,
    body: []const u8,
    consumed: usize,
};

pub fn parseHandshake(data: []const u8) !Handshake {
    if (data.len < 4) return error.ShortHandshake;
    const len = (@as(usize, data[1]) << 16) | (@as(usize, data[2]) << 8) | data[3];
    if (data.len < 4 + len) return error.ShortHandshake;
    return .{
        .msg_type = data[0],
        .body = data[4 .. 4 + len],
        .consumed = 4 + len,
    };
}

pub const handshake_client_hello: u8 = 1;
pub const handshake_server_hello: u8 = 2;
pub const handshake_certificate: u8 = 11;
pub const handshake_finished: u8 = 20;
