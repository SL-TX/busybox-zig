//! Pure-Zig bzip2 helpers (decoder and encoder) for the libbb archival applets.
//! Implements BZh1..BZh9 streams: Huffman/MTF/RLE2 decoding, inverse BWT and
//! RLE1, with per-block and stream CRCs verified.  Randomised blocks (an
//! obsolete bzip2 feature also rejected by BusyBox) are reported as errors.
//!
//! The encoder uses a simple, valid coding strategy: RLE1 + a suffix-ranking
//! BWT + MTF/RLE2 + equal-length canonical Huffman codes in one group.  It is
//! fully interoperable (its output is accepted by external bzip2 decoders)
//! but does not try to match the reference compressor's ratio or speed.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadMagic,
    BadHeader,
    CorruptInput,
    Truncated,
    Unsupported,
    ChecksumMismatch,
} || Allocator.Error;

const block_magic: u64 = 0x314159265359;
const final_magic: u64 = 0x177245385090;
const max_symbols = 258; // 256 byte values + RUNA + RUNB + EOB
const group_size = 50;

/// bzip2 uses the non-reflected CRC-32 (polynomial 0x04C11DB7), unlike
/// gzip/zlib's reflected CRC-32.
fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffff_ffff;
    for (bytes) |b| {
        crc ^= @as(u32, b) << 24;
        for (0..8) |_| {
            crc = if ((crc & 0x8000_0000) != 0) (crc << 1) ^ 0x04c1_1db7 else crc << 1;
        }
    }
    return ~crc;
}

fn rotl1(x: u32) u32 {
    return (x << 1) | (x >> 31);
}

// ---------------------------------------------------------------- bit reader

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    bit: u3 = 0,

    fn readBit(self: *BitReader) Error!u1 {
        if (self.pos >= self.data.len) return error.Truncated;
        const value: u1 = @intCast((self.data[self.pos] >> (7 - @as(u3, self.bit))) & 1);
        self.bit +%= 1;
        if (self.bit == 0) {
            self.pos += 1;
        }
        return value;
    }

    fn readBits(self: *BitReader, n: u6) Error!u32 {
        var value: u32 = 0;
        for (0..n) |_| value = (value << 1) | try self.readBit();
        return value;
    }

    fn alignByte(self: *BitReader) void {
        if (self.bit != 0) {
            self.bit = 0;
            self.pos += 1;
        }
    }
};

const BitWriter = struct {
    out: *std.ArrayList(u8),
    allocator: Allocator,
    current: u8 = 0,
    used: u3 = 0,

    fn writeBit(self: *BitWriter, value: u1) Error!void {
        self.current = (self.current << 1) | value;
        self.used +%= 1;
        if (self.used == 0) {
            try self.out.append(self.allocator, self.current);
            self.current = 0;
        }
    }

    fn writeBits(self: *BitWriter, value: u32, n: u6) Error!void {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            try self.writeBit(@intCast((value >> @intCast(i)) & 1));
        }
    }

    fn alignByte(self: *BitWriter) Error!void {
        if (self.used != 0) {
            try self.writeBits(0, @intCast(8 - @as(u4, self.used)));
        }
    }
};

// ------------------------------------------------------------ huffman tables

const SymTable = struct {
    lens: [max_symbols]u8 = @splat(0),
    codes: [max_symbols]u32 = @splat(0),
    min_len: u8 = 20,
    max_len: u8 = 1,

    fn read(self: *SymTable, br: *BitReader, count: usize) Error!void {
        var len: i32 = @as(i32, @intCast(try br.readBits(5))) - 1;
        for (0..count) |sym| {
            while (true) {
                // A leading 0 bit terminates the delta; the following bit is
                // only consumed when the delta is non-zero.
                if (try br.readBit() == 0) break;
                // "10" increments, "11" decrements (matches bzip2's delta code).
                len += if (try br.readBit() == 0) @as(i32, 1) else -1;
                if (len < 0 or len > 19) return error.CorruptInput;
            }
            const l: u8 = @intCast(len + 1);
            if (l == 0 or l > 20) return error.CorruptInput;
            self.lens[sym] = l;
            self.min_len = @min(self.min_len, l);
            self.max_len = @max(self.max_len, l);
        }
        // Canonical codes: for each length, symbols in index order.
        var code: u32 = 0;
        for (1..21) |l| {
            code <<= 1;
            for (0..count) |sym| {
                if (self.lens[sym] == l) {
                    self.codes[sym] = code;
                    code += 1;
                    if (code > (@as(u32, 1) << @intCast(l))) return error.CorruptInput;
                }
            }
        }
    }

    fn decode(self: *const SymTable, br: *BitReader) Error!usize {
        var code: u32 = 0;
        var l: usize = 1;
        while (l <= self.max_len) : (l += 1) {
            code = (code << 1) | try br.readBit();
            if (l < self.min_len) continue;
            for (0..max_symbols) |sym| {
                if (self.lens[sym] == l and self.codes[sym] == code) return sym;
            }
        }
        return error.CorruptInput;
    }
};

// ------------------------------------------------------------- decompression

pub fn decompress(allocator: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var br = BitReader{ .data = data };
    while (true) {
        try readStreamHeader(&br); // "BZhN"
        var combined: u32 = 0;
        while (true) {
            const hi = try br.readBits(24);
            const lo = try br.readBits(24);
            const magic: u64 = (@as(u64, hi) << 24) | lo;
            if (magic == final_magic) {
                const want = try br.readBits(32);
                if (want != combined) return error.ChecksumMismatch;
                br.alignByte();
                break;
            }
            if (magic != block_magic) return error.BadMagic;
            try decodeBlock(allocator, &br, &out, &combined);
        }
        if (br.pos == data.len) break; // no trailing stream
    }
    return out.toOwnedSlice(allocator);
}

fn readStreamHeader(br: *BitReader) Error!void {
    if (br.data.len - br.pos < 4) return error.Truncated;
    if (br.data[br.pos] != 'B' or br.data[br.pos + 1] != 'Z' or br.data[br.pos + 2] != 'h')
        return error.BadMagic;
    if (br.data[br.pos + 3] < '1' or br.data[br.pos + 3] > '9') return error.BadHeader;
    br.pos += 4;
    br.bit = 0;
}

fn decodeBlock(allocator: Allocator, br: *BitReader, out: *std.ArrayList(u8), combined: *u32) Error!void {
    const block_crc = try br.readBits(32);
    if (try br.readBit() != 0) return error.Unsupported; // block randomised
    const orig_ptr = try br.readBits(24);

    var sym_to_byte: [256]u8 = undefined;
    var sym_total: usize = 0;
    var outer = try br.readBits(16);
    for (0..16) |group| {
        if ((outer & 0x8000) != 0) {
            const inner = try br.readBits(16);
            for (0..16) |k| {
                if ((inner & (@as(u32, 1) << @intCast(15 - k))) != 0) {
                    if (sym_total >= 256) return error.CorruptInput;
                    sym_to_byte[sym_total] = @intCast(group * 16 + k);
                    sym_total += 1;
                }
            }
        }
        outer <<= 1;
    }
    if (sym_total == 0) return error.CorruptInput;

    const groups = try br.readBits(3);
    if (groups < 2 or groups > 6) return error.CorruptInput;
    const selectors_n = try br.readBits(15);
    if (selectors_n == 0 or selectors_n > 32768) return error.CorruptInput;
    const selectors = try allocator.alloc(u8, selectors_n);
    defer allocator.free(selectors);
    var mtf_group: [6]u8 = undefined;
    for (0..groups) |i| mtf_group[i] = @intCast(i);
    for (0..selectors_n) |i| {
        var n: usize = 0;
        while (try br.readBit() != 0) {
            n += 1;
            if (n >= groups) return error.CorruptInput;
        }
        const value = mtf_group[n];
        var j = n;
        while (j > 0) : (j -= 1) mtf_group[j] = mtf_group[j - 1];
        mtf_group[0] = value;
        selectors[i] = value;
    }

    var tables: [6]SymTable = .{ .{}, .{}, .{}, .{}, .{}, .{} };
    for (0..groups) |g| try tables[g].read(br, sym_total + 2);

    var mtf: [256]u8 = undefined;
    for (0..sym_total) |i| mtf[i] = @intCast(i);
    var counts: [256]u32 = @splat(0);
    var dbuf: std.ArrayList(u32) = .empty;
    defer dbuf.deinit(allocator);

    var run_pos: u64 = 0;
    var run_count: u64 = 0;
    var selector: usize = 0;
    var in_group: usize = group_size;
    var active: ?*const SymTable = null;
    const max_block = 900_000;
    while (true) {
        if (in_group == group_size) {
            if (selector >= selectors_n) return error.CorruptInput;
            const g = selectors[selector];
            if (g >= groups) return error.CorruptInput;
            selector += 1;
            in_group = 0;
            active = &tables[g];
        }
        in_group += 1;
        const sym = try active.?.decode(br);
        if (sym <= 1) {
            if (run_pos == 0) {
                run_pos = 1;
                run_count = 0;
            }
            run_count += run_pos << @as(u6, @intCast(sym));
            if (run_count > max_block) return error.CorruptInput;
            if (run_pos < max_block) run_pos <<= 1;
            continue;
        }
        if (run_pos != 0) {
            const b = sym_to_byte[mtf[0]];
            if (run_count > max_block or dbuf.items.len + @as(usize, @intCast(run_count)) > max_block)
                return error.CorruptInput;
            counts[b] += @intCast(run_count);
            for (0..@as(usize, @intCast(run_count))) |_| try dbuf.append(allocator, b);
            run_pos = 0;
            run_count = 0;
        }
        if (sym > sym_total) break; // end of block
        const idx = sym - 1;
        if (idx >= sym_total) return error.CorruptInput;
        const b = mtf[idx];
        var k = idx;
        while (k > 0) : (k -= 1) mtf[k] = mtf[k - 1];
        mtf[0] = b;
        if (dbuf.items.len >= max_block) return error.CorruptInput;
        counts[sym_to_byte[b]] += 1;
        try dbuf.append(allocator, sym_to_byte[b]);
    }

    const n = dbuf.items.len;
    if (orig_ptr >= n and n != 0) return error.CorruptInput;

    var cntsum: usize = 0;
    for (counts) |c| cntsum += c;
    // Inverse BWT: cumulative counts, then the successor vector.
    var cumulative: [256]u32 = @splat(0);
    var sum: u32 = 0;
    for (0..256) |i| {
        const c = counts[i];
        cumulative[i] = sum;
        sum += c;
    }
    const tt = try allocator.alloc(u32, n);
    defer allocator.free(tt);
    const cursor = try allocator.dupe(u32, cumulative[0..]);
    defer allocator.free(cursor);
    for (dbuf.items, 0..) |v, i| {
        const b: u8 = @intCast(v & 0xff);
        const at = cursor[b];
        tt[at] = @as(u32, b) | (@as(u32, @intCast(i)) << 8);
        cursor[b] += 1;
    }

    // RLE1 expansion.  The first byte (at the cumulative position orig_ptr)
    // is emitted before following the successor vector; a run of four equal
    // bytes is followed by a count byte as in the bzip2 stream format.
    const block_start = out.items.len;
    var pos: u32 = if (n != 0) tt[orig_ptr] >> 8 else 0;
    var current: u8 = if (n != 0) @intCast(tt[orig_ptr] & 0xff) else 0;
    var countdown: i32 = 4; // first byte was emitted unchecked above
    var steps: usize = 0;
    if (n != 0) try out.append(allocator, current);
    while (steps + 1 < n) {
        const previous = current;
        const t = tt[pos];
        current = @intCast(t & 0xff);
        pos = t >> 8;
        steps += 1;
        var copies: usize = 0;
        if (countdown > 1) {
            countdown -= 1;
            if (current != previous) countdown = 4;
        } else {
            copies = current;
            current = previous;
            countdown = 5;
            if (copies == 0) continue;
        }
        try out.append(allocator, current);
        if (copies > 1) {
            for (1..copies) |_| try out.append(allocator, current);
        }
        if (out.items.len > 64 * 1024 * 1024) return error.CorruptInput;
    }
    if (crc32(out.items[block_start..]) != block_crc) return error.ChecksumMismatch;
    combined.* = rotl1(combined.*) ^ block_crc;
}

// ------------------------------------------------------------------ encoder

pub fn compress(allocator: Allocator, data: []const u8, level: u4) Error![]u8 {
    if (level < 1 or level > 9) return error.BadHeader;
    const block_size: usize = 100_000 * @as(usize, level);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "BZh");
    try out.append(allocator, '0' + @as(u8, level));
    var bw = BitWriter{ .out = &out, .allocator = allocator };
    var combined: u32 = 0;

    var offset: usize = 0;
    while (offset < data.len) {
        const n = @min(block_size, data.len - offset);
        const chunk = data[offset .. offset + n];
        try encodeBlock(allocator, &bw, chunk);
        const crc = crc32(chunk);
        combined = rotl1(combined) ^ crc;
        offset += n;
    }

    try bw.writeBits(@truncate(final_magic >> 24), 24);
    try bw.writeBits(@truncate(final_magic), 24);
    try bw.writeBits(combined, 32);
    try bw.alignByte();
    return out.toOwnedSlice(allocator);
}

fn encodeBlock(allocator: Allocator, bw: *BitWriter, chunk: []const u8) Error!void {
    const rle = try rle1(allocator, chunk);
    defer allocator.free(rle);
    const bwt_result = try forwardBwt(allocator, rle);
    defer allocator.free(bwt_result.last);
    defer allocator.free(bwt_result.sa);
    defer allocator.free(bwt_result.rank);
    defer allocator.free(bwt_result.next_rank);
    const last = bwt_result.last;

    // The wire format stores a sorted bitmap of used bytes, so the decoder
    // assigns symbol indices in ascending byte order.
    var used: [256]bool = @splat(false);
    for (last) |b| used[b] = true;
    var sym_to_byte: [256]u8 = undefined;
    var byte_to_sym: [256]?u8 = @splat(null);
    var sym_total: usize = 0;
    for (0..256) |b| {
        if (used[b]) {
            byte_to_sym[@intCast(b)] = @intCast(sym_total);
            sym_to_byte[sym_total] = @intCast(b);
            sym_total += 1;
        }
    }
    if (sym_total == 0) return error.CorruptInput;

    var mtf: [256]u8 = undefined;
    for (0..sym_total) |i| mtf[i] = @intCast(i);
    var mtfv: std.ArrayList(u16) = .empty;
    defer mtfv.deinit(allocator);
    var pending: usize = 0;
    for (last) |b| {
        const sym = byte_to_sym[b].?;
        if (mtf[0] == sym) {
            pending += 1;
            continue;
        }
        if (pending != 0) {
            try appendRun(&mtfv, allocator, pending);
            pending = 0;
        }
        var idx: usize = 1;
        while (idx < sym_total and mtf[idx] != sym) : (idx += 1) {}
        if (idx >= sym_total) return error.CorruptInput;
        try mtfv.append(allocator, @intCast(idx + 1));
        var k = idx;
        while (k > 0) : (k -= 1) mtf[k] = mtf[k - 1];
        mtf[0] = sym;
    }
    if (pending != 0) try appendRun(&mtfv, allocator, pending);
    try mtfv.append(allocator, @intCast(sym_total + 1)); // EOB

    // Block header.
    try bw.writeBits(@truncate(block_magic >> 24), 24);
    try bw.writeBits(@truncate(block_magic), 24);
    try bw.writeBits(crc32(chunk), 32);
    try bw.writeBit(0); // not randomised
    try bw.writeBits(@intCast(bwt_result.orig), 24);

    var outer: u16 = 0;
    var inner: [16]u16 = @splat(0);
    for (0..sym_total) |s| {
        const byte = sym_to_byte[s];
        inner[byte >> 4] |= @as(u16, 1) << @intCast(15 - (byte & 15));
    }
    for (0..16) |g| if (inner[g] != 0) {
        outer |= @as(u16, 1) << @intCast(15 - g);
    };
    try bw.writeBits(outer, 16);
    for (0..16) |g| if (inner[g] != 0) {
        try bw.writeBits(inner[g], 16);
    };

    try bw.writeBits(2, 3); // two Huffman groups
    const n_selectors: usize = (mtfv.items.len + group_size - 1) / group_size;
    try bw.writeBits(@intCast(n_selectors), 15);
    for (0..n_selectors) |_| try bw.writeBit(0); // MTF selector 0

    const code_bits: u5 = 9; // 2^9 >= 258 symbols
    for (0..2) |_| {
        try bw.writeBits(code_bits, 5);
        for (0..sym_total + 2) |_| try bw.writeBit(0); // zero length deltas
    }
    for (mtfv.items) |sym| try bw.writeBits(sym, code_bits);
    // bzip2 packs the next block (or the final marker) directly after the
    // last Huffman symbol; only the end of the whole stream is byte-aligned.
}

fn appendRun(mtfv: *std.ArrayList(u16), allocator: Allocator, count: usize) Error!void {
    var z: i64 = @as(i64, @intCast(count)) - 1;
    while (true) {
        try mtfv.append(allocator, if ((z & 1) != 0) 1 else 0); // RUNB / RUNA
        z -= 2;
        if (z < 0) break;
        z = @divTrunc(z, 2);
    }
}

fn rle1(allocator: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        var run: usize = 1;
        while (i + run < data.len and data[i + run] == b) : (run += 1) {}
        var left = run;
        while (left > 0) {
            if (left >= 4) {
                try out.appendNTimes(allocator, b, 4);
                left -= 4;
                const extra = @min(left, 255);
                try out.append(allocator, @intCast(extra));
                left -= extra;
            } else {
                try out.appendNTimes(allocator, b, left);
                left = 0;
            }
        }
        i += run;
    }
    return out.toOwnedSlice(allocator);
}

const BwtResult = struct {
    last: []u8,
    sa: []u32,
    rank: []u32,
    next_rank: []u32,
    orig: usize,
};

const SortCtx = struct { rank: []const u32, k: u32, n: u32 };

fn rotationLess(ctx: SortCtx, a: u32, b: u32) bool {
    const ak = (a + ctx.k) % ctx.n;
    const bk = (b + ctx.k) % ctx.n;
    if (ctx.rank[a] != ctx.rank[b]) return ctx.rank[a] < ctx.rank[b];
    return ctx.rank[ak] < ctx.rank[bk];
}

fn forwardBwt(allocator: Allocator, data: []const u8) Error!BwtResult {
    const n = data.len;
    var rank = try allocator.alloc(u32, n);
    var next_rank = try allocator.alloc(u32, n);
    var sa = try allocator.alloc(u32, n);
    var last = try allocator.alloc(u8, n);
    errdefer allocator.free(rank);
    errdefer allocator.free(next_rank);
    errdefer allocator.free(sa);
    errdefer allocator.free(last);
    var orig: usize = 0;
    for (0..n) |i| {
        rank[i] = data[i];
        sa[i] = @intCast(i);
    }
    var k: u32 = 1;
    while (k < n) : (k <<= 1) {
        const ctx = SortCtx{ .rank = rank, .k = k, .n = @intCast(n) };
        std.mem.sort(u32, sa, ctx, rotationLess);
        next_rank[sa[0]] = 0;
        var classes: u32 = 1;
        for (1..n) |i| {
            if (rotationLess(ctx, sa[i - 1], sa[i])) {
                next_rank[sa[i]] = classes;
                classes += 1;
            } else {
                next_rank[sa[i]] = classes - 1;
            }
        }
        const tmp = rank;
        rank = next_rank;
        next_rank = tmp;
        if (classes == n) break;
        if (k > (1 << 30)) return error.CorruptInput;
    }
    // origPtr is the sorted row whose rotation begins at offset zero.
    for (0..n) |i| {
        const prev = if (sa[i] == 0) @as(usize, n - 1) else @as(usize, sa[i]) - 1;
        last[i] = data[prev];
        if (sa[i] == 0) orig = i;
    }
    return .{ .last = last, .sa = sa, .rank = rank, .next_rank = next_rank, .orig = orig };
}
