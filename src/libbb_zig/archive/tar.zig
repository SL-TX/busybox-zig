//! tar helpers (USTAR, GNU longname/sparse and PAX path/linkpath records).
//! Pure buffer-based API: `build` writes an archive, `parse` reads one back.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadMagic,
    CorruptHeader,
    Truncated,
    Unsupported,
} || Allocator.Error;

pub const SparseExtent = struct { offset: u64, length: u64 };

pub const Entry = struct {
    name: []const u8 = "",
    data: []const u8 = "",
    linkname: []const u8 = "",
    mode: u32 = 0o100644,
    uid: u32 = 0,
    gid: u32 = 0,
    mtime: u64 = 0,
    typeflag: u8 = '0',
    realsize: u64 = 0,
    size: ?u64 = null,
    sparse: []const SparseExtent = &.{},
};

const Header = struct {
    name: [100]u8,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    mtime: u64,
    typeflag: u8,
    linkname: [100]u8,
    prefix: [155]u8,
    gnu: bool,
    sparse: [4]SparseExtent,
    is_extended: bool,
    realsize: u64,
};

fn parseOctal(field: []const u8) Error!u64 {
    if (field.len == 0) return 0;
    if ((field[0] & 0x80) != 0) {
        // GNU base-256 encoding.
        var value: u64 = @intCast(field[0] & 0x7f);
        for (field[1..]) |b| value = (value << 8) | b;
        return value;
    }
    var value: u64 = 0;
    var seen = false;
    for (field) |c| {
        if (c == 0 or c == ' ') {
            if (seen) break;
            continue;
        }
        if (c < '0' or c > '7') return error.CorruptHeader;
        seen = true;
        value = value *% 8 +% (c - '0');
    }
    return value;
}

fn writeOctal(field: []u8, value: u64) void {
    @memset(field, 0);
    if (field.len == 0) return;
    var digits: [32]u8 = undefined;
    var n: usize = 0;
    var v = value;
    while (v > 0) {
        digits[n] = @intCast('0' + (v & 7));
        n += 1;
        v >>= 3;
    }
    const total = field.len - 1;
    if (n > total) n = total;
    var i: usize = 0;
    while (i < n) : (i += 1) field[total - n + i] = digits[n - 1 - i];
}

fn cstr(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

fn fixed100(field: []const u8) [100]u8 {
    var out: [100]u8 = @splat(0);
    const src = cstr(field);
    @memcpy(out[0..src.len], src);
    return out;
}

fn fixed155(field: []const u8) [155]u8 {
    var out: [155]u8 = @splat(0);
    const src = cstr(field);
    @memcpy(out[0..src.len], src);
    return out;
}

fn parseHeader(block: *const [512]u8) Error!Header {
    var stored: u64 = 0;
    for (block[148..156]) |c| {
        if (c == 0 or c == ' ') continue;
        if (c < '0' or c > '7') return error.CorruptHeader;
        stored = stored * 8 + (c - '0');
    }
    var computed: u64 = 0;
    for (block, 0..) |c, i| {
        computed += if (i >= 148 and i < 156) ' ' else c;
    }
    if (stored != computed) return error.CorruptHeader;
    const magic = block[257..263];
    const gnu = std.mem.eql(u8, magic, "ustar ");
    if (!gnu and !std.mem.eql(u8, magic, "ustar\x00")) return error.BadMagic;

    var h = Header{
        .name = fixed100(block[0..100]),
        .mode = @intCast(try parseOctal(block[100..108])),
        .uid = @intCast(try parseOctal(block[108..116])),
        .gid = @intCast(try parseOctal(block[116..124])),
        .size = try parseOctal(block[124..136]),
        .mtime = try parseOctal(block[136..148]),
        .typeflag = block[156],
        .linkname = fixed100(block[157..257]),
        .prefix = if (gnu) @as([155]u8, @splat(0)) else fixed155(block[345..500]),
        .gnu = gnu,
        .sparse = @splat(.{ .offset = 0, .length = 0 }),
        .is_extended = false,
        .realsize = 0,
    };
    // Only GNU-sparse headers (magic "ustar ") use bytes 345..400 for the
    // sparse map; in USTAR headers that area is the ASCII prefix string.
    if (gnu) {
        for (0..4) |i| {
            const off = try parseOctal(block[345 + i * 24 ..][0..12]);
            const len = try parseOctal(block[345 + i * 24 + 12 ..][0..12]);
            h.sparse[i] = .{ .offset = off, .length = len };
        }
        h.is_extended = block[387] != 0;
        h.realsize = try parseOctal(block[388..400]);
    }
    return h;
}

/// Largest slash that lets both the prefix (<=155) and basename (<=100)
/// fit in a USTAR header.  Used by both build() and makeHeader() so the
/// GNU-longname decision can never disagree with the actual split.
fn prefixSplit(name: []const u8) ?usize {
    if (name.len <= 100) return null;
    var i: usize = @min(name.len - 1, 155);
    while (i > 0) : (i -= 1) {
        if (name[i] == '/' and name.len - i - 1 <= 100) return i;
    }
    return null;
}

fn makeHeader(name: []const u8, linkname: []const u8, entry: Entry) Error![512]u8 {
    var block: [512]u8 = @splat(0);
    const nlen: usize = @min(name.len, 100);
    @memcpy(block[0..nlen], name[0..nlen]);
    writeOctal(block[100..108], entry.mode);
    writeOctal(block[108..116], entry.uid);
    writeOctal(block[116..124], entry.gid);
    writeOctal(block[124..136], entry.size orelse entry.data.len);
    writeOctal(block[136..148], entry.mtime);
    block[156] = entry.typeflag;
    const llen: usize = @min(linkname.len, 100);
    @memcpy(block[157 .. 157 + llen], linkname[0..llen]);
    if (entry.typeflag == 'S') {
        @memcpy(block[257..263], "ustar ");
        block[263] = ' ';
        block[264] = 0;
    } else {
        @memcpy(block[257..265], "ustar\x00" ++ "00");
    }
    // USTAR prefix split when it fits; otherwise the caller emits GNU 'L'.
    if (entry.typeflag != 'S') {
        if (prefixSplit(name)) |s| {
            @memset(block[0..100], 0); // discard the raw first 100 bytes
            @memset(block[345..500], 0);
            @memcpy(block[0..100][0 .. name.len - s - 1], name[s + 1 ..]);
            @memcpy(block[345..500][0..s], name[0..s]);
        }
    }
    if (entry.typeflag == 'S') {
        for (entry.sparse, 0..) |ext, i| {
            if (i >= 4) break;
            writeOctal(block[345 + i * 24 ..][0..12], ext.offset);
            writeOctal(block[345 + i * 24 + 12 ..][0..12], ext.length);
        }
        writeOctal(block[388..400], entry.realsize);
    }
    @memset(block[148..156], ' ');
    var sum: u64 = 0;
    for (block) |c| sum += c;
    var check: [8]u8 = @splat('0');
    var v = sum;
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        check[i] = @intCast('0' + (v & 7));
        v >>= 3;
    }
    @memcpy(block[148..154], check[0..6]);
    block[154] = 0;
    block[155] = ' ';
    return block;
}

fn appendData(out: *std.ArrayList(u8), allocator: Allocator, bytes: []const u8) Error!void {
    try out.appendSlice(allocator, bytes);
    const padding = (512 - (bytes.len % 512)) % 512;
    try out.appendNTimes(allocator, 0, padding);
}

pub fn build(allocator: Allocator, entries: []const Entry) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (entries) |entry| {
        var name = entry.name;
        var linkname = entry.linkname;
        var long_name_buf: ?[]u8 = null;
        defer if (long_name_buf) |b| allocator.free(b);
        if (name.len > 100) {
            if (prefixSplit(name) == null or entry.typeflag == 'S') {
                long_name_buf = try std.mem.concat(allocator, u8, &.{ name, "\x00" });
                name = long_name_buf.?;
                const hdr = try makeHeader("././@LongLink", "", .{ .typeflag = 'L', .size = name.len });
                try out.appendSlice(allocator, &hdr);
                try appendData(&out, allocator, name);
                name = "././@LongLink";
            }
        }
        if (linkname.len > 100) {
            const long_link = try std.mem.concat(allocator, u8, &.{ linkname, "\x00" });
            defer allocator.free(long_link);
            const hdr = try makeHeader("././@LongLink", "", .{ .typeflag = 'K', .size = long_link.len });
            try out.appendSlice(allocator, &hdr);
            try appendData(&out, allocator, long_link);
            linkname = "";
        }
        const hdr = try makeHeader(name, linkname, entry);
        try out.appendSlice(allocator, &hdr);
        try appendData(&out, allocator, entry.data);
    }
    try out.appendNTimes(allocator, 0, 1024);
    return out.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.data);
        allocator.free(entry.linkname);
        if (entry.sparse.len > 0) allocator.free(entry.sparse);
    }
    allocator.free(entries);
}

pub fn parse(allocator: Allocator, data: []const u8) Error![]Entry {
    if (data.len < 512) return error.Truncated;
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| {
            allocator.free(e.name);
            allocator.free(e.data);
            allocator.free(e.linkname);
            if (e.sparse.len > 0) allocator.free(e.sparse);
        }
        out.deinit(allocator);
    }
    var pos: usize = 0;
    var long_name: ?[]u8 = null;
    var long_link: ?[]u8 = null;
    var pax_path: ?[]u8 = null;
    defer {
        if (long_name) |v| allocator.free(v);
        if (long_link) |v| allocator.free(v);
        if (pax_path) |v| allocator.free(v);
    }
    while (true) {
        if (data.len - pos < 512) return error.Truncated;
        const block: *const [512]u8 = @ptrCast(data[pos..].ptr);
        pos += 512;
        var all_zero = true;
        for (block) |b| if (b != 0) {
            all_zero = false;
            break;
        };
        if (all_zero) break;
        const h = try parseHeader(block);
        const padded = std.mem.alignForward(usize, h.size, 512);
        if (padded > data.len - pos) return error.Truncated;
        const body = data[pos .. pos + @as(usize, @intCast(h.size))];
        switch (h.typeflag) {
            'L' => {
                if (long_name) |v| allocator.free(v);
                long_name = try allocator.dupe(u8, std.mem.trimEnd(u8, body, "\x00"));
            },
            'K' => {
                if (long_link) |v| allocator.free(v);
                long_link = try allocator.dupe(u8, std.mem.trimEnd(u8, body, "\x00"));
            },
            'x', 'g' => {
                if (try paxValue(body, "path")) |v| {
                    if (pax_path) |old| allocator.free(old);
                    pax_path = try allocator.dupe(u8, v);
                }
            },
            else => {
                var name = if (h.prefix[0] != 0)
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cstr(&h.prefix), cstr(&h.name) })
                else
                    try allocator.dupe(u8, cstr(&h.name));
                var link = try allocator.dupe(u8, cstr(&h.linkname));
                if (pax_path) |p| {
                    allocator.free(name);
                    name = try allocator.dupe(u8, p);
                } else if (long_name) |p| {
                    allocator.free(name);
                    name = try allocator.dupe(u8, p);
                }
                if (long_link) |p| {
                    allocator.free(link);
                    link = try allocator.dupe(u8, p);
                }
                var sparse_count: usize = 0;
                for (h.sparse) |ext| if (ext.length != 0) {
                    sparse_count += 1;
                };
                const sp = try allocator.alloc(SparseExtent, sparse_count);
                var si: usize = 0;
                for (h.sparse) |ext| if (ext.length != 0) {
                    sp[si] = ext;
                    si += 1;
                };
                try out.append(allocator, .{
                    .name = name,
                    .data = try allocator.dupe(u8, body),
                    .linkname = link,
                    .mode = h.mode,
                    .uid = h.uid,
                    .gid = h.gid,
                    .mtime = h.mtime,
                    .typeflag = h.typeflag,
                    .realsize = if (h.realsize != 0) h.realsize else h.size,
                    .sparse = sp,
                });
                if (h.typeflag != 'x' and h.typeflag != 'g') {
                    if (long_name) |v| {
                        allocator.free(v);
                        long_name = null;
                    }
                    if (long_link) |v| {
                        allocator.free(v);
                        long_link = null;
                    }
                    if (pax_path) |v| {
                        allocator.free(v);
                        pax_path = null;
                    }
                }
            },
        }
        pos += padded;
    }
    return out.toOwnedSlice(allocator);
}

fn paxValue(body: []const u8, wanted: []const u8) Error!?[]const u8 {
    var pos: usize = 0;
    while (pos < body.len) {
        const space = std.mem.indexOfScalarPos(u8, body, pos, ' ') orelse return error.CorruptHeader;
        const len = std.fmt.parseInt(usize, body[pos..space], 10) catch return error.CorruptHeader;
        if (len == 0 or len > body.len - pos) return error.CorruptHeader;
        const end = pos + len;
        if (space + 1 > end) return error.CorruptHeader;
        const record = body[space + 1 .. end];
        if (std.mem.startsWith(u8, record, wanted) and record.len > wanted.len and record[wanted.len] == '=') {
            return std.mem.trimEnd(u8, record[wanted.len + 1 ..], "\n");
        }
        pos = end;
    }
    return null;
}
