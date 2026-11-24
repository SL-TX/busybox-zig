//! SHA-1 / SHA-256 / HMAC wrappers (pure Zig, backed by std.crypto).

const std = @import("std");

pub const Sha1 = std.crypto.hash.Sha1;
pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn sha1(data: []const u8, out: *[20]u8) void {
    Sha1.hash(data, out, .{});
}

pub fn sha256(data: []const u8, out: *[32]u8) void {
    Sha256.hash(data, out, .{});
}

pub fn hmacSha256(key: []const u8, message: []const u8, out: *[32]u8) void {
    std.crypto.auth.hmac.sha2.HmacSha256.create(out, message, key);
}

pub const hex = "0123456789abcdef";

pub fn toHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

pub fn fromHex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, text.len / 2);
    for (0..out.len) |i| {
        out[i] = (std.fmt.charToDigit(text[i * 2], 16) catch return error.InvalidHex) << 4 |
            (std.fmt.charToDigit(text[i * 2 + 1], 16) catch return error.InvalidHex);
    }
    return out;
}
