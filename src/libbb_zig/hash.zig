//! Hashing primitives ported from busybox libbb (sha256, md5, crc32).
//! Password-hashing helpers live in pw.zig.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Md5 = std.crypto.hash.Md5;

pub const Sha256Ctx = Sha256;

pub fn sha256_init() Sha256Ctx {
    return Sha256.init(.{});
}

pub fn sha256(bytes: []const u8, out: *[32]u8) void {
    Sha256.hash(bytes, out, .{});
}

pub fn md5(bytes: []const u8, out: *[16]u8) void {
    Md5.hash(bytes, out, .{});
}

pub fn crc32(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}
