//! TLS 1.2 pseudorandom function (P_SHA256) and key expansion helpers.

const std = @import("std");
const sha = @import("sha.zig");

/// P_hash(HMAC-SHA256): output blocks are HMAC(secret, A(i) + seed), where
/// A(0) = seed and A(i) = HMAC(secret, A(i-1)).
pub fn pHashSha256(allocator: std.mem.Allocator, secret: []const u8, seed: []const u8, out_len: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    const block = try allocator.alloc(u8, 32 + seed.len);
    defer allocator.free(block);
    @memcpy(block[32..], seed);

    // A(1) = HMAC(secret, A(0)) where A(0) is the whole seed.
    var a: [32]u8 = undefined;
    sha.hmacSha256(secret, seed, &a);

    while (out.items.len < out_len) {
        @memcpy(block[0..32], &a);
        var mac: [32]u8 = undefined;
        sha.hmacSha256(secret, block, &mac);
        const need = @min(@as(usize, 32), out_len - out.items.len);
        try out.appendSlice(allocator, mac[0..need]);
        var next: [32]u8 = undefined;
        sha.hmacSha256(secret, &a, &next);
        a = next;
    }
    return out.toOwnedSlice(allocator);
}

/// TLS 1.2 PRF(secret, label, seed, length) using SHA-256.
pub fn tlsPrfSha256(allocator: std.mem.Allocator, secret: []const u8, label: []const u8, seed: []const u8, out_len: usize) ![]u8 {
    var label_seed = try allocator.alloc(u8, label.len + seed.len);
    defer allocator.free(label_seed);
    @memcpy(label_seed[0..label.len], label);
    @memcpy(label_seed[label.len..], seed);
    return pHashSha256(allocator, secret, label_seed, out_len);
}
