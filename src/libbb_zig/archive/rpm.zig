//! RPM lead / header / payload helpers (no applet logic).  Headers are read
//! in their on-disk big-endian format; string and integer tags are exposed
//! by numeric tag, and gzip payloads use the libbb gzip helper.

const std = @import("std");
const gzip = @import("../compression/gzip.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadHeader,
    BadMagic,
    ChecksumMismatch,
    CorruptHeader,
    CorruptInput,
    SizeMismatch,
    Truncated,
    Unsupported,
} || Allocator.Error;

pub const Tag = enum(u32) {
    name = 1000,
    version = 1001,
    release = 1002,
    buildtime = 1006,
    summary = 1004,
    description = 1005,
    license = 1014,
    os = 1021,
    arch = 1022,
    payload_format = 1124,
    payload_compressor = 1125,
    payload_flags = 1126,
};

pub const Lead = struct {
    major: u16,
    minor: u16,
    kind: u16,
    arch: u16,
    name: [66]u8,
    os: u16,
};

const IndexEntry = struct { tag: u32, kind: u32, offset: u32, count: u32 };

pub const Header = struct {
    index_raw: []const u8,
    count: usize,
    store: []const u8,

    fn entryAt(self: Header, i: usize) IndexEntry {
        const b = self.index_raw[i * 16 ..][0..16];
        return .{
            .tag = std.mem.readInt(u32, b[0..4], .big),
            .kind = std.mem.readInt(u32, b[4..8], .big),
            .offset = std.mem.readInt(u32, b[8..12], .big),
            .count = std.mem.readInt(u32, b[12..16], .big),
        };
    }

    pub fn find(self: Header, tag: Tag) ?IndexEntry {
        for (0..self.count) |i| {
            const e = self.entryAt(i);
            if (e.tag == @backingInt(tag)) return e;
        }
        return null;
    }
};

pub const Rpm = struct {
    lead: Lead,
    signature: Header,
    header: Header,
    payload: []const u8,

    pub fn payloadData(self: Rpm, allocator: Allocator) Error![]u8 {
        const compressor = getString(self.header, .payload_compressor) orelse "gzip";
        if (std.mem.eql(u8, compressor, "none") or std.mem.eql(u8, compressor, "cpio"))
            return allocator.dupe(u8, self.payload);
        if (std.mem.eql(u8, compressor, "gzip"))
            return gzip.decompress(allocator, self.payload);
        return error.Unsupported;
    }
};

fn readHeader(data: []const u8, pos: usize) Error!struct { header: Header, end: usize } {
    if (pos + 16 > data.len) return error.Truncated;
    if (!std.mem.eql(u8, data[pos..][0..8], &.{ 0x8e, 0xad, 0xe8, 0x01, 0, 0, 0, 0 })) return error.BadMagic;
    const nindex = std.mem.readInt(u32, data[pos + 8 ..][0..4], .big);
    const hsize = std.mem.readInt(u32, data[pos + 12 ..][0..4], .big);
    const index_bytes = @as(usize, nindex) * 16;
    if (pos + 16 + index_bytes + hsize > data.len) return error.Truncated;
    const store_start = pos + 16 + index_bytes;
    return .{
        .header = .{
            .index_raw = data[pos + 16 ..][0..index_bytes],
            .count = nindex,
            .store = data[store_start .. store_start + hsize],
        },
        .end = store_start + hsize,
    };
}

pub fn parse(data: []const u8) Error!Rpm {
    if (data.len < 96) return error.Truncated;
    if (!std.mem.eql(u8, data[0..4], &.{ 0xed, 0xab, 0xee, 0xdb })) return error.BadMagic;
    const lead = Lead{
        .major = std.mem.readInt(u16, data[4..6], .big),
        .minor = std.mem.readInt(u16, data[6..8], .big),
        .kind = std.mem.readInt(u16, data[8..10], .big),
        .arch = std.mem.readInt(u16, data[10..12], .big),
        .name = data[12..78].*,
        .os = std.mem.readInt(u16, data[78..80], .big),
    };
    const sig = try readHeader(data, 96);
    const main = try readHeader(data, std.mem.alignForward(usize, sig.end, 8));
    // BusyBox starts the payload immediately after the main header (no
    // 8-byte pad), so match that offset for interoperability.
    const payload_start = main.end;
    if (payload_start > data.len) return error.Truncated;
    return .{ .lead = lead, .signature = sig.header, .header = main.header, .payload = data[payload_start..] };
}

fn entryData(header: Header, entry: IndexEntry) Error![]const u8 {
    if (entry.offset > header.store.len or entry.count > header.store.len - entry.offset)
        return error.CorruptHeader;
    return header.store[entry.offset .. entry.offset + entry.count];
}

fn entryRaw(header: Header, entry: IndexEntry) Error![]const u8 {
    if (entry.offset > header.store.len) return error.CorruptHeader;
    return header.store[entry.offset..];
}

pub fn getString(header: Header, tag: Tag) ?[]const u8 {
    const entry = header.find(tag) orelse return null;
    if (entry.kind != 6 and entry.kind != 9) return null;
    const bytes = entryRaw(header, entry) catch return null;
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}

pub fn getInt(header: Header, tag: Tag) ?u32 {
    const entry = header.find(tag) orelse return null;
    if (entry.kind != 4 or entry.count < 1) return null;
    const bytes = entryData(header, entry) catch return null;
    if (bytes.len < 4) return null;
    return std.mem.readInt(u32, bytes[0..4], .big);
}

pub fn getStrings(header: Header, tag: Tag, allocator: Allocator) Error![][]const u8 {
    const entry = header.find(tag) orelse return &.{};
    if (entry.kind != 8) return error.Unsupported;
    const bytes = try entryData(header, entry);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, pos, 0) orelse bytes.len;
        try list.append(allocator, bytes[pos..end]);
        pos = end + 1;
    }
    return list.toOwnedSlice(allocator);
}

pub const BuildOptions = struct {
    name: []const u8,
    version: []const u8,
    release: []const u8,
    arch: []const u8,
    payload: []const u8,
    payload_compressor: []const u8 = "none",
};

const TagValue = struct { tag: Tag, kind: u32, value: []const u8 };

fn appendHeader(out: *std.ArrayList(u8), allocator: Allocator, tags: []const TagValue) Error!void {
    var index: std.ArrayList(u8) = .empty;
    defer index.deinit(allocator);
    var store: std.ArrayList(u8) = .empty;
    defer store.deinit(allocator);
    for (tags) |t| {
        const off: u32 = @intCast(store.items.len);
        try store.appendSlice(allocator, t.value);
        try store.append(allocator, 0);
        var b: [16]u8 = undefined;
        std.mem.writeInt(u32, b[0..4], @backingInt(t.tag), .big);
        std.mem.writeInt(u32, b[4..8], t.kind, .big);
        std.mem.writeInt(u32, b[8..12], off, .big);
        std.mem.writeInt(u32, b[12..16], 1, .big);
        try index.appendSlice(allocator, &b);
    }
    try out.appendSlice(allocator, &.{ 0x8e, 0xad, 0xe8, 0x01, 0, 0, 0, 0 });
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(tags.len), .big);
    try out.appendSlice(allocator, &b);
    std.mem.writeInt(u32, &b, @intCast(store.items.len), .big);
    try out.appendSlice(allocator, &b);
    try out.appendSlice(allocator, index.items);
    try out.appendSlice(allocator, store.items);
}

pub fn build(allocator: Allocator, opts: BuildOptions) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0xed, 0xab, 0xee, 0xdb, 0, 3, 0, 0, 0, 1 });
    try out.appendNTimes(allocator, 0, 66);
    const name = opts.name;
    const n = @min(name.len, 66);
    @memcpy(out.items[12 .. 12 + n], name[0..n]);
    try out.appendSlice(allocator, &.{ 0, 1, 0, 0 });
    try out.appendNTimes(allocator, 0, 16);
    try appendHeader(&out, allocator, &.{}); // signature header
    while (out.items.len % 8 != 0) try out.append(allocator, 0);
    try appendHeader(&out, allocator, &.{
        .{ .tag = .name, .kind = 6, .value = opts.name },
        .{ .tag = .version, .kind = 6, .value = opts.version },
        .{ .tag = .release, .kind = 6, .value = opts.release },
        .{ .tag = .arch, .kind = 6, .value = opts.arch },
        .{ .tag = .os, .kind = 6, .value = "linux" },
        .{ .tag = .payload_format, .kind = 6, .value = "cpio" },
        .{ .tag = .payload_compressor, .kind = 6, .value = opts.payload_compressor },
    });
    try out.appendSlice(allocator, opts.payload);
    return out.toOwnedSlice(allocator);
}
