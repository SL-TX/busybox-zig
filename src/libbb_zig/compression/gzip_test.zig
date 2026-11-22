//! Tests for the libbb gzip/zlib/deflate helpers (RFC 1951/1950/1952).

const std = @import("std");
const gzip = @import("libbb_zig").compression.gzip;

const hello = "Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! ";

// Produced with python3 gzip.compress(data, mtime=0) / zlib.compress(data).
const hello_gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xf3\x48\xcd\xc9\xc9\xd7\x51\x70\x2a\x2d\xae\x74\xca\xaf\x50\x28\x48\x2c\xca\x2c\xa9\x54\x54\xf0\xa0\xa1\x30\x00\x88\xae\x91\xb2\x73\x00\x00\x00";
const hello_zlib = "\x78\x9c\xf3\x48\xcd\xc9\xc9\xd7\x51\x70\x2a\x2d\xae\x74\xca\xaf\x50\x28\x48\x2c\xca\x2c\xa9\x54\x54\xf0\xa0\xa1\x30\x00\x1d\xc5\x28\x1f";
const empty_gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00";

test "checksums match published check values" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), gzip.crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0x11E60398), gzip.adler32("Wikipedia"));
}

test "inflate RFC 1952 / RFC 1950 fixtures" {
    const a = try std.testing.allocator.dupe(u8, hello_gzip);
    defer std.testing.allocator.free(a);
    const plain_gz = try gzip.decompress(std.testing.allocator, a);
    defer std.testing.allocator.free(plain_gz);
    try std.testing.expectEqualStrings(hello, plain_gz);

    const z = try std.testing.allocator.dupe(u8, hello_zlib);
    defer std.testing.allocator.free(z);
    const plain_zl = try gzip.decompress(std.testing.allocator, z);
    defer std.testing.allocator.free(plain_zl);
    try std.testing.expectEqualStrings(hello, plain_zl);

    const e = try std.testing.allocator.dupe(u8, empty_gzip);
    defer std.testing.allocator.free(e);
    const plain_e = try gzip.decompress(std.testing.allocator, e);
    defer std.testing.allocator.free(plain_e);
    try std.testing.expectEqual(@as(usize, 0), plain_e.len);
}

test "gzip/zlib/raw round trip across sizes" {
    var buf: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x1337);
    for ([_]usize{ 0, 1, 3, 17, 100, 1024, 4096 }) |n| {
        for (0..n) |i| buf[i] = if (i % 7 == 0) 'x' else prng.random().int(u8);
        const data = buf[0..n];
        inline for (.{ gzip.Format.gzip, gzip.Format.zlib, gzip.Format.raw }) |fmt| {
            const compressed = try gzip.compress(std.testing.allocator, data, fmt);
            defer std.testing.allocator.free(compressed);
            const out = try gzip.decompressFormat(std.testing.allocator, compressed, fmt);
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualSlices(u8, data, out);
        }
    }
}

test "gzip auto-detect handles a multi-member stream" {
    const a = try gzip.compress(std.testing.allocator, "first", .gzip);
    defer std.testing.allocator.free(a);
    const b = try gzip.compress(std.testing.allocator, "second", .gzip);
    defer std.testing.allocator.free(b);
    const joined = try std.mem.concat(std.testing.allocator, u8, &.{ a, b });
    defer std.testing.allocator.free(joined);
    const out = try gzip.decompress(std.testing.allocator, joined);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("firstsecond", out);
}

test "gzip rejects corrupt checksums, bad sizes and truncation" {
    const compressed = try std.testing.allocator.dupe(u8, hello_gzip);
    defer std.testing.allocator.free(compressed);

    compressed[compressed.len - 8] ^= 0xff; // CRC32
    try std.testing.expectError(error.ChecksumMismatch, gzip.decompress(std.testing.allocator, compressed));
    compressed[compressed.len - 8] ^= 0xff;

    compressed[compressed.len - 4] ^= 0xff; // ISIZE
    try std.testing.expectError(error.SizeMismatch, gzip.decompress(std.testing.allocator, compressed));
    compressed[compressed.len - 4] ^= 0xff;

    try std.testing.expectError(error.Truncated, gzip.decompress(std.testing.allocator, compressed[0 .. compressed.len - 1]));
    try std.testing.expectError(error.Truncated, gzip.decompress(std.testing.allocator, compressed[0..5]));

    compressed[3] = 0xff; // reserved flags must be zero
    try std.testing.expectError(error.CorruptInput, gzip.decompress(std.testing.allocator, compressed));
}

test "gzip rejects non-gzip and malformed zlib streams" {
    try std.testing.expectError(error.BadMagic, gzip.decompress(std.testing.allocator, "not compressed"));
    const z = try std.testing.allocator.dupe(u8, hello_zlib);
    defer std.testing.allocator.free(z);
    z[1] ^= 0xff;
    try std.testing.expectError(error.BadHeader, gzip.decompress(std.testing.allocator, z));
}
