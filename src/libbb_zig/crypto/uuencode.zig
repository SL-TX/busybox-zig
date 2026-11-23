//! Traditional uuencode/uudecode (the format emitted by BusyBox's uuencode
//! applet): a "begin <mode> <name>" line, 45-byte data lines, a zero-length
//! terminator line, and "end".  Padding uses the backtick character.

const std = @import("std");

pub const table = "`!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_";
pub const line_len = 45;

pub const Decoded = struct {
    name: []u8,
    mode: u16,
    data: []u8,

    pub fn deinit(self: *Decoded, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.data);
    }
};

fn decodeChar(c: u8) ?u6 {
    if (c == '`') return 0; // length/padding character (table index 0)
    if (c < ' ' or c > '_') return null;
    return @intCast(c - ' ');
}

/// Emit a full "begin ... / data / end" document.  `mode` is the Unix mode
/// as printed by BusyBox (e.g. 0o664).
pub fn encode(a: std.mem.Allocator, name: []const u8, mode: u16, data: []const u8) ![]u8 {
    if (name.len == 0) return error.InvalidName;
    for (name) |c| {
        if (c <= ' ' or c == 0x7f) return error.InvalidName;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "begin {o} {s}\n", .{ mode, name });

    var pos: usize = 0;
    while (pos < data.len) {
        const n = @min(line_len, data.len - pos);
        try out.append(a, table[n]);
        var i: usize = 0;
        while (i < n) : (i += 3) {
            const b0 = data[pos + i];
            const b1: u8 = if (i + 1 < n) data[pos + i + 1] else 0;
            const b2: u8 = if (i + 2 < n) data[pos + i + 2] else 0;
            try out.append(a, table[b0 >> 2]);
            try out.append(a, table[((b0 & 0x3) << 4) | (b1 >> 4)]);
            try out.append(a, table[((b1 & 0xf) << 2) | (b2 >> 6)]);
            try out.append(a, table[b2 & 0x3f]);
        }
        try out.append(a, '\n');
        pos += n;
    }
    try out.appendSlice(a, "`\nend\n");
    return out.toOwnedSlice(a);
}

/// Parse a uuencoded document.  Trailing text after "end" is ignored, as in
/// BusyBox's uudecode.  Malformed headers, characters and lengths are errors.
pub fn decode(a: std.mem.Allocator, text: []const u8) !Decoded {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return error.MalformedHeader;
    var hdr = std.mem.tokenizeAny(u8, header, " \t\r");
    if (!std.mem.eql(u8, hdr.next() orelse return error.MalformedHeader, "begin")) return error.MalformedHeader;
    const mode_text = hdr.next() orelse return error.MalformedHeader;
    const mode = std.fmt.parseInt(u16, mode_text, 8) catch return error.MalformedHeader;
    const name_text = hdr.next() orelse return error.MalformedHeader;
    const name = try a.dupe(u8, name_text);
    errdefer a.free(name);

    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(a);
    var saw_end = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, "end")) {
            saw_end = true;
            break;
        }
        if (line.len == 0) continue;
        const n = decodeChar(line[0]) orelse return error.InvalidLength;
        if (n == 0) continue;
        if (line.len != 1 + 4 * ((n + 2) / 3)) return error.InvalidLength;
        var i: usize = 1;
        var written: usize = 0;
        while (written < n) : (written += 3) {
            var c: [4]u6 = undefined;
            for (0..4) |k| {
                c[k] = decodeChar(line[i + k]) orelse return error.InvalidCharacter;
            }
            try data.append(a, @intCast((@as(u8, c[0]) << 2) | @as(u8, c[1] >> 4)));
            if (written + 1 < n) try data.append(a, @intCast((@as(u8, c[1]) << 4) | @as(u8, c[2] >> 2)));
            if (written + 2 < n) try data.append(a, @intCast((@as(u8, c[2]) << 6) | @as(u8, c[3])));
            i += 4;
        }
    }
    if (!saw_end) return error.MissingEnd;
    return .{ .name = name, .mode = mode, .data = try data.toOwnedSlice(a) };
}
