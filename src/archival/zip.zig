//! Minimal pure-Zig ZIP reader used by the `unzip` applet. Supports stored
//! and DEFLATE members, the central directory, and CRC verification.

const std = @import("std");
const gzip = @import("libbb_zig").compression.gzip;

pub const Error = gzip.Error || error{
    BadSignature,
    Corrupt,
    Unsupported,
};

pub const Entry = struct {
    name: []const u8,
    method: u16,
    crc: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    dos_time: u16,
    dos_date: u16,
    local_offset: u32,
    is_dir: bool,
    /// Unix mode from the ZIP central directory's external attributes.
    mode: u32 = 0,
};

fn u16le(data: []const u8, pos: usize) Error!u16 {
    if (pos + 2 > data.len) return error.Corrupt;
    return std.mem.readInt(u16, data[pos..][0..2], .little);
}

fn u32le(data: []const u8, pos: usize) Error!u32 {
    if (pos + 4 > data.len) return error.Corrupt;
    return std.mem.readInt(u32, data[pos..][0..4], .little);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) Error![]Entry {
    if (data.len < 22) return error.Corrupt;
    // Locate the End of Central Directory record.
    var eocd: ?usize = null;
    var i: usize = data.len - 22;
    while (true) {
        if (u32le(data, i) catch 0 == 0x06054b50) {
            eocd = i;
            break;
        }
        if (i == 0) break;
        i -= 1;
    }
    const e = eocd orelse return error.BadSignature;
    const count = try u16le(data, e + 10);
    var pos: usize = @intCast(try u32le(data, e + 16));
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    for (0..count) |_| {
        if ((try u32le(data, pos)) != 0x02014b50) return error.BadSignature;
        const method = try u16le(data, pos + 10);
        const crc = try u32le(data, pos + 16);
        const csize = try u32le(data, pos + 20);
        const usize_ = try u32le(data, pos + 24);
        const name_len = try u16le(data, pos + 28);
        const extra_len = try u16le(data, pos + 30);
        const comment_len = try u16le(data, pos + 32);
        const local = try u32le(data, pos + 42);
        const external = try u32le(data, pos + 38);
        const name_start = pos + 46;
        if (name_start + name_len > data.len) return error.Corrupt;
        const name = try allocator.dupe(u8, data[name_start .. name_start + name_len]);
        try entries.append(allocator, .{
            .name = name,
            .method = method,
            .crc = crc,
            .compressed_size = csize,
            .uncompressed_size = usize_,
            .dos_time = try u16le(data, pos + 12),
            .dos_date = try u16le(data, pos + 14),
            .local_offset = local,
            .is_dir = name.len > 0 and name[name.len - 1] == '/',
            .mode = external >> 16,
        });
        pos = name_start + name_len + extra_len + comment_len;
    }
    return entries.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.name);
    allocator.free(entries);
}

pub fn extract(allocator: std.mem.Allocator, data: []const u8, e: Entry) Error![]u8 {
    const p: usize = @intCast(e.local_offset);
    if ((try u32le(data, p)) != 0x04034b50) return error.BadSignature;
    const name_len = try u16le(data, p + 26);
    const extra_len = try u16le(data, p + 28);
    const start = p + 30 + name_len + extra_len;
    if (start + e.compressed_size > data.len) return error.Corrupt;
    const body = data[start .. start + e.compressed_size];
    switch (e.method) {
        0 => return allocator.dupe(u8, body),
        8 => return gzip.rawInflate(allocator, body),
        else => return error.Unsupported,
    }
}

pub fn crcOk(e: Entry, data: []const u8) bool {
    return gzip.crc32(data) == e.crc;
}
