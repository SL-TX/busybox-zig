//! Task 26 — editor applets: cmp, diff, ed, patch, sed, awk and vi.
//!
//! cmp/diff/patch hold their own byte/line comparison and unified-patch
//! engines; awk and sed are re-exported from the coreutils module and hardened
//! in Task 26; ed and vi are driven through the harness pty helper.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const coreutils = @import("coreutils");
pub const edvi = @import("edvi.zig");

pub const init = struct {
    pub fn init() void {}
};

const a = std.heap.page_allocator;

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const out = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

fn prog(argv: []const []const u8) []const u8 {
    const name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "busybox";
    bb.env.setProgramName(name);
    return name;
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn dieUsage(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn badOption(name: []const u8, ch: u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("invalid option -- '{c}'", .{ch});
    dieUsage(name);
}

fn badLong(name: []const u8, text: []const u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("unrecognized option '--{s}'", .{text});
    dieUsage(name);
}

fn missingArg(name: []const u8, ch: u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("option requires an argument -- '{c}'", .{ch});
    dieUsage(name);
}

fn number(name: []const u8, text: []const u8) u64 {
    const n = bb.util.xatou(text) catch {
        bb.messages.program_name = name;
        bb.messages.plainMsg("invalid number '{s}'", .{text});
        std.process.exit(1);
    };
    return n;
}

fn writeFd(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        off += n;
    }
}

fn writeStdout(bytes: []const u8) void {
    writeFd(1, bytes);
}

fn zpath(path: []const u8) ?[:0]u8 {
    return a.dupeSentinel(u8, path, 0) catch null;
}

fn readAll(path: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    defer a.free(z);
    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    const f: linux.fd_t = @intCast(fd);
    defer _ = linux.close(f);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(f, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(a, buf[0..@intCast(n)]) catch return null;
    }
    return list.toOwnedSlice(a) catch null;
}

fn readStdin() []u8 {
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(a, buf[0..@intCast(n)]) catch break;
    }
    return list.toOwnedSlice(a) catch &.{};
}

fn statOk(path: []const u8) bool {
    const z = a.dupeSentinel(u8, path, 0) catch return false;
    defer a.free(z);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z.ptr, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    return linux.errno(rc) == .SUCCESS;
}

// ----------------------------------------------------------------------- cmp

pub fn cmp_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var list_all = false;
    var quiet = false;
    var limit: ?u64 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                'l' => list_all = true,
                's' => quiet = true,
                'n' => {
                    var value: []const u8 = undefined;
                    if (j + 1 < tok.len) value = tok[j + 1 ..] else if (i + 1 < args.len) {
                        i += 1;
                        value = args[i];
                    } else missingArg(name, 'n');
                    limit = number(name, value);
                    break;
                },
                else => badOption(name, tok[j]),
            }
        }
    }
    const pos = args[i..];
    if (pos.len == 0) dieUsage(name);
    const first = readAll(pos[0]) orelse {
        bb.messages.program_name = name;
        bb.messages.errorMsg(2, "{s}", .{pos[0]});
        return 2;
    };
    const second: []u8 = if (pos.len > 1) (readAll(pos[1]) orelse {
        bb.messages.program_name = name;
        bb.messages.errorMsg(2, "{s}", .{pos[1]});
        return 2;
    }) else readStdin();
    var skip1: usize = 0;
    var skip2: usize = 0;
    if (pos.len > 2) skip1 = @intCast(number(name, pos[2]));
    if (pos.len > 3) skip2 = @intCast(number(name, pos[3]));
    const max: usize = if (limit) |n| @intCast(n) else @min(first.len, second.len);
    var n1 = @min(skip1 + max, first.len);
    var n2 = @min(skip2 + max, second.len);
    const count = @min(n1 - skip1, n2 - skip2);
    n1 = skip1 + count;
    n2 = skip2 + count;

    var line: usize = 1;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const c1 = first[skip1 + k];
        const c2 = second[skip2 + k];
        if (c1 == '\n') line += 1;
        if (c1 == c2) continue;
        if (quiet) return 1;
        if (list_all) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{d} {o:0>3} {o:0>3}\n", .{ skip1 + k + 1, c1, c2 }) catch continue;
            writeStdout(msg);
        } else {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} {s} differ: byte {d}, line {d}\n", .{ pos[0], if (pos.len > 1) pos[1] else "-", k + 1, line }) catch continue;
            writeStdout(msg);
            return 1;
        }
    }
    return if (foundDiff(list_all, quiet, first, second, skip1, skip2, count)) 1 else 0;
}

fn foundDiff(list_all: bool, quiet: bool, f1: []const u8, f2: []const u8, s1: usize, s2: usize, count: usize) bool {
    _ = quiet;
    _ = list_all;
    for (0..count) |k| if (f1[s1 + k] != f2[s2 + k]) return true;
    return false;
}

// ----------------------------------------------------------------------- diff

const DiffLine = struct { text: []const u8, key: []u8 };

pub fn normalizeLine(text: []const u8, ignore_case: bool, ignore_space: bool, all_space: bool, buf: []u8) []u8 {
    var n: usize = 0;
    var last_space = false;
    for (text) |c| {
        var ch = c;
        if (ignore_case) ch = std.ascii.toLower(ch);
        if (all_space and std.ascii.isWhitespace(ch)) {
            if (!last_space) {
                buf[n] = ' ';
                n += 1;
            }
            last_space = true;
            continue;
        }
        if (ignore_space and std.ascii.isWhitespace(ch)) {
            if (!last_space) {
                buf[n] = ' ';
                n += 1;
            }
            last_space = true;
            continue;
        }
        buf[n] = ch;
        n += 1;
        last_space = false;
    }
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    return buf[0..n];
}

fn splitLines(data: []const u8) [][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        list.append(a, line) catch {};
    }
    return list.toOwnedSlice(a) catch &.{};
}

pub fn nonBlank(lines: []const []const u8) [][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        if (std.mem.trim(u8, line, " \t\r").len != 0) result.append(a, line) catch {};
    }
    return result.toOwnedSlice(a) catch &.{};
}

fn appendFmt(list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    list.appendSlice(a, text) catch {};
}

fn rangeText(list: *std.ArrayList(u8), start: usize, count: usize) void {
    appendFmt(list, "{d}", .{if (count == 0) start else start + 1});
    if (count != 1) appendFmt(list, ",{d}", .{count});
}

fn unifiedDiff(out_writer: *std.ArrayList(u8), alines: []const []const u8, blines: []const []const u8, akeys: []const []u8, bkeys: []const []u8, label1: []const u8, label2: []const u8, context: usize) void {
    const an = alines.len;
    const bn = blines.len;
    // LCS table (memory bounded by input size used in parity cases).
    const table = a.alloc(usize, (an + 1) * (bn + 1)) catch return;
    defer a.free(table);
    for (0..an + 1) |ii| table[ii * (bn + 1)] = 0;
    for (0..bn + 1) |jj| table[jj] = 0;
    for (0..an) |ii| {
        for (0..bn) |jj| {
            table[(ii + 1) * (bn + 1) + jj + 1] = if (std.mem.eql(u8, akeys[ii], bkeys[jj]))
                table[ii * (bn + 1) + jj] + 1
            else
                @max(table[ii * (bn + 1) + jj + 1], table[(ii + 1) * (bn + 1) + jj]);
        }
    }
    const Op = struct { kind: u8, line: []const u8 };
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(a);
    var rev: std.ArrayList(Op) = .empty;
    defer rev.deinit(a);
    var i: usize = an;
    var j: usize = bn;
    while (i > 0 and j > 0) {
        if (std.mem.eql(u8, akeys[i - 1], bkeys[j - 1])) {
            rev.append(a, .{ .kind = ' ', .line = alines[i - 1] }) catch {};
            i -= 1;
            j -= 1;
        } else if (table[(i - 1) * (bn + 1) + j] > table[i * (bn + 1) + j - 1]) {
            rev.append(a, .{ .kind = '-', .line = alines[i - 1] }) catch {};
            i -= 1;
        } else {
            rev.append(a, .{ .kind = '+', .line = blines[j - 1] }) catch {};
            j -= 1;
        }
    }
    while (i > 0) {
        i -= 1;
        rev.append(a, .{ .kind = '-', .line = alines[i] }) catch {};
    }
    while (j > 0) {
        j -= 1;
        rev.append(a, .{ .kind = '+', .line = blines[j] }) catch {};
    }
    var ri: usize = rev.items.len;
    while (ri > 0) {
        ri -= 1;
        ops.append(a, rev.items[ri]) catch {};
    }

    appendFmt(out_writer, "--- {s}\n+++ {s}\n", .{ label1, label2 });
    var idx: usize = 0;
    while (idx < ops.items.len) {
        while (idx < ops.items.len and ops.items[idx].kind == ' ') idx += 1;
        if (idx >= ops.items.len) break;
        const hstart = idx - @min(context, idx);
        var hend = idx;
        while (hend < ops.items.len) : (hend += 1) {
            if (ops.items[hend].kind != ' ' and hend + 1 < ops.items.len and ops.items[hend + 1].kind == ' ') {
                var tail = hend + 1;
                var run: usize = 0;
                while (tail < ops.items.len and ops.items[tail].kind == ' ') : (tail += 1) run += 1;
                if (run > 2 * context) {
                    hend += 1 + context;
                    break;
                }
            }
        }
        var acount: usize = 0;
        var bcount: usize = 0;
        var astart: usize = 0;
        var bstart: usize = 0;
        var seen = false;
        for (ops.items[hstart..hend], 0..) |op, k| {
            if (!seen and op.kind != '+') {
                astart = k;
                seen = true;
            }
            if (op.kind != '+') acount += 1;
            if (op.kind != '-') bcount += 1;
        }
        for (ops.items[0..hstart]) |op| {
            if (op.kind != '+') astart += 1;
            if (op.kind != '-') bstart += 1;
        }
        out_writer.appendSlice(a, "@@ -") catch {};
        rangeText(out_writer, astart, acount);
        out_writer.appendSlice(a, " +") catch {};
        rangeText(out_writer, bstart, bcount);
        out_writer.appendSlice(a, " @@\n") catch {};
        for (ops.items[hstart..hend]) |op| {
            out_writer.append(a, op.kind) catch {};
            out_writer.appendSlice(a, op.line) catch {};
            out_writer.append(a, '\n') catch {};
        }
        idx = hend;
    }
}

fn expandTabsLine(list: *std.ArrayList(u8), line: []const u8) void {
    var col: usize = 0;
    for (line) |c| {
        if (c == '\t') {
            const spaces = 8 - (col % 8);
            var k: usize = 0;
            while (k < spaces) : (k += 1) list.append(a, ' ') catch {};
            col += spaces;
        } else {
            list.append(a, c) catch {};
            col += 1;
        }
    }
}

fn postProcessDiff(text: []const u8, tab_prefix: bool, expand_tabs: bool) []const u8 {
    if (!tab_prefix and !expand_tabs) return text;
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) out.append(a, '\n') catch {};
        first = false;
        const header = std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "@@ ");
        const body = line.len > 0 and !header and (line[0] == ' ' or line[0] == '-' or line[0] == '+');
        if (body) out.append(a, line[0]) catch {};
        if (body and tab_prefix) out.append(a, '\t') catch {};
        const content = if (body) line[1..] else line;
        if (expand_tabs) expandTabsLine(&out, content) else out.appendSlice(a, content) catch {};
    }
    return out.toOwnedSlice(a) catch text;
}

const DiffOpts = struct {
    quick: bool = false,
    same: bool = false,
    ignore_case: bool = false,
    ignore_space: bool = false,
    all_space: bool = false,
    blank: bool = false,
    force_text: bool = false,
    force_empty: bool = false,
    recursive: bool = false,
    start_file: ?[]const u8 = null,
    tab_prefix: bool = false,
    expand_tabs: bool = false,
    context: usize = 3,
    labels: [2][]const u8 = .{ "", "" },
    nlabels: usize = 0,
};

fn hasBinary(d1: []const u8, d2: []const u8) bool {
    const n = @min(d1.len, d2.len);
    for (0..n) |k| if (d1[k] == 0 or d2[k] == 0) return true;
    return false;
}

/// Compare one pair of files and print the result. Returns 1 when different.
fn diffPair(name: []const u8, f1: []const u8, f2: []const u8, label1: []const u8, label2: []const u8, opts: DiffOpts) c_int {
    const d1 = readAll(f1) orelse "";
    const d2 = readAll(f2) orelse "";
    var differ = !std.mem.eql(u8, d1, d2);
    var a_lines = splitLines(d1);
    var b_lines = splitLines(d2);
    if (opts.blank) {
        a_lines = nonBlank(a_lines);
        b_lines = nonBlank(b_lines);
    }
    var same_content = !differ;
    if (opts.ignore_case or opts.ignore_space or opts.all_space) {
        if (a_lines.len == b_lines.len) {
            same_content = true;
            for (a_lines, b_lines) |x, y| {
                var bx: [4096]u8 = undefined;
                var by: [4096]u8 = undefined;
                const kx = normalizeLine(x, opts.ignore_case, opts.ignore_space, opts.all_space, &bx);
                const ky = normalizeLine(y, opts.ignore_case, opts.ignore_space, opts.all_space, &by);
                if (!std.mem.eql(u8, kx, ky)) {
                    same_content = false;
                    break;
                }
            }
            differ = !same_content;
        }
    }
    if (!differ) {
        if (opts.same) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Files {s} and {s} are identical\n", .{ label1, label2 }) catch "";
            writeStdout(msg);
        }
        return 0;
    }
    if (opts.quick or (hasBinary(d1, d2) and !opts.force_text)) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Files {s} and {s} differ\n", .{ label1, label2 }) catch "";
        writeStdout(msg);
        return 1;
    }
    const akeys = a.alloc([]u8, a_lines.len) catch return 1;
    const bkeys = a.alloc([]u8, b_lines.len) catch return 1;
    for (a_lines, 0..) |line, k| {
        const buf = a.alloc(u8, line.len + 2) catch return 1;
        akeys[k] = normalizeLine(line, opts.ignore_case, opts.ignore_space, opts.all_space, buf);
    }
    for (b_lines, 0..) |line, k| {
        const buf = a.alloc(u8, line.len + 2) catch return 1;
        bkeys[k] = normalizeLine(line, opts.ignore_case, opts.ignore_space, opts.all_space, buf);
    }
    var result_text: std.ArrayList(u8) = .empty;
    unifiedDiff(&result_text, a_lines, b_lines, akeys, bkeys, label1, label2, opts.context);
    writeStdout(postProcessDiff(result_text.items, opts.tab_prefix, opts.expand_tabs));
    _ = name;
    return 1;
}

fn isDir(path: []const u8) bool {
    const z = zpath(path) orelse return false;
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z.ptr, 0, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return false;
    return (st.mode & linux.S.IFMT) == linux.S.IFDIR;
}

fn diffDirs(name: []const u8, f1: []const u8, f2: []const u8, opts: DiffOpts) c_int {
    var names: std.ArrayList([]const u8) = .empty;
    const Ctx = struct { list: *std.ArrayList([]const u8) };
    var ctx = Ctx{ .list = &names };
    const cb: bb.file.EntryCallback = struct {
        fn call(entry: []const u8, opaque_ctx: ?*anyopaque) anyerror!void {
            const c: *Ctx = @ptrCast(@alignCast(opaque_ctx.?));
            try c.list.append(a, try a.dupe(u8, entry));
        }
    }.call;
    if (zpath(f1)) |f1z| bb.file.forEachEntry(f1z.ptr, cb, &ctx) catch {};
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    var status: c_int = 0;
    for (names.items) |entry| {
        if (opts.start_file) |sf| {
            if (!std.mem.eql(u8, sf, entry)) continue;
        }
        const z1 = std.fmt.allocPrint(a, "{s}/{s}", .{ f1, entry }) catch continue;
        const z2 = std.fmt.allocPrint(a, "{s}/{s}", .{ f2, entry }) catch continue;
        if (isDir(z1) or isDir(z2)) continue;
        if (!statOk(z2)) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Only in {s}: {s}\n", .{ f1, entry }) catch "";
            writeStdout(msg);
            status = 1;
            continue;
        }
        const rc = diffPair(name, z1, z2, z1, z2, opts);
        if (rc != 0) status = rc;
    }
    return status;
}

pub fn diff_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var opts = DiffOpts{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (eq(tok, "--no-dereference")) continue;
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            switch (ch) {
                'a' => opts.force_text = true,
                'd' => {}, // search heuristic only; same final hunks for these cases
                'N' => opts.force_empty = true,
                'r' => opts.recursive = true,
                'T' => opts.tab_prefix = true,
                't' => opts.expand_tabs = true,
                'q' => opts.quick = true,
                's' => opts.same = true,
                'i' => opts.ignore_case = true,
                'b' => opts.ignore_space = true,
                'w' => opts.all_space = true,
                'B' => opts.blank = true,
                'L', 'U', 'S' => {
                    var value: []const u8 = undefined;
                    if (j + 1 < tok.len) value = tok[j + 1 ..] else if (i + 1 < args.len) {
                        i += 1;
                        value = args[i];
                    } else missingArg(name, ch);
                    if (ch == 'L') {
                        if (opts.nlabels < 2) {
                            opts.labels[opts.nlabels] = value;
                            opts.nlabels += 1;
                        }
                    } else if (ch == 'U') {
                        opts.context = @intCast(number(name, value));
                    } else {
                        opts.start_file = value;
                        opts.recursive = true;
                    }
                    break;
                },
                else => badOption(name, ch),
            }
        }
    }
    if (i + 1 >= args.len) dieUsage(name);
    const f1 = args[i];
    const f2 = args[i + 1];
    var f1_exists = statOk(f1);
    var f2_exists = statOk(f2);
    if (opts.force_empty) {
        // -N treats missing operands as empty files for the comparison.
        if (!f1_exists or !f2_exists) {
            const empty1 = !f1_exists;
            const empty2 = !f2_exists;
            const rc = diffPair(name, if (empty1) "/dev/null" else f1, if (empty2) "/dev/null" else f2, f1, f2, opts);
            return rc;
        }
    }
    if (!f1_exists) {
        bb.messages.program_name = name;
        bb.messages.errorMsg(2, "can't stat '{s}'", .{f1});
        return 2;
    }
    if (!f2_exists) {
        bb.messages.program_name = name;
        bb.messages.errorMsg(2, "can't stat '{s}'", .{f2});
        return 2;
    }
    _ = &f1_exists;
    _ = &f2_exists;
    if (opts.recursive and isDir(f1) and isDir(f2)) return diffDirs(name, f1, f2, opts);
    const label1 = if (opts.nlabels > 0) opts.labels[0] else f1;
    const label2 = if (opts.nlabels > 1) opts.labels[1] else f2;
    return diffPair(name, f1, f2, label1, label2, opts);
}

// ---------------------------------------------------------------------- patch

const Hunk = struct {
    a_start: usize,
    a_count: usize,
    b_start: usize,
    b_count: usize,
    body: [][]const u8,
};

pub fn stripPath(path: []const u8, strip: usize) []const u8 {
    var result = path;
    var n: usize = 0;
    while (n < strip) : (n += 1) {
        const slash = std.mem.indexOfScalar(u8, result, '/') orelse return result;
        result = result[slash + 1 ..];
    }
    return result;
}

pub fn ed_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return edvi.ed_main(argc, argv);
}

pub fn vi_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return edvi.vi_main(argc, argv);
}

pub fn patch_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var reverse = false;
    var strip: usize = 0;
    var diff_file: ?[]const u8 = null;
    var dry_run = false;
    var erase_empty = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (eq(tok, "--dry-run")) {
            dry_run = true;
            continue;
        }
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                'R' => reverse = true,
                'N' => {}, // verified no-op for already-applied patches
                'E' => erase_empty = true,
                'p', 'i' => |ch| {
                    var value: []const u8 = undefined;
                    if (j + 1 < tok.len) value = tok[j + 1 ..] else if (i + 1 < args.len) {
                        i += 1;
                        value = args[i];
                    } else missingArg(name, ch);
                    if (ch == 'p') strip = @intCast(number(name, value)) else diff_file = value;
                    break;
                },
                else => badOption(name, tok[j]),
            }
        }
    }
    if (i >= args.len and diff_file == null) return 0;

    var patch_data: []u8 = undefined;
    if (diff_file) |path| {
        patch_data = readAll(path) orelse {
            bb.messages.program_name = name;
            bb.messages.errorMsg(2, "can't open '{s}'", .{path});
            return 1;
        };
    } else {
        patch_data = readStdin();
    }
    const p_lines = splitLines(patch_data);
    var target: ?[]const u8 = if (i < args.len) args[i] else null;
    var hunks: std.ArrayList(Hunk) = .empty;
    var k: usize = 0;
    while (k < p_lines.len) : (k += 1) {
        const line = p_lines[k];
        if (std.mem.startsWith(u8, line, "+++ ") and target == null) {
            target = stripPath(std.mem.trim(u8, line[4..], " \t"), strip);
        }
        if (!std.mem.startsWith(u8, line, "@@")) continue;
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const plus = std.mem.indexOfScalarPos(u8, line, dash, '+') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, line, plus, '@') orelse continue;
        var as: usize = 0;
        var ac: usize = 1;
        var bs: usize = 0;
        var bc: usize = 1;
        var it1 = std.mem.splitScalar(u8, line[dash + 1 .. plus], ',');
        as = number(name, std.mem.trim(u8, it1.next() orelse "0", " "));
        if (it1.next()) |v| ac = @intCast(number(name, std.mem.trim(u8, v, " ")));
        var it2 = std.mem.splitScalar(u8, line[plus + 1 .. close], ',');
        bs = number(name, std.mem.trim(u8, it2.next() orelse "0", " "));
        if (it2.next()) |v| bc = @intCast(number(name, std.mem.trim(u8, v, " ")));
        var body: std.ArrayList([]const u8) = .empty;
        k += 1;
        while (k < p_lines.len and !std.mem.startsWith(u8, p_lines[k], "@@") and !std.mem.startsWith(u8, p_lines[k], "--- ")) : (k += 1) {
            body.append(a, p_lines[k]) catch {};
        }
        hunks.append(a, .{ .a_start = @intCast(as), .a_count = ac, .b_start = @intCast(bs), .b_count = bc, .body = body.toOwnedSlice(a) catch &.{} }) catch {};
        k -= 1;
    }
    if (target == null) return 0;
    const file_name = target.?;
    const data = readAll(file_name) orelse {
        bb.messages.program_name = name;
        bb.messages.errorMsg(2, "can't open '{s}'", .{file_name});
        return 1;
    };
    const lines = splitLines(data);
    var result: std.ArrayList([]const u8) = .empty;
    var src: usize = 0;
    var hunk_no: usize = 0;
    for (hunks.items) |h| {
        hunk_no += 1;
        const start = (if (reverse) h.b_start else h.a_start) -| 1;
        while (src < start and src < lines.len) : (src += 1) result.append(a, lines[src]) catch {};
        var matched = true;
        // `src` walks the revision we are patching; `other` walks the other
        // revision (only needed to keep the two line numbering schemes apart
        // when a hunk mixes context with additions/removals).
        var other: usize = (if (reverse) h.a_start else h.b_start) -| 1;
        for (h.body) |bline| {
            if (bline.len == 0 or (bline[0] != ' ' and bline[0] != '-' and bline[0] != '+')) continue;
            const from_source = switch (bline[0]) {
                ' ' => true,
                '-' => !reverse,
                '+' => reverse,
                else => false,
            };
            if (from_source) {
                if (src >= lines.len or !std.mem.eql(u8, std.mem.trimEnd(u8, bline[1..], "\r"), std.mem.trimEnd(u8, lines[src], "\r"))) {
                    matched = false;
                    break;
                }
                if (bline[0] == ' ') result.append(a, lines[src]) catch {};
                src += 1;
                other += 1;
            } else {
                result.append(a, bline[1..]) catch {};
                other += 1;
            }
        }
        if (!matched) {
            var pbuf: [512]u8 = undefined;
            const pmsg = std.fmt.bufPrint(&pbuf, "patching file {s}\n", .{file_name}) catch "";
            writeStdout(pmsg);
            var buf: [128]u8 = undefined;
            const hdr = std.fmt.bufPrint(&buf, "Hunk {d} FAILED 1/1.\n", .{hunk_no}) catch "";
            writeFd(2, hdr);
            for (h.body) |bline| {
                writeFd(2, bline);
                writeFd(2, "\n");
            }
            return 1;
        }
    }
    while (src < lines.len) : (src += 1) result.append(a, lines[src]) catch {};

    if (erase_empty and result.items.len == 0 and !dry_run) {
        const rz = zpath(file_name) orelse return 1;
        _ = linux.unlink(rz.ptr);
        var rbuf: [512]u8 = undefined;
        const rmsg = std.fmt.bufPrint(&rbuf, "removing {s}\n", .{file_name}) catch "";
        writeStdout(rmsg);
        return 0;
    }
    var pbuf2: [512]u8 = undefined;
    const pmsg2 = std.fmt.bufPrint(&pbuf2, "patching file {s}\n", .{file_name}) catch "";
    writeStdout(pmsg2);
    if (dry_run) return 0;
    var content: std.ArrayList(u8) = .empty;
    for (result.items) |line| {
        content.appendSlice(a, line) catch {};
        content.append(a, '\n') catch {};
    }
    const z = a.dupeSentinel(u8, file_name, 0) catch return 1;
    const fd = linux.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return 1;
    var off: usize = 0;
    while (off < content.items.len) {
        const n = linux.write(@intCast(fd), content.items.ptr + off, content.items.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        off += n;
    }
    _ = linux.close(@intCast(fd));
    return 0;
}
