//! SHA-3 and Keccak (FIPS 202) wrappers around Zig's standard library.
//! BusyBox exposes these through the sha3sum applet.

const std = @import("std");

pub const Sha3_224 = std.crypto.hash.sha3.Sha3_224;
pub const Sha3_256 = std.crypto.hash.sha3.Sha3_256;
pub const Sha3_384 = std.crypto.hash.sha3.Sha3_384;
pub const Sha3_512 = std.crypto.hash.sha3.Sha3_512;
pub const Keccak256 = std.crypto.hash.sha3.Keccak256;

pub fn hash256(bytes: []const u8, out: *[32]u8) void {
    Sha3_256.hash(bytes, out, .{});
}

pub fn hash384(bytes: []const u8, out: *[48]u8) void {
    Sha3_384.hash(bytes, out, .{});
}

pub fn hash512(bytes: []const u8, out: *[64]u8) void {
    Sha3_512.hash(bytes, out, .{});
}

pub fn keccak256(bytes: []const u8, out: *[32]u8) void {
    Keccak256.hash(bytes, out, .{});
}
