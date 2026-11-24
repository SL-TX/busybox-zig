//! LZMA1 (.lzma / "alone" format) helpers.  Decoding uses Zig std; encoding
//! uses a literal-only range coder (no LZ matches) so the output is a fully
//! valid LZMA1 stream, albeit with a poor compression ratio.  This keeps the
//! helper dependency-free and is sufficient for the archival applets' needs.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadMagic,
    CorruptInput,
    Truncated,
} || Allocator.Error;

pub fn decompress(allocator: Allocator, data: []const u8) Error![]u8 {
    if (data.len < 13) return error.Truncated;
    if (data[0] >= 225) return error.CorruptInput;
    var reader: std.Io.Reader = .fixed(data);
    const buffer = allocator.alloc(u8, 4096) catch |err| return err;
    var dec = std.compress.lzma.Decompress.initOptions(
        &reader,
        allocator,
        buffer,
        .{ .unpacked_size = .read_from_header },
        1 << 30,
    ) catch |err| {
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
        else => error.CorruptInput,
    };
}

/// LZMA1 properties lc=0, lp=0, pb=0 plus a 4 KiB dictionary.
pub fn compress(allocator: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 0); // props: lc=0, lp=0, pb=0
    var dict: [4]u8 = undefined;
    std.mem.writeInt(u32, &dict, 0x1000, .little);
    try out.appendSlice(allocator, &dict);
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, @intCast(data.len), .little);
    try out.appendSlice(allocator, &size);

    var rc = RangeEncoder{ .out = &out, .allocator = allocator };
    var probs: [192]u16 = @splat(0x400); // is_match, states 0..11 * 16
    var literals: [0x300]u16 = @splat(0x400);
    for (data) |byte| {
        // state is always 0 after a literal; pos_state is always 0 (pb=0).
        try rc.encodeBit(&probs[0], 0);
        var symbol: usize = 1;
        for (0..8) |i| {
            const bit: u1 = @intCast((byte >> @intCast(7 - i)) & 1);
            try rc.encodeBit(&literals[symbol], bit);
            symbol = (symbol << 1) | bit;
        }
    }
    try encodeEndMarker(&rc, &probs);
    try rc.finish();
    return out.toOwnedSlice(allocator);
}

/// LZMA end marker: a match of length 2 with distance 0xFFFFFFFF.
fn encodeEndMarker(rc: *RangeEncoder, probs: *[192]u16) Error!void {
    var is_rep: [12]u16 = @splat(0x400);
    var choice: [3]u16 = @splat(0x400);
    var low: [8]u16 = @splat(0x400);
    var pos_slot: [64]u16 = @splat(0x400);
    var align_probs: [16]u16 = @splat(0x400);
    try rc.encodeBit(&probs[0], 1); // match
    try rc.encodeBit(&is_rep[0], 0); // normal match
    try rc.encodeBit(&choice[0], 0); // "low" length tree
    try encodeBitTree(rc, &low, 3, 0); // length code 0 -> length 2
    try encodeBitTree(rc, &pos_slot, 6, 63); // largest distance slot
    var direct: usize = 26; // 30 footer bits minus 4 alignment bits
    while (direct > 0) {
        direct -= 1;
        const bit: u1 = @intCast((@as(u32, 0x03ff_ffff) >> @intCast(direct)) & 1);
        try rc.encodeDirectBit(bit);
    }
    try encodeReverseBitTree(rc, &align_probs, 4, 15);
}

fn encodeBitTree(rc: *RangeEncoder, probs: []u16, n: u5, value: usize) Error!void {
    var idx: usize = 1;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const bit: u1 = @intCast((value >> @intCast(i)) & 1);
        try rc.encodeBit(&probs[idx], bit);
        idx = (idx << 1) | bit;
    }
}

fn encodeReverseBitTree(rc: *RangeEncoder, probs: []u16, n: u5, value: usize) Error!void {
    var idx: usize = 1;
    for (0..n) |i| {
        const bit: u1 = @intCast((value >> @intCast(i)) & 1);
        try rc.encodeBit(&probs[idx], bit);
        idx = (idx << 1) | bit;
    }
}

const RangeEncoder = struct {
    out: *std.ArrayList(u8),
    allocator: Allocator,
    low: u64 = 0,
    range: u32 = 0xffff_ffff,
    cache: u8 = 0,
    cache_size: u32 = 1,

    fn shiftLow(self: *RangeEncoder) Error!void {
        const high: u32 = @truncate(self.low >> 32);
        const low32: u32 = @truncate(self.low);
        if (high != 0 or low32 < 0xff00_0000) {
            var temp = self.cache;
            const carry: u8 = @truncate(high);
            while (self.cache_size > 0) : (self.cache_size -= 1) {
                try self.out.append(self.allocator, temp +% carry);
                temp = 0xff;
            }
            self.cache = @truncate(low32 >> 24);
        }
        self.cache_size += 1;
        self.low = @as(u64, low32 & 0x00ff_ffff) << 8;
    }

    fn encodeBit(self: *RangeEncoder, prob: *u16, bit: u1) Error!void {
        const bound: u32 = (self.range >> 11) * prob.*;
        if (bit == 0) {
            self.range = bound;
            prob.* += @intCast((0x800 - prob.*) >> 5);
        } else {
            self.low += bound;
            self.range -= bound;
            prob.* -= prob.* >> 5;
        }
        while (self.range < 0x0100_0000) {
            self.range <<= 8;
            try self.shiftLow();
        }
    }

    fn encodeDirectBit(self: *RangeEncoder, bit: u1) Error!void {
        const bound: u32 = self.range >> 1;
        if (bit == 0) {
            self.range = bound;
        } else {
            self.low += bound;
            self.range -= bound;
        }
        while (self.range < 0x0100_0000) {
            self.range <<= 8;
            try self.shiftLow();
        }
    }

    fn finish(self: *RangeEncoder) Error!void {
        self.range = 0xffff_ffff; // prevent further normalizations while flushing
        for (0..5) |_| try self.shiftLow();
    }
};
