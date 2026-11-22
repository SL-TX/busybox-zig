//! Tests for the lzop / LZO1X helpers.

const std = @import("std");
const lzop = @import("libbb_zig").compression.lzop;

const hello = "Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! ";

// lzop container built around a real LZO1X block produced by liblzo2's
// lzo1x_1_compress (the same algorithm BusyBox uses).
const ref_lzop = "\x89\x4c\x5a\x4f\x00\x0d\x0a\x1a\x0a\x10\x10\x20\x30\x09\x40\x01\x05\x03\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x94\x00\xc4\x00\x00\x00\x73\x00\x00\x00\x24\x1d\xc5\x28\x1f\x00\x09\x48\x65\x6c\x6c\x6f\x2c\x20\x42\x75\x73\x79\x42\x6f\x78\x20\x70\x61\x72\x69\x74\x79\x21\x20\x48\x65\x6c\x6c\x20\x37\x58\x00\x11\x00\x00\x00\x00\x00\x00";

// The LZO1X block alone (uncompressed size 115).
const ref_block = "\x00\x05\x48\x65\x6c\x6c\x6f\x2c\x20\x42\x75\x73\x79\x42\x6f\x78\x20\x70\x61\x72\x69\x74\x79\x21\x20\x20\x2b\x58\x00\x0d\x42\x75\x73\x79\x42\x6f\x78\x20\x70\x61\x72\x69\x74\x79\x21\x20\x11\x00\x00";

test "decode a liblzo-produced LZO1X block" {
    const block = try std.testing.allocator.dupe(u8, ref_block);
    defer std.testing.allocator.free(block);
    const out = try lzop.lzo1xDecompress(std.testing.allocator, block, hello.len);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(hello, out);
}

test "decode a reference lzop stream" {
    const file = try std.testing.allocator.dupe(u8, ref_lzop);
    defer std.testing.allocator.free(file);
    const out = try lzop.decompress(std.testing.allocator, file);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(hello, out);
}

test "lzop round trip across sizes" {
    var buf: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x12f0);
    for ([_]usize{ 0, 1, 2, 3, 4, 17, 100, 1000, 4096, 8192 }) |n| {
        for (0..n) |i| buf[i] = if (i % 9 == 0) 'q' else prng.random().int(u8);
        const encoded = try lzop.compress(std.testing.allocator, buf[0..n], 1);
        defer std.testing.allocator.free(encoded);
        const out = try lzop.decompress(std.testing.allocator, encoded);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualSlices(u8, buf[0..n], out);
    }
}

test "lzop rejects corrupt headers, checksums and truncation" {
    const file = try std.testing.allocator.dupe(u8, ref_lzop);
    defer std.testing.allocator.free(file);
    file[0] = 0;
    try std.testing.expectError(error.BadMagic, lzop.decompress(std.testing.allocator, file));
    file[0] = 0x89;

    try std.testing.expectError(error.Truncated, lzop.decompress(std.testing.allocator, file[0..20]));

    const badsum = try std.testing.allocator.dupe(u8, ref_lzop);
    defer std.testing.allocator.free(badsum);
    badsum[46] ^= 0xff; // uncompressed block checksum (after 38B header + 8B block sizes)
    try std.testing.expectError(error.ChecksumMismatch, lzop.decompress(std.testing.allocator, badsum));
}
