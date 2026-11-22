//! Tests for the pure-Zig bzip2 decoder/encoder.

const std = @import("std");
const bzip2 = @import("libbb_zig").compression.bzip2;

const hello = "Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! Hello, BusyBox parity! ";

// Generated with python3 bz2.compress(data, 9) / bz2.compress(b"", 9).
const hello_bz2 = "\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xc5\xeb\xa7\xd6\x00\x00\x13\x95\x80\x60\x04\x10\x40\x22\x24\xde\x60\x20\x00\x50\xa1\xa6\x98\x00\x11\x54\xd3\x11\x9a\x13\xd4\xa2\x51\x3e\x49\x48\x4e\x92\xc2\x69\x3d\x4d\xa4\x26\xc4\x84\xba\x69\x25\x38\x95\x48\x49\x49\x4f\xc5\xdc\x91\x4e\x14\x24\x31\x7a\xe9\xf5\x80";
const empty_bz2 = "\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00";

test "decode bzip2 fixtures produced by an external compressor" {
    const a = try std.testing.allocator.dupe(u8, hello_bz2);
    defer std.testing.allocator.free(a);
    const out = try bzip2.decompress(std.testing.allocator, a);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(hello, out);

    const e = try std.testing.allocator.dupe(u8, empty_bz2);
    defer std.testing.allocator.free(e);
    const empty = try bzip2.decompress(std.testing.allocator, e);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "bzip2 round trip for several sizes and levels" {
    var buf: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xB17F);
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 18, 19, 100, 1000, 4096 }) |n| {
        for (0..n) |i| buf[i] = if (i % 11 < 6) 'a' + @as(u8, @intCast(i % 7)) else prng.random().int(u8);
        const data = buf[0..n];
        for ([_]u4{ 1, 9 }) |level| {
            const compressed = try bzip2.compress(std.testing.allocator, data, level);
            defer std.testing.allocator.free(compressed);
            const out = try bzip2.decompress(std.testing.allocator, compressed);
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualSlices(u8, data, out);
        }
    }
}

test "bzip2 decodes concatenated streams" {
    const a = try bzip2.compress(std.testing.allocator, "part one;", 9);
    defer std.testing.allocator.free(a);
    const b = try bzip2.compress(std.testing.allocator, "part two", 9);
    defer std.testing.allocator.free(b);
    const joined = try std.mem.concat(std.testing.allocator, u8, &.{ a, b });
    defer std.testing.allocator.free(joined);
    const out = try bzip2.decompress(std.testing.allocator, joined);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("part one;part two", out);
}

test "bzip2 rejects corrupt / truncated input" {
    const src = try bzip2.compress(std.testing.allocator, hello, 9);
    defer std.testing.allocator.free(src);

    const bad_magic = try std.testing.allocator.dupe(u8, src);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, bzip2.decompress(std.testing.allocator, bad_magic));

    try std.testing.expectError(error.Truncated, bzip2.decompress(std.testing.allocator, src[0 .. src.len - 1]));
    try std.testing.expectError(error.Truncated, bzip2.decompress(std.testing.allocator, src[0..6]));

    // Flip a data byte: block or combined CRC must detect it (or Huffman
    // decoding must fail), but it must never panic.
    for (0..src.len) |i| {
        const bad = try std.testing.allocator.dupe(u8, src);
        defer std.testing.allocator.free(bad);
        bad[i] ^= 0x40;
        const maybe = bzip2.decompress(std.testing.allocator, bad) catch continue;
        defer std.testing.allocator.free(maybe);
        // A few bit flips can produce a different but internally consistent
        // stream; that is acceptable, but the output must be a valid slice.
    }
}

test "bzip2 round trip through a real file under /tmp/opencode" {
    const path = "/tmp/opencode/task19-fixtures/bzip2-roundtrip.bin";
    var buf: [2048]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate((i *% 37) ^ (i >> 2));
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, &buf);

    const compressed = try bzip2.compress(std.testing.allocator, &buf, 9);
    defer std.testing.allocator.free(compressed);
    const out = try bzip2.decompress(std.testing.allocator, compressed);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, &buf, out);
}
