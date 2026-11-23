//! HMAC (RFC 2104) wrappers around Zig's standard library.

const std = @import("std");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;

pub fn sha1(key: []const u8, msg: []const u8, out: *[20]u8) void {
    HmacSha1.create(out, msg, key);
}

pub fn sha256(key: []const u8, msg: []const u8, out: *[32]u8) void {
    HmacSha256.create(out, msg, key);
}

pub fn sha512(key: []const u8, msg: []const u8, out: *[64]u8) void {
    HmacSha512.create(out, msg, key);
}
