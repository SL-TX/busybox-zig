//! SHA-384 / SHA-512 (FIPS 180-4) wrappers around Zig's standard library.

const std = @import("std");

pub const Context = std.crypto.hash.sha2.Sha512;
pub const digest_length = 64;
pub const Sha384 = std.crypto.hash.sha2.Sha384;

pub fn hash(bytes: []const u8, out: *[digest_length]u8) void {
    Context.hash(bytes, out, .{});
}

pub fn hash384(bytes: []const u8, out: *[48]u8) void {
    Sha384.hash(bytes, out, .{});
}
