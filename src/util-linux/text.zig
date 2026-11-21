//! Text-formatting util-linux applets: cal, rev, xxd, hd, hexdump, more, getopt.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

// ---------------------------------------------------------------- cal -----

const month_names = [_][]const u8{
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
};
const day_names = [_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };
const days_in_month = [_]u32{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

const SPACE: i64 = -1;

fn leapYear(y: u32) bool {
    if (y <= 1752) return y % 4 == 0;
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

fn leapYearsSinceYear1(y: u32) u32 {
    const cent: u32 = if (y > 1700) y / 100 - 17 else 0;
    const quad: u32 = if (y > 1600) (y - 1600) / 400 else 0;
    return y / 4 - cent + quad;
}

fn dayArray(month: u32, year: u32, weekstart: u32, julian: bool, days: *[42]i64) void {
    @memset(days, SPACE);
    if (month == 9 and year == 1752) {
        const sep = [_]u32{ 1, 2, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30 };
        const off: i64 = if (julian) 244 else 0;
        for (sep, 0..) |d, i| {
            const idx: usize = @intCast(i + 2 - @as(usize, weekstart));
            if (idx < days.len) days[idx] = @as(i64, d) + off;
        }
        return;
    }
    var day: u32 = 1;
    if (month > 2 and leapYear(year)) day += 1;
    var i = month;
    while (i != 0) {
        i -= 1;
        day += days_in_month[i];
    }
    const temp: i64 = @as(i64, year - 1) * 365 + @as(i64, leapYearsSinceYear1(year - 1)) + @as(i64, day);
    var dw: i64 = if (temp < 639787) @mod(temp - 1 + 6, 7) else @mod(temp - 1 + 6 - 11, 7);
    dw = @mod(dw - @as(i64, weekstart) + 7, 7);
    if (!julian) day = 1;
    var dm: i64 = @intCast(days_in_month[month]);
    if (month == 2 and leapYear(year)) dm += 1;
    var k: i64 = 0;
    while (k < dm) : (k += 1) {
        if (dw >= 0 and dw < 42) days[@intCast(dw)] = @as(i64, day);
        dw += 1;
        day += 1;
    }
}

fn trimAndPrint(s: []u8) void {
    var end = s.len;
    while (end > 0 and std.ascii.isWhitespace(s[end - 1])) end -= 1;
    if (end == 0) end = s.len;
    c.out(s[0..end]);
    c.out("\n");
}

/// build_row: 21 chars per week (normal) or 28 (julian), starting at p[0].
fn buildRow(p: []u8, dp: []const i64, julian: bool) void {
    const width: usize = if (julian) 28 else 21;
    @memset(p[0..width], ' ');
    var pos: usize = 0;
    for (dp[0..7]) |d| {
        if (d != SPACE) {
            var day: u32 = @intCast(d);
            if (julian) {
                pos += 1;
                if (day >= 100) {
                    p[pos] = '0';
                    p[pos - 1] = @as(u8, @intCast(day / 100)) + '0';
                    day %= 100;
                }
            }
            const tens = day / 10;
            if (tens > 0) p[pos] = @as(u8, @intCast(tens)) + '0';
            pos += 1;
            p[pos] = @as(u8, @intCast(day % 10)) + '0';
            pos += 2;
        } else {
            pos += if (julian) 4 else 3;
        }
    }
}

fn center(buf: []u8, len: usize, separate: usize) void {
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    var tmp: [128]u8 = undefined;
    @memcpy(tmp[0..n], buf[0..n]);
    const l = len -| n;
    var idx: usize = 0;
    const lead = l / 2;
    var j: usize = 0;
    while (j < lead and idx < buf.len) : (j += 1) { buf[idx] = ' '; idx += 1; }
    @memcpy(buf[idx .. idx + n], tmp[0..n]);
    idx += n;
    const tail = (l / 2) + (l % 2) + separate;
    j = 0;
    while (j < tail and idx < buf.len) : (j += 1) { buf[idx] = ' '; idx += 1; }
    if (idx < buf.len) buf[idx] = 0;
}

var heading_buf: [64]u8 = undefined;
fn dayHeadings(julian: bool, weekstart: usize) []const u8 {
    if (!julian) {
        var pos: usize = 0;
        for (0..7) |i| {
            const d = day_names[(i + weekstart) % 7];
            @memcpy(heading_buf[pos .. pos + 2], d);
            pos += 2;
            if (i != 6) { heading_buf[pos] = ' '; pos += 1; }
        }
        return heading_buf[0..pos];
    }
    var pos: usize = 0;
    for (0..7) |i| {
        heading_buf[pos] = ' '; pos += 1;
        const d = day_names[(i + weekstart) % 7];
        @memcpy(heading_buf[pos .. pos + 2], d);
        pos += 2;
        if (i != 6) { heading_buf[pos] = ' '; pos += 1; }
    }
    return heading_buf[0..pos];
}

fn currentYearMonth() struct { year: u32, month: u32 } {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const secs: i64 = ts.sec;
    // days since 1970-01-01 (UTC; harness sets TZ=UTC)
    const z = @divFloor(secs, 86400);
    // civil_from_days (Howard Hinnant)
    const zz = z + 719468;
    const era = @divFloor(if (zz >= 0) zz else zz - 146096, 146097);
    const doe = zz - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else -9);
    y += if (m <= 2) 1 else 0;
    _ = d;
    return .{ .year = @intCast(y), .month = @intCast(m) };
}

pub fn cal_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("cal", args, "jmy", &.{});
    const julian = c.flagged(o, 0);
    const monday = c.flagged(o, 1);
    const yearflag = c.flagged(o, 2);
    const pos = o.args;
    const weekstart: u32 = if (monday) 1 else 0;

    var month: u32 = 0;
    var year: u32 = 0;
    if (pos.len == 0) {
        const now = currentYearMonth();
        year = now.year;
        if (!yearflag) month = now.month;
    } else {
        if (pos.len > 2) c.usageDie("cal");
        if (pos.len == 2) {
            if (!yearflag) {
                month = std.fmt.parseInt(u32, pos[0], 10) catch {
                    c.plain("invalid number '{s}'", .{pos[0]});
                    return 1;
                };
                if (month < 1 or month > 12) {
                    c.plain("number {d} is not in 1..12 range", .{month});
                    return 1;
                }
            }
            year = std.fmt.parseInt(u32, pos[1], 10) catch {
                c.plain("invalid number '{s}'", .{pos[1]});
                return 1;
            };
        } else {
            year = std.fmt.parseInt(u32, pos[0], 10) catch {
                c.plain("invalid number '{s}'", .{pos[0]});
                return 1;
            };
        }
        if (year < 1 or year > 9999) {
            c.plain("number {d} is not in 1..9999 range", .{year});
            return 1;
        }
    }
    if (year == 0) {
        const now = currentYearMonth();
        year = now.year;
    }

    if (month != 0) {
        var days: [42]i64 = undefined;
        dayArray(month, year, weekstart, julian, &days);
        var title: [40]u8 = undefined;
        const tl = std.fmt.bufPrint(&title, "{s} {d}", .{ month_names[month - 1], year }) catch return 1;
        const width: usize = if (julian) 27 else 20;
        const lead = (width -| tl.len) / 2;
        var i: usize = 0;
        while (i < lead) : (i += 1) c.out(" ");
        c.out(tl);
        c.out("\n");
        c.out(dayHeadings(julian, weekstart));
        c.out("\n");
        var row: usize = 0;
        while (row < 6) : (row += 1) {
            var line: [40]u8 = undefined;
            buildRow(&line, days[row * 7 ..][0..7], julian);
            trimAndPrint(line[0 .. if (julian) 28 else 21]);
        }
    } else {
        var title: [80]u8 = undefined;
        @memset(&title, 0);
        const yl = std.fmt.bufPrint(&title, "{d}", .{year}) catch return 1;
        _ = yl;
        center(&title, 64, 0);
        c.out(std.mem.sliceTo(&title, 0));
        c.out("\n\n");
        var all: [12][42]i64 = undefined;
        for (0..12) |i| dayArray(@intCast(i + 1), year, weekstart, julian, &all[i]);
        var line: [80]u8 = undefined;
        @memset(&line, ' ');
        const week_len: usize = if (julian) 27 else 20;
        const step: usize = if (julian) 1 else 3;
        var mi: usize = 0;
        while (mi < 12) : (mi += step) {
            var mname: [80]u8 = undefined;
            @memset(&mname, 0);
            @memcpy(mname[0..month_names[mi].len], month_names[mi]);
            center(&mname, week_len, 2);
            c.out(std.mem.span(@as([*:0]const u8, @ptrCast(&mname))));
            if (!julian) {
                var m2: [80]u8 = undefined;
                @memset(&m2, 0);
                @memcpy(m2[0..month_names[mi + 1].len], month_names[mi + 1]);
                center(&m2, week_len, 2);
                c.out(std.mem.span(@as([*:0]const u8, @ptrCast(&m2))));
            }
            var m3: [80]u8 = undefined;
            @memset(&m3, 0);
            const last = if (julian) mi + 1 else mi + 2;
            @memcpy(m3[0..month_names[last].len], month_names[last]);
            center(&m3, week_len, 0);
            c.out(std.mem.span(@as([*:0]const u8, @ptrCast(&m3))));
            c.out("\n");
            c.out(dayHeadings(julian, weekstart));
            c.out("  ");
            c.out(dayHeadings(julian, weekstart));
            if (!julian) {
                c.out("  ");
                c.out(dayHeadings(julian, weekstart));
            }
            c.out("\n");
            var row: usize = 0;
            while (row < 42) : (row += 7) {
                const ncal: usize = if (julian) 2 else 3;
                for (0..ncal) |which| {
                    buildRow(line[which * (week_len + 2) ..][0..(if (julian) 28 else 21)], all[mi + which][row..][0..7], julian);
                }
                trimAndPrint(line[0..79]);
            }
        }
    }
    return 0;
}

// ---------------------------------------------------------------- rev -----

pub fn rev_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = c.opts("rev", args, "", &.{});
    var paths = args[c.opts("rev", args, "", &.{ }).index..];
    if (paths.len == 0) paths = &.{"-"};
    var ret: c_int = 0;
    for (paths) |path| {
        const data = c.readInput(path) catch {
            ret = 1;
            continue;
        };
        var start: usize = 0;
        while (start < data.len) {
            var end = start;
            while (end < data.len and data[end] != '\n') end += 1;
            var seg_end = end;
            if (seg_end > start and data[seg_end - 1] == '\r') seg_end -= 1;
            var i = start;
            var j = seg_end;
            while (i < j) {
                j -= 1;
                const t = data[i];
                data[i] = data[j];
                data[j] = t;
                i += 1;
            }
            c.out(data[start..end]);
            if (end < data.len) c.out("\n");
            start = if (end < data.len) end + 1 else end;
        }
    }
    return ret;
}

// --------------------------------------------------------------- xxd -------

fn isPrint(ch: u8) bool {
    return ch >= 0x20 and ch < 0x7f;
}

fn hexLower(b: u8) [2]u8 {
    const d = "0123456789abcdef";
    return .{ d[b >> 4], d[b & 0xf] };
}

fn emitHex(buf: []u8, pos: *usize, b: u8) void {
    const h = hexLower(b);
    buf[pos.*] = h[0]; pos.* += 1;
    buf[pos.*] = h[1]; pos.* += 1;
}

fn parseNum(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var base: u8 = 10;
    var body = s;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        base = 16; body = s[2..];
    }
    return std.fmt.parseInt(usize, body, base) catch null;
}

fn val(s: []const u8, name: []const u8) usize {
    return parseNum(s) orelse {
        c.plain("invalid number '{s}'", .{s});
        _ = name;
        return 0;
    };
}

pub fn xxd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    var group: usize = 2;
    var per_line: usize = 16;
    var plain = false;
    var inc_style = false;
    var reverse = false;
    var len: ?usize = null;
    var skip: usize = 0;
    var add_off: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-' or std.mem.eql(u8, a, "-")) break;
        if (std.mem.eql(u8, a, "-ps")) { plain = true; per_line = 30; continue; }
        if (std.mem.eql(u8, a, "-i")) { inc_style = true; per_line = 12; continue; }
        if (std.mem.eql(u8, a, "-r")) { reverse = true; continue; }
        if (std.mem.startsWith(u8, a, "-g") and a.len > 2) { group = val(a[2..], "xxd"); continue; }
        if (std.mem.eql(u8, a, "-g")) {
            i += 1; if (i >= args.len) c.usageDie("xxd");
            group = val(args[i], "xxd"); continue;
        }
        if (std.mem.startsWith(u8, a, "-c") and a.len > 2) { per_line = val(a[2..], "xxd"); continue; }
        if (std.mem.eql(u8, a, "-c")) {
            i += 1; if (i >= args.len) c.usageDie("xxd");
            per_line = val(args[i], "xxd"); continue;
        }
        if (std.mem.startsWith(u8, a, "-l") and a.len > 2) { len = val(a[2..], "xxd"); continue; }
        if (std.mem.eql(u8, a, "-l")) {
            i += 1; if (i >= args.len) c.usageDie("xxd");
            len = val(args[i], "xxd"); continue;
        }
        if (std.mem.startsWith(u8, a, "-s") and a.len > 2) { skip = val(a[2..], "xxd"); continue; }
        if (std.mem.eql(u8, a, "-s")) {
            i += 1; if (i >= args.len) c.usageDie("xxd");
            skip = val(args[i], "xxd"); continue;
        }
        if (std.mem.startsWith(u8, a, "-o") and a.len > 2) { add_off = val(a[2..], "xxd"); continue; }
        if (std.mem.eql(u8, a, "-o")) {
            i += 1; if (i >= args.len) c.usageDie("xxd");
            add_off = val(args[i], "xxd"); continue;
        }
        c.plain("invalid option -- '{c}'", .{a[1]});
        c.usageDie("xxd");
    }
    if (i >= args.len or std.mem.eql(u8, args[i], "-")) {
        if (reverse) {
            const text = c.readStdin();
            var outb: std.ArrayList(u8) = .empty;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |ln| {
                if (std.mem.indexOfScalar(u8, ln, ':')) |colon| {
                    var toks = std.mem.tokenizeAny(u8, ln[colon + 1 ..], " \t");
                    while (toks.next()) |tok| {
                        if (tok.len == 0 or tok.len % 2 != 0) break;
                        var allhex = true;
                        for (tok) |ch| if (!std.ascii.isHex(ch)) { allhex = false; break; };
                        if (!allhex) break;
                        var k: usize = 0;
                        while (k < tok.len) : (k += 2) {
                            const b = std.fmt.parseInt(u8, tok[k .. k + 2], 16) catch break;
                            outb.append(c.A, b) catch {};
                        }
                    }
                }
            }
            c.out(outb.items);
            return 0;
        }
        var data = c.readStdin();
        if (skip > 0) {
            if (skip >= data.len) data = &.{} else data = data[skip..];
        }
        if (len) |l| {
            if (l < data.len) data = data[0..l];
        }
        if (plain) {
            for (data) |b| { const h = hexLower(b); c.out(&h); }
            c.out("\n");
        } else if (inc_style) {
            c.out("  ");
            for (data, 0..) |b, k| {
                if (k != 0) c.out(" ");
                c.put("0x{x:0>2},", .{b});
            }
            c.out("\n");
        } else {
            var off: usize = 0;
            while (off < data.len) : (off += per_line) {
                var line: [600]u8 = undefined;
                var pos: usize = 0;
                var obuf: [16]u8 = undefined;
                const offs = std.fmt.bufPrint(&obuf, "{x:0>8}", .{add_off + off}) catch break;
                @memcpy(line[pos .. pos + offs.len], offs); pos += offs.len;
                line[pos] = ':'; pos += 1;
                line[pos] = ' '; pos += 1;
                const hexstart = pos;
                const n = @min(per_line, data.len - off);
                var gi: usize = 0;
                while (gi < n) : (gi += group) {
                    const lim = @min(gi + group, n);
                    var kk = gi;
                    while (kk < lim) : (kk += 1) emitHex(&line, &pos, data[off + kk]);
                    if (lim < n) { line[pos] = ' '; pos += 1; }
                }
                const field: usize = 2 * per_line + per_line / group + 1;
                var pad = field -| (pos - hexstart);
                while (pad > 0) : (pad -= 1) { line[pos] = ' '; pos += 1; }
                c.out(line[0..pos]);
                for (data[off .. off + n]) |b| c.out(&[_]u8{if (isPrint(b)) b else '.'});
                c.out("\n");
            }
        }
        return 0;
    }
    c.plain("can't open '{s}': No such file or directory", .{args[i]});
    return 1;
}

// -------------------------------------------------------- hexdump / hd -----

fn emitCanonical(data: []const u8) void {
    if (data.len == 0) return;
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        var line: [600]u8 = undefined;
        var pos: usize = 0;
        var obuf: [16]u8 = undefined;
        const offs = std.fmt.bufPrint(&obuf, "{x:0>8}", .{off}) catch break;
        @memcpy(line[pos .. pos + offs.len], offs); pos += offs.len;
        line[pos] = ' '; pos += 1;
        const n = @min(16, data.len - off);
        for (0..16) |k| {
            if (k == 8) { line[pos] = ' '; pos += 1; }
            line[pos] = ' '; pos += 1;
            if (k < n) {
                const h = hexLower(data[off + k]);
                line[pos] = h[0]; pos += 1;
                line[pos] = h[1]; pos += 1;
            } else {
                line[pos] = ' '; pos += 1;
                line[pos] = ' '; pos += 1;
            }
        }
        while (pos < 58) : (pos += 1) line[pos] = ' ';
        line[pos] = ' '; pos += 1;
        line[pos] = ' '; pos += 1;
        line[pos] = '|'; pos += 1;
        for (data[off .. off + n]) |b| {
            line[pos] = if (isPrint(b)) b else '.';
            pos += 1;
        }
        line[pos] = '|'; pos += 1;
        c.out(line[0..pos]);
        c.out("\n");
    }
    const fin = std.fmt.bufPrint(&line_final, "{x:0>8}", .{data.len}) catch return;
    c.out(fin); c.out("\n");
}
var line_final: [32]u8 = undefined;

fn emitDefault(data: []const u8) void {
    if (data.len == 0) return;
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        var line: [200]u8 = undefined;
        var pos: usize = 0;
        var obuf: [16]u8 = undefined;
        const offs = std.fmt.bufPrint(&obuf, "{x:0>7}", .{off}) catch break;
        @memcpy(line[pos .. pos + offs.len], offs); pos += offs.len;
        line[pos] = ' '; pos += 1;
        const n = @min(16, data.len - off);
        var wi: usize = 0;
        while (wi < 8) : (wi += 1) {
            if (off + wi * 2 < data.len) {
                const b0 = data[off + wi * 2];
                const b1 = if (off + wi * 2 + 1 < data.len) data[off + wi * 2 + 1] else 0;
                const word: u16 = @as(u16, b0) | (@as(u16, b1) << 8);
                _ = std.fmt.bufPrint(line[pos..][0..4], "{x:0>4}", .{word}) catch break;
            } else {
                @memset(line[pos .. pos + 4], ' ');
            }
            pos += 4;
            if (wi != 7) { line[pos] = ' '; pos += 1; }
        }
        while (pos < 47) : (pos += 1) line[pos] = ' ';
        c.out(line[0..47]); c.out("\n");
        _ = n;
    }
    const fin = std.fmt.bufPrint(&line_final, "{x:0>7}", .{data.len}) catch return;
    c.out(fin); c.out("\n");
}

fn emitOctal(data: []const u8) void {
    if (data.len == 0) return;
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        var line: [200]u8 = undefined;
        var pos: usize = 0;
        var obuf: [16]u8 = undefined;
        const offs = std.fmt.bufPrint(&obuf, "{x:0>7}", .{off}) catch break;
        @memcpy(line[pos .. pos + offs.len], offs); pos += offs.len;
        line[pos] = ' '; pos += 1;
        for (0..16) |k| {
            if (off + k < data.len) {
                _ = std.fmt.bufPrint(line[pos..][0..3], "{o:0>3}", .{data[off + k]}) catch break;
                pos += 3;
            } else { @memset(line[pos .. pos + 3], ' '); pos += 3; }
            if (k != 15) { line[pos] = ' '; pos += 1; }
        }
        c.out(line[0..71]); c.out("\n");
    }
    const fin = std.fmt.bufPrint(&line_final, "{x:0>7}", .{data.len}) catch return;
    c.out(fin); c.out("\n");
}

fn emitChar(data: []const u8) void {
    if (data.len == 0) return;
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        var line: [200]u8 = undefined;
        @memset(&line, ' ');
        var pos: usize = 0;
        var obuf: [16]u8 = undefined;
        const offs = std.fmt.bufPrint(&obuf, "{x:0>7}", .{off}) catch break;
        @memcpy(line[pos .. pos + offs.len], offs); pos += offs.len;
        pos = 10;
        for (0..16) |k| {
            if (off + k < data.len and isPrint(data[off + k])) line[pos] = data[off + k];
            pos += 4;
        }
        c.out(line[0..71]); c.out("\n");
    }
    const fin = std.fmt.bufPrint(&line_final, "{x:0>7}", .{data.len}) catch return;
    c.out(fin); c.out("\n");
}

fn emitHexWords(data: []const u8, width: usize, lead: usize) void {
    if (data.len == 0) return;
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        var line: [200]u8 = undefined;
        @memset(&line, ' ');
        var pos: usize = 0;
        var obuf: [16]u8 = undefined;
        const offs = std.fmt.bufPrint(&obuf, "{x:0>7}", .{off}) catch break;
        @memcpy(line[pos .. pos + offs.len], offs); pos += offs.len;
        line[pos] = ' '; pos += 1;
        pos += lead;
        var wi: usize = 0;
        while (wi < 8) : (wi += 1) {
            if (off + wi * 2 < data.len) {
                const b0 = data[off + wi * 2];
                const b1 = if (off + wi * 2 + 1 < data.len) data[off + wi * 2 + 1] else 0;
                const word: u16 = @as(u16, b0) | (@as(u16, b1) << 8);
                _ = std.fmt.bufPrint(line[pos..][0..4], "{x:0>4}", .{word}) catch break;
            } else {
                @memset(line[pos .. pos + 4], ' ');
            }
            pos += 4;
            pos += width - 4;
        }
        c.out(line[0..71]); c.out("\n");
    }
    const fin = std.fmt.bufPrint(&line_final, "{x:0>7}", .{data.len}) catch return;
    c.out(fin); c.out("\n");
}

pub fn hexdump_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    if (std.mem.eql(u8, name, "hd")) {
        for (args[1..]) |a| {
            if (a.len > 1 and a[0] == '-') {
                c.plain("invalid option -- '{c}'", .{a[1]});
                c.usageDie("hd");
            }
        }
        const paths = args[1..];
        if (paths.len == 0) emitCanonical(c.readStdin()) else {
            for (paths) |p| {
                const d = c.readFile(p) catch {
                    c.msg(2, "can't open '{s}'", .{p});
                    return 1;
                };
                emitCanonical(d);
            }
        }
        return 0;
    }
    var canonical = false;
    var oct = false;
    var chars = false;
    var hexw = false;
    var i: usize = 1;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-C")) { canonical = true; continue; }
        if (std.mem.eql(u8, a, "-b")) { oct = true; continue; }
        if (std.mem.eql(u8, a, "-c")) { chars = true; continue; }
        if (std.mem.eql(u8, a, "-x")) { hexw = true; continue; }
        if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "-o")) continue;
        if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "-f")) {
            i += 1; if (i >= args.len) c.usageDie("hexdump"); continue;
        }
        c.plain("invalid option -- '{c}'", .{a[1]});
        c.usageDie("hexdump");
    }
    const paths = args[i..];
    var data: []u8 = undefined;
    if (paths.len == 0) {
        data = c.readStdin();
    } else {
        data = c.readFile(paths[0]) catch {
            c.msg(2, "can't open '{s}'", .{paths[0]});
            return 1;
        };
    }
    if (canonical) emitCanonical(data) else if (oct) emitOctal(data) else if (chars) emitChar(data) else if (hexw) emitHexWords(data, 8, 3) else emitDefault(data);
    return 0;
}

pub fn hd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return hexdump_main(argc, argv);
}

// ---------------------------------------------------------------- more -----

pub fn more_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("more", args, "", &.{});
    var paths = args[o.index..];
    if (paths.len == 0) paths = &.{"-"};
    var ret: c_int = 0;
    for (paths) |p| {
        const d = c.readInput(p) catch {
            c.msg(2, "can't open '{s}'", .{p});
            ret = 1;
            continue;
        };
        c.out(d);
    }
    return ret;
}

// --------------------------------------------------------------- getopt ----

fn normQuote(arg: []const u8, quote: bool, buf: []u8) []const u8 {
    if (!quote) return arg;
    var pos: usize = 0;
    buf[pos] = '\''; pos += 1;
    for (arg) |ch| {
        if (ch == '\'') {
            const seq = "'\\''";
            @memcpy(buf[pos .. pos + 4], seq); pos += 4;
        } else {
            buf[pos] = ch; pos += 1;
        }
    }
    buf[pos] = '\''; pos += 1;
    return buf[0..pos];
}

pub fn getopt_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len < 2) {
        c.plain("missing optstring argument", .{});
        return 1;
    }
    // Compat form: argv[1] does not start with '-'
    var quiet_errors = false;
    var quiet_output = false;
    var quote = true;
    var test_only = false;
    var optstr: ?[]const u8 = null;
    var own_i: usize = 1;
    var compat = false;
    if (args[1].len == 0 or args[1][0] != '-') {
        compat = true;
        quote = false;
    }
    if (!compat) {
        while (own_i < args.len) : (own_i += 1) {
            const a = args[own_i];
            if (std.mem.eql(u8, a, "--")) { own_i += 1; break; }
            if (a.len < 2 or a[0] != '-') break;
            if (std.mem.eql(u8, a, "-o")) {
                own_i += 1; if (own_i >= args.len) c.usageDie("getopt");
                optstr = args[own_i];
            } else if (std.mem.eql(u8, a, "-n")) {
                own_i += 1; if (own_i >= args.len) c.usageDie("getopt");
            } else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "-s")) {
                own_i += 1; if (own_i >= args.len) c.usageDie("getopt");
            } else if (std.mem.eql(u8, a, "-q")) quiet_errors = true
            else if (std.mem.eql(u8, a, "-Q")) quiet_output = true
            else if (std.mem.eql(u8, a, "-u")) quote = false
            else if (std.mem.eql(u8, a, "-a")) {}
            else if (std.mem.eql(u8, a, "-T")) test_only = true
            else {
                c.plain("invalid option -- '{c}'", .{a[1]});
                c.usageDie("getopt");
            }
        }
    }
    if (test_only) return 4;
    var start: usize = if (compat) 1 else own_i;
    if (optstr == null) {
        if (start >= args.len) {
            c.plain("missing optstring argument", .{});
            return 1;
        }
        optstr = args[start];
        start += 1;
    } else if (!compat) {
        // with -o, getopt32 consumes it; start points after own options
    }
    const os = optstr.?;
    const params = args[start..];

    var ret: c_int = 0;
    var idx: usize = 0;
    var nonopts: [64][]const u8 = undefined;
    var nnon: usize = 0;
    var qbuf: [4096]u8 = undefined;
    while (idx < params.len) : (idx += 1) {
        const tok = params[idx];
        if (std.mem.eql(u8, tok, "--")) { idx += 1; break; }
        if (tok.len >= 2 and tok[0] == '-') {
            var k: usize = 1;
            while (k < tok.len) : (k += 1) {
                const ch = tok[k];
                if (std.mem.indexOfScalar(u8, os, ch) == null) {
                    ret = 1;
                    if (!quiet_errors) c.plain("invalid option -- '{c}'", .{ch});
                    continue;
                }
                if (!quiet_output) {
                    var ob: [64]u8 = undefined;
                    const s = std.fmt.bufPrint(&ob, " -{c}", .{ch}) catch "";
                    c.out(s);
                }
                const oi = std.mem.indexOfScalar(u8, os, ch).?;
                if (oi + 1 < os.len and os[oi + 1] == ':') {
                    var av: []const u8 = "";
                    if (k + 1 < tok.len) { av = tok[k + 1 ..]; k = tok.len; }
                    else if (idx + 1 < params.len) { idx += 1; av = params[idx]; }
                    if (!quiet_output) {
                        c.out(" ");
                        c.out(normQuote(av, quote, &qbuf));
                    }
                }
            }
        } else {
            if (os.len > 0 and os[0] == '-') {
                if (!quiet_output) { c.out(" "); c.out(normQuote(tok, quote, &qbuf)); }
            } else if (nnon < nonopts.len) { nonopts[nnon] = tok; nnon += 1; }
        }
    }
    if (!quiet_output) {
        c.out(" --");
        for (nonopts[0..nnon]) |no| {
            c.out(" ");
            c.out(normQuote(no, quote, &qbuf));
        }
        while (idx < params.len) : (idx += 1) {
            c.out(" ");
            c.out(normQuote(params[idx], quote, &qbuf));
        }
        c.out("\n");
    }
    return ret;
}
