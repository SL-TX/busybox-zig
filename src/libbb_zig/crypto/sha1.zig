//! SHA-1 (RFC 3174) wrapper around the Zig standard-library implementation.

const std = @import("std");

pub const Context = std.crypto.hash.Sha1;
pub const digest_length = 20;

pub fn hash(bytes: []const u8, out: *[digest_length]u8) void {
    Context.hash(bytes, out, .{});
}
