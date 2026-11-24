//! Traditional DES crypt(3) ("DES"), the algorithm used by BusyBox's
//! `cryptpw -m des` / `mkpasswd -m des`.  Pure Zig: a compact DES block
//! cipher plus the salt-dependent key schedule and 25-round feedback used by
//! historical Unix crypt.  Zig's std library has no DES primitive, so this is
//! the one algorithm here implemented directly rather than wrapped.

const std = @import("std");

const itoa64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

const ip = [64]u8{
    58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9,  1, 59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
};
const fp = [64]u8{
    40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
};
const ebox = [48]u8{
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13,
    12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23,
    24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
};
const pbox = [32]u8{
    16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
    2,  8, 24, 14, 32, 27, 3,  9, 19, 13, 30, 6, 22, 11, 4, 25,
};
const pc1 = [56]u8{
    57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
    10, 2,  59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
    14, 6,  61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
};
const pc2 = [48]u8{
    14, 17, 11, 24, 1,  5,  3,  28, 15, 6,  21, 10,
    23, 19, 12, 4,  26, 8,  16, 7,  27, 20, 13, 2,
    41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
};
const shifts = [16]u8{ 1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1 };
const sboxes = [8][64]u8{
    .{ 14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13 },
    .{ 15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9 },
    .{ 10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12 },
    .{ 7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14 },
    .{ 2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3 },
    .{ 12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13 },
    .{ 4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12 },
    .{ 13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11 },
};

/// Permute `value` (in_bits wide, MSB-first table entries) into `table.len` bits.
fn permute(value: u64, comptime table: []const u8, in_bits: usize) u64 {
    var out: u64 = 0;
    inline for (table) |pos| {
        out = (out << 1) | ((value >> @intCast(in_bits - pos)) & 1);
    }
    return out;
}

const Halves = struct { l: u32, r: u32 };

/// The 16 Feistel rounds.  Initial/final permutations are deliberately NOT
/// applied here: traditional DES crypt feeds the preoutput straight back into
/// the rounds 25 times and permutes only once at the very end.  `salt` selects
/// which pairs of expanded-R bits are exchanged (the crypt(3) modification).
fn feistel(l_in: u32, r_in: u32, salt: u12, subkeys: *const [16]u48) Halves {
    var l = l_in;
    var r = r_in;
    for (subkeys) |subkey| {
        var expanded: u48 = @truncate(permute(r, &ebox, 32));
        // crypt(3) salting: exchange expanded-R bits i and i+24 (counted from
        // the MSB) for every set bit of the 12-bit salt.  This is applied to
        // the data, NOT to the subkeys (the S-boxes make the two distinct).
        inline for (0..12) |i| {
            if ((salt >> @intCast(i)) & 1 != 0) {
                const hi: u6 = @intCast(47 - i);
                const lo: u6 = @intCast(23 - i);
                const bit_hi = (expanded >> hi) & 1;
                const bit_lo = (expanded >> lo) & 1;
                expanded = (expanded & ~(@as(u48, 1) << hi)) | (bit_lo << hi);
                expanded = (expanded & ~(@as(u48, 1) << lo)) | (bit_hi << lo);
            }
        }
        const mixed = expanded ^ subkey;
        var s_out: u32 = 0;
        inline for (0..8) |box| {
            const six: u8 = @truncate((mixed >> @intCast(42 - 6 * box)) & 0x3f);
            const row: usize = @as(usize, (six & 0x20) >> 4) | @as(usize, six & 1);
            const col: usize = @as(usize, (six >> 1) & 0xf);
            s_out = (s_out << 4) | sboxes[box][row * 16 + col];
        }
        const f: u32 = @truncate(permute(s_out, &pbox, 32));
        const next = l ^ f;
        l = r;
        r = next;
    }
    return .{ .l = l, .r = r };
}

/// One complete DES encryption of a 64-bit block, with salt-modified subkeys.
fn encryptBlock(block: u64, subkeys: *const [16]u48) u64 {
    const ip_out = permute(block, &ip, 64);
    const halves = feistel(@truncate(ip_out >> 32), @truncate(ip_out), 0, subkeys);
    return permute((@as(u64, halves.r) << 32) | halves.l, &fp, 64);
}

fn makeSubkeys(key: u64) [16]u48 {
    const pc1_out = permute(key, &pc1, 64);
    // u32 (not u28) so a cumulative rotation of 28 is still a legal shift.
    var c: u32 = @truncate(pc1_out >> 28);
    var d: u32 = @as(u32, @truncate(pc1_out)) & 0x0fffffff;
    var out: [16]u48 = undefined;
    for (&out, shifts) |*subkey, shift| {
        // Rotate each half by the incremental shift for this round (the
        // accumulated effect follows from rotating the previous round's half).
        const n: u5 = @intCast(shift);
        c = ((c << n) | (c >> @as(u5, @intCast(28 - n)))) & 0x0fffffff;
        d = ((d << n) | (d >> @as(u5, @intCast(28 - n)))) & 0x0fffffff;
        subkey.* = @truncate(permute((@as(u64, c) << 28) | d, &pc2, 56));
    }
    return out;
}

/// Raw DES encryption of one block.  Exposed for the FIPS 46-3 known-answer
/// test in des_test.zig.
pub fn encryptBlockRaw(key: u64, block: u64) u64 {
    const subkeys = makeSubkeys(key);
    return encryptBlock(block, &subkeys);
}

fn ascii64(c: u8) ?u6 {
    if (std.ascii.isDigit(c)) return @intCast(c - '0');
    if (c >= 'A' and c <= 'Z') return @intCast(c - 'A' + 10);
    if (c >= 'a' and c <= 'z') return @intCast(c - 'a' + 38);
    if (c == '.') return 0;
    if (c == '/') return 1;
    return null;
}

/// DES crypt for a traditional salt.  As in crypt(3), only the first two
/// characters of `salt` are significant: a full 13-byte DES hash can be passed
/// back as the salt (this is what lets pw_encrypt.matches() verify DES hashes).
/// Returns a newly allocated 13-byte string (salt + 11 encoded bytes).
pub fn crypt(a: std.mem.Allocator, key: []const u8, salt: []const u8) ![]u8 {
    if (salt.len < 2) return error.InvalidSalt;
    const s0 = ascii64(salt[0]) orelse return error.InvalidSalt;
    const s1 = ascii64(salt[1]) orelse return error.InvalidSalt;
    const salt_bits: u12 = @as(u12, s0) | (@as(u12, s1) << 6);

    // crypt(3) uses at most eight key bytes, each shifted up one bit; the
    // high bit is dropped, leaving seven significant bits per byte.
    var key_bytes: [8]u8 = @splat(0);
    var k: usize = 0;
    for (&key_bytes) |*b| {
        if (k < key.len and key[k] != 0) {
            b.* = key[k] << 1;
            k += 1;
        }
    }
    var key_u64: u64 = 0;
    for (key_bytes) |b| key_u64 = (key_u64 << 8) | b;

    const subkeys = makeSubkeys(key_u64);

    // 25 DES rounds sequences over zero input; only the final output goes
    // through the inverse initial permutation (as in crypt(3)).
    var l: u32 = 0;
    var r: u32 = 0;
    for (0..25) |_| {
        const halves = feistel(l, r, salt_bits, &subkeys);
        l = halves.r;
        r = halves.l;
    }
    const block = permute((@as(u64, l) << 32) | r, &fp, 64);

    const out = try a.alloc(u8, 13);
    out[0] = salt[0];
    out[1] = salt[1];
    const bits: u128 = @as(u128, block) << 2;
    for (0..11) |i| {
        const shift: u7 = @intCast(66 - 6 * (i + 1));
        out[2 + i] = itoa64[@intCast((bits >> shift) & 0x3f)];
    }
    return out;
}
