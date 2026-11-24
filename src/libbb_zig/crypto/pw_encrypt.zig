//! Password hashing dispatcher matching BusyBox's `crypt(3)` selection:
//! `$1$` MD5-crypt, `$5$`/`$6$` SHA-crypt (with optional `rounds=N$`), and
//! two-character-salt DES crypt.  Yescrypt/Blowfish are recognised but
//! rejected: the reference BusyBox build has no backend for them.

const std = @import("std");
const pw = @import("../pw.zig");
const des = @import("des.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const itoa64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

const rounds_default: u64 = 5000;
const rounds_min: u64 = 1000;
const rounds_max: u64 = 999999999;
const salt_max: usize = 16;

fn appendB64(out: *std.ArrayList(u8), a: std.mem.Allocator, b2: u8, b1: u8, b0: u8, count: usize) !void {
    var v: u32 = (@as(u32, b2) << 16) | (@as(u32, b1) << 8) | b0;
    for (0..count) |_| {
        try out.append(a, itoa64[@intCast(v & 0x3f)]);
        v >>= 6;
    }
}

fn copyRepeated(dest: []u8, src: []const u8) void {
    for (dest, 0..) |*b, i| b.* = src[i % src.len];
}

/// Ulrich Drepper's SHA-crypt (the algorithm in busybox pw_encrypt_sha.c).
fn shaCrypt(comptime H: type, comptime digest_len: usize, a: std.mem.Allocator, key: []const u8, salt_data: []const u8) ![]u8 {
    if (salt_data.len < 4 or salt_data[2] != '$') return error.InvalidSalt;

    var rest = salt_data[3..];
    var rounds: u64 = rounds_default;
    var explicit_rounds = false;
    if (std.mem.startsWith(u8, rest, "rounds=")) {
        if (std.mem.indexOfScalar(u8, rest, '$')) |end| {
            if (std.fmt.parseInt(u64, rest[7..end], 10)) |parsed| {
                rounds = @min(@max(parsed, rounds_min), rounds_max);
                rest = rest[end + 1 ..];
                explicit_rounds = true;
            } else |_| {}
        }
    }
    const salt_end = std.mem.indexOfScalar(u8, rest, '$') orelse rest.len;
    const salt = rest[0..@min(salt_end, salt_max)];
    if (salt.len == 0) return error.InvalidSalt;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, salt_data[0..3]);
    if (explicit_rounds) try out.print(a, "rounds={d}$", .{rounds});
    try out.appendSlice(a, salt);
    try out.append(a, '$');

    var ctx = H.init(.{});
    ctx.update(key);
    ctx.update(salt);

    var alt_ctx = H.init(.{});
    alt_ctx.update(key);
    alt_ctx.update(salt);
    alt_ctx.update(key);
    var alt: [digest_len]u8 = undefined;
    alt_ctx.final(&alt);

    // One byte of the alternate sum per key byte, plus a final partial copy.
    var left = key.len;
    while (left > digest_len) : (left -= digest_len) ctx.update(&alt);
    ctx.update(alt[0..left]);

    // Binary representation of the key length selects alt sum or key.
    var n = key.len;
    while (n != 0) : (n >>= 1) {
        if (n & 1 != 0) ctx.update(&alt) else ctx.update(key);
    }
    ctx.final(&alt);

    // P byte sequence: the password repeated key.len times, then truncated.
    alt_ctx = H.init(.{});
    for (0..key.len) |_| alt_ctx.update(key);
    var temp: [digest_len]u8 = undefined;
    alt_ctx.final(&temp);
    const p_bytes = try a.alloc(u8, key.len);
    defer a.free(p_bytes);
    copyRepeated(p_bytes, &temp);

    // S byte sequence: the salt repeated (16 + alt[0]) times, then truncated.
    alt_ctx = H.init(.{});
    for (0..16 + @as(usize, alt[0])) |_| alt_ctx.update(salt);
    alt_ctx.final(&temp);
    const s_bytes = try a.alloc(u8, salt.len);
    defer a.free(s_bytes);
    copyRepeated(s_bytes, &temp);

    var round: u64 = 0;
    while (round < rounds) : (round += 1) {
        var c = H.init(.{});
        if (round & 1 != 0) c.update(p_bytes) else c.update(&alt);
        if (round % 3 != 0) c.update(s_bytes);
        if (round % 7 != 0) c.update(p_bytes);
        if (round & 1 != 0) c.update(&alt) else c.update(p_bytes);
        c.final(&alt);
    }

    if (digest_len == 32) {
        const triples = [_]struct { a: usize, b: usize, c: usize }{
            .{ .a = 0, .b = 10, .c = 20 }, .{ .a = 21, .b = 1, .c = 11 },
            .{ .a = 12, .b = 22, .c = 2 },  .{ .a = 3, .b = 13, .c = 23 },
            .{ .a = 24, .b = 4, .c = 14 },  .{ .a = 15, .b = 25, .c = 5 },
            .{ .a = 6, .b = 16, .c = 26 },  .{ .a = 27, .b = 7, .c = 17 },
            .{ .a = 18, .b = 28, .c = 8 },  .{ .a = 9, .b = 19, .c = 29 },
        };
        inline for (triples) |t| try appendB64(&out, a, alt[t.a], alt[t.b], alt[t.c], 4);
        try appendB64(&out, a, 0, alt[31], alt[30], 3);
    } else {
        const triples = [_]struct { a: usize, b: usize, c: usize }{
            .{ .a = 0, .b = 21, .c = 42 },  .{ .a = 22, .b = 43, .c = 1 },
            .{ .a = 44, .b = 2, .c = 23 },   .{ .a = 3, .b = 24, .c = 45 },
            .{ .a = 25, .b = 46, .c = 4 },   .{ .a = 47, .b = 5, .c = 26 },
            .{ .a = 6, .b = 27, .c = 48 },   .{ .a = 28, .b = 49, .c = 7 },
            .{ .a = 50, .b = 8, .c = 29 },   .{ .a = 9, .b = 30, .c = 51 },
            .{ .a = 31, .b = 52, .c = 10 },  .{ .a = 53, .b = 11, .c = 32 },
            .{ .a = 12, .b = 33, .c = 54 },  .{ .a = 34, .b = 55, .c = 13 },
            .{ .a = 56, .b = 14, .c = 35 },  .{ .a = 15, .b = 36, .c = 57 },
            .{ .a = 37, .b = 58, .c = 16 },  .{ .a = 59, .b = 17, .c = 38 },
            .{ .a = 18, .b = 39, .c = 60 },  .{ .a = 40, .b = 61, .c = 19 },
            .{ .a = 62, .b = 20, .c = 41 },
        };
        inline for (triples) |t| try appendB64(&out, a, alt[t.a], alt[t.b], alt[t.c], 4);
        try appendB64(&out, a, 0, 0, alt[63], 2);
    }
    @memset(&alt, 0);
    @memset(&temp, 0);
    return out.toOwnedSlice(a);
}

pub fn encrypt(a: std.mem.Allocator, key: []const u8, salt: []const u8) ![]u8 {
    if (salt.len == 0) return error.InvalidSalt;
    if (salt[0] == '$') {
        const end = std.mem.indexOfScalarPos(u8, salt, 1, '$') orelse return error.InvalidSalt;
        const id = salt[1..end];
        if (std.mem.eql(u8, id, "1")) {
            if (end + 1 >= salt.len) return error.InvalidSalt;
            return pw.encryptMd5(a, key, salt[end + 1 ..]);
        }
        if (std.mem.eql(u8, id, "5")) return shaCrypt(Sha256, 32, a, key, salt);
        if (std.mem.eql(u8, id, "6")) return shaCrypt(Sha512, 64, a, key, salt);
        return error.UnsupportedAlgorithm;
    }
    return des.crypt(a, key, salt);
}

/// Verify a password against a hashed string.  Malformed hashes simply do not
/// match; the final comparison is constant time over a fixed-size buffer.
pub fn matches(a: std.mem.Allocator, key: []const u8, hashed: []const u8) !bool {
    if (hashed.len == 0 or hashed.len > 256) return false;
    const expected = encrypt(a, key, hashed) catch return false;
    defer a.free(expected);
    var lhs: [256]u8 = std.mem.zeroes([256]u8);
    var rhs: [256]u8 = std.mem.zeroes([256]u8);
    @memcpy(lhs[0..expected.len], expected);
    @memcpy(rhs[0..hashed.len], hashed);
    return std.crypto.timing_safe.eql([256]u8, lhs, rhs);
}
