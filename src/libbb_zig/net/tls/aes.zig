//! AES block and CBC helpers (pure Zig, backed by std.crypto).

const std = @import("std");
const aes = std.crypto.core.aes;

pub const block_len = 16;

pub fn encryptBlock128(key: [16]u8, plaintext: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    var ctx = aes.Aes128.initEnc(key);
    ctx.encrypt(&out, &plaintext);
    return out;
}

pub fn decryptBlock128(key: [16]u8, ciphertext: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    var ctx = aes.Aes128.initDec(key);
    ctx.decrypt(&out, &ciphertext);
    return out;
}

pub fn encryptBlock256(key: [32]u8, plaintext: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    var ctx = aes.Aes256.initEnc(key);
    ctx.encrypt(&out, &plaintext);
    return out;
}

pub fn decryptBlock256(key: [32]u8, ciphertext: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    var ctx = aes.Aes256.initDec(key);
    ctx.decrypt(&out, &ciphertext);
    return out;
}

fn xorBlock(a: *[16]u8, b: []const u8) void {
    for (0..16) |i| a[i] ^= b[i];
}

/// AES-CBC over a whole number of blocks (no padding).
pub fn cbcEncryptNoPad(allocator: std.mem.Allocator, key: []const u8, iv: [16]u8, plaintext: []const u8) ![]u8 {
    if (key.len != 16 and key.len != 32) return error.InvalidKeyLength;
    if (plaintext.len == 0 or plaintext.len % block_len != 0) return error.InvalidCiphertext;
    const out = try allocator.alloc(u8, plaintext.len);
    var prev = iv;
    var off: usize = 0;
    while (off < plaintext.len) : (off += block_len) {
        var block: [16]u8 = undefined;
        @memcpy(&block, plaintext[off .. off + block_len]);
        xorBlock(&block, &prev);
        if (key.len == 16) {
            var k: [16]u8 = undefined;
            @memcpy(&k, key);
            prev = encryptBlock128(k, block);
        } else {
            var k: [32]u8 = undefined;
            @memcpy(&k, key);
            prev = encryptBlock256(k, block);
        }
        @memcpy(out[off .. off + block_len], &prev);
    }
    return out;
}

pub fn cbcDecryptNoPad(allocator: std.mem.Allocator, key: []const u8, iv: [16]u8, ciphertext: []const u8) ![]u8 {
    if (key.len != 16 and key.len != 32) return error.InvalidKeyLength;
    if (ciphertext.len == 0 or ciphertext.len % block_len != 0) return error.InvalidCiphertext;
    const out = try allocator.alloc(u8, ciphertext.len);
    var prev = iv;
    var off: usize = 0;
    while (off < ciphertext.len) : (off += block_len) {
        var block: [16]u8 = undefined;
        @memcpy(&block, ciphertext[off .. off + block_len]);
        var plain: [16]u8 = undefined;
        if (key.len == 16) {
            var k: [16]u8 = undefined;
            @memcpy(&k, key);
            plain = decryptBlock128(k, block);
        } else {
            var k: [32]u8 = undefined;
            @memcpy(&k, key);
            plain = decryptBlock256(k, block);
        }
        xorBlock(&plain, &prev);
        @memcpy(out[off .. off + block_len], &plain);
        prev = block;
    }
    return out;
}

/// AES-CBC with PKCS#7 padding. Caller owns the returned ciphertext.
pub fn cbcEncrypt(allocator: std.mem.Allocator, key: []const u8, iv: [16]u8, plaintext: []const u8) ![]u8 {
    if (key.len != 16 and key.len != 32) return error.InvalidKeyLength;
    const pad: u8 = @intCast(block_len - (plaintext.len % block_len));
    const total = plaintext.len + pad;
    const out = try allocator.alloc(u8, total);
    var prev = iv;
    var off: usize = 0;
    while (off < total) : (off += block_len) {
        var block: [16]u8 = std.mem.zeroes([16]u8);
        const avail = if (off < plaintext.len) @min(block_len, plaintext.len - off) else 0;
        if (avail > 0) @memcpy(block[0..avail], plaintext[off .. off + avail]);
        if (avail < block_len) @memset(block[avail..], pad);
        xorBlock(&block, &prev);
        if (key.len == 16) {
            var key_arr: [16]u8 = undefined;
            @memcpy(&key_arr, key);
            prev = encryptBlock128(key_arr, block);
        } else {
            var key_arr: [32]u8 = undefined;
            @memcpy(&key_arr, key);
            prev = encryptBlock256(key_arr, block);
        }
        @memcpy(out[off .. off + block_len], &prev);
    }
    return out;
}

/// AES-CBC decrypt with PKCS#7 padding validation. Caller owns the plaintext.
pub fn cbcDecrypt(allocator: std.mem.Allocator, key: []const u8, iv: [16]u8, ciphertext: []const u8) ![]u8 {
    if (key.len != 16 and key.len != 32) return error.InvalidKeyLength;
    if (ciphertext.len == 0 or ciphertext.len % block_len != 0) return error.InvalidCiphertext;
    const out = try allocator.alloc(u8, ciphertext.len);
    var prev = iv;
    var off: usize = 0;
    while (off < ciphertext.len) : (off += block_len) {
        var block: [16]u8 = undefined;
        @memcpy(&block, ciphertext[off .. off + block_len]);
        var plain: [16]u8 = undefined;
        if (key.len == 16) {
            var key_arr: [16]u8 = undefined;
            @memcpy(&key_arr, key);
            plain = decryptBlock128(key_arr, block);
        } else {
            var key_arr: [32]u8 = undefined;
            @memcpy(&key_arr, key);
            plain = decryptBlock256(key_arr, block);
        }
        xorBlock(&plain, &prev);
        @memcpy(out[off .. off + block_len], &plain);
        prev = block;
    }
    const pad: usize = out[out.len - 1];
    if (pad == 0 or pad > block_len or pad > out.len) {
        allocator.free(out);
        return error.InvalidPadding;
    }
    for (out[out.len - pad ..]) |b| {
        if (b != pad) {
            allocator.free(out);
            return error.InvalidPadding;
        }
    }
    return allocator.realloc(out, out.len - pad);
}
