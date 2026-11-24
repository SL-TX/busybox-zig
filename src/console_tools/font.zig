//! loadfont and setfont: PSF1/PSF2/raw font loading plus screen maps.
//!
//! The ioctl to a non-console fd (/dev/null in the differential cases) fails
//! with ENOTTY exactly as in the reference, after the font bytes have been
//! parsed. Distinct malformed-font diagnostics make the parser observable.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

const KDFONTOP: u32 = 0x4B72;
const PIO_UNIMAP: u32 = 0x4B67;
const PIO_UNIMAPCLR: u32 = 0x4B68;
const PIO_SCRNMAP: u32 = 0x4B41;
const PIO_UNISCRNMAP: u32 = 0x4B6A;
const E_TABSZ: usize = 256;

const Font = struct {
    data: []const u8, // glyph bitmap bytes
    height: u32,
    width: u32,
    charsize: u32,
    fontsize: u32,
    table: ?[]const u8, // unicode table tail
    psf2: bool,
};

fn le32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// Port of do_loadfont(): reformat the glyphs to 32-row cells and submit them
/// with KDFONTOP.
fn doLoadFont(fd: linux.fd_t, f: Font) void {
    if (f.height < 1 or f.height > 32 or f.width < 1 or f.width > 32)
        c.plainDie("bad character size {d}x{d}", .{ f.height, f.width });
    const charwidth = 32 * ((f.width + 7) / 8);
    const count: usize = @intCast(if (f.fontsize < 128) 128 else f.fontsize);
    var buf = std.heap.page_allocator.alloc(u8, @as(usize, @intCast(charwidth)) * count) catch
        c.errorMsgAndDie(12, "cannot allocate font buffer", .{});
    defer std.heap.page_allocator.free(buf);
    @memset(buf, 0);
    const n: usize = @intCast(f.fontsize);
    for (0..n) |i| {
        const src: usize = i * @as(usize, @intCast(f.charsize));
        const dst: usize = i * @as(usize, @intCast(charwidth));
        const len: usize = @intCast(f.charsize);
        if (src + len <= f.data.len and dst + len <= buf.len)
            @memcpy(buf[dst .. dst + len], f.data[src .. src + len]);
    }
    const cfo = extern struct {
        op: u32 = 0, // KD_FONT_OP_SET
        flags: u32 = 0,
        width: u32,
        height: u32,
        charcount: u32,
        data: [*]u8,
    }{
        .width = f.width,
        .height = f.height,
        .charcount = f.fontsize,
        .data = buf.ptr,
    };
    c.xioctl(fd, KDFONTOP, @intFromPtr(&cfo), "KDFONTOP");
}

/// Port of do_loadtable(): build the unicode-to-font pairs and submit them.
fn doLoadTable(fd: linux.fd_t, tail: []const u8, fontsize: u32, psf2: bool) void {
    const advice = extern struct {
        advised_hashsize: u16 = 0,
        advised_hashstep: u16 = 0,
        advised_hashlevel: u16 = 0,
    }{};
    c.xioctl(fd, PIO_UNIMAPCLR, @intFromPtr(&advice), "PIO_UNIMAPCLR");

    var pairs: [8192]extern struct { unicode: u16, fontpos: u16 } = undefined;
    var ct: usize = 0;
    var pos: usize = 0;
    for (0..@as(usize, fontsize)) |glyph| {
        while (pos < tail.len) {
            var unicode: u32 = 0;
            if (!psf2) {
                if (pos + 2 > tail.len) break;
                unicode = (@as(u32, tail[pos + 1]) << 8) | tail[pos];
                pos += 2;
                if (unicode == 0xffff) break;
            } else {
                const first = tail[pos];
                pos += 1;
                if (first == 0xff) break;
                if (first == 0xfe) c.plainDie("unicode sequences not implemented", .{});
                if (first >= 0xc0) {
                    var more: u8 = undefined;
                    if (first >= 0xfc) {
                        unicode = first & 0x01;
                        more = 5;
                    } else if (first >= 0xf8) {
                        unicode = first & 0x03;
                        more = 4;
                    } else if (first >= 0xf0) {
                        unicode = first & 0x07;
                        more = 3;
                    } else if (first >= 0xe0) {
                        unicode = first & 0x0f;
                        more = 2;
                    } else {
                        unicode = first & 0x1f;
                        more = 1;
                    }
                    while (more > 0) : (more -= 1) {
                        if (pos >= tail.len or tail[pos] < 0x80 or tail[pos] > 0xbf)
                            c.plainDie("illegal UTF-8 character", .{});
                        unicode = (unicode << 6) | (tail[pos] & 0x3f);
                        pos += 1;
                    }
                } else if (first >= 0x80) {
                    c.plainDie("illegal UTF-8 character", .{});
                } else {
                    unicode = first;
                }
            }
            if (ct < pairs.len) {
                pairs[ct] = .{ .unicode = @truncate(unicode), .fontpos = @intCast(glyph) };
                ct += 1;
            }
        }
    }
    const desc = extern struct { entry_ct: u16, entries: [*]const @TypeOf(pairs[0]) }{
        .entry_ct = @intCast(ct),
        .entries = pairs[0..ct].ptr,
    };
    c.xioctl(fd, PIO_UNIMAP, @intFromPtr(&desc), "PIO_UNIMAP");
}

fn parseFont(buffer: []const u8) Font {
    var f = Font{
        .data = &.{},
        .height = 0,
        .width = 8,
        .charsize = 0,
        .fontsize = 256,
        .table = null,
        .psf2 = false,
    };
    if (buffer.len >= 4 and buffer[0] == 0x36 and buffer[1] == 0x04) {
        if (buffer[2] > 5) c.plainDie("unsupported psf file mode", .{});
        if ((buffer[2] & 0x01) != 0) f.fontsize = 512;
        if ((buffer[2] & 0x02) != 0) f.table = &.{}; // sentinel: table present
        f.height = buffer[3];
        f.charsize = buffer[3];
        f.data = buffer[4..];
    } else if (buffer.len >= 32 and buffer[0] == 0x72 and buffer[1] == 0xb5 and
        buffer[2] == 0x4a and buffer[3] == 0x86)
    {
        if (le32(buffer, 4) > 0) c.plainDie("unsupported psf file version", .{});
        f.fontsize = le32(buffer, 16);
        f.psf2 = true;
        if ((le32(buffer, 12) & 0x01) != 0) f.table = &.{};
        f.charsize = le32(buffer, 20);
        f.height = le32(buffer, 24);
        f.width = le32(buffer, 28);
        const off = le32(buffer, 8);
        if (off > buffer.len) c.plainDie("input file: bad length", .{});
        f.data = buffer[@intCast(off)..];
    } else if (buffer.len == 9780) {
        f.height = 16;
        f.charsize = 16;
        f.data = buffer[40..];
    } else if ((buffer.len & 0xff) == 0) {
        f.height = @intCast(buffer.len / 256);
        f.charsize = f.height;
        f.data = buffer;
    } else {
        c.plainDie("input file: bad length or unsupported font type", .{});
    }

    const table_start: usize = @as(usize, @intCast(f.fontsize)) * @as(usize, @intCast(f.charsize));
    if (table_start > f.data.len) c.plainDie("input file: bad length", .{});
    const tail = f.data[table_start..];
    if (f.table == null and tail.len != 0) c.plainDie("input file: bad length", .{});
    f.data = f.data[0..table_start];
    f.table = tail;
    return f;
}

fn doLoad(fd: linux.fd_t, buffer: []const u8) void {
    const f = parseFont(buffer);
    doLoadFont(fd, f);
    if (f.table) |tail| doLoadTable(fd, tail, f.fontsize, f.psf2);
}

// ---------------------------------------------------------------- loadfont

pub fn loadfontMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("loadfont");
    const av = c.argsFrom(std.heap.page_allocator, argv, argc) catch &.{};
    const o = c.opts("loadfont", av, "^", &.{});
    if (o.args.len != 0) c.usageDie("loadfont");
    const buffer = c.readStdin(std.heap.page_allocator) catch
        c.plainDie("error reading input font", .{});
    const fd = c.consoleFdOrDie();
    doLoad(fd, buffer);
    return 0;
}

// ----------------------------------------------------------------- setfont

fn charToInt(s0: []const u8) i64 {
    const s = s0;
    if (s.len == 3 and s[0] == '\'' and s[2] == '\'') return s[1];
    if (s.len >= 2 and s[0] == 'U' and s[1] == '+') {
        var copy: [64]u8 = undefined;
        if (s.len > copy.len) return -1;
        @memcpy(copy[0..s.len], s);
        copy[0] = '0';
        copy[1] = 'x';
        return std.fmt.parseInt(i64, copy[0..s.len], 0) catch -1;
    }
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return -1;
    return std.fmt.parseInt(i64, s, 0) catch -1;
}

/// Pure textual-map parser for unit tests: fills `unicodes` and reports
/// whether a Unicode screen map is required.
pub fn parseTextualMap(text: []const u8, unicodes: []u16) !bool {
    for (unicodes, 0..) |*slot, i| slot.* = @intCast(0xf000 + i);
    var unicode_mode = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.indexOfScalar(u8, raw_line, '#')) |p| raw_line[0..p] else raw_line;
        var toks = std.mem.tokenizeAny(u8, line, " \t\r");
        const t0 = toks.next() orelse continue;
        const t1 = toks.next() orelse return error.MapFormat;
        const a = charToInt(t0);
        const b = charToInt(t1);
        if (a < 0 or a >= E_TABSZ or b < 0 or b > 65535) return error.MapFormat;
        unicodes[@intCast(a)] = @intCast(b);
        if (b > 255) unicode_mode = true;
    }
    return unicode_mode;
}

fn optionArg(av: []const []const u8, ch: u8) ?[]const u8 {
    for (av, 0..) |a, i| {
        if (a.len >= 2 and a[0] == '-' and a[1] == ch) {
            if (a.len > 2) return a[2..];
            if (i + 1 < av.len) return av[i + 1];
        }
    }
    return null;
}

pub fn setfontMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("setfont");
    const av = c.argsFrom(std.heap.page_allocator, argv, argc) catch &.{};
    const o = c.opts("setfont", av, "^m:C:", &.{});
    if (o.args.len != 1) c.usageDie("setfont");
    const tty_name = optionArg(av, 'C') orelse "/dev/tty";
    const fd = c.openReadNonblock(tty_name);

    const font_path = o.args[0];
    var ferr: c_int = 0;
    const font = c.readFile(std.heap.page_allocator, font_path, &ferr) orelse
        c.errorMsgAndDie(ferr, "{s}", .{font_path});
    doLoad(fd, font);

    if ((o.flags & 1) != 0) {
        const map_path = optionArg(av, 'm') orelse c.usageDie("setfont");
        var merr: c_int = 0;
        const map = c.readFile(std.heap.page_allocator, map_path, &merr) orelse
            c.errorMsgAndDie(merr, "{s}", .{map_path});
        var mode: u32 = PIO_SCRNMAP;
        var data: []const u8 = map;
        if (map.len == E_TABSZ or map.len == 2 * E_TABSZ) {
            if (map.len == 2 * E_TABSZ) mode = PIO_UNISCRNMAP;
        } else {
            var unicodes: [E_TABSZ]u16 = undefined;
            const unicode_mode = parseTextualMap(@as([]const u8, map), &unicodes) catch
                c.plainDie("map format", .{});
            if (unicode_mode) mode = PIO_UNISCRNMAP;
            if (mode != PIO_UNISCRNMAP) {
                var ascii: [E_TABSZ]u8 = undefined;
                for (unicodes, 0..) |u, i| ascii[i] = @truncate(u);
                data = std.heap.page_allocator.dupe(u8, &ascii) catch c.errorMsgAndDie(12, "out of memory", .{});
            } else {
                var words = std.heap.page_allocator.alloc(u8, E_TABSZ * 2) catch c.errorMsgAndDie(12, "out of memory", .{});
                for (unicodes, 0..) |u, i| std.mem.writeInt(u16, words[i * 2 ..][0..2], u, .little);
                data = words;
            }
        }
        c.xioctl(fd, mode, @intFromPtr(data.ptr), switch (mode) {
            PIO_UNISCRNMAP => "PIO_UNISCRNMAP",
            else => "PIO_SCRNMAP",
        });
    }
    _ = linux.close(fd);
    return 0;
}
