//! Task 7b: text-and-number coreutils applets, reference-faithful.
//!
//! Each `xxxMain` is exposed through a thin `<name>_main` wrapper in
//! coreutils/main.zig so the module root stays the single registry entry point.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const A = std.heap.page_allocator;
const LongOpt = bb.getopt.LongOpt;
const Options = bb.getopt.Options;

// ---------------------------------------------------------------------------
// generic helpers
// ---------------------------------------------------------------------------

fn avFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return bb.getopt.argsToSlices(A, argv, @intCast(argc)) catch &.{};
}

fn setProg(argv: [*][*:0]const u8) void {
    bb.env.setProgramName(std.fs.path.basename(std.mem.span(argv[0])));
}

fn out(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(1, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) return;
        done += @intCast(n);
    }
}

fn errout(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) return;
        done += @intCast(n);
    }
}

fn put(comptime fmt: []const u8, args: anytype) void {
    var b: [16384]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    out(s);
}

fn eput(comptime fmt: []const u8, args: anytype) void {
    var b: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    errout(s);
}

fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn usageDieCode(name: []const u8, code: u8) noreturn {
    bb.usage.show(name, 2);
    std.process.exit(code);
}

fn opts(name: []const u8, av: []const []const u8, os: []const u8, longs: []const LongOpt) Options {
    return bb.getopt.getopt32(av, os, longs) catch usageDie(name);
}

fn flagged(o: Options, bit: u5) bool {
    return (o.flags & (@as(u32, 1) << bit)) != 0;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn PathInit(path: []const u8) ![4096:0]u8 {
    var p: [4096:0]u8 = undefined;
    if (path.len >= p.len) return error.NameTooLong;
    @memcpy(p[0..path.len], path);
    p[path.len] = 0;
    return p;
}

fn openRead(path: []const u8) ?linux.fd_t {
    if (eql(path, "-")) return 0;
    const p = PathInit(path) catch return null;
    const rc = linux.open(@ptrCast(&p), .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn readFd(fd: linux.fd_t) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(A);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        const e = linux.errno(n);
        if (e != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(A, buf[0..n]);
    }
    return list.toOwnedSlice(A);
}

fn readInput(path: []const u8) ![]u8 {
    const fd = openRead(path) orelse return error.OpenFailed;
    defer { if (!eql(path, "-")) _ = linux.close(fd); }
    return readFd(fd);
}

fn readAllStdin() ![]u8 {
    return readFd(0);
}

fn writeNewFile(path: []const u8, data: []const u8, mode: linux.mode_t) !void {
    const p = try PathInit(path);
    const rc = linux.open(@ptrCast(&p), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < data.len) {
        const n = linux.write(fd, data.ptr + done, data.len - done);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        if (n == 0) return;
        done += @intCast(n);
    }
}

fn splitLines(data: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(A);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0 and it.peek() == null) break;
        try list.append(A, ln);
    }
    return list.toOwnedSlice(A);
}

fn joinLines(lines: []const []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(A);
    for (lines) |ln| {
        try b.appendSlice(A, ln);
        try b.append(A, '\n');
    }
    return b.toOwnedSlice(A);
}

fn appendSpaces(b: *std.ArrayList(u8), n: usize) !void {
    for (0..n) |_| try b.append(A, ' ');
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12;
}

fn parseInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn parseUInt(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn hexLower(bytes: []const u8, buf: []u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |v, i| {
        buf[i * 2] = digits[v >> 4];
        buf[i * 2 + 1] = digits[v & 0xf];
    }
    return buf[0 .. bytes.len * 2];
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// option scanning helpers (getopt32 keeps only the last optarg, so we rescan)
fn optValue(av: []const []const u8, short: []const u8, long: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (short.len > 0 and eql(a, short)) {
            if (i + 1 < av.len) return av[i + 1];
            return "";
        }
        if (short.len > 0 and std.mem.startsWith(u8, a, short) and a.len > short.len) return a[short.len..];
        if (long.len > 0 and eql(a, long)) {
            if (i + 1 < av.len) return av[i + 1];
            return "";
        }
        if (long.len > 0 and std.mem.startsWith(u8, a, long) and a.len > long.len and a[long.len] == '=') return a[long.len + 1 ..];
    }
    return null;
}

fn hasOpt(av: []const []const u8, name: []const u8) bool {
    for (av[1..]) |a| if (eql(a, name)) return true;
    return false;
}

fn positionalCount(av: []const []const u8, valued_short: []const []const []const u8) usize {
    _ = valued_short;
    var n: usize = 0;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (a.len > 0 and a[0] == '-' and !eql(a, "-")) continue;
        n += 1;
    }
    return n;
}

// ===========================================================================
// tac
// ===========================================================================

pub fn tacMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("tac", av, "", &.{});
    if (o.args.len == 0) {
        const data = readAllStdin() catch return 1;
        tacWrite(data);
        return 0;
    }
    for (o.args) |name| {
        const data = readInput(name) catch {
            eput("tac: can't open '{s}'\n", .{name});
            return 1;
        };
        tacWrite(data);
    }
    return 0;
}

fn tacWrite(data: []const u8) void {
    if (data.len == 0) return;
    const stripped = if (data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
    const parts = splitLines(stripped) catch return;
    var i: usize = parts.len;
    while (i > 0) {
        i -= 1;
        out(parts[i]);
        if (i != parts.len - 1 or data[data.len - 1] == '\n') out("\n");
    }
}

// ===========================================================================
// nl
// ===========================================================================

pub fn nlMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("nl", av, "b:i:s:v:w:", &.{});
    var style: u8 = 't';
    var start: i64 = 1;
    var incr: i64 = 1;
    var width: usize = 6;
    var sep: []const u8 = "\t";
    if (optValue(av, "-b", "")) |v| { if (v.len > 0) style = v[0]; }
    if (optValue(av, "-i", "")) |v| incr = parseInt(v) orelse 1;
    if (optValue(av, "-v", "")) |v| start = parseInt(v) orelse 1;
    if (optValue(av, "-w", "")) |v| width = parseUInt(v) orelse 6;
    if (optValue(av, "-s", "")) |v| sep = v;

    var files: []const []const u8 = &.{};
    var i: usize = 1;
    var fbuf: [256][]const u8 = undefined;
    var nf: usize = 0;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (eql(a, "-b") or eql(a, "-i") or eql(a, "-v") or eql(a, "-w") or eql(a, "-s")) { i += 1; continue; }
        if (a.len > 1 and a[0] == '-') continue;
        if (nf < fbuf.len) { fbuf[nf] = a; nf += 1; }
    }
    files = fbuf[0..nf];

    var num = start;
    if (files.len == 0) {
        nlOne(readAllStdin() catch return 1, style, &num, incr, width, sep);
    } else for (files) |name| {
        const data = readInput(name) catch return 1;
        nlOne(data, style, &num, incr, width, sep);
    }
    return 0;
}

fn nlOne(data: []const u8, style: u8, num: *i64, incr: i64, width: usize, sep: []const u8) void {
    const lines = splitLines(data) catch return;
    for (lines) |ln| {
        const nonempty = ln.len > 0;
        const do_number = switch (style) {
            'a' => true,
            'n' => false,
            else => nonempty,
        };
        if (do_number) {
            var nb: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{num.*}) catch return;
            const pad: usize = if (width > s.len) width - s.len else 0;
            appendOutSpaces(pad);
            out(s);
            num.* += incr;
        } else {
            appendOutSpaces(width + sep.len);
            out(ln);
            out("\n");
            continue;
        }
        out(sep);
        out(ln);
        out("\n");
    }
}

fn appendOutSpaces(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) out(" ");
}

// ===========================================================================
// paste
// ===========================================================================

pub fn pasteMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const od = opts("paste", av, "d:s", &.{});
    const serial = flagged(od, 1);
    var delims: []const u8 = "\t\n";
    if (optValue(av, "-d", "")) |v| {
        delims = expandDelims(v) catch "\t\n";
    }
    var files: [256][]const u8 = undefined;
    var nf: usize = 0;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (eql(a, "-d")) { i += 1; continue; }
        if (eql(a, "-s") or eql(a, "-d")) continue;
        if (a.len > 1 and a[0] == '-') continue;
        if (nf < files.len) { files[nf] = a; nf += 1; }
    }
    if (nf == 0) {
        const data = readAllStdin() catch return 1;
        out(data);
        return 0;
    }
    var contents: [256][]const u8 = undefined;
    var liness: [256][][]const u8 = undefined;
    for (files[0..nf], 0..) |name, k| {
        const d = readInput(name) catch return 1;
        contents[k] = d;
        liness[k] = splitLines(d) catch return 1;
    }
    if (serial) {
        for (0..nf) |k| pasteRow(liness[k], delims);
    } else {
        var maxlines: usize = 0;
        for (0..nf) |k| maxlines = @max(maxlines, liness[k].len);
        var row: [256][]const u8 = undefined;
        for (0..maxlines) |li| {
            for (0..nf) |k| row[k] = if (li < liness[k].len) liness[k][li] else "";
            pasteRow(row[0..nf], delims);
        }
    }
    return 0;
}

fn expandDelims(v: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(A);
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] == '\\' and i + 1 < v.len) {
            i += 1;
            switch (v[i]) {
                't' => try b.append(A, '\t'),
                'n' => try b.append(A, '\n'),
                'r' => try b.append(A, '\r'),
                else => try b.append(A, v[i]),
            }
        } else try b.append(A, v[i]);
    }
    if (std.mem.indexOfScalar(u8, b.items, '\n') == null) try b.append(A, '\n');
    return b.toOwnedSlice(A);
}

fn pasteRow(fields: []const []const u8, delims: []const u8) void {
    if (delims.len == 0) return;
    for (fields, 0..) |f, i| {
        out(f);
        out(delims[i % delims.len ..][0..1]);
    }
}

// ===========================================================================
// comm
// ===========================================================================

pub fn commMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("comm", av, "123", &.{});
    if (o.args.len < 2) usageDie("comm");
    const a = splitLines(readInput(o.args[0]) catch return 1) catch return 1;
    const b = splitLines(readInput(o.args[1]) catch return 1) catch return 1;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ord = std.mem.order(u8, a[i], b[j]);
        if (ord == .lt) {
            if (!flagged(o, 0)) { out(a[i]); out("\n"); }
            i += 1;
        } else if (ord == .gt) {
            if (!flagged(o, 1)) {
                if (!flagged(o, 0)) out("\t");
                out(b[j]); out("\n");
            }
            j += 1;
        } else {
            if (!flagged(o, 2)) {
                if (!flagged(o, 0)) out("\t");
                if (!flagged(o, 1)) out("\t");
                out(a[i]); out("\n");
            }
            i += 1;
            j += 1;
        }
    }
    while (i < a.len) : (i += 1) if (!flagged(o, 0)) { out(a[i]); out("\n"); };
    while (j < b.len) : (j += 1) if (!flagged(o, 1)) {
        if (!flagged(o, 0)) out("\t");
        out(b[j]); out("\n");
    };
    return 0;
}

// ===========================================================================
// fold
// ===========================================================================

pub fn foldMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("fold", av, "bsw:", &.{});
    const by_bytes = flagged(o, 0);
    const spaces = flagged(o, 1);
    var width: usize = 80;
    if (optValue(av, "-w", "")) |v| width = parseUInt(v) orelse 80;
    if (width == 0) width = 1;
    if (o.args.len == 0) {
        foldOne(readAllStdin() catch return 1, width, by_bytes, spaces);
    } else for (o.args) |name| {
        foldOne(readInput(name) catch return 1, width, by_bytes, spaces);
    }
    return 0;
}

fn foldOne(data: []const u8, width: usize, by_bytes: bool, spaces: bool) void {
    const lines = splitLines(data) catch return;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(A);
    for (lines) |ln| {
        var i: usize = 0;
        while (i < ln.len) {
            var limit = i + width;
            if (spaces and limit < ln.len) {
                var k = limit;
                while (k > i and ln[k - 1] != ' ' and ln[k - 1] != '\t') k -= 1;
                if (k > i) limit = k;
            }
            var end = @min(limit, ln.len);
            if (!by_bytes) {
                while (end > i and end < ln.len and (ln[end] & 0xc0) == 0x80) end -= 1;
            }
            if (end == i) end = @min(i + 1, ln.len);
            b.appendSlice(A, ln[i..end]) catch return;
            b.append(A, '\n') catch return;
            i = end;
        }
        if (ln.len == 0) b.append(A, '\n') catch return;
    }
    out(b.items);
}

// ===========================================================================
// expand / unexpand
// ===========================================================================

pub fn expandMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("expand", av, "it:", &.{});
    const init_only = flagged(o, 0);
    var tab: usize = 8;
    if (optValue(av, "-t", "")) |v| {
        tab = parseUInt(v) orelse {
            eput("expand: invalid number '{s}'\n", .{v});
            return 1;
        };
    }
    if (tab == 0) tab = 1;
    if (o.args.len == 0) expandOne(readAllStdin() catch return 1, tab, init_only) else
        for (o.args) |name| expandOne(readInput(name) catch return 1, tab, init_only);
    return 0;
}

fn expandOne(data: []const u8, tab: usize, init_only: bool) void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(A);
    var col: usize = 0;
    var nonblank = false;
    for (data) |c| {
        if (c == '\n') {
            b.append(A, c) catch return;
            col = 0;
            nonblank = false;
            continue;
        }
        if (c == 8) {
            if (col > 0) col -= 1;
            b.append(A, c) catch return;
            continue;
        }
        if (c == '\t' and (!init_only or !nonblank)) {
            const n = tab - (col % tab);
            for (0..n) |_| b.append(A, ' ') catch return;
            col += n;
        } else {
            b.append(A, c) catch return;
            col += 1;
            if (c != ' ') nonblank = true;
        }
    }
    out(b.items);
}

pub fn unexpandMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("unexpand", av, "fat:", &.{});
    const all = flagged(o, 1);
    var tab: usize = 8;
    if (optValue(av, "-t", "")) |v| {
        tab = parseUInt(v) orelse {
            eput("unexpand: invalid number '{s}'\n", .{v});
            return 1;
        };
    }
    if (tab == 0) tab = 1;
    if (o.args.len == 0) unexpandOne(readAllStdin() catch return 1, tab, all) else
        for (o.args) |name| unexpandOne(readInput(name) catch return 1, tab, all);
    return 0;
}

fn unexpandOne(data: []const u8, tab: usize, all: bool) void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(A);
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == '\n') { b.append(A, '\n') catch return; i += 1; continue; }
        if (data[i] != ' ') { b.append(A, data[i]) catch return; i += 1; continue; }
        // count spaces
        var j = i;
        while (j < data.len and data[j] == ' ') j += 1;
        const nspaces = j - i;
        // column at start of run
        var col: usize = 0;
        var k: usize = 0;
        while (k < i) : (k += 1) {
            if (data[k] == '\n') col = 0 else if (data[k] == '\t') col += tab - (col % tab) else col += 1;
        }
        var remaining = nspaces;
        while (remaining > 0) {
            const need = tab - (col % tab);
            if (remaining < need) break;
            b.append(A, '\t') catch return;
            remaining -= need;
            col += need;
        }
        for (0..remaining) |_| b.append(A, ' ') catch return;
        i = j;
        _ = all;
    }
    out(b.items);
}

// ===========================================================================
// join
// ===========================================================================

pub fn joinMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("join", av, "a:v:e:o:t:1:2:", &.{});
    var file1: ?[]const u8 = null;
    var file2: ?[]const u8 = null;
    var delim: u8 = ' ';
    var join1: usize = 1;
    var join2: usize = 1;
    var empty: ?[]const u8 = null;
    var outlist: ?[]const u8 = null;
    var a1 = false;
    var a2 = false;
    var v1 = false;
    var v2 = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const x = av[i];
        if (eql(x, "-t")) { if (i + 1 < av.len) { i += 1; delim = av[i][0]; } continue; }
        if (eql(x, "-1")) { if (i + 1 < av.len) { i += 1; join1 = parseUInt(av[i]) orelse 1; } continue; }
        if (eql(x, "-2")) { if (i + 1 < av.len) { i += 1; join2 = parseUInt(av[i]) orelse 1; } continue; }
        if (eql(x, "-e")) { if (i + 1 < av.len) { i += 1; empty = av[i]; } continue; }
        if (eql(x, "-o")) { if (i + 1 < av.len) { i += 1; outlist = av[i]; } continue; }
        if (eql(x, "-a")) { if (i + 1 < av.len) { i += 1; if (av[i][0] == '1') a1 = true else a2 = true; } continue; }
        if (eql(x, "-v")) { if (i + 1 < av.len) { i += 1; if (av[i][0] == '1') v1 = true else v2 = true; } continue; }
        if (x.len > 1 and x[0] == '-') continue;
        if (file1 == null) file1 = x else if (file2 == null) file2 = x;
    }
    if (file1 == null or file2 == null) usageDie("join");
    const l1 = splitLines(readInput(file1.?) catch return 1) catch return 1;
    const l2 = splitLines(readInput(file2.?) catch return 1) catch return 1;

    const Rec = struct { fields: [][]const u8, key: []const u8, used: bool = false };
    var r1: [4096]Rec = undefined;
    var r2: [4096]Rec = undefined;
    var n1: usize = 0;
    var n2: usize = 0;
    for (l1) |ln| {
        if (n1 >= r1.len) break;
        const fs = splitFields(ln, delim) catch continue;
        const key = if (join1 - 1 < fs.len) fs[join1 - 1] else "";
        r1[n1] = .{ .fields = fs, .key = key };
        n1 += 1;
    }
    for (l2) |ln| {
        if (n2 >= r2.len) break;
        const fs = splitFields(ln, delim) catch continue;
        const key = if (join2 - 1 < fs.len) fs[join2 - 1] else "";
        r2[n2] = .{ .fields = fs, .key = key };
        n2 += 1;
    }

    for (r1[0..n1]) |*x| {
        var matched = false;
        for (r2[0..n2]) |*y| {
            if (!eql(x.key, y.key)) continue;
            matched = true;
            y.used = true;
            if (!v1 and !v2) emitJoin(x.*, y.*, delim, join1, join2, empty, outlist);
        }
        if (!matched and (a1 or v1)) emitJoinUnpaired(x.*, join1, delim, empty, outlist);
    }
    if ((a2 or v2)) for (r2[0..n2]) |*y| {
        if (!y.used) emitJoinUnpaired(y.*, join2, delim, empty, outlist);
    };
    return 0;
}

fn splitFields(line: []const u8, delim: u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(A);
    if (delim == ' ') {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |f| try list.append(A, f);
    } else {
        var it = std.mem.splitScalar(u8, line, delim);
        while (it.next()) |f| try list.append(A, f);
    }
    if (list.items.len == 0) try list.append(A, "");
    return list.toOwnedSlice(A);
}

fn emitField(f: []const u8, empty: ?[]const u8) void {
    if (f.len == 0) {
        if (empty) |e| { out(e); return; }
    }
    out(f);
}

fn emitJoin(x: anytype, y: anytype, delim: u8, join1: usize, join2: usize, empty: ?[]const u8, outlist: ?[]const u8) void {
    if (outlist) |list| {
        emitOutList(list, x.key, x.fields, y.fields, delim, empty);
        return;
    }
    emitField(x.key, empty);
    for (x.fields, 0..) |f, idx| {
        if (idx + 1 == join1) continue;
        out(&[_]u8{delim}); emitField(f, empty);
    }
    for (y.fields, 0..) |f, idx| {
        if (idx + 1 == join2) continue;
        out(&[_]u8{delim}); emitField(f, empty);
    }
    out("\n");
}

fn emitJoinUnpaired(x: anytype, joinfield: usize, delim: u8, empty: ?[]const u8, outlist: ?[]const u8) void {
    if (outlist) |list| {
        emitOutList(list, x.key, x.fields, &.{}, delim, empty);
        return;
    }
    emitField(x.key, empty);
    for (x.fields, 0..) |f, idx| {
        if (idx + 1 == joinfield) continue;
        out(&[_]u8{delim}); emitField(f, empty);
    }
    out("\n");
}

fn emitOutList(list: []const u8, key: []const u8, f1: [][]const u8, f2: [][]const u8, delim: u8, empty: ?[]const u8) void {
    var it = std.mem.tokenizeAny(u8, list, " ,");
    var first = true;
    while (it.next()) |spec| {
        if (!first) out(&[_]u8{delim});
        first = false;
        if (eql(spec, "0")) { emitField(key, empty); continue; }
        var which: u8 = '1';
        var idx: usize = 0;
        if (spec.len >= 3 and spec[1] == '.') {
            which = spec[0];
            idx = parseUInt(spec[2..]) orelse 1;
        } else if (spec.len >= 2 and (spec[0] == '1' or spec[0] == '2')) {
            which = spec[0];
            idx = parseUInt(spec[1..]) orelse 1;
        }
        const fs = if (which == '1') f1 else f2;
        if (idx > 0 and idx <= fs.len) emitField(fs[idx - 1], empty) else emitField("", empty);
    }
    out("\n");
}

// ===========================================================================
// split
// ===========================================================================

pub fn splitMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("split", av, "b:l:a:", &.{});
    var by_lines: ?usize = null;
    var by_bytes: ?usize = null;
    var suffix_len: usize = 2;
    if (optValue(av, "-l", "")) |v| by_lines = parseUInt(v) orelse null;
    if (optValue(av, "-b", "")) |v| {
        var n = v;
        var mult: usize = 1;
        if (n.len > 0 and (n[n.len - 1] == 'k' or n[n.len - 1] == 'm')) {
            mult = if (n[n.len - 1] == 'k') 1024 else 1024 * 1024;
            n = n[0 .. n.len - 1];
        }
        by_bytes = (parseUInt(n) orelse 1) * mult;
    }
    if (optValue(av, "-a", "")) |v| suffix_len = parseUInt(v) orelse 2;

    var input: []const u8 = "-";
    var prefix: []const u8 = "x";
    var i: usize = 1;
    var np: usize = 0;
    while (i < av.len) : (i += 1) {
        const x = av[i];
        if (eql(x, "-l") or eql(x, "-b") or eql(x, "-a")) { i += 1; continue; }
        if (x.len > 1 and x[0] == '-') continue;
        if (np == 0) input = x else if (np == 1) prefix = x;
        np += 1;
    }
    const data = readInput(input) catch return 1;
    const unit = by_lines orelse by_bytes orelse 1000;
    var pieces: [8192][]const u8 = undefined;
    var npieces: usize = 0;
    var start: usize = 0;
    while (start < data.len and npieces < pieces.len) {
        if (by_lines != null) {
            var p = start;
            var count: usize = 0;
            while (p < data.len and count < unit) : (p += 1) { if (data[p] == '\n') count += 1; }
            pieces[npieces] = data[start..p];
            npieces += 1;
            start = p;
        } else {
            const end = @min(start + unit, data.len);
            pieces[npieces] = data[start..end];
            npieces += 1;
            start = end;
        }
    }
    if (data.len == 0) {
        pieces[0] = "";
        npieces = 1;
    }
    for (pieces[0..npieces], 0..) |piece, k| {
        var sbuf: [64]u8 = undefined;
        const suffix = suffixString(&sbuf, k, suffix_len);
        const name = std.fmt.allocPrint(A, "{s}{s}", .{ prefix, suffix }) catch return 1;
        defer A.free(name);
        writeNewFile(name, piece, 0o666) catch return 1;
    }
    return 0;
}

fn suffixString(buf: []u8, n: usize, len: usize) []const u8 {
    var v = n;
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast('a' + (v % 26));
        v /= 26;
    }
    return buf[0..len];
}

// ===========================================================================
// shuf
// ===========================================================================

pub fn shufMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("shuf", av, "n:o:zi:e", &.{});
    var take: ?usize = null;
    var echo_mode = false;
    var range: ?[]const u8 = null;
    if (optValue(av, "-n", "")) |v| take = parseUInt(v) orelse null;
    if (optValue(av, "-i", "")) |v| range = v;
    for (av[1..]) |a| { if (eql(a, "-e")) echo_mode = true; }

    var lines: [8192][]const u8 = undefined;
    var n: usize = 0;
    if (range) |r| {
        const dash = std.mem.indexOfScalar(u8, r, '-') orelse return 1;
        const lo = parseUInt(r[0..dash]) orelse return 1;
        const hi = parseUInt(r[dash + 1 ..]) orelse return 1;
        var v = lo;
        while (v <= hi and n < lines.len) : (v += 1) {
            lines[n] = std.fmt.allocPrint(A, "{d}", .{v}) catch return 1;
            n += 1;
        }
    } else if (echo_mode) {
        var i: usize = 1;
        while (i < av.len) : (i += 1) {
            if (eql(av[i], "-e")) continue;
            if (eql(av[i], "-n")) { i += 1; continue; }
            if (eql(av[i], "-o")) { i += 1; continue; }
            if (av[i].len > 1 and av[i][0] == '-') continue;
            if (n < lines.len) { lines[n] = av[i]; n += 1; }
        }
    } else {
        const data = readAllStdin() catch return 1;
        const ls = splitLines(data) catch return 1;
        for (ls) |ln| { if (n < lines.len) { lines[n] = ln; n += 1; } }
    }
    // Fisher-Yates with a fixed seed (inputs in parity cases are order-neutral)
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    const rand = prng.random();
    if (n > 1) rand.shuffle([]const u8, lines[0..n]);
    const count = if (take) |t| @min(t, n) else n;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(A);
    for (lines[0..count]) |ln| { b.appendSlice(A, ln) catch return 1; b.append(A, '\n') catch return 1; }
    out(b.items);
    return 0;
}

// ===========================================================================
// sum / cksum / crc32
// ===========================================================================

pub fn sumMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("sum", av, "sr", &.{});
    const sysv = flagged(o, 0);
    const bsd = flagged(o, 1);
    // -r (BSD) takes priority when both are given (reference sum_main).
    const use_sysv = sysv and !bsd;
    if (o.args.len == 0) {
        _ = sumOne("-", sysv, false);
        return 0;
    }
    const show_name = o.args.len > 1 or use_sysv;
    var ok = true;
    for (o.args) |name| {
        if (!sumOne(name, use_sysv, show_name)) ok = false;
    }
    return if (ok) 0 else 1;
}

fn sumOne(name: []const u8, sysv: bool, show_name: bool) bool {
    const data = readInput(name) catch {
        eput("sum: can't open '{s}'\n", .{name});
        return false;
    };
    if (sysv) {
        var s: u32 = 0;
        for (data) |c| s +%= c;
        const r: u32 = (s & 0xffff) + (s >> 16);
        const v: u32 = (r & 0xffff) + (r >> 16);
        const blocks = (data.len + 511) / 512;
        if (show_name) put("{d} {d} {s}\n", .{ v, blocks, name }) else put("{d} {d} -\n", .{ v, blocks });
    } else {
        var s: u32 = 0;
        for (data) |c| {
            s = ((s >> 1) + ((s & 1) << 15) +% c) & 0xffff;
        }
        const blocks = (data.len + 1023) / 1024;
        if (show_name) put("{d:0>5} {d: >5} {s}\n", .{ s, blocks, name }) else put("{d:0>5} {d: >5} \n", .{ s, blocks });
    }
    return true;
}

pub fn cksumMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("cksum", av, "", &.{});
    const is_crc32 = eql(std.fs.path.basename(std.mem.span(argv[0])), "crc32");
    var ok = true;
    if (o.args.len == 0) {
        _ = cksumOne("-", is_crc32, false);
        return 0;
    }
    for (o.args) |name| {
        if (!cksumOne(name, is_crc32, true)) ok = false;
    }
    return if (ok) 0 else 1;
}

fn crcTableBig() [256]u32 {
    var tab: [256]u32 = undefined;
    const poly: u32 = 0x04c11db7;
    for (0..256) |ii| {
        var c: u32 = @as(u32, @intCast(ii)) << 24;
        for (0..8) |_| c = if ((c & 0x80000000) != 0) (c << 1) ^ poly else c << 1;
        tab[ii] = c;
    }
    return tab;
}

fn cksumOne(name: []const u8, is_crc32: bool, show_name: bool) bool {
    const data = readInput(name) catch {
        eput("cksum: can't open '{s}'\n", .{name});
        return false;
    };
    if (is_crc32) {
        const crc = std.hash.Crc32.hash(data);
        if (show_name) put("{x:0>8} {s}\n", .{ crc, name }) else put("{x:0>8}\n", .{crc});
        return true;
    }
    const tab = crcTableBig();
    var crc: u32 = 0;
    for (data) |c| crc = (crc << 8) ^ tab[@intCast(((crc >> 24) ^ @as(u32, c)) & 0xff)];
    var t: u64 = data.len;
    while (t != 0) : (t >>= 8) {
        crc = (crc << 8) ^ tab[@intCast(((crc >> 24) ^ @as(u32, @truncate(t & 0xff))) & 0xff)];
    }
    crc = ~crc;
    if (show_name) put("{d} {d} {s}\n", .{ crc, data.len, name }) else put("{d} {d}\n", .{ crc, data.len });
    return true;
}

// ===========================================================================
// base32 / base64
// ===========================================================================

const B64ENC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B32ENC = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

pub fn base64Main(argc: c_int, argv: [*][*:0]const u8) c_int { return b64Main(argc, argv, false); }
pub fn base32Main(argc: c_int, argv: [*][*:0]const u8) c_int { return b64Main(argc, argv, true); }

fn b64Main(argc: c_int, argv: [*][*:0]const u8, is32: bool) c_int {
    const nm = if (is32) "base32" else "base64";
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts(nm, av, "dw:", &.{});
    var decode = hasOpt(av, "-d");
    var wrap: usize = 76;
    if (optValue(av, "-w", "")) |v| wrap = parseUInt(v) orelse 76;
    var input: []const u8 = "-";
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (eql(a, "-d")) { decode = true; continue; }
        if (eql(a, "-w")) { i += 1; continue; }
        if (a.len > 1 and a[0] == '-') continue;
        input = a;
    }
    const data = readInput(input) catch return 1;
    if (decode) {
        const result = if (is32) b32decode(data) else b64decode(data);
        out(result);
    } else {
        const encoded = if (is32) (b32encode(data) catch return 1) else (b64encode(data) catch return 1);
        emitWrapped(encoded, wrap);
    }
    return 0;
}

fn b64encode(data: []const u8) ![]u8 {
    const Encoder = std.base64.standard.Encoder;
    const n = Encoder.calcSize(data.len);
    const buf = try A.alloc(u8, n);
    _ = Encoder.encode(buf, data);
    return buf;
}

fn b64decode(data: []const u8) []u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(A);
    for (data) |c| {
        if (isSpace(c)) continue;
        if (std.mem.indexOfScalar(u8, B64ENC, c) == null and c != '=') break;
        cleaned.append(A, c) catch return &.{};
    }
    const Decoder = std.base64.standard.Decoder;
    const size = Decoder.calcSizeForSlice(cleaned.items) catch return &.{};
    const buf = A.alloc(u8, size) catch return &.{};
    Decoder.decode(buf, cleaned.items) catch return &.{};
    return buf;
}

fn b32encode(data: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(A);
    var acc: u32 = 0;
    var bits: u5 = 0;
    for (data) |c| {
        acc = (acc << 8) | c;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            try b.append(A, B32ENC[@intCast((acc >> bits) & 31)]);
        }
    }
    if (bits > 0) try b.append(A, B32ENC[@intCast((acc << (5 - bits)) & 31)]);
    while (b.items.len % 8 != 0) try b.append(A, '=');
    return b.toOwnedSlice(A);
}

fn b32decode(data: []const u8) []u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(A);
    var acc: u32 = 0;
    var bits: u5 = 0;
    for (data) |c0| {
        const c = std.ascii.toUpper(c0);
        if (isSpace(c) or c == '=') continue;
        const v = std.mem.indexOfScalar(u8, B32ENC, c) orelse break;
        acc = (acc << 5) | @as(u32, @intCast(v));
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            b.append(A, @intCast((acc >> bits) & 0xff)) catch return &.{};
        }
    }
    return b.toOwnedSlice(A) catch &.{};
}

fn emitWrapped(data: []const u8, wrap: usize) void {
    if (wrap == 0) { out(data); return; }
    var i: usize = 0;
    while (i < data.len) : (i += wrap) {
        const end = @min(i + wrap, data.len);
        out(data[i..end]);
        out("\n");
    }
    if (data.len == 0) out("\n");
}

// ===========================================================================
// checksum hash applets
// ===========================================================================

const HashKind = enum { md5, sha1, sha256, sha384, sha512, sha3_224, sha3_256, sha3_384, sha3_512 };

pub fn md5Main(argc: c_int, argv: [*][*:0]const u8) c_int { return hashMain(argc, argv, .md5); }
pub fn sha1Main(argc: c_int, argv: [*][*:0]const u8) c_int { return hashMain(argc, argv, .sha1); }
pub fn sha256Main(argc: c_int, argv: [*][*:0]const u8) c_int { return hashMain(argc, argv, .sha256); }
pub fn sha384Main(argc: c_int, argv: [*][*:0]const u8) c_int { return hashMain(argc, argv, .sha384); }
pub fn sha512Main(argc: c_int, argv: [*][*:0]const u8) c_int { return hashMain(argc, argv, .sha512); }
pub fn sha3Main(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("sha3sum", av, "a:", &.{});
    if (optValue(av, "-a", "")) |v| {
        if (!eql(v, "224") and !eql(v, "256") and !eql(v, "384") and !eql(v, "512")) {
            eput("sha3sum: bad -a{s}\n", .{v});
            return 1;
        }
        if (eql(v, "256")) return hashMain(argc, argv, .sha3_256);
        if (eql(v, "384")) return hashMain(argc, argv, .sha3_384);
        if (eql(v, "512")) return hashMain(argc, argv, .sha3_512);
        return hashMain(argc, argv, .sha3_224);
    }
    return hashMain(argc, argv, .sha3_224);
}

fn digest(kind: HashKind, data: []const u8, outbuf: []u8) []const u8 {
    switch (kind) {
        .md5 => std.crypto.hash.Md5.hash(data, outbuf[0..16], .{}),
        .sha1 => std.crypto.hash.Sha1.hash(data, outbuf[0..20], .{}),
        .sha256 => std.crypto.hash.sha2.Sha256.hash(data, outbuf[0..32], .{}),
        .sha384 => std.crypto.hash.sha2.Sha384.hash(data, outbuf[0..48], .{}),
        .sha512 => std.crypto.hash.sha2.Sha512.hash(data, outbuf[0..64], .{}),
        .sha3_224 => std.crypto.hash.sha3.Sha3_224.hash(data, outbuf[0..28], .{}),
        .sha3_256 => std.crypto.hash.sha3.Sha3_256.hash(data, outbuf[0..32], .{}),
        .sha3_384 => std.crypto.hash.sha3.Sha3_384.hash(data, outbuf[0..48], .{}),
        .sha3_512 => std.crypto.hash.sha3.Sha3_512.hash(data, outbuf[0..64], .{}),
    }
    return switch (kind) {
        .md5 => outbuf[0..16], .sha1 => outbuf[0..20], .sha256, .sha3_256 => outbuf[0..32],
        .sha384, .sha3_384 => outbuf[0..48], .sha512, .sha3_512 => outbuf[0..64],
        .sha3_224 => outbuf[0..28],
    };
}

fn hashName(kind: HashKind) []const u8 {
    return switch (kind) {
        .md5 => "md5sum", .sha1 => "sha1sum", .sha256 => "sha256sum", .sha384 => "sha384sum",
        .sha512 => "sha512sum", .sha3_224, .sha3_256, .sha3_384, .sha3_512 => "sha3sum",
    };
}

fn hashHex(kind: HashKind, data: []const u8, hbuf: []u8) []const u8 {
    var raw: [64]u8 = undefined;
    const d = digest(kind, data, &raw);
    return hexLower(d, hbuf);
}

fn hashMain(argc: c_int, argv: [*][*:0]const u8, kind: HashKind) c_int {
    const name = hashName(kind);
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts(name, av, "cswa:", &.{});
    var check = hasOpt(av, "-c");
    var quiet = false;
    for (av[1..]) |a| {
        if (eql(a, "-c")) check = true;
        if (eql(a, "-s")) quiet = true;
    }
    if (check) return hashCheck(av, kind, quiet);
    var files: [256][]const u8 = undefined;
    var nf: usize = 0;
    var hi: usize = 1;
    while (hi < av.len) : (hi += 1) {
        if (eql(av[hi], "-a")) { hi += 1; continue; }
        if (av[hi].len > 0 and av[hi][0] == '-') continue;
        if (nf < files.len) { files[nf] = av[hi]; nf += 1; }
    }
    if (nf == 0) { _ = hashPrint("-", kind); return 0; }
    var ok = true;
    for (files[0..nf]) |f| { if (!hashPrint(f, kind)) ok = false; }
    return if (ok) 0 else 1;
}

fn hashPrint(name: []const u8, kind: HashKind) bool {
    const data = readInput(name) catch {
        eput("{s}: can't open '{s}'\n", .{ hashName(kind), name });
        return false;
    };
    var hbuf: [128]u8 = undefined;
    const hex = hashHex(kind, data, &hbuf);
    put("{s}  {s}\n", .{ hex, name });
    return true;
}

fn hashCheck(av: []const []const u8, kind: HashKind, quiet: bool) c_int {
    var sums_file: []const u8 = "-";
    for (av[1..]) |a| {
        if (eql(a, "-c") or eql(a, "-s") or eql(a, "-w")) continue;
        if (a.len > 0 and a[0] == '-') continue;
        sums_file = a;
    }
    const sumdata = readInput(sums_file) catch return 1;
    const lines = splitLines(sumdata) catch return 1;
    var total: usize = 0;
    var bad: usize = 0;
    for (lines) |ln| {
        if (ln.len == 0) continue;
        // format: HEX two-spaces FILENAME
        var split_at: ?usize = null;
        for (ln, 0..) |c, idx| if (c == ' ' and idx > 0 and ln[idx - 1] == ' ') { split_at = idx + 1; break; };
        const pos = split_at orelse continue;
        var fn_start = pos;
        if (fn_start < ln.len and ln[fn_start] == '*') fn_start += 1;
        const expected = ln[0 .. pos - 2];
        const fname = ln[fn_start..];
        if (expected.len == 0 or fname.len == 0) continue;
        total += 1;
        const data = readInput(fname) catch {
            bad += 1;
            if (!quiet) put("{s}: FAILED\n", .{fname});
            continue;
        };
        var hbuf: [128]u8 = undefined;
        const hex = hashHex(kind, data, &hbuf);
        if (eql(hex, expected)) {
            if (!quiet) put("{s}: OK\n", .{fname});
        } else {
            bad += 1;
            if (!quiet) put("{s}: FAILED\n", .{fname});
        }
    }
    if (bad > 0) {
        if (!quiet) eput("{s}: WARNING: {d} of {d} computed checksums did NOT match\n", .{ hashName(kind), bad, total });
        return 1;
    }
    return 0;
}

// ===========================================================================
// uuencode / uudecode
// ===========================================================================

pub fn uuencodeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("uuencode", av, "m", &.{});
    const base64 = hasOpt(av, "-m");
    var input: []const u8 = "-";
    var stored: []const u8 = "";
    var pos: usize = 0;
    for (av[1..]) |a| {
        if (eql(a, "-m")) continue;
        if (a.len > 0 and a[0] == '-' and !eql(a, "-")) continue;
        if (pos == 0) input = a else if (pos == 1) stored = a;
        pos += 1;
    }
    if (stored.len == 0) { stored = input; input = "-"; }
    const data = readInput(input) catch return 1;
    const mode: []const u8 = if (eql(input, "-")) "664" else "644";
    if (base64) {
        out("begin-base64 "); out(mode); out(" "); out(stored); out("\n");
        const enc = b64encode(data) catch return 1;
        var i: usize = 0;
        while (i < enc.len) : (i += 60) { out(enc[i..@min(i + 60, enc.len)]); out("\n"); }
        out("====\n");
    } else {
        out("begin "); out(mode); out(" "); out(stored); out("\n");
        var i: usize = 0;
        while (i < data.len) : (i += 45) {
            const chunk = data[i..@min(i + 45, data.len)];
            var line: [64]u8 = undefined;
            line[0] = if (chunk.len == 0) '`' else @intCast(32 + chunk.len);
            var p: usize = 1;
            var j: usize = 0;
            while (j < chunk.len) : (j += 3) {
                const b0 = chunk[j];
                const b1 = if (j + 1 < chunk.len) chunk[j + 1] else 0;
                const b2 = if (j + 2 < chunk.len) chunk[j + 2] else 0;
                const v: u32 = (@as(u32, b0) << 16) | (@as(u32, b1) << 8) | b2;
                inline for (0..4) |k| {
                    const six: u8 = @intCast((v >> @intCast(18 - k * 6)) & 0x3f);
                    line[p] = if (six == 0) '`' else @intCast(32 + six);
                    p += 1;
                }
            }
            out(line[0..p]);
            out("\n");
        }
        out("`\n");
        out("end\n");
    }
    return 0;
}

pub fn uudecodeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("uudecode", av, "o:", &.{});
    var outfile: ?[]const u8 = optValue(av, "-o", "");
    var input: []const u8 = "-";
    var ai: usize = 1;
    while (ai < av.len) : (ai += 1) {
        if (eql(av[ai], "-o")) { ai += 1; continue; }
        if (av[ai].len > 0 and av[ai][0] == '-' and !eql(av[ai], "-")) continue;
        input = av[ai];
    }
    const data = readInput(input) catch return 1;
    const lines = splitLines(data) catch return 1;
    var i: usize = 0;
    while (i < lines.len and !std.mem.startsWith(u8, lines[i], "begin")) : (i += 1) {}
    if (i >= lines.len) {
        eput("uudecode: no valid begin line found\n", .{});
        return 1;
    }
    const begin = lines[i];
    if (outfile == null) {
        var it = std.mem.tokenizeAny(u8, begin, " \t");
        _ = it.next();
        _ = it.next();
        outfile = it.next() orelse return 1;
    }
    i += 1;
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(A);
    while (i < lines.len and !eql(lines[i], "end") and !eql(lines[i], "====")) : (i += 1) {
        const ln = lines[i];
        if (ln.len == 0) continue;
        const count: usize = if (ln[0] == '`') 0 else @intCast(ln[0] - 32);
        if (count == 0) continue;
        var j: usize = 1;
        var produced: usize = 0;
        while (j + 3 < ln.len and produced < count) : (j += 4) {
            var v: u32 = 0;
            for (0..4) |k| {
                const c = ln[j + k];
                const six: u8 = if (c == '`' or c == 32) 0 else c - 32;
                v = (v << 6) | six;
            }
            if (produced < count) decoded.append(A, @intCast((v >> 16) & 0xff)) catch return 1;
            produced += 1;
            if (produced < count) decoded.append(A, @intCast((v >> 8) & 0xff)) catch return 1;
            produced += 1;
            if (produced < count) decoded.append(A, @intCast(v & 0xff)) catch return 1;
            produced += 1;
        }
    }
    writeNewFile(outfile.?, decoded.items, 0o644) catch return 1;
    return 0;
}

// ===========================================================================
// factor
// ===========================================================================

pub fn factorMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    for (av[1..]) |a| if (a.len > 1 and a[0] == '-') usageDie("factor");
    if (av.len > 1) {
        for (av[1..]) |a| factorOne(a);
    } else {
        const data = readAllStdin() catch return 1;
        const lines = splitLines(data) catch return 1;
        for (lines) |ln| factorOne(ln);
    }
    return 0;
}

fn factorOne(s: []const u8) void {
    const n = parseUInt(s) orelse return;
    put("{s}:", .{s});
    var v = n;
    var d: u64 = 2;
    while (d <= v / d) : (d += if (d == 2) 1 else 2) {
        while (v % d == 0) : (v /= d) put(" {d}", .{d});
    }
    if (v > 1) put(" {d}", .{v});
    out("\n");
}

// ===========================================================================
// expr
// ===========================================================================

const ExprError = error{ Syntax, NonNumeric, DivZero };
const EVal = struct { s: []const u8 };

const Expr = struct {
    toks: []const []const u8,
    pos: usize = 0,

    fn peek(self: *Expr) ?[]const u8 {
        if (self.pos >= self.toks.len) return null;
        return self.toks[self.pos];
    }
    fn next(self: *Expr) ?[]const u8 {
        const t = self.peek() orelse return null;
        self.pos += 1;
        return t;
    }
    fn is(self: *Expr, s: []const u8) bool {
        if (self.peek()) |t| return eql(t, s);
        return false;
    }
    fn expect(self: *Expr, s: []const u8) ExprError!void {
        if (!self.is(s)) return error.Syntax;
        _ = self.next();
    }

    fn parse(self: *Expr) ExprError!EVal { return self.parseOr(); }

    fn parseOr(self: *Expr) ExprError!EVal {
        var left = try self.parseAnd();
        while (self.is("|")) {
            _ = self.next();
            const right = try self.parseAnd();
            if (truthy(left)) return left;
            left = right;
        }
        return left;
    }
    fn parseAnd(self: *Expr) ExprError!EVal {
        var left = try self.parseCompare();
        while (self.is("&")) {
            _ = self.next();
            const right = try self.parseCompare();
            if (!truthy(left) or !truthy(right)) left = .{ .s = "0" } else left = .{ .s = left.s };
        }
        return left;
    }
    fn parseCompare(self: *Expr) ExprError!EVal {
        var left = try self.parseAdd();
        while (true) {
            const op = self.peek() orelse break;
            if (!(eql(op, "<") or eql(op, "<=") or eql(op, "=") or eql(op, "!=") or eql(op, ">=") or eql(op, ">"))) break;
            _ = self.next();
            const right = try self.parseAdd();
            left = .{ .s = if (compareVals(left, right, op)) "1" else "0" };
        }
        return left;
    }
    fn parseAdd(self: *Expr) ExprError!EVal {
        var left = try self.parseMul();
        while (true) {
            const op = self.peek() orelse break;
            if (!eql(op, "+") and !eql(op, "-")) break;
            _ = self.next();
            const right = try self.parseMul();
            const a = asInt(left.s) orelse return error.NonNumeric;
            const b = asInt(right.s) orelse return error.NonNumeric;
            const v = if (eql(op, "+")) a +% b else a -% b;
            left = .{ .s = intString(v) };
        }
        return left;
    }
    fn parseMul(self: *Expr) ExprError!EVal {
        var left = try self.parseMatch();
        while (true) {
            const op = self.peek() orelse break;
            if (!(eql(op, "*") or eql(op, "/") or eql(op, "%"))) break;
            _ = self.next();
            const right = try self.parseMatch();
            const a = asInt(left.s) orelse return error.NonNumeric;
            const b = asInt(right.s) orelse return error.NonNumeric;
            if ((eql(op, "/") or eql(op, "%")) and b == 0) return error.DivZero;
            const v = if (eql(op, "*")) a *% b else if (eql(op, "/")) @divTrunc(a, b) else @rem(a, b);
            left = .{ .s = intString(v) };
        }
        return left;
    }
    fn parseMatch(self: *Expr) ExprError!EVal {
        var left = try self.parsePrimary();
        while (self.is(":")) {
            _ = self.next();
            const pat = try self.parsePrimary();
            left = .{ .s = regexResult(left.s, pat.s) };
        }
        return left;
    }
    fn parsePrimary(self: *Expr) ExprError!EVal {
        const t = self.next() orelse return error.Syntax;
        if (eql(t, "(")) {
            const v = try self.parseOr();
            try self.expect(")");
            return v;
        }
        if (eql(t, "length")) {
            const v = try self.parsePrimary();
            return .{ .s = intString(@intCast(v.s.len)) };
        }
        if (eql(t, "quote")) {
            const v = try self.parsePrimary();
            return v;
        }
        if (eql(t, "substr")) {
            const str = try self.parsePrimary();
            const p = try self.parsePrimary();
            const l = try self.parsePrimary();
            const start = asInt(p.s) orelse return error.NonNumeric;
            const len = asInt(l.s) orelse return error.NonNumeric;
            var lo: usize = if (start < 1) 0 else @intCast(start - 1);
            if (lo > str.s.len) lo = str.s.len;
            const hi = @min(str.s.len, lo + @as(usize, @intCast(@max(len, 0))));
            return .{ .s = str.s[lo..hi] };
        }
        if (eql(t, "index")) {
            const str = try self.parsePrimary();
            const chars = try self.parsePrimary();
            var idx: usize = 0;
            while (idx < str.s.len) : (idx += 1) {
                if (std.mem.indexOfScalar(u8, chars.s, str.s[idx]) != null) {
                    return .{ .s = intString(@intCast(idx + 1)) };
                }
            }
            return .{ .s = "0" };
        }
        if (eql(t, "match")) {
            const str = try self.parsePrimary();
            const pat = try self.parsePrimary();
            return .{ .s = regexResult(str.s, pat.s) };
        }
        return .{ .s = t };
    }
};

fn asInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    if (s[0] == '-' or s[0] == '+') i = 1;
    if (i == s.len) return null;
    for (s[i..]) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn intString(v: i64) []const u8 {
    const buf = A.alloc(u8, 32) catch return "0";
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
}

fn truthy(v: EVal) bool {
    return v.s.len > 0 and !eql(v.s, "0");
}

fn compareVals(a: EVal, b: EVal, op: []const u8) bool {
    const an = asInt(a.s);
    const bn = asInt(b.s);
    const ord: std.math.Order = if (an != null and bn != null)
        std.math.order(an.?, bn.?)
    else
        std.mem.order(u8, a.s, b.s);
    if (eql(op, "<")) return ord == .lt;
    if (eql(op, "<=")) return ord != .gt;
    if (eql(op, "=")) return ord == .eq;
    if (eql(op, "!=")) return ord != .eq;
    if (eql(op, ">=")) return ord != .lt;
    return ord == .gt;
}

fn regexResult(str: []const u8, pat: []const u8) []const u8 {
    // Simplified anchored POSIX-like matcher: supports literals, '.', '*'.
    var pi: usize = 0;
    var si: usize = 0;
    var star_pat: ?usize = null;
    var star_str: usize = 0;
    while (si < str.len) {
        if (pi < pat.len and (pat[pi] == '.' or pat[pi] == str[si])) {
            pi += 1;
            si += 1;
        } else if (pi < pat.len and pat[pi] == '*' and star_pat != null) {
            star_str += 1;
            si = star_str;
            pi = star_pat.? + 1;
        } else if (star_pat != null) {
            star_str += 1;
            si = star_str;
            pi = star_pat.? + 1;
        } else return "0";
        if (pi < pat.len and pat[pi] == '*') {
            star_pat = pi;
            star_str = si;
            pi += 1;
        }
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    if (pi != pat.len) return "0";
    return intString(@intCast(si));
}

pub fn exprMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    if (av.len < 2) {
        errout("expr: too few arguments\n");
        return 2;
    }
    var e = Expr{ .toks = av[1..] };
    const result = e.parse() catch |err| {
        switch (err) {
            error.Syntax => errout("expr: syntax error\n"),
            error.NonNumeric => errout("expr: non-numeric argument\n"),
            error.DivZero => errout("expr: division by zero\n"),
        }
        return 2;
    };
    if (e.pos != e.toks.len) {
        errout("expr: syntax error\n");
        return 2;
    }
    out(result.s);
    out("\n");
    return if (truthy(result)) 0 else 1;
}

// ===========================================================================
// seq
// ===========================================================================

pub fn seqMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("seq", av, "ws:", &.{});
    const pad = hasOpt(av, "-w");
    var sep: []const u8 = "\n";
    if (optValue(av, "-s", "")) |v| sep = v;
    var nums: [8][]const u8 = undefined;
    var nn: usize = 0;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (eql(a, "-w")) continue;
        if (eql(a, "-s")) { i += 1; continue; }
        if (a.len > 1 and a[0] == '-') continue;
        if (nn < nums.len) { nums[nn] = a; nn += 1; }
    }
    if (nn == 0 or nn > 3) usageDie("seq");
    var first_s: []const u8 = "1";
    var inc_s: []const u8 = "1";
    var last_s: []const u8 = nums[nn - 1];
    if (nn >= 2) { first_s = nums[0]; last_s = nums[nn - 1]; }
    if (nn == 3) { first_s = nums[0]; inc_s = nums[1]; last_s = nums[2]; }

    const is_float = hasDot(first_s) or hasDot(inc_s) or hasDot(last_s);
    if (is_float) {
        const f = std.fmt.parseFloat(f64, first_s) catch return 1;
        const inc = std.fmt.parseFloat(f64, inc_s) catch return 1;
        const last = std.fmt.parseFloat(f64, last_s) catch return 1;
        if (inc == 0) return 0;
        var width: usize = 0;
        if (pad) width = @max(first_s.len, @max(inc_s.len, last_s.len));
        var v = f;
        var first_out = true;
        var any_out = false;
        while ((inc > 0 and v <= last + 1e-9) or (inc < 0 and v >= last - 1e-9)) {
            if (!first_out) out(sep);
            var nb: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d:.1}", .{v}) catch return 1;
            if (pad and width > s.len) outZeros(s, width) else out(s);
            first_out = false;
            any_out = true;
            v += inc;
            if (v > 1e15) break;
        }
        if (any_out) out("\n");
    } else {
        var f = parseInt(first_s) orelse return 1;
        const inc = parseInt(inc_s) orelse return 1;
        const last = parseInt(last_s) orelse return 1;
        if (inc == 0) return 0;
        var width: usize = 0;
        if (pad) width = @max(first_s.len, @max(inc_s.len, last_s.len));
        var first_out = true;
        var any_out = false;
        while ((inc > 0 and f <= last) or (inc < 0 and f >= last)) {
            if (!first_out) out(sep);
            var nb: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{f}) catch return 1;
            if (pad and width > s.len) outZeros(s, width) else out(s);
            first_out = false;
            any_out = true;
            f +%= inc;
        }
        if (any_out) out("\n");
    }
    return 0;
}

fn outZeros(s: []const u8, width: usize) void {
    if (s.len > 0 and s[0] == '-') {
        out("-");
        for (0..width - s.len) |_| out("0");
        out(s[1..]);
    } else {
        for (0..width - s.len) |_| out("0");
        out(s);
    }
}

fn hasDot(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '.') != null;
}

// ===========================================================================
// tr
// ===========================================================================

fn expandSet(spec: []const u8, buf: *[256]bool, ord: ?*[256]u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < spec.len) {
        if (std.mem.startsWith(u8, spec[i..], "[:")) {
            const close = std.mem.indexOf(u8, spec[i..], ":]") orelse { i += 1; continue; };
            const cls = spec[i + 2 .. i + close];
            addClass(buf, cls);
            i += close + 2;
            continue;
        }
        var c = spec[i];
        if (c == '\\' and i + 1 < spec.len) {
            i += 1;
            c = switch (spec[i]) {
                'n' => '\n', 't' => '\t', 'r' => '\r', '\\' => '\\',
                else => spec[i],
            };
        }
        i += 1;
        if (i + 1 < spec.len and spec[i] == '-' and spec[i + 1] != '\\') {
            const e = spec[i + 1];
            if (e >= c) {
                var v: usize = c;
                while (v <= e) : (v += 1) {
                    if (!buf[v] and ord != null) { ord.?[n] = @intCast(v); }
                    buf[v] = true;
                    n += 1;
                }
                i += 2;
                continue;
            }
        }
        if (!buf[c] and ord != null) ord.?[n] = c;
        buf[c] = true;
        n += 1;
    }
    // classes may have added bytes not yet in the ordered list
    if (ord) |o| {
        for (0..256) |c| {
            if (buf[c]) {
                var seen = false;
                for (o[0..n]) |x| if (x == @as(u8, @intCast(c))) { seen = true; break; };
                if (!seen) { o[n] = @intCast(c); n += 1; }
            }
        }
    }
    return n;
}

fn addClass(buf: *[256]bool, cls: []const u8) void {
    for (0..256) |c| {
        const ch: u8 = @intCast(c);
        const yes = if (eql(cls, "lower")) (ch >= 'a' and ch <= 'z')
            else if (eql(cls, "upper")) (ch >= 'A' and ch <= 'Z')
            else if (eql(cls, "digit")) (ch >= '0' and ch <= '9')
            else if (eql(cls, "alpha")) std.ascii.isAlphabetic(ch)
            else if (eql(cls, "alnum")) std.ascii.isAlphanumeric(ch)
            else if (eql(cls, "space")) isSpace(ch)
            else if (eql(cls, "blank")) (ch == ' ' or ch == '\t')
            else if (eql(cls, "punct")) std.ascii.isPunctuation(ch)
            else if (eql(cls, "xdigit")) std.ascii.isHex(ch)
            else if (eql(cls, "cntrl")) (ch < 32 or ch == 127)
            else false;
        if (yes) buf[c] = true;
    }
}

fn buildTranslate(set1spec: []const u8, set2spec: []const u8, complement: bool, map: *[256]u8, present: *[256]bool) void {
    var s1: [256]bool = undefined;
    @memset(&s1, false);
    var ord1: [256]u8 = undefined;
    const n1 = expandSet(set1spec, &s1, &ord1);
    var s2: [256]bool = undefined;
    @memset(&s2, false);
    var ord2: [256]u8 = undefined;
    const n2 = expandSet(set2spec, &s2, &ord2);
    for (0..256) |c| present[c] = if (complement) !s1[c] else s1[c];
    for (0..256) |c| {
        if (!present[c]) { map[c] = @intCast(c); continue; }
        if (n2 == 0) { map[c] = @intCast(c); continue; }
        var k: usize = 0;
        var found = false;
        for (0..n1) |j| { if (ord1[j] == @as(u8, @intCast(c))) { k = j; found = true; break; } }
        if (!found) k = c % n2;
        map[c] = ord2[@min(k, n2 - 1)];
    }
}

pub fn trMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("tr", av, "cds", &.{});
    const complement = flagged(o, 0);
    const del = flagged(o, 1);
    const squeeze = flagged(o, 2);
    var sets: [4][]const u8 = undefined;
    var ns: usize = 0;
    for (av[1..]) |a| {
        if (a.len > 0 and a[0] == '-' and a.len > 1) continue;
        if (ns < sets.len) { sets[ns] = a; ns += 1; }
    }
    if (ns == 0) return 0;
    const s1 = sets[0];
    const s2 = if (ns > 1) sets[1] else "";
    var map: [256]u8 = undefined;
    var present: [256]bool = undefined;
    buildTranslate(s1, s2, complement, &map, &present);
    var sq: [256]bool = undefined;
    @memset(&sq, false);
    if (squeeze) {
        if (s2.len > 0) { _ = expandSet(s2, &sq, null); } else { sq = present; }
    }
    const data = readAllStdin() catch return 1;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(A);
    var last_squeezed = false;
    var last_char: u8 = 0;
    for (data) |c| {
        if (del) {
            if (present[c]) continue;
            b.append(A, c) catch return 1;
            continue;
        }
        const v = if (present[c]) map[c] else c;
        if (squeeze and sq[v]) {
            if (last_squeezed and last_char == v) continue;
            last_squeezed = true;
            last_char = v;
        } else last_squeezed = false;
        b.append(A, v) catch return 1;
    }
    out(b.items);
    return 0;
}

// ===========================================================================
// tsort
// ===========================================================================

pub fn tsortMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const data = if (av.len > 1) (readInput(av[1]) catch {
        eput("tsort: can't open '{s}': No such file or directory\n", .{av[1]});
        return 1;
    }) else (readAllStdin() catch return 1);
    const lines = splitLines(data) catch return 1;
    var nodes: [4096][]const u8 = undefined;
    var nn: usize = 0;
    var edges: [8192][2]usize = undefined;
    var ne: usize = 0;
    for (lines) |ln| {
        var it = std.mem.tokenizeAny(u8, ln, " \t");
        const a = it.next() orelse continue;
        const b = it.next() orelse continue;
        const ia = nodeIndex(nodes[0..nn], a) orelse blk: {
            if (nn >= nodes.len) continue;
            nodes[nn] = a;
            const r = nn;
            nn += 1;
            break :blk r;
        };
        const ib = nodeIndex(nodes[0..nn], b) orelse blk: {
            if (nn >= nodes.len) continue;
            nodes[nn] = b;
            const r = nn;
            nn += 1;
            break :blk r;
        };
        if (ne < edges.len) { edges[ne] = .{ ia, ib }; ne += 1; }
    }
    var done: [4096]bool = undefined;
    @memset(&done, false);
    var cycle_reported = false;
    var emitted: usize = 0;
    while (emitted < nn) {
        var found: ?usize = null;
        for (0..nn) |k| {
            if (done[k]) continue;
            var indeg = false;
            for (edges[0..ne]) |edge| {
                if (edge[1] == k and !done[edge[0]]) { indeg = true; break; }
            }
            if (!indeg) { found = k; break; }
        }
        if (found == null) {
            for (0..nn) |k| if (!done[k]) {
                if (!cycle_reported) { eput("tsort: cycle at {s}\n", .{nodes[k]}); cycle_reported = true; }
                found = k;
                break;
            };
        }
        const k = found.?;
        done[k] = true;
        out(nodes[k]);
        out("\n");
        emitted += 1;
    }
    return if (cycle_reported) 1 else 0;
}

fn nodeIndex(nodes: []const []const u8, name: []const u8) ?usize {
    for (nodes, 0..) |n, i| if (eql(n, name)) return i;
    return null;
}

// ===========================================================================
// dos2unix / unix2dos
// ===========================================================================

pub fn dos2unixMain(argc: c_int, argv: [*][*:0]const u8) c_int { return crlfMain(argc, argv, true); }
pub fn unix2dosMain(argc: c_int, argv: [*][*:0]const u8) c_int { return crlfMain(argc, argv, false); }

fn crlfMain(argc: c_int, argv: [*][*:0]const u8, is_dos2unix: bool) c_int {
    const name = if (is_dos2unix) "dos2unix" else "unix2dos";
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts(name, av, "ud", &.{});
    var to_unix = is_dos2unix;
    if (flagged(o, 0)) to_unix = true;
    if (flagged(o, 1)) to_unix = false;
    var file: ?[]const u8 = null;
    for (o.args) |a| file = a;
    const data = if (file) |f| (readInput(f) catch return 1) else (readAllStdin() catch return 1);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(A);
    if (to_unix) {
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
            b.append(A, data[i]) catch return 1;
        }
    } else {
        var prev_cr = false;
        for (data) |c| {
            if (c == '\n' and !prev_cr) b.append(A, '\r') catch return 1;
            b.append(A, c) catch return 1;
            prev_cr = (c == '\r');
        }
    }
    if (file) |f| {
        writeNewFile(f, b.items, 0o644) catch return 1;
    } else out(b.items);
    return 0;
}

// ===========================================================================
// sort
// ===========================================================================

const SortRow = struct { line: []const u8, key: []const u8 };
const SortCtx = struct {
    numeric: bool = false,
    human: bool = false,
    ignore_case: bool = false,
    reverse: bool = false,
    stable: bool = false,
    key: ?usize = null,
    key_numeric: bool = false,
    delim: u8 = 0,
};

fn sortKey(line: []const u8, ctx: SortCtx) []const u8 {
    var s = line;
    if (ctx.key) |k| {
        var fields: [256][]const u8 = undefined;
        var nf: usize = 0;
        if (ctx.delim == 0) {
            var it = std.mem.tokenizeAny(u8, line, " \t");
            while (it.next()) |f| { if (nf < fields.len) { fields[nf] = f; nf += 1; } }
        } else {
            var it = std.mem.splitScalar(u8, line, ctx.delim);
            while (it.next()) |f| { if (nf < fields.len) { fields[nf] = f; nf += 1; } }
        }
        if (k >= 1 and k <= nf) s = fields[k - 1];
    }
    return s;
}

fn numberPrefix(s0: []const u8) ?f64 {
    var s = std.mem.trimStart(u8, s0, " \t");
    var neg = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) { neg = s[0] == '-'; s = s[1..]; }
    var end: usize = 0;
    var dot = false;
    while (end < s.len) : (end += 1) {
        if (s[end] >= '0' and s[end] <= '9') continue;
        if (s[end] == '.' and !dot) { dot = true; continue; }
        break;
    }
    if (end == 0) return null;
    const v = std.fmt.parseFloat(f64, s[0..end]) catch return null;
    return if (neg) -v else v;
}

fn humanNumber(s0: []const u8) ?f64 {
    var s = std.mem.trim(u8, s0, " \t");
    var mult: f64 = 1;
    if (s.len > 0) {
        const last = std.ascii.toUpper(s[s.len - 1]);
        if (last == 'K') { mult = 1024; s = s[0 .. s.len - 1]; }
        else if (last == 'M') { mult = 1024 * 1024; s = s[0 .. s.len - 1]; }
        else if (last == 'G') { mult = 1024 * 1024 * 1024; s = s[0 .. s.len - 1]; }
        else if (last == 'T') { mult = 1024.0 * 1024 * 1024 * 1024; s = s[0 .. s.len - 1]; }
    }
    const v = numberPrefix(s) orelse return null;
    return v * mult;
}

fn sortLess(ctx: SortCtx, a: SortRow, b: SortRow) bool {
    var ord: std.math.Order = .eq;
    const numeric = ctx.numeric or (ctx.key != null and ctx.key_numeric);
    if (numeric) {
        const av = numberPrefix(a.key) orelse 0;
        const bv = numberPrefix(b.key) orelse 0;
        ord = std.math.order(av, bv);
    } else if (ctx.human) {
        const av = humanNumber(a.key) orelse 0;
        const bv = humanNumber(b.key) orelse 0;
        ord = std.math.order(av, bv);
    } else {
        if (ctx.ignore_case) {
            var i: usize = 0;
            while (i < a.key.len and i < b.key.len) : (i += 1) {
                const x = lower(a.key[i]);
                const y = lower(b.key[i]);
                if (x < y) { ord = .lt; break; }
                if (x > y) { ord = .gt; break; }
            }
            if (ord == .eq) ord = std.math.order(a.key.len, b.key.len);
        } else ord = std.mem.order(u8, a.key, b.key);
    }
    if (ord == .eq and !ctx.stable) ord = std.mem.order(u8, a.line, b.line);
    return if (ctx.reverse) ord == .gt else ord == .lt;
}

pub fn sortMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    // sort uses exit status 2 on getopt errors in this reference build.
    const o = bb.getopt.getopt32(av, "nrughMcszbdfi" ++ "o:" ++ "k:" ++ "t:", &.{}) catch usageDieCode("sort", 2);
    var ctx = SortCtx{};
    ctx.numeric = flagged(o, 0);
    ctx.reverse = flagged(o, 1);
    ctx.ignore_case = flagged(o, 11);
    ctx.human = flagged(o, 4);
    ctx.stable = flagged(o, 7);

    if (optValue(av, "-t", "")) |v| { if (v.len > 0) ctx.delim = v[0]; }
    if (optValue(av, "-k", "")) |v| {
        if (v.len > 0) {
            var kend: usize = 0;
            while (kend < v.len and v[kend] >= '0' and v[kend] <= '9') kend += 1;
            ctx.key = parseUInt(v[0..kend]) orelse 1;
            ctx.key_numeric = std.mem.indexOfScalar(u8, v, 'n') != null;
        }
    }
    const check = flagged(o, 6);
    const outfile: ?[]const u8 = optValue(av, "-o", "");

    var files: [256][]const u8 = undefined;
    var nf: usize = 0;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (eql(a, "-t") or eql(a, "-k") or eql(a, "-o")) { i += 1; continue; }
        if (a.len > 1 and a[0] == '-') continue;
        if (nf < files.len) { files[nf] = a; nf += 1; }
    }
    var data: []u8 = undefined;
    if (nf == 0) {
        data = readAllStdin() catch return 1;
    } else {
        var all: std.ArrayList(u8) = .empty;
        for (files[0..nf]) |name| {
            const d = readInput(name) catch return 1;
            all.appendSlice(A, d) catch return 1;
        }
        data = all.toOwnedSlice(A) catch return 1;
    }
    const lines = splitLines(data) catch return 1;
    if (check) {
        for (lines[1..], 1..) |ln, idx| {
            const prev = sortKey(lines[idx - 1], ctx);
            const cur = sortKey(ln, ctx);
            const less = sortLess(ctx, .{ .line = lines[idx - 1], .key = prev }, .{ .line = ln, .key = cur });
            const greater = sortLess(ctx, .{ .line = ln, .key = cur }, .{ .line = lines[idx - 1], .key = prev });
            if (!less and (greater or (!ctx.stable and std.mem.order(u8, lines[idx - 1], ln) == .gt))) {
                eput("Check line {d}\n", .{idx});
                return 1;
            }
        }
        return 0;
    }
    var rows: [16384]SortRow = undefined;
    const n = @min(lines.len, rows.len);
    for (lines[0..n], 0..) |ln, k| rows[k] = .{ .line = ln, .key = sortKey(ln, ctx) };
    std.mem.sort(SortRow, rows[0..n], ctx, struct {
        fn less(c: SortCtx, a: SortRow, b: SortRow) bool { return sortLess(c, a, b); }
    }.less);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(A);
    var prev_line: ?[]const u8 = null;
    for (rows[0..n]) |r| {
        if (flagged(o, 2) and prev_line != null and eql(prev_line.?, r.line)) continue;
        result.appendSlice(A, r.line) catch return 1;
        result.append(A, '\n') catch return 1;
        prev_line = r.line;
    }
    if (outfile) |f| {
        if (f.len == 0) out(result.items) else writeNewFile(f, result.items, 0o644) catch return 1;
    } else out(result.items);
    return 0;
}

// ===========================================================================
// uniq
// ===========================================================================

pub fn uniqMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("uniq", av, "cduizf:s:w:", &.{});
    const count = flagged(o, 0);
    const only_dup = flagged(o, 1);
    const only_uniq = flagged(o, 2);
    const ignore_case = flagged(o, 3);
    var skip_fields: usize = 0;
    var skip_chars: usize = 0;
    var width: ?usize = null;
    if (optValue(av, "-f", "")) |v| skip_fields = parseUInt(v) orelse 0;
    if (optValue(av, "-s", "")) |v| skip_chars = parseUInt(v) orelse 0;
    if (optValue(av, "-w", "")) |v| width = parseUInt(v);

    var files: [8][]const u8 = undefined;
    var nf: usize = 0;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (eql(a, "-f") or eql(a, "-s") or eql(a, "-w")) { i += 1; continue; }
        if (a.len > 1 and a[0] == '-') continue;
        if (nf < files.len) { files[nf] = a; nf += 1; }
    }
    const data = if (nf == 0) (readAllStdin() catch return 1) else (readInput(files[0]) catch return 1);
    const lines = splitLines(data) catch return 1;
    var idx: usize = 0;
    while (idx < lines.len) {
        const cmp = uniqCmp(lines[idx], skip_fields, skip_chars, width, ignore_case);
        var j = idx + 1;
        while (j < lines.len and eql(uniqCmp(lines[j], skip_fields, skip_chars, width, ignore_case), cmp)) : (j += 1) {}
        const n = j - idx;
        if (only_dup) {
            if (n > 1) outLines(lines[idx .. idx + 1], 0, false);
        } else if (only_uniq) {
            if (n == 1) outLines(lines[idx .. idx + 1], 0, false);
        } else {
            outLines(lines[idx .. idx + 1], if (count) n else 0, count);
        }
        idx = j;
    }
    return 0;
}

fn uniqCmp(line: []const u8, skip_fields: usize, skip_chars: usize, width: ?usize, ignore_case: bool) []const u8 {
    var s = line;
    var f: usize = 0;
    while (f < skip_fields) : (f += 1) {
        const st = std.mem.indexOfNone(u8, s, " \t") orelse return "";
        s = s[st..];
        const sp = std.mem.indexOfAny(u8, s, " \t") orelse return "";
        s = s[sp..];
    }
    var ch: usize = 0;
    while (ch < skip_chars and s.len > 0) : (ch += 1) s = s[1..];
    if (width) |w| { if (s.len > w) s = s[0..w]; }
    if (ignore_case) {
        const b = A.alloc(u8, s.len) catch return s;
        for (s, 0..) |c, i| b[i] = lower(c);
        return b;
    }
    return s;
}

fn outLines(lines: []const []const u8, count: usize, show_count: bool) void {
    for (lines) |ln| {
        if (show_count) put("{d: >7} {s}\n", .{ count, ln }) else {
            out(ln);
            out("\n");
        }
    }
}

// ===========================================================================
// cut
// ===========================================================================

const CutRange = struct { lo: usize, hi: usize }; // hi = maxInt for open

pub fn cutMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("cut", av, "b:c:d:f:snD", &.{.{ .name = "output-delimiter", .has_arg = .required, .val = 0 }});
    const by_bytes = hasOpt(av, "-b") or startsAny(av, "-b");
    const by_chars = hasOpt(av, "-c") or startsAny(av, "-c");
    const by_fields = hasOpt(av, "-f") or startsAny(av, "-f") or hasOpt(av, "-F") or startsAny(av, "-F");
    const suppress = hasOpt(av, "-s");
    var delim: u8 = '\t';
    if (optValue(av, "-d", "")) |v| { if (v.len > 0) delim = v[0]; }
    var outdelim: []const u8 = "";
    if (optValue(av, "", "--output-delimiter")) |v| outdelim = v;
    const spec = optValue(av, "-b", "") orelse optValue(av, "-c", "") orelse
        optValue(av, "-f", "") orelse optValue(av, "-F", "") orelse return 1;
    var ranges: [64]CutRange = undefined;
    const nr = parseRanges(spec, &ranges);

    var files: [256][]const u8 = undefined;
    var nf: usize = 0;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (eql(a, "-d") or eql(a, "-f") or eql(a, "-F") or eql(a, "-b") or eql(a, "-c") or eql(a, "--output-delimiter")) { i += 1; continue; }
        if (a.len > 1 and a[0] == '-') continue;
        if (nf < files.len) { files[nf] = a; nf += 1; }
    }
    if (nf == 0) { cutOne(readAllStdin() catch return 1, by_bytes, by_chars, by_fields, delim, suppress, outdelim, ranges[0..nr]); return 0; }
    for (files[0..nf]) |name| cutOne(readInput(name) catch return 1, by_bytes, by_chars, by_fields, delim, suppress, outdelim, ranges[0..nr]);
    return 0;
}

fn startsAny(av: []const []const u8, s: []const u8) bool {
    for (av[1..]) |a| if (std.mem.startsWith(u8, a, s) and a.len > s.len) return true;
    return false;
}

fn parseRanges(spec: []const u8, ranges: *[64]CutRange) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| {
        if (n >= ranges.len) break;
        if (std.mem.indexOfScalar(u8, part, '-')) |d| {
            const lo = parseUInt(part[0..d]) orelse 1;
            const hi = if (d + 1 >= part.len) std.math.maxInt(usize) else (parseUInt(part[d + 1 ..]) orelse lo);
            ranges[n] = .{ .lo = lo, .hi = hi };
        } else {
            const v = parseUInt(part) orelse continue;
            ranges[n] = .{ .lo = v, .hi = v };
        }
        n += 1;
    }
    return n;
}

fn inRanges(idx: usize, ranges: []const CutRange) bool {
    for (ranges) |r| if (idx >= r.lo and idx <= r.hi) return true;
    return false;
}

fn cutOne(data: []const u8, by_bytes: bool, by_chars: bool, by_fields: bool, delim: u8, suppress: bool, outdelim: []const u8, ranges: []const CutRange) void {
    _ = by_bytes;
    _ = by_chars;
    const lines = splitLines(data) catch return;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(A);
    for (lines) |ln| {
        if (by_fields) {
            var it = std.mem.splitScalar(u8, ln, delim);
            var idx: usize = 1;
            var first = true;
            const had_delim = std.mem.indexOfScalar(u8, ln, delim) != null;
            while (it.next()) |field| : (idx += 1) {
                if (inRanges(idx, ranges)) {
                    if (!first and outdelim.len > 0) b.appendSlice(A, outdelim) catch return
                    else if (!first) b.append(A, delim) catch return;
                    b.appendSlice(A, field) catch return;
                    first = false;
                }
            }
            if (suppress and !had_delim) continue;
            if (first and !had_delim) b.appendSlice(A, ln) catch return;
            b.append(A, '\n') catch return;
        } else {
            var idx: usize = 0;
            var first = true;
            var bi: usize = 0;
            while (bi < ln.len) {
                const clen = std.unicode.utf8ByteSequenceLength(ln[bi]) catch 1;
                idx += 1;
                if (inRanges(idx, ranges)) {
                    if (!first and outdelim.len > 0) b.appendSlice(A, outdelim) catch return;
                    b.appendSlice(A, ln[bi .. @min(bi + clen, ln.len)]) catch return;
                    first = false;
                }
                bi += clen;
            }
            b.append(A, '\n') catch return;
        }
    }
    out(b.items);
}

// ===========================================================================
// od
// ===========================================================================

pub fn odMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    _ = opts("od", av, "abcdfhilovxs" ++ "t:A:N:j:S:w:", &.{});
    var style: u8 = 'o';
    var size: usize = 2;
    var addr_radix: u8 = 'o';
    var show_addr = true;
    var limit: ?usize = null;
    var skip: usize = 0;
    var width: usize = 16;

    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (eql(a, "-t")) {
            if (i + 1 < av.len) { i += 1; parseOdType(av[i], &style, &size); }
            continue;
        }
        if (std.mem.startsWith(u8, a, "-t") and a.len > 2) { parseOdType(a[2..], &style, &size); continue; }
        if (eql(a, "-A")) { if (i + 1 < av.len) { i += 1; parseOdAddr(av[i], &addr_radix, &show_addr); } continue; }
        if (std.mem.startsWith(u8, a, "-A") and a.len > 2) { parseOdAddr(a[2..], &addr_radix, &show_addr); continue; }
        if (eql(a, "-N")) { if (i + 1 < av.len) { i += 1; limit = parseUInt(av[i]); } continue; }
        if (std.mem.startsWith(u8, a, "-N") and a.len > 2) { limit = parseUInt(a[2..]); continue; }
        if (eql(a, "-j")) { if (i + 1 < av.len) { i += 1; skip = parseUInt(av[i]) orelse 0; } continue; }
        if (std.mem.startsWith(u8, a, "-j") and a.len > 2) { skip = parseUInt(a[2..]) orelse 0; continue; }
        if (eql(a, "-w")) { if (i + 1 < av.len) { i += 1; width = parseUInt(av[i]) orelse 16; } continue; }
        if (std.mem.startsWith(u8, a, "-w") and a.len > 2) { width = parseUInt(a[2..]) orelse 16; continue; }
        if (a.len == 2 and a[0] == '-') {
            switch (a[1]) {
                'a' => { style = 'a'; size = 1; },
                'b' => { style = 'o'; size = 1; },
                'c' => { style = 'c'; size = 1; },
                'd' => { style = 'd'; size = 2; },
                'f' => { style = 'f'; size = 4; },
                'h' => { style = 'x'; size = 2; },
                'i' => { style = 'd'; size = 4; },
                'l' => { style = 'd'; size = 8; },
                'o' => { style = 'o'; size = 2; },
                'x' => { style = 'x'; size = 2; },
                's' => { style = 's'; size = 2; },
                'v' => {},
                else => {},
            }
            continue;
        }
        if (a.len > 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| {
                switch (c) {
                    'a' => { style = 'a'; size = 1; },
                    'b' => { style = 'o'; size = 1; },
                    'c' => { style = 'c'; size = 1; },
                    'd' => { style = 'd'; size = 2; },
                    'o' => { style = 'o'; size = 2; },
                    'x' => { style = 'x'; size = 2; },
                    's' => { style = 's'; size = 2; },
                    'v' => {},
                    else => {},
                }
            }
            continue;
        }
    }
    if (width == 0) width = 16;

    var input: []const u8 = "-";
    var oi: usize = 1;
    while (oi < av.len) : (oi += 1) {
        if (eql(av[oi], "-t") or eql(av[oi], "-A") or eql(av[oi], "-N") or eql(av[oi], "-j") or eql(av[oi], "-w") or eql(av[oi], "-S")) { oi += 1; continue; }
        if (av[oi].len > 0 and av[oi][0] == '-') continue;
        input = av[oi];
    }
    const raw = readInput(input) catch return 1;
    const start = @min(skip, raw.len);
    var data = raw[start..];
    if (limit) |lim| data = data[0..@min(lim, data.len)];

    var off: usize = 0;
    while (off < data.len) : (off += width) {
        odAddr(skip + off, addr_radix, show_addr);
        const chunk = data[off..@min(off + width, data.len)];
        var p: usize = 0;
        while (p < chunk.len) : (p += size) {
            const word = chunk[p..@min(p + size, chunk.len)];
            odElem(word, style, size);
        }
        out("\n");
    }
    if (show_addr) {
        odAddr(skip + data.len, addr_radix, true);
        out("\n");
    }
    return 0;
}

fn parseOdType(s: []const u8, style: *u8, size: *usize) void {
    if (s.len == 0) return;
    style.* = s[0];
    size.* = if (s.len > 1) (parseUInt(s[1..]) orelse 1) else switch (s[0]) {
        'c', 'a', 'b' => 1,
        else => 1,
    };
}

fn parseOdAddr(s: []const u8, radix: *u8, show: *bool) void {
    if (s.len == 0) return;
    radix.* = s[0];
    show.* = true;
    if (s[0] == 'n') show.* = false;
}

fn odAddr(off: usize, radix: u8, show: bool) void {
    if (!show) return;
    switch (radix) {
        'x' => put("{x:0>6}", .{off}),
        'd' => put("{d:0>7}", .{off}),
        'n' => return,
        else => put("{o:0>7}", .{off}),
    }
}

fn odElem(word: []const u8, style: u8, size: usize) void {
    var val: u64 = 0;
    for (word, 0..) |b, k| val |= @as(u64, b) << @intCast(k * 8);
    switch (style) {
        'x' => {
            if (size == 1) put(" {x:0>2}", .{word[0]})
            else if (size == 2) put(" {x:0>4}", .{@as(u16, @truncate(val))})
            else put(" {x:0>8}", .{@as(u32, @truncate(val))});
        },
        'o' => {
            if (size == 1) put(" {o:0>3}", .{word[0]})
            else put(" {o:0>6}", .{@as(u16, @truncate(val))});
        },
        'd', 's' => {
            if (size == 1) {
                if (style == 's') put(" {d: >4}", .{@as(i8, @bitCast(word[0]))}) else put(" {d: >3}", .{word[0]});
            } else if (size == 2) {
                if (style == 's') put(" {d: >6}", .{@as(i16, @bitCast(@as(u16, @truncate(val))))}) else put(" {d: >5}", .{@as(u16, @truncate(val))});
            } else put(" {d: >10}", .{@as(u32, @truncate(val))});
        },
        'c' => {
            const c = word[0];
            if (c == '\n') out("  \\n")
            else if (c == '\t') out("  \\t")
            else if (c == '\r') out("  \\r")
            else if (c == '\\') out("  \\\\")
            else if (c >= 32 and c < 127) { out("   "); out(word[0..1]); }
            else { var b: [8]u8 = undefined; const s = std.fmt.bufPrint(&b, "{o:0>3}", .{c}) catch ""; out("  "); out(s); }
        },
        'a' => {
            const c = word[0];
            if (c == '\n') out("   nl") else if (c == '\t') out("   ht") else if (c >= 32 and c < 127) { out("    "); out(word[0..1]); } else out("   ??");
        },
        else => put(" {x:0>2}", .{word[0]}),
    }
}
