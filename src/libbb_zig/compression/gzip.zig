//! gzip / zlib / raw DEFLATE helpers for the libbb archival applets.
//! RFC 1951 (deflate), RFC 1950 (zlib) and RFC 1952 (gzip) containers are
//! handled on top of the Zig standard library's flate codec.  Container
//! headers and trailers are parsed here so that multi-member gzip streams and
//! malformed inputs are handled explicitly (and never panic).

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

pub const Format = enum { gzip, zlib, raw };

pub const Error = error{
    BadMagic,
    BadHeader,
    CorruptInput,
    Truncated,
    ChecksumMismatch,
    SizeMismatch,
} || Allocator.Error;

pub fn crc32(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

pub fn adler32(bytes: []const u8) u32 {
    return std.hash.Adler32.hash(bytes);
}

pub fn compress(allocator: Allocator, data: []const u8, format: Format) Error![]u8 {
    return compressLevel(allocator, data, format, .default);
}

pub fn compressLevel(allocator: Allocator, data: []const u8, format: Format, opts: flate.Compress.Options) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(64);
    const container: flate.Container = switch (format) {
        .gzip => .gzip,
        .zlib => .zlib,
        .raw => .raw,
    };
    var window: [flate.max_window_len * 2]u8 = undefined;
    var comp = flate.Compress.init(&out.writer, &window, container, opts) catch |err| return mapCompressError(err);
    comp.writer.writeAll(data) catch |err| return mapCompressError(err);
    comp.finish() catch |err| return mapCompressError(err);
    return out.toOwnedSlice();
}

pub fn gzipCompress(allocator: Allocator, data: []const u8) Error![]u8 {
    return compress(allocator, data, .gzip);
}

pub fn zlibCompress(allocator: Allocator, data: []const u8) Error![]u8 {
    return compress(allocator, data, .zlib);
}

pub fn rawDeflate(allocator: Allocator, data: []const u8) Error![]u8 {
    return compress(allocator, data, .raw);
}

/// Transparently handles gzip, zlib and concatenated gzip members.  Raw
/// deflate must be requested explicitly with `decompressFormat`.
pub fn decompress(allocator: Allocator, data: []const u8) Error![]u8 {
    if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b)
        return decompressFormat(allocator, data, .gzip);
    if (data.len >= 2 and (data[0] & 0x0f) == 8 and (data[0] >> 4) <= 7)
        return decompressFormat(allocator, data, .zlib);
    return error.BadMagic;
}

pub fn gunzip(allocator: Allocator, data: []const u8) Error![]u8 {
    return decompressFormat(allocator, data, .gzip);
}

pub fn zlibDecompress(allocator: Allocator, data: []const u8) Error![]u8 {
    return decompressFormat(allocator, data, .zlib);
}

pub fn rawInflate(allocator: Allocator, data: []const u8) Error![]u8 {
    return decompressFormat(allocator, data, .raw);
}

pub fn decompressFormat(allocator: Allocator, data: []const u8, format: Format) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (true) {
        const header_start = pos;
        switch (format) {
            .gzip => {
                if (data.len - pos < 10) return error.Truncated;
                const hdr = data[pos..][0..10];
                if (hdr[0] != 0x1f or hdr[1] != 0x8b) return error.BadMagic;
                if (hdr[2] != 8) return error.BadHeader;
                if ((hdr[3] & 0xe0) != 0) return error.CorruptInput;
                const flags = hdr[3];
                pos += 10;
                if ((flags & 0x04) != 0) {
                    if (data.len - pos < 2) return error.Truncated;
                    const xlen = std.mem.readInt(u16, data[pos..][0..2], .little);
                    pos += 2;
                    if (xlen > data.len - pos) return error.Truncated;
                    pos += xlen;
                }
                if ((flags & 0x08) != 0) pos = try skipZTerminated(data, pos);
                if ((flags & 0x10) != 0) pos = try skipZTerminated(data, pos);
                if ((flags & 0x02) != 0) {
                    if (data.len - pos < 2) return error.Truncated;
                    const expected = std.mem.readInt(u16, data[pos..][0..2], .little);
                    if ((crc32(data[header_start..pos]) & 0xffff) != expected) return error.ChecksumMismatch;
                    pos += 2;
                }
            },
            .zlib => {
                if (data.len - pos < 2) return error.Truncated;
                const cmf = data[pos];
                const flg = data[pos + 1];
                if ((cmf & 0x0f) != 8 or (cmf >> 4) > 7 or (((@as(u16, cmf) << 8) | flg) % 31) != 0)
                    return error.BadHeader;
                if ((flg & 0x20) != 0) return error.CorruptInput; // preset dictionary unsupported
                pos += 2;
            },
            .raw => {},
        }

        const start = out.items.len;
        const consumed = try inflateInto(allocator, data[pos..], &out);
        pos += consumed;
        const member = out.items[start..];

        switch (format) {
            .gzip => {
                if (data.len - pos < 8) return error.Truncated;
                const want_crc = std.mem.readInt(u32, data[pos..][0..4], .little);
                const want_size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
                pos += 8;
                if (want_crc != crc32(member)) return error.ChecksumMismatch;
                if (want_size != @as(u32, @truncate(member.len))) return error.SizeMismatch;
            },
            .zlib => {
                if (data.len - pos < 4) return error.Truncated;
                const want_adler = std.mem.readInt(u32, data[pos..][0..4], .big);
                pos += 4;
                if (want_adler != adler32(member)) return error.ChecksumMismatch;
            },
            .raw => {},
        }

        if (pos == data.len) break;
        if (format != .gzip or data.len - pos < 2 or data[pos] != 0x1f or data[pos + 1] != 0x8b)
            return error.CorruptInput;
    }
    return out.toOwnedSlice(allocator);
}

fn skipZTerminated(data: []const u8, start: usize) Error!usize {
    var pos = start;
    while (pos < data.len) : (pos += 1) {
        if (data[pos] == 0) return pos + 1;
    }
    return error.Truncated;
}

fn mapCompressError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CorruptInput,
    };
}

fn mapInflateError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EndOfStream, error.ReadFailed => error.Truncated,
        else => error.CorruptInput,
    };
}

/// Inflate one raw deflate member from `data`, appending to `out`, and return
/// the number of compressed bytes consumed.
fn inflateInto(allocator: Allocator, data: []const u8, out: *std.ArrayList(u8)) Error!usize {
    var input: std.Io.Reader = .fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&input, .raw, &window);
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = dec.reader.readSliceShort(&tmp) catch |err| return mapInflateError(err);
        if (n == 0) break;
        out.appendSlice(allocator, tmp[0..n]) catch |err| return err;
    }
    return input.seek;
}
