//! Tests for the xz / lzma (alone) helpers.

const std = @import("std");
const xz = @import("libbb_zig").compression.xz;
const lzma = @import("libbb_zig").compression.lzma;

const hello = "Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! ";

// Generated with python3 lzma.compress(data) / lzma.compress(data,
// format=FORMAT_ALONE).
const hello_xz = "\xfd\x37\x7a\x58\x5a\x00\x00\x04\xe6\xd6\xb4\x46\x02\x00\x21\x01\x16\x00\x00\x00\x74\x2f\xe5\xa3\xe0\x00\x72\x00\x1f\x5d\x00\x24\x19\x49\x98\x6f\x16\x02\x86\x81\x44\x89\xab\x44\xef\xd8\xcf\x32\xd5\xc3\x03\x2d\xe5\x2c\xa3\xce\x8c\x6e\x0a\x04\x00\x00\x00\x00\xf6\xd6\x0c\xf3\x7c\xf1\xe6\xaf\x00\x01\x3b\x73\x95\x7a\x38\xd5\x1f\xb6\xf3\x7d\x01\x00\x00\x00\x00\x04\x59\x5a";
const empty_xz = "\xfd\x37\x7a\x58\x5a\x00\x00\x04\xe6\xd6\xb4\x46\x00\x00\x00\x00\x1c\xdf\x44\x21\x1f\xb6\xf3\x7d\x01\x00\x00\x00\x00\x04\x59\x5a";
const hello_lzma = "\x5d\x00\x00\x80\x00\xff\xff\xff\xff\xff\xff\xff\xff\x00\x24\x19\x49\x98\x6f\x16\x02\x86\x81\x44\x89\xab\x44\xef\xd8\xcf\x32\xd5\xc3\x03\x2d\xe5\x2c\xa3\xce\x8c\x6e\x65\x8a\x77\xff\xff\xd4\xf8\x00\x00";
const empty_lzma = "\x5d\x00\x00\x80\x00\xff\xff\xff\xff\xff\xff\xff\xff\x00\x83\xff\xfb\xff\xff\xc0\x00\x00\x00";

test "decode xz and lzma fixtures from an external compressor" {
    const hx = try std.testing.allocator.dupe(u8, hello_xz);
    defer std.testing.allocator.free(hx);
    const out = try xz.decompress(std.testing.allocator, hx);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(hello, out);

    const ex = try std.testing.allocator.dupe(u8, empty_xz);
    defer std.testing.allocator.free(ex);
    const empty = try xz.decompress(std.testing.allocator, ex);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const hl = try std.testing.allocator.dupe(u8, hello_lzma);
    defer std.testing.allocator.free(hl);
    const lout = try lzma.decompress(std.testing.allocator, hl);
    defer std.testing.allocator.free(lout);
    try std.testing.expectEqualStrings(hello, lout);

    const el = try std.testing.allocator.dupe(u8, empty_lzma);
    defer std.testing.allocator.free(el);
    const lempty = try lzma.decompress(std.testing.allocator, el);
    defer std.testing.allocator.free(lempty);
    try std.testing.expectEqual(@as(usize, 0), lempty.len);
}

test "xz round trip (uncompressed LZMA2 blocks in a valid xz container)" {
    var buf: [5000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xA2);
    for ([_]usize{ 0, 1, 3, 100, 1000, 4096, 5000 }) |n| {
        for (0..n) |i| buf[i] = if (i % 5 == 0) 'z' else prng.random().int(u8);
        const encoded = try xz.compress(std.testing.allocator, buf[0..n]);
        defer std.testing.allocator.free(encoded);
        const out = try xz.decompress(std.testing.allocator, encoded);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualSlices(u8, buf[0..n], out);
    }
}

test "lzma-alone round trip" {
    var buf: [2048]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x12AB);
    for ([_]usize{ 0, 1, 2, 17, 100, 1000, 2048 }) |n| {
        for (0..n) |i| buf[i] = if (i % 3 == 0) 'l' else prng.random().int(u8);
        const encoded = try lzma.compress(std.testing.allocator, buf[0..n]);
        defer std.testing.allocator.free(encoded);
        const out = try lzma.decompress(std.testing.allocator, encoded);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualSlices(u8, buf[0..n], out);
    }
}

test "xz/lzma reject corrupt and truncated streams" {
    const xsrc = try std.testing.allocator.dupe(u8, hello_xz);
    defer std.testing.allocator.free(xsrc);
    xsrc[xsrc.len - 1] ^= 0xff;
    try std.testing.expectError(error.CorruptInput, xz.decompress(std.testing.allocator, xsrc));
    xsrc[xsrc.len - 1] ^= 0xff;
    try std.testing.expectError(error.CorruptInput, xz.decompress(std.testing.allocator, xsrc[0..20]));
    try std.testing.expectError(error.BadMagic, xz.decompress(std.testing.allocator, "not an xz file"));

    const lsrc = try std.testing.allocator.dupe(u8, hello_lzma);
    defer std.testing.allocator.free(lsrc);
    try std.testing.expectError(error.Truncated, lzma.decompress(std.testing.allocator, lsrc[0..8]));
    try std.testing.expectError(error.CorruptInput, lzma.decompress(std.testing.allocator, "not lzma!!!!!!!"));
}
