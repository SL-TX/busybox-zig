//! xz container helpers.  Decoding uses Zig std's LZMA2/xz decoder; encoding
//! emits a valid xz stream made of LZMA2 *uncompressed* chunks (no external
//! library, no shelling out).  The result is fully interoperable, just larger
//! than a match-compressed stream.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Check = enum(u4) { none = 0 };

pub const Error = error{
    BadMagic,
    CorruptInput,
    Truncated,
} || Allocator.Error;

fn crc32(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

pub fn decompress(allocator: Allocator, data: []const u8) Error![]u8 {
    if (data.len < 12) return error.Truncated;
    if (!std.mem.eql(u8, data[0..6], &.{ 0xfd, '7', 'z', 'X', 'Z', 0x00 })) return error.BadMagic;
    var reader: std.Io.Reader = .fixed(data);
    const buffer = allocator.alloc(u8, 4096) catch |err| return err;
    var dec = std.compress.xz.Decompress.init(&reader, allocator, buffer) catch |err| {
        allocator.free(buffer);
        return mapError(err);
    };
    defer dec.deinit();
    const out = dec.reader.allocRemaining(allocator, .unlimited) catch |err| return mapError(err);
    return out;
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotXzStream => error.BadMagic,
        else => error.CorruptInput,
    };
}

pub fn compress(allocator: Allocator, data: []const u8) Error![]u8 {
    // xz has no "zero chunks" LZMA2 block; use a canonical empty stream.
    if (data.len == 0) {
        const empty = [_]u8{
            0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x04, 0xe6, 0xd6, 0xb4, 0x46,
            0x00, 0x00, 0x00, 0x00, 0x1c, 0xdf, 0x44, 0x21, 0x1f, 0xb6, 0xf3, 0x7d,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x59, 0x5a,
        };
        return allocator.dupe(u8, &empty);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Stream header: magic, stream flags (check = none), flags CRC32.
    try out.appendSlice(allocator, &.{ 0xfd, '7', 'z', 'X', 'Z', 0x00 });
    const flags = [_]u8{ 0, 0 };
    try out.appendSlice(allocator, &flags);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, crc32(&flags), .little);
    try out.appendSlice(allocator, &crc);

    // LZMA2 data: 64 KiB uncompressed chunks, first one resetting the dict.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    if (data.len == 0) try payload.append(allocator, 0x00); // LZMA2 end marker
    var pos: usize = 0;
    while (pos < data.len) {
        const n = @min(0x10000, data.len - pos);
        try payload.append(allocator, if (pos == 0) 0x01 else 0x02);
        var len_field: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_field, @intCast(n - 1), .big);
        try payload.appendSlice(allocator, &len_field);
        try payload.appendSlice(allocator, data[pos .. pos + n]);
        pos += n;
    }
    if (data.len != 0) try payload.append(allocator, 0x00); // end marker

    // Block header: flags (both sizes present, one filter), VLI sizes and
    // filter descriptor (LZMA2, 1 property byte: 4 KiB dictionary).
    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(allocator);
    try header.append(allocator, 0x00); // one filter, no explicit sizes
    try appendVli(&header, allocator, 0x21); // LZMA2 filter id
    try appendVli(&header, allocator, 1);
    try header.append(allocator, 0x0c); // dict size 256 KiB
    const padded_header_len = std.mem.alignForward(usize, header.items.len + 1 + 4, 4);
    try out.append(allocator, @intCast(padded_header_len / 4 - 1));
    try out.appendSlice(allocator, header.items);
    const header_padding = padded_header_len - 1 - 4 - header.items.len;
    for (0..header_padding) |_| try out.append(allocator, 0);
    var hcrc: [4]u8 = undefined;
    const header_uncrc_len = 1 + header.items.len + header_padding;
    const hslice = out.items[out.items.len - header_uncrc_len ..];
    std.mem.writeInt(u32, &hcrc, crc32(hslice), .little);
    try out.appendSlice(allocator, &hcrc);
    const block_header_len = padded_header_len;

    try out.appendSlice(allocator, payload.items);
    const block_padding = (4 - (payload.items.len % 4)) % 4;
    for (0..block_padding) |_| try out.append(allocator, 0);
    const unpadded_size = block_header_len + payload.items.len; // excludes block padding

    // Index: one record, padded and CRC32'd.
    const index_start = out.items.len;
    try out.append(allocator, 0x00); // index indicator
    try appendVli(&out, allocator, 1);
    try appendVli(&out, allocator, unpadded_size);
    try appendVli(&out, allocator, data.len);
    const index_padding = (4 - ((out.items.len - index_start) % 4)) % 4;
    for (0..index_padding) |_| try out.append(allocator, 0);
    var icrc: [4]u8 = undefined;
    std.mem.writeInt(u32, &icrc, crc32(out.items[index_start..]), .little);
    try out.appendSlice(allocator, &icrc);
    const index_len = out.items.len - index_start; // includes the index CRC

    // Stream footer: backward size CRC, stream flags, "YZ".
    var backward: [4]u8 = undefined;
    std.mem.writeInt(u32, &backward, @intCast(index_len / 4 - 1), .little);
    var bcrc: [4]u8 = undefined;
    var footer_crc_input: [6]u8 = undefined;
    @memcpy(footer_crc_input[0..4], &backward);
    @memcpy(footer_crc_input[4..6], &flags);
    std.mem.writeInt(u32, &bcrc, crc32(&footer_crc_input), .little);
    try out.appendSlice(allocator, &bcrc);
    try out.appendSlice(allocator, &backward);
    try out.appendSlice(allocator, &flags);
    try out.appendSlice(allocator, "YZ");
    return out.toOwnedSlice(allocator);
}

fn appendVli(list: *std.ArrayList(u8), allocator: Allocator, value: usize) Error!void {
    var v = value;
    while (v >= 0x80) {
        try list.append(allocator, @intCast((v & 0x7f) | 0x80));
        v >>= 7;
    }
    try list.append(allocator, @intCast(v));
}
