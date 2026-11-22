//! RSA primitives in pure Zig: big-integer modular exponentiation, a minimal
//! DER SubjectPublicKeyInfo parser and PKCS#1 v1.5 signature verification.

const std = @import("std");
const Big = std.math.big.int.Managed;
const sha = @import("sha.zig");

pub const RsaError = error{
    InvalidKey,
    InvalidSignature,
    OutOfMemory,
};

fn assign(allocator: std.mem.Allocator, dst: *Big, src: *const Big) !void {
    const text = try src.toString(allocator, 16, .lower);
    defer allocator.free(text);
    try dst.setString(16, text);
}

fn reduce(allocator: std.mem.Allocator, value: *Big, modulus: *const Big, q: *Big, r: *Big) !void {
    try q.divFloor(r, value, modulus);
    try assign(allocator, value, r);
}

/// Return base^exponent mod modulus as a big-endian byte string of exactly
/// modulus.len bytes. All inputs are big-endian bytes.
pub fn powMod(allocator: std.mem.Allocator, base: []const u8, exponent: []const u8, modulus: []const u8) ![]u8 {
    if (modulus.len == 0 or exponent.len == 0) return error.InvalidKey;

    const base_hex = try sha.toHex(allocator, base);
    defer allocator.free(base_hex);
    const exp_hex = try sha.toHex(allocator, exponent);
    defer allocator.free(exp_hex);
    const mod_hex = try sha.toHex(allocator, modulus);
    defer allocator.free(mod_hex);

    var b = try Big.init(allocator);
    defer b.deinit();
    var e = try Big.init(allocator);
    defer e.deinit();
    var m = try Big.init(allocator);
    defer m.deinit();
    var result = try Big.init(allocator);
    defer result.deinit();
    var q = try Big.init(allocator);
    defer q.deinit();
    var r = try Big.init(allocator);
    defer r.deinit();
    var tmp = try Big.init(allocator);
    defer tmp.deinit();

    try b.setString(16, base_hex);
    try e.setString(16, exp_hex);
    try m.setString(16, mod_hex);
    try result.set(@as(u8, 1));

    try reduce(allocator, &b, &m, &q, &r);

    const bits = e.bitCountAbs();
    for (0..bits) |_| {
        if (e.isOdd()) {
            try tmp.mul(&result, &b);
            try assign(allocator, &result, &tmp);
            try reduce(allocator, &result, &m, &q, &r);
        }
        try tmp.mul(&b, &b);
        try assign(allocator, &b, &tmp);
        try reduce(allocator, &b, &m, &q, &r);
        try e.shiftRight(&e, 1);
    }

    const text = try result.toString(allocator, 16, .lower);
    defer allocator.free(text);
    const out = try allocator.alloc(u8, modulus.len);
    @memset(out, 0);
    var di: usize = text.len;
    var oi: usize = out.len;
    while (di > 0 and oi > 0) {
        oi -= 1;
        const hi: u8 = if (di >= 2) std.fmt.charToDigit(text[di - 2], 16) catch 0 else 0;
        const lo: u8 = std.fmt.charToDigit(text[di - 1], 16) catch 0;
        out[oi] = (hi << 4) | lo;
        di = if (di >= 2) di - 2 else 0;
    }
    return out;
}

/// Faster modular exponentiation: the Task 12 `powMod` converts both operands
/// to hex on every loop iteration; the handshake path needs many 2048-bit
/// exponentiations, so operate directly on Managed integers and swap buffers.
pub fn powModFast(allocator: std.mem.Allocator, base: []const u8, exponent: []const u8, modulus: []const u8) ![]u8 {
    if (modulus.len == 0 or exponent.len == 0) return error.InvalidKey;

    const base_hex = try sha.toHex(allocator, base);
    defer allocator.free(base_hex);
    const exp_hex = try sha.toHex(allocator, exponent);
    defer allocator.free(exp_hex);
    const mod_hex = try sha.toHex(allocator, modulus);
    defer allocator.free(mod_hex);

    var b = try Big.init(allocator);
    defer b.deinit();
    var e = try Big.init(allocator);
    defer e.deinit();
    var m = try Big.init(allocator);
    defer m.deinit();
    var result = try Big.init(allocator);
    defer result.deinit();
    var q = try Big.init(allocator);
    defer q.deinit();
    var r = try Big.init(allocator);
    defer r.deinit();
    var tmp = try Big.init(allocator);
    defer tmp.deinit();

    try b.setString(16, base_hex);
    try e.setString(16, exp_hex);
    try m.setString(16, mod_hex);
    try result.set(@as(u8, 1));
    try q.divFloor(&r, &b, &m);
    b.swap(&r);

    const bits = e.bitCountAbs();
    for (0..bits) |_| {
        if (e.isOdd()) {
            try tmp.mul(&result, &b);
            result.swap(&tmp);
            try q.divFloor(&r, &result, &m);
            result.swap(&r);
        }
        try tmp.mul(&b, &b);
        b.swap(&tmp);
        try q.divFloor(&r, &b, &m);
        b.swap(&r);
        try e.shiftRight(&e, 1);
    }

    const text = try result.toString(allocator, 16, .lower);
    defer allocator.free(text);
    const out = try allocator.alloc(u8, modulus.len);
    @memset(out, 0);
    var di: usize = text.len;
    var oi: usize = out.len;
    while (di > 0 and oi > 0) {
        oi -= 1;
        const hi: u8 = if (di >= 2) std.fmt.charToDigit(text[di - 2], 16) catch 0 else 0;
        const lo: u8 = std.fmt.charToDigit(text[di - 1], 16) catch 0;
        out[oi] = (hi << 4) | lo;
        di = if (di >= 2) di - 2 else 0;
    }
    return out;
}

const Tlv = struct { tag: u8, value: []const u8, next: usize };

fn readTlv(data: []const u8, pos: usize) !Tlv {
    if (pos + 2 > data.len) return error.InvalidKey;
    const tag = data[pos];
    var len: usize = data[pos + 1];
    var hdr: usize = 2;
    if (len & 0x80 != 0) {
        const n = len & 0x7f;
        if (n == 0 or n > 4 or pos + 2 + n > data.len) return error.InvalidKey;
        len = 0;
        for (0..n) |i| len = (len << 8) | data[pos + 2 + i];
        hdr = 2 + n;
    }
    if (pos + hdr + len > data.len) return error.InvalidKey;
    return .{ .tag = tag, .value = data[pos + hdr .. pos + hdr + len], .next = pos + hdr + len };
}

fn readInteger(data: []const u8, pos: usize) !struct { value: []const u8, next: usize } {
    const tlv = try readTlv(data, pos);
    if (tlv.tag != 0x02) return error.InvalidKey;
    var value = tlv.value;
    while (value.len > 1 and value[0] == 0) value = value[1..];
    return .{ .value = value, .next = tlv.next };
}

pub const PublicKey = struct {
    modulus: []u8,
    exponent: []u8,
    pub fn deinit(self: *PublicKey, allocator: std.mem.Allocator) void {
        allocator.free(self.modulus);
        allocator.free(self.exponent);
    }
};

/// Parse an ASN.1 DER SubjectPublicKeyInfo holding an rsaEncryption key.
pub fn parsePublicKeyDer(allocator: std.mem.Allocator, der: []const u8) !PublicKey {
    const outer = try readTlv(der, 0);
    if (outer.tag != 0x30) return error.InvalidKey;
    const alg = try readTlv(outer.value, 0);
    if (alg.tag != 0x30) return error.InvalidKey;
    const bits = try readTlv(outer.value, alg.next);
    if (bits.tag != 0x03 or bits.value.len < 2) return error.InvalidKey;
    const rsa = try readTlv(bits.value[1..], 0);
    if (rsa.tag != 0x30) return error.InvalidKey;
    const n = try readInteger(rsa.value, 0);
    const e = try readInteger(rsa.value, n.next);
    const mod = try allocator.dupe(u8, n.value);
    const exp = try allocator.dupe(u8, e.value);
    return .{ .modulus = mod, .exponent = exp };
}

const sha256_prefix = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
};

/// Verify an RSASSA-PKCS1-v1_5 SHA-256 signature.
pub fn verifyPkcs1V15Sha256(
    allocator: std.mem.Allocator,
    modulus: []const u8,
    exponent: []const u8,
    message: []const u8,
    signature: []const u8,
) !void {
    if (signature.len != modulus.len) return error.InvalidSignature;
    const em = try powModFast(allocator, signature, exponent, modulus);
    defer allocator.free(em);
    if (em[0] != 0x00 or em[1] != 0x01) return error.InvalidSignature;
    var i: usize = 2;
    const ff_start = i;
    while (i < em.len and em[i] == 0xff) i += 1;
    if (i - ff_start < 8 or i >= em.len or em[i] != 0x00) return error.InvalidSignature;
    i += 1;
    const rest = em[i..];
    if (rest.len < sha256_prefix.len + 32) return error.InvalidSignature;
    if (!std.mem.eql(u8, rest[0..sha256_prefix.len], &sha256_prefix)) return error.InvalidSignature;
    var digest: [32]u8 = undefined;
    sha.sha256(message, &digest);
    if (!std.mem.eql(u8, rest[sha256_prefix.len .. sha256_prefix.len + 32], &digest))
        return error.InvalidSignature;
}

pub const PrivateKey = struct {
    modulus: []u8,
    private_exponent: []u8,
    pub fn deinit(self: *PrivateKey, allocator: std.mem.Allocator) void {
        allocator.free(self.modulus);
        allocator.free(self.private_exponent);
    }
};

fn parsePrivateKeyDer(allocator: std.mem.Allocator, der: []const u8) !PrivateKey {
    const seq = try readTlv(der, 0);
    if (seq.tag != 0x30) return error.InvalidKey;
    const v = try readInteger(seq.value, 0);
    if (v.value.len == 1 and v.value[0] == 1) {
        // PKCS#8 PrivateKeyInfo: version, AlgorithmIdentifier, OCTET STRING.
        const alg = try readTlv(seq.value, v.next);
        if (alg.tag != 0x30) return error.InvalidKey;
        const oct = try readTlv(seq.value, alg.next);
        if (oct.tag != 0x04) return error.InvalidKey;
        return parsePrivateKeyDer(allocator, oct.value);
    }
    const n = try readInteger(seq.value, v.next);
    const e = try readInteger(seq.value, n.next);
    const d = try readInteger(seq.value, e.next);
    return .{
        .modulus = try allocator.dupe(u8, n.value),
        .private_exponent = try allocator.dupe(u8, d.value),
    };
}

/// Decode a PEM "RSA PRIVATE KEY" or "PRIVATE KEY" block (PEM is plain text,
/// so parity cases can carry it as an ordinary file).
pub fn parsePrivateKeyPem(allocator: std.mem.Allocator, pem: []const u8) !PrivateKey {
    const begin = std.mem.indexOf(u8, pem, "-----BEGIN ") orelse return error.InvalidKey;
    const line_end = std.mem.indexOfScalarPos(u8, pem, begin, '\n') orelse return error.InvalidKey;
    const end = std.mem.indexOf(u8, pem, "-----END ") orelse return error.InvalidKey;
    const body = pem[line_end + 1 .. end];
    var compact = std.ArrayList(u8).empty;
    defer compact.deinit(allocator);
    for (body) |c| {
        switch (c) {
            '\n', '\r', ' ', '\t' => {},
            else => try compact.append(allocator, c),
        }
    }
    const der = try allocator.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(compact.items) catch return error.InvalidKey);
    defer allocator.free(der);
    std.base64.standard.Decoder.decode(der, compact.items) catch return error.InvalidKey;
    return parsePrivateKeyDer(allocator, der);
}

/// PKCS#1 v1.5 RSA decryption (EM = 0x00 0x02 PS 0x00 M) as used by the TLS
/// RSA key-exchange cipher suites.
pub fn decryptPkcs1V15(allocator: std.mem.Allocator, key: PrivateKey, ciphertext: []const u8) ![]u8 {
    if (ciphertext.len != key.modulus.len) return error.InvalidCiphertext;
    const em = try powModFast(allocator, ciphertext, key.private_exponent, key.modulus);
    defer allocator.free(em);
    if (em.len < 11 or em[0] != 0 or em[1] != 2) return error.InvalidCiphertext;
    var i: usize = 2;
    while (i < em.len and em[i] != 0) : (i += 1) {}
    if (i < 10 or i >= em.len) return error.InvalidCiphertext;
    return allocator.dupe(u8, em[i + 1 ..]);
}

/// Verify an RSASSA-PKCS1-v1_5 SHA-256 signature with an arbitrary DigestInfo
/// prefix style (the standard prefix is used by X.2049 certificates).
pub fn verifySha256Signature(allocator: std.mem.Allocator, modulus: []const u8, exponent: []const u8, message: []const u8, signature: []const u8) !void {
    try verifyPkcs1V15Sha256(allocator, modulus, exponent, message, signature);
}
