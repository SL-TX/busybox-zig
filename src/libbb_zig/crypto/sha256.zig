//! SHA-224 / SHA-256 (FIPS 180-4) wrappers around Zig's standard library.

const std = @import("std");

pub const Context = std.crypto.hash.sha2.Sha256;
pub const digest_length = 32;
pub const Sha224 = std.crypto.hash.sha2.Sha224;

pub fn hash(bytes: []const u8, out: *[digest_length]u8) void {
    Context.hash(bytes, out, .{});
}

pub fn hash224(bytes: []const u8, out: *[28]u8) void {
    Sha224.hash(bytes, out, .{});
}
