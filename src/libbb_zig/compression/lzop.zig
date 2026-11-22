//! lzop container and LZO1X helpers.  The decompressor is a bounds-checked
//! Zig port of the LZO1X-1 "safe" decoder; the compressor emits literal-only
//! LZO1X streams (and uses lzop's stored-block option when literals would
//! expand the data).  No external LZO library is used.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadMagic,
    BadHeader,
    CorruptInput,
    Truncated,
    ChecksumMismatch,
    Unsupported,
} || Allocator.Error;

const magic = [_]u8{ 0x89, 0x4c, 0x5a, 0x4f, 0x00, 0x0d, 0x0a, 0x1a, 0x0a };
const F_ADLER32_D: u32 = 0x00000001;
const OS_UNIX: u32 = 0x03000000;

fn adler32(bytes: []const u8) u32 {
    return std.hash.Adler32.hash(bytes);
}

// ------------------------------------------------------------- LZO1X decoder

/// Decompress one LZO1X block, checking every input/output access.
pub fn lzo1xDecompress(allocator: Allocator, input: []const u8, expected_len: usize) Error![]u8 {
    const out = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(out);
    var ip: usize = 0;
    var op: usize = 0;

    if (input.len == 0) return error.Truncated;
    if (input[0] > 17) {
        var t: usize = input[0] - 17;
        ip = 1;
        if (t >= 4) {
            if (input.len - ip < t or out.len - op < t) return error.CorruptInput;
            @memcpy(out[op..][0..t], input[ip..][0..t]);
            ip += t;
            op += t;
            t = try take(input, &ip);
            if (t < 16) return error.CorruptInput;
            _ = try matchToken(input, out, &ip, &op, t);
            return out;
        }
        // t < 4: a short initial literal run followed by a match.
        if (input.len - ip < t or out.len - op < t) return error.CorruptInput;
        @memcpy(out[op..][0..t], input[ip..][0..t]);
        ip += t;
        op += t;
    }

    while (ip < input.len and op < out.len) {
        var t: usize = try take(input, &ip);
        if (t >= 16) {
            const eof = try matchToken(input, out, &ip, &op, t);
            if (eof) return out;
            continue;
        }
        if (t == 0) {
            while (ip < input.len and input[ip] == 0) {
                t += 255;
                ip += 1;
            }
            if (ip >= input.len) return error.Truncated;
            t += 15 + try take(input, &ip);
        }
        const count = t + 3;
        if (input.len - ip < count or out.len - op < count) return error.CorruptInput;
        @memcpy(out[op..][0..count], input[ip..][0..count]);
        ip += count;
        op += count;
        if (ip >= input.len) return error.Truncated;
        t = try take(input, &ip); // first_literal_run token
        if (t >= 16) {
            const eof = try matchToken(input, out, &ip, &op, t);
            if (eof) return out;
        } else {
            // M1 match (offset 0x800 + t/4 + b*4), length 3.
            const b = try take(input, &ip);
            const dist = 1 + 0x800 + (t >> 2) + (@as(usize, b) << 2);
            try copyMatch(out, &op, dist, 3);
            const tail = input[ip - 2] & 3;
            if (tail != 0) try copyLiterals(input, out, &ip, &op, tail);
        }
    }
    // A successful decompression can end exactly when the output buffer is
    // full (lzo1x's EOF token is optional when the size is known).
    if (op == out.len) return out;
    return error.CorruptInput;
}

fn take(input: []const u8, ip: *usize) Error!usize {
    if (ip.* >= input.len) return error.Truncated;
    const b = input[ip.*];
    ip.* += 1;
    return b;
}

fn copyLiterals(input: []const u8, out: []u8, ip: *usize, op: *usize, n: usize) Error!void {
    if (input.len - ip.* < n or out.len - op.* < n) return error.CorruptInput;
    @memcpy(out[op.*..][0..n], input[ip.*..][0..n]);
    ip.* += n;
    op.* += n;
}

fn copyMatch(out: []u8, op: *usize, dist: usize, len: usize) Error!void {
    if (dist == 0 or dist > op.* or out.len - op.* < len) return error.CorruptInput;
    const start = op.* - dist;
    for (0..len) |i| out[op.* + i] = out[start + i];
    op.* += len;
}

/// Handle a match token (value >= 16).  Returns true at the LZO EOF code.
fn matchToken(input: []const u8, out: []u8, ip: *usize, op: *usize, initial: usize) Error!bool {
    var t = initial;
    while (true) {
        if (t >= 64) {
            // M2: offset 1 + ((t>>2)&7) + b*8, length (t>>5)+2.
            const b = try take(input, ip);
            const dist = 1 + ((t >> 2) & 7) + (@as(usize, b) << 3);
            try copyMatch(out, op, dist, (t >> 5) + 2);
        } else if (t >= 32) {
            // M3: 2-byte offset, extended length.
            t &= 31;
            if (t == 0) {
                while (ip.* < input.len and input[ip.*] == 0) {
                    t += 255;
                    ip.* += 1;
                }
                t += 31 + try take(input, ip);
            }
            if (input.len - ip.* < 2) return error.Truncated;
            const b0 = input[ip.*];
            const b1 = input[ip.* + 1];
            ip.* += 2;
            const dist = 1 + (b0 >> 2) + (@as(usize, b1) << 6);
            try copyMatch(out, op, dist, t + 2);
        } else if (t >= 16) {
            // M4: 2-byte offset with a 0x4000 bias; zero offset is EOF.
            const high = (t & 8) << 11;
            t &= 7;
            if (t == 0) {
                while (ip.* < input.len and input[ip.*] == 0) {
                    t += 255;
                    ip.* += 1;
                }
                t += 7 + try take(input, ip);
            }
            if (input.len - ip.* < 2) return error.Truncated;
            const b0 = input[ip.*];
            const b1 = input[ip.* + 1];
            ip.* += 2;
            const dist1 = high + (b0 >> 2) + (@as(usize, b1) << 6);
            if (dist1 == 0) return true;
            try copyMatch(out, op, dist1 + 0x4000, t + 3);
        } else {
            // M1: length 2.
            const b = try take(input, ip);
            const dist = 1 + (t >> 2) + (@as(usize, b) << 2);
            try copyMatch(out, op, dist, 2);
            return false;
        }
        const tail = input[ip.* - 2] & 3;
        if (tail == 0) return false;
        try copyLiterals(input, out, ip, op, tail);
        t = try take(input, ip);
    }
}

// ------------------------------------------------------------ LZO1X encoder

/// Literal-only LZO1X stream: a single literal run followed by the EOF code.
pub fn lzo1xCompress(allocator: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const n = data.len;
    if (n == 0) {
        try out.appendSlice(allocator, &.{ 0x11, 0x00, 0x00 });
        return out.toOwnedSlice(allocator);
    }
    if (n <= 3) {
        try out.append(allocator, @intCast(n + 17));
    } else if (n <= 18) {
        try out.append(allocator, @intCast(n - 3));
    } else {
        try out.append(allocator, 0);
        var tt = n - 18;
        while (true) {
            if (tt <= 255) {
                try out.append(allocator, @intCast(tt));
                break;
            }
            try out.append(allocator, 0);
            tt -= 255;
        }
    }
    try out.appendSlice(allocator, data);
    try out.appendSlice(allocator, &.{ 0x11, 0x00, 0x00 });
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------- lzop container

pub fn compress(allocator: Allocator, data: []const u8, level: u4) Error![]u8 {
    if (level < 1 or level > 9) return error.BadHeader;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &magic);
    const header_start = out.items.len;
    try appendU16BE(&out, allocator, 0x1040); // version 1.04
    try appendU16BE(&out, allocator, 0x1040); // lib version
    try appendU16BE(&out, allocator, 0x0940); // needed version
    try out.append(allocator, 1); // LZO1X-1
    try out.append(allocator, @intCast(level));
    try appendU32BE(&out, allocator, F_ADLER32_D | OS_UNIX);
    try appendU32BE(&out, allocator, 0o100644);
    try appendU32BE(&out, allocator, 0); // mtime
    try appendU32BE(&out, allocator, 0); // gmtdiff
    try out.append(allocator, 0); // no original file name
    try appendU32BE(&out, allocator, adler32(out.items[header_start..]));

    if (data.len != 0) {
        const lzo = try lzo1xCompress(allocator, data);
        defer allocator.free(lzo);
        // lzop stores raw data when literal encoding would expand it.
        const store = lzo.len >= data.len;
        // lzop block header order is: uncompressed size, compressed size.
        try appendU32BE(&out, allocator, @intCast(data.len));
        try appendU32BE(&out, allocator, @intCast(if (store) data.len else lzo.len));
        try appendU32BE(&out, allocator, adler32(data));
        try out.appendSlice(allocator, if (store) data else lzo);
    }
    try appendU32BE(&out, allocator, 0); // end of blocks (single zero word)
    return out.toOwnedSlice(allocator);
}

pub fn decompress(allocator: Allocator, data: []const u8) Error![]u8 {
    if (data.len < magic.len + 25) return error.Truncated;
    if (!std.mem.eql(u8, data[0..magic.len], &magic)) return error.BadMagic;
    var pos: usize = magic.len;
    const header_start = pos;
    const version = try readU16BE(data, &pos);
    _ = try readU16BE(data, &pos); // lib version
    const needed = try readU16BE(data, &pos);
    const method = try take(data, &pos);
    _ = try take(data, &pos); // level
    const flags = try readU32BE(data, &pos);
    _ = try readU32BE(data, &pos); // mode
    _ = try readU32BE(data, &pos); // mtime
    _ = try readU32BE(data, &pos); // gmtdiff
    const name_len = try take(data, &pos);
    if (pos + name_len + 4 > data.len) return error.Truncated;
    pos += name_len;
    if (version < 0x0940 or needed < 0x0940 or needed > 0x1040) return error.BadHeader;
    if (method == 0 or method > 3) return error.BadHeader;
    if ((flags & F_ADLER32_D) == 0) return error.Unsupported;
    const want_header_sum = try readU32BE(data, &pos);
    if (want_header_sum != adler32(data[header_start .. pos - 4])) return error.ChecksumMismatch;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (true) {
        if (data.len - pos < 4) return error.Truncated;
        const unpacked_len = try readU32BE(data, &pos);
        // The reference writer terminates the block list with a single zero
        // word (BusyBox lzop.c: write32(0)).
        if (unpacked_len == 0) break;
        if (data.len - pos < 4) return error.Truncated;
        const packed_len = try readU32BE(data, &pos);
        if (data.len - pos < 4) return error.Truncated;
        const want_sum = try readU32BE(data, &pos);
        if (packed_len > data.len - pos) return error.Truncated;
        const block = data[pos .. pos + packed_len];
        pos += packed_len;
        const start = out.items.len;
        if (packed_len == unpacked_len) {
            try out.appendSlice(allocator, block);
        } else if (packed_len < unpacked_len) {
            const decoded = try lzo1xDecompress(allocator, block, unpacked_len);
            defer allocator.free(decoded);
            try out.appendSlice(allocator, decoded);
        } else {
            return error.CorruptInput;
        }
        if (adler32(out.items[start..]) != want_sum) return error.ChecksumMismatch;
    }
    return out.toOwnedSlice(allocator);
}

fn appendU16BE(list: *std.ArrayList(u8), allocator: Allocator, value: u16) Error!void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, value, .big);
    try list.appendSlice(allocator, &b);
}

fn appendU32BE(list: *std.ArrayList(u8), allocator: Allocator, value: u32) Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, value, .big);
    try list.appendSlice(allocator, &b);
}

fn readU16BE(data: []const u8, pos: *usize) Error!u16 {
    if (data.len - pos.* < 2) return error.Truncated;
    const v = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    return v;
}

fn readU32BE(data: []const u8, pos: *usize) Error!u32 {
    if (data.len - pos.* < 4) return error.Truncated;
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .big);
    pos.* += 4;
    return v;
}
