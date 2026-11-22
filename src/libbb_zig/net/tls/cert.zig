//! X.509 certificate parsing and validation (pure Zig, backed by std.crypto).

const std = @import("std");
const rsa = @import("rsa.zig");

pub const Parsed = struct {
    common_name: []const u8,
    subject: []const u8,
    issuer: []const u8,
    not_before: u64,
    not_after: u64,
    is_rsa: bool,
};

pub fn parse(der: []const u8) !Parsed {
    const cert = try std.crypto.Certificate.parse(.{ .buffer = der, .index = 0 });
    return .{
        .common_name = cert.commonName(),
        .subject = cert.subject(),
        .issuer = cert.issuer(),
        .not_before = cert.validity.not_before,
        .not_after = cert.validity.not_after,
        .is_rsa = switch (cert.pub_key_algo) {
            .rsaEncryption => true,
            else => false,
        },
    };
}

pub fn verifyHostName(der: []const u8, host_name: []const u8) !void {
    const cert = try std.crypto.Certificate.parse(.{ .buffer = der, .index = 0 });
    try cert.verifyHostName(host_name);
}

const Tlv = struct {
    tag: u8,
    value: []const u8,
    encoded: []const u8,
    next: usize,
};

fn readTlv(data: []const u8, pos: usize) !Tlv {
    if (pos + 2 > data.len) return error.InvalidCertificate;
    const tag = data[pos];
    var len: usize = data[pos + 1];
    var hdr: usize = 2;
    if (len & 0x80 != 0) {
        const n = len & 0x7f;
        if (n == 0 or n > 4 or pos + 2 + n > data.len) return error.InvalidCertificate;
        len = 0;
        for (0..n) |i| len = (len << 8) | data[pos + 2 + i];
        hdr = 2 + n;
    }
    if (pos + hdr + len > data.len) return error.InvalidCertificate;
    return .{
        .tag = tag,
        .value = data[pos + hdr .. pos + hdr + len],
        .encoded = data[pos .. pos + hdr + len],
        .next = pos + hdr + len,
    };
}

pub const CertInfo = struct {
    /// Encoded TBSCertificate — the exact bytes covered by the signature.
    tbs: []const u8,
    /// SubjectPublicKeyInfo of the subject (the issuer key when verifying).
    spki: []const u8,
    /// Raw signature bits (the leading BIT STRING "unused bits" byte removed).
    signature: []const u8,
};

/// Pull the three fields needed to check a certificate's signature.
pub fn extract(der: []const u8) !CertInfo {
    const outer = try readTlv(der, 0);
    if (outer.tag != 0x30) return error.InvalidCertificate;
    const tbs = try readTlv(outer.value, 0);
    if (tbs.tag != 0x30) return error.InvalidCertificate;
    const alg = try readTlv(outer.value, tbs.next);
    if (alg.tag != 0x30) return error.InvalidCertificate;
    const sig = try readTlv(outer.value, alg.next);
    if (sig.tag != 0x03 or sig.value.len < 2 or sig.value[0] != 0) return error.InvalidCertificate;

    var pos: usize = 0;
    if (tbs.value.len > 0 and tbs.value[0] == 0xa0) {
        const ver = try readTlv(tbs.value, 0);
        pos = ver.next;
    }
    const serial = try readTlv(tbs.value, pos);
    pos = serial.next;
    const sig_alg = try readTlv(tbs.value, pos);
    pos = sig_alg.next;
    const issuer = try readTlv(tbs.value, pos);
    pos = issuer.next;
    const validity = try readTlv(tbs.value, pos);
    pos = validity.next;
    const subject = try readTlv(tbs.value, pos);
    const spki = try readTlv(tbs.value, subject.next);
    if (spki.tag != 0x30) return error.InvalidCertificate;
    return .{ .tbs = tbs.encoded, .spki = spki.encoded, .signature = sig.value[1..] };
}

/// Check `der` was signed by the key in `issuer_der` (RSA/SHA-256).
pub fn verifySignedBy(allocator: std.mem.Allocator, der: []const u8, issuer_der: []const u8) !void {
    const child = try extract(der);
    const issuer = try extract(issuer_der);
    var key = try rsa.parsePublicKeyDer(allocator, issuer.spki);
    defer key.deinit(allocator);
    try rsa.verifyPkcs1V15Sha256(allocator, key.modulus, key.exponent, child.tbs, child.signature);
}

/// Validate a certificate chain (leaf first). The last certificate is a trust
/// anchor and must be self-signed. Optionally check the leaf's host name.
pub fn verifyChain(allocator: std.mem.Allocator, certs: []const []const u8, host_name: ?[]const u8) !void {
    if (certs.len == 0) return error.InvalidCertificate;
    for (certs, 0..) |der, i| {
        const issuer = if (i + 1 < certs.len) certs[i + 1] else der;
        try verifySignedBy(allocator, der, issuer);
    }
    if (host_name) |host| try verifyHostName(certs[0], host);
}
