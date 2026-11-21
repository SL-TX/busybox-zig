//! X.509 certificate parsing wrapper (pure Zig, backed by std.crypto).

const std = @import("std");

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
