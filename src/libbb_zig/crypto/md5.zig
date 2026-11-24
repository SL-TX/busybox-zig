//! MD5 (RFC 1321) wrapper around the Zig standard-library implementation.
//! BusyBox uses MD5 both as a checksum tool and as the basis of $1$ crypt.

const std = @import("std");

pub const Context = std.crypto.hash.Md5;
pub const digest_length = 16;

pub fn hash(bytes: []const u8, out: *[digest_length]u8) void {
    Context.hash(bytes, out, .{});
}
