//! Task 7a: simple coreutils applets, reference-faithful implementations.
//!
//! Each `xxxMain` is called through a thin `<name>_main` wrapper in main.zig,
//! so the coreutils module exposes exactly one main symbol per applet.
//! All diagnostics use libbb_zig helpers (messages/usage/getopt/env/path).

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const A = std.heap.page_allocator;
const LongOpt = bb.getopt.LongOpt;
const Options = bb.getopt.Options;

// --- generic helpers --------------------------------------------------------

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
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    out(s);
}

fn eput(comptime fmt: []const u8, args: anytype) void {
    var b: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    errout(s);
}

fn msg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

fn plain(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

fn openFd(path_z: [*:0]const u8, flags: linux.O, mode: linux.mode_t) ?linux.fd_t {
    const rc = linux.open(path_z, flags, mode);
    if (linux.errno(rc) != .SUCCESS) {
        bb.process.errno = @intFromEnum(linux.errno(rc));
        return null;
    }
    return @intCast(rc);
}

fn msgDie(errnum: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    bb.messages.errorMsgAndDie(errnum, fmt, args);
}

fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn opts(name: []const u8, av: []const []const u8, os: []const u8, longs: []const LongOpt) Options {
    return bb.getopt.getopt32(av, os, longs) catch usageDie(name);
}

fn flagged(o: Options, bit: u5) bool {
    return (o.flags & (@as(u32, 1) << bit)) != 0;
}

const Path = struct {
    buf: [4096:0]u8 = undefined,
    fn init(s: []const u8) !Path {
        var p: Path = .{};
        if (s.len >= p.buf.len) return error.NameTooLong;
        @memcpy(p.buf[0..s.len], s);
        p.buf[s.len] = 0;
        return p;
    }
    fn z(self: *const Path) [*:0]const u8 {
        return @ptrCast(&self.buf);
    }
};

fn readFd(fd: linux.fd_t) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(A);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        const e = linux.errno(n);
        if (e != .SUCCESS) {
            bb.process.errno = @intFromEnum(e);
            return error.ReadFailed;
        }
        if (n == 0) break;
        try list.appendSlice(A, buf[0..n]);
    }
    return list.toOwnedSlice(A);
}

fn readFile(path: []const u8) ![]u8 {
    const p = try Path.init(path);
    const fd = openFd(p.z(), .{ .ACCMODE = .RDONLY }, 0) orelse return error.OpenFailed;
    defer _ = linux.close(fd);
    return readFd(fd);
}

fn isDir(path: []const u8) bool {
    const p = Path.init(path) catch return false;
    const fd = openFd(p.z(), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) orelse return false;
    _ = linux.close(fd);
    return true;
}

fn pathExists(path: []const u8) bool {
    const p = Path.init(path) catch return false;
    return linux.errno(linux.access(p.z(), 0)) == .SUCCESS;
}

fn readWhole(name: []const u8) []u8 {
    if (std.mem.eql(u8, name, "-")) return readFd(0) catch &.{};
    return readFile(name) catch &.{};
}

fn errOpen(name: []const u8, errnum: c_int) void {
    msg(errnum, "can't open '{s}'", .{name});
}

fn openRead(name: []const u8) ?linux.fd_t {
    if (std.mem.eql(u8, name, "-")) return 0;
    const p = Path.init(name) catch return null;
    return openFd(p.z(), .{ .ACCMODE = .RDONLY }, 0);
}

fn durationNs(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var end = s.len;
    var mult: u64 = 1_000_000_000;
    switch (s[s.len - 1]) {
        's' => end -= 1,
        'm' => { end -= 1; mult = 60 * 1_000_000_000; },
        'h' => { end -= 1; mult = 3600 * 1_000_000_000; },
        'd' => { end -= 1; mult = 86400 * 1_000_000_000; },
        else => {},
    }
    if (end == 0 or s[0] == '-') return null;
    // Accept integer and decimal seconds.
    var whole: u64 = 0;
    var frac: u64 = 0;
    var scale: u64 = 1;
    var seen_dot = false;
    for (s[0..end]) |c| {
        if (c == '.' and !seen_dot) { seen_dot = true; continue; }
        if (c < '0' or c > '9') return null;
        if (seen_dot) {
            if (scale < 1_000_000_000) {
                frac = frac * 10 + (c - '0');
                scale *= 10;
            }
        } else whole = whole * 10 + (c - '0');
    }
    const secs = std.math.mul(u64, whole, mult) catch return null;
    const frac_ns = std.math.mul(u64, frac, mult) catch return null;
    return std.math.add(u64, secs, frac_ns / scale) catch null;
}

fn sleepNs(ns: u64) void {
    if (ns == 0) return;
    var remain = ns;
    while (remain > 0) {
        const chunk: u64 = @min(remain, 1_000_000_000);
        var req = linux.timespec{ .sec = @intCast(chunk / 1_000_000_000), .nsec = @intCast(chunk % 1_000_000_000) };
        var rem = linux.timespec{ .sec = 0, .nsec = 0 };
        _ = linux.nanosleep(&req, &rem);
        const left: u64 = @as(u64, @intCast(rem.sec)) * 1_000_000_000 + @as(u64, @intCast(rem.nsec));
        if (left == 0) break;
        remain -= chunk - left;
    }
}

fn numSuffix(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var end = s.len;
    var mult: u64 = 1;
    switch (s[s.len - 1]) {
        'b', 'B' => { end -= 1; mult = 512; },
        'k', 'K' => { end -= 1; mult = 1024; },
        'm', 'M' => { end -= 1; mult = 1024 * 1024; },
        else => {},
    }
    if (end == 0) return null;
    const n = std.fmt.parseInt(u64, s[0..end], 10) catch return null;
    return n * mult;
}

// --- escape sequence handling (echo/printf %b) ------------------------------

fn appendEscape(list: *std.ArrayList(u8), src: []const u8, idx: *usize) !void {
    // src[*idx] is the character after the backslash.
    const i = idx.*;
    if (i >= src.len) {
        try list.append(A, '\\');
        return;
    }
    var c = src[i];
    if (c == 'x') {
        var j = i + 1;
        var val: u32 = 0;
        var n: usize = 0;
        while (j < src.len and n < 2) : (j += 1) {
            const d = std.fmt.charToDigit(src[j], 16) catch break;
            val = val * 16 + d;
            n += 1;
        }
        if (n == 0) {
            try list.append(A, '\\');
            return;
        }
        idx.* = j - 1;
        try list.append(A, @intCast(val & 0xff));
        return;
    }
    if (c == '0' and i + 1 < src.len and src[i + 1] >= '0' and src[i + 1] <= '7') {
        idx.* += 1;
        c = src[idx.*];
    }
    if (c >= '0' and c <= '7') {
        var val: u32 = 0;
        var j = i;
        var n: usize = 0;
        while (j < src.len and n < 3 and src[j] >= '0' and src[j] <= '7') : (j += 1) {
            val = val * 8 + (src[j] - '0');
            n += 1;
        }
        idx.* = j - 1;
        try list.append(A, @intCast(val & 0xff));
        return;
    }
    const mapped: ?u8 = switch (c) {
        'a' => 7, 'b' => 8, 'e' => 27, 'f' => 12, 'n' => 10, 'r' => 13,
        't' => 9, 'v' => 11, '\\' => '\\', else => null,
    };
    if (mapped) |v| try list.append(A, v) else {
        try list.append(A, '\\');
        try list.append(A, c);
    }
}

// --- true / false -----------------------------------------------------------

pub fn trueMain(_: c_int, _: [*][*:0]const u8) c_int { return 0; }
pub fn falseMain(_: c_int, _: [*][*:0]const u8) c_int { return 1; }

// --- echo -------------------------------------------------------------------

pub fn echoMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    var no_nl = false;
    var escapes = false;
    var first: usize = 1;
    while (first < a.len and a[first].len > 1 and a[first][0] == '-') {
        var valid = true;
        for (a[first][1..]) |c| switch (c) {
            'n' => no_nl = true,
            'e' => escapes = true,
            'E' => {},
            else => valid = false,
        };
        if (!valid) break;
        first += 1;
    }
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(A);
    var stop_all = false;
    for (a[first..], 0..) |arg, k| {
        if (stop_all) break;
        if (k != 0) list.append(A, ' ') catch return 1;
        if (!escapes) {
            list.appendSlice(A, arg) catch return 1;
            continue;
        }
        var i: usize = 0;
        while (i < arg.len) {
            if (arg[i] == '\\' and i + 1 < arg.len) {
                if (arg[i + 1] == 'c') { stop_all = true; break; }
                var idx = i + 1;
                const before = list.items.len;
                appendEscape(&list, arg, &idx) catch return 1;
                i = idx + 1;
                if (list.items.len == before + 2 and list.items[before] == '\\') {
                    // Unknown escape: appendEscape emitted backslash + char.
                    i = idx + 1;
                }
                continue;
            }
            list.append(A, arg[i]) catch return 1;
            i += 1;
        }
    }
    if (!no_nl and !stop_all) list.append(A, '\n') catch return 1;
    out(list.items);
    return 0;
}

// --- printf -----------------------------------------------------------------

fn printfEscape(list: *std.ArrayList(u8), fmt: []const u8, i: *usize) !bool {
    if (i.* + 1 >= fmt.len) { try list.append(A, '\\'); return false; }
    if (fmt[i.* + 1] == 'c') return true;
    var idx = i.* + 1;
    try appendEscape(list, fmt, &idx);
    i.* = idx;
    return false;
}

fn writePadded(list: *std.ArrayList(u8), text: []const u8, width: usize, left: bool, pad_zero: bool) !void {
    if (width <= text.len) return list.appendSlice(A, text);
    const n = width - text.len;
    if (!left and pad_zero and text.len > 0 and (text[0] == '-' or text[0] == '+')) {
        try list.append(A, text[0]);
        for (0..n) |_| try list.append(A, '0');
        return list.appendSlice(A, text[1..]);
    }
    if (left) {
        try list.appendSlice(A, text);
        for (0..n) |_| try list.append(A, ' ');
    } else {
        for (0..n) |_| try list.append(A, if (pad_zero) '0' else ' ');
        try list.appendSlice(A, text);
    }
}

pub fn printfMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    var a = avFrom(argv, argc);
    if (a.len > 1 and std.mem.eql(u8, a[1], "--")) a = a[1..];
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    if (a.len < 2) usageDie(name);
    const fmt = a[1];
    var ai: usize = 2;
    var bad = false;
    printf_list = .empty;
    var stopped = false;
    while (!stopped) {
      var consumed_any = false;
      var i: usize = 0;
      while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c == '\\') {
            if (printfEscape(&printf_list, fmt, &i) catch false) { stopped = true; break; }
            continue;
        }
        if (c != '%') {
            printf_list.append(A, c) catch return 1;
            continue;
        }
        const start = i;
        i += 1;
        if (i >= fmt.len) {
            eput("{s}: %: invalid format\n", .{name});
            bad = true;
            break;
        }
        if (fmt[i] == '%') {
            printf_list.append(A, '%') catch return 1;
            continue;
        }
        if (fmt[i] == 'b') {
            i += 1;
            i -= 1;
            if (ai < a.len) {
                const s = a[ai]; ai += 1; consumed_any = true;
                var j: usize = 0;
                while (j < s.len) {
                    if (s[j] == '\\') {
                        if (j + 1 < s.len and s[j + 1] == 'c') break;
                        var idx = j + 1;
                        appendEscape(&printf_list, s, &idx) catch return 1;
                        j = idx + 1;
                    } else {
                        printf_list.append(A, s[j]) catch return 1;
                        j += 1;
                    }
                }
            }
            continue;
        }
        var left = false;
        var zero = false;
        var plus = false;
        var space = false;
        var alt = false;
        while (i < fmt.len and std.mem.indexOfScalar(u8, "-+ #0", fmt[i]) != null) : (i += 1) {
            switch (fmt[i]) {
                '-' => left = true,
                '0' => zero = true,
                '+' => plus = true,
                ' ' => space = true,
                '#' => alt = true,
                else => {},
            }
        }
        var width: usize = 0;
        if (i < fmt.len and fmt[i] == '*') {
            i += 1;
            if (ai < a.len) {
                width = @intCast(std.fmt.parseInt(i64, a[ai], 10) catch 0);
                ai += 1; consumed_any = true;
            }
        } else while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
            width = width * 10 + (fmt[i] - '0');
        }
        var prec: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            prec = 0;
            if (i < fmt.len and fmt[i] == '*') {
                i += 1;
                if (ai < a.len) {
                    prec = @intCast(std.fmt.parseInt(i64, a[ai], 10) catch 0);
                    ai += 1; consumed_any = true;
                }
            } else while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
                prec.? = prec.? * 10 + (fmt[i] - '0');
            }
        }
        while (i < fmt.len and (fmt[i] == 'l' or fmt[i] == 'h' or fmt[i] == 'z' or fmt[i] == 'L' or fmt[i] == 'j' or fmt[i] == 't')) : (i += 1) {}
        if (i >= fmt.len) {
            eput("{s}: {s}: invalid format\n", .{ name, fmt[start..] });
            bad = true;
            break;
        }
        const conv = fmt[i];
        i += 1;
        if (std.mem.indexOfScalar(u8, "diouxXfeEgGcs", conv) == null) {
            eput("{s}: {s}: invalid format\n", .{ name, fmt[start .. i] });
            bad = true;
            break;
        }
        const arg: []const u8 = if (ai < a.len) blk: { const r = a[ai]; ai += 1; consumed_any = true; break :blk r; } else "";
        var b: [512]u8 = undefined;
        var text: []const u8 = "";
        switch (conv) {
            's' => text = if (prec) |p| arg[0..@min(p, arg.len)] else arg,
            'c' => text = if (arg.len > 0) arg[0..1] else "",
            'd', 'i' => {
                const n = std.fmt.parseInt(i64, arg, 10) catch blk: { bad = true; break :blk @as(i64, 0); };
                var digits: [64]u8 = undefined;
                const neg = n < 0;
                const mag: u64 = if (neg) @intCast(-n) else @intCast(n);
                const ds = std.fmt.bufPrint(&digits, "{d}", .{mag}) catch "";
                var num: std.ArrayList(u8) = .empty;
                defer num.deinit(A);
                if (neg) num.append(A, '-') catch {} else if (plus) num.append(A, '+') catch {} else if (space) num.append(A, ' ') catch {};
                if (prec) |p| for (0..(p -| ds.len)) |_| num.append(A, '0') catch {};
                num.appendSlice(A, ds) catch {};
                text = A.dupe(u8, num.items) catch "";
            },
            'o', 'u', 'x', 'X' => {
                var n = std.fmt.parseInt(u64, arg, 0) catch blk: { bad = true; break :blk @as(u64, 0); };
                if (conv == 'u' or conv == 'o' or conv == 'x' or conv == 'X') {
                    if (arg.len > 0 and arg[0] == '-') n = @bitCast(std.fmt.parseInt(i64, arg, 10) catch @as(i64, 0));
                }
                _ = &n;
                var digits: [128]u8 = undefined;
                const mag = n;
                const ds = switch (conv) {
                    'X' => std.fmt.bufPrint(&digits, "{X}", .{mag}) catch "",
                    'o' => std.fmt.bufPrint(&digits, "{o}", .{mag}) catch "",
                    'x' => std.fmt.bufPrint(&digits, "{x}", .{mag}) catch "",
                    else => std.fmt.bufPrint(&digits, "{d}", .{mag}) catch "",
                };
                var num: std.ArrayList(u8) = .empty;
                defer num.deinit(A);
                if (alt and (conv == 'x' or conv == 'X') and mag != 0) {
                    num.append(A, '0') catch {};
                    num.append(A, if (conv == 'X') 'X' else 'x') catch {};
                } else if (alt and conv == 'o' and (ds.len == 0 or ds[0] != '0')) num.append(A, '0') catch {};
                if (prec) |p| for (0..(p -| ds.len)) |_| num.append(A, '0') catch {};
                num.appendSlice(A, ds) catch {};
                text = A.dupe(u8, num.items) catch "";
            },
            'f', 'e', 'E', 'g', 'G' => {
                const v = std.fmt.parseFloat(f64, arg) catch blk: { bad = true; break :blk @as(f64, 0); };
                const full = std.fmt.bufPrint(&b, "{d}", .{v}) catch "";
                if (prec) |p| {
                    if (std.mem.indexOfScalar(u8, full, '.')) |dot| {
                        const keep = @min(dot + 1 + p, full.len);
                        text = full[0..keep];
                    } else text = full;
                } else text = full;
            },
            else => {},
        }
        if (zero and prec == null and !left) zero = true;
        writePadded(&printf_list, text, width, left, zero) catch return 1;
        i -= 1;
      }
      if (!consumed_any or ai >= a.len or bad) break;
    }
    out(printf_list.items);
    return if (bad) 1 else 0;
}

var printf_list: std.ArrayList(u8) = .empty;

// --- pwd --------------------------------------------------------------------

pub fn pwdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("pwd", a, "LP", &.{});
    _ = o;
    const got = bb.path.xgetcwd(A) catch return 1;
    defer A.free(got);
    var cwd = got;
    while (cwd.len > 0 and cwd[cwd.len - 1] == 0) cwd = cwd[0 .. cwd.len - 1];
    put("{s}\n", .{cwd});
    return 0;
}

// --- basename / dirname -----------------------------------------------------

fn stripLastComponent(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";
    const trimmed = path[0..end];
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |p| {
        if (p == 0) return "/";
        return trimmed[0..p];
    }
    return ".";
}

fn baseNameStrip(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";
    const trimmed = path[0..end];
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |p| return trimmed[p + 1 ..];
    return trimmed;
}

pub fn basenameMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("basename", a, "^+as:", &.{});
    if (o.args.len == 0) usageDie("basename");
    const all = flagged(o, 0);
    var suffix: ?[]const u8 = if (flagged(o, 1)) o.optarg else null;
    if (!all and suffix == null and o.args.len > 2) usageDie("basename");
    if (!all and suffix == null and o.args.len == 2) suffix = o.args[1];
    const limit = if (all or flagged(o, 1)) o.args.len else 1;
    for (o.args[0..limit]) |arg| {
        var s = baseNameStrip(arg);
        if (suffix) |sfx| {
            if (s.len > sfx.len and std.mem.endsWith(u8, s, sfx)) s = s[0 .. s.len - sfx.len];
        }
        put("{s}\n", .{s});
    }
    return 0;
}

pub fn dirnameMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len != 2) usageDie("dirname");
    put("{s}\n", .{stripLastComponent(a[1])});
    return 0;
}

// --- cat --------------------------------------------------------------------

fn visibleByte(c: u8, flags: u32, buf: *[8]u8) []const u8 {
    const VIS_E = @as(u32, 1) << 0;
    const VIS_T = @as(u32, 1) << 1;
    const VIS_V = @as(u32, 1) << 2;
    if (c == '\n' and flags & VIS_E != 0) {
        buf[0] = '$'; buf[1] = '\n'; return buf[0..2];
    }
    if (c == '\t' and flags & VIS_T != 0) {
        buf[0] = '^'; buf[1] = 'I'; return buf[0..2];
    }
    if (flags & VIS_V == 0) {
        buf[0] = c;
        return buf[0..1];
    }
    if (c >= 0x80) {
        buf[0] = 'M'; buf[1] = '-';
        const lo = c - 0x80;
        if (lo < 32 or lo == 127) {
            return std.fmt.bufPrint(buf[2..], "^{c}", .{lo ^ 64}) catch "";
        }
        buf[2] = lo;
        return buf[0..3];
    }
    if (c == '\n' or c == '\t') {
        buf[0] = c; return buf[0..1];
    }
    if (c < 32 or c == 127) {
        buf[0] = '^'; buf[1] = c ^ 64;
        return buf[0..2];
    }
    buf[0] = c;
    return buf[0..1];
}

pub fn catMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("cat", a, "^etvAnbu", &.{});
    var files = o.args;
    if (files.len == 0) files = &.{"-"};
    const A_flag = flagged(o, 3);
    const vis: u32 = (if (A_flag or flagged(o, 0)) @as(u32, 1) else 0) |
        (if (A_flag or flagged(o, 1)) @as(u32, 2) else 0) |
        (if (A_flag or flagged(o, 2)) @as(u32, 4) else 0);
    const numbered = flagged(o, 4) or flagged(o, 5);
    var status: c_int = 0;
    for (files) |name| {
        const fd = openRead(name) orelse {
            errOpen(name, @intCast(bb.process.errno));
            status = 1;
            continue;
        };
        const data = readFd(fd) catch &.{};
        if (fd != 0) _ = linux.close(fd);
        if (vis != 0) {
            var vbuf: [8]u8 = undefined;
            for (data) |ch| out(visibleByte(ch, vis, &vbuf));
        } else if (numbered) {
            const only_nonempty = flagged(o, 5);
            var lineno: usize = 0;
            var at_start = true;
            var i: usize = 0;
            while (i < data.len) : (i += 1) {
                const ch = data[i];
                if (at_start and !(only_nonempty and ch == '\n')) {
                    lineno += 1;
                    put("{d: >6}\t", .{lineno});
                }
                at_start = ch == '\n';
                out(data[i .. i + 1]);
            }
        } else out(data);
    }
    return status;
}

// --- head / tail ------------------------------------------------------------

fn printHeader(name: []const u8, first: *bool) void {
    if (first.*) {
        put("==> {s} <==\n", .{name});
        first.* = false;
    } else put("\n==> {s} <==\n", .{name});
}

pub fn headMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a0 = avFrom(argv, argc);
    var a = a0;
    var count: usize = 10;
    var count_bytes = false;
    var negative = false;
    if (a.len > 1 and a[1].len > 1 and a[1][0] == '-' and std.ascii.isDigit(a[1][1])) {
        count = numSuffix(a[1][1..]) orelse 10;
        a = a[1..];
    }
    const o = opts("head", a, "n:c:qv", &.{});
    if (flagged(o, 1)) count_bytes = true;
    const want_num = flagged(o, 0) or flagged(o, 1);
    var numstr: ?[]const u8 = null;
    if (want_num) {
        // getopt32 keeps only the last optarg; re-scan for -n/-c values.
        numstr = o.optarg;
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            if ((std.mem.eql(u8, a[j], "-n") or std.mem.eql(u8, a[j], "-c")) and j + 1 < a.len) numstr = a[j + 1];
            if (a[j].len > 2 and a[j][0] == '-' and (a[j][1] == 'n' or a[j][1] == 'c')) numstr = a[j][2..];
        }
    }
    if (numstr) |ns| {
        if (ns.len > 0 and ns[0] == '-') { negative = true; count = numSuffix(ns[1..]) orelse 0; }
        else count = numSuffix(ns) orelse 10;
    }
    const quiet = flagged(o, 2);
    const always = flagged(o, 3);
    var files = o.args;
    if (files.len == 0) files = &.{"-"};
    const headers = if (quiet) false else if (always) true else files.len > 1;
    var first = true;
    var status: c_int = 0;
    for (files) |name| {
        const fd = openRead(name) orelse { msg(bb.process.errno, "{s}", .{name}); status = 1; continue; };
        const data = readFd(fd) catch &.{};
        if (fd != 0) _ = linux.close(fd);
        if (headers) printHeader(if (std.mem.eql(u8, name, "-")) "<stdin>" else name, &first);
        if (count == 0) continue;
        if (count_bytes and !negative) {
            out(data[0..@min(count, data.len)]);
        } else if (count_bytes and negative) {
            const skip = @min(count, data.len);
            out(data[skip..]);
        } else if (!negative) {
            var seen: usize = 0;
            var i: usize = 0;
            while (i < data.len) : (i += 1) {
                if (data[i] == '\n') {
                    seen += 1;
                    if (seen == count) { out(data[0 .. i + 1]); break; }
                }
            } else out(data);
        } else {
            var total: usize = 0;
            for (data) |ch| if (ch == '\n') { total += 1; };
            if (total <= count) continue;
            const want = total - count;
            if (want == 0) continue;
            var seen: usize = 0;
            for (data, 0..) |ch, i| {
                if (ch == '\n') {
                    seen += 1;
                    if (seen == want) { out(data[0 .. i + 1]); break; }
                }
            }
        }
    }
    return status;
}

pub fn tailMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a0 = avFrom(argv, argc);
    var a = a0;
    var count: usize = 10;
    var from_top = false;
    if (a.len > 1 and (a[1][0] == '+' or a[1][0] == '-') and a[1].len > 1 and std.ascii.isDigit(a[1][1])) {
        const ns = a[1];
        from_top = ns[0] == '+';
        count = numSuffix(ns[1..]) orelse 10;
        a = a[1..];
    }
    const o = opts("tail", a, "^fc:n:qvF s:+", &.{});
    var count_bytes = false;
    var numstr: ?[]const u8 = null;
    var j: usize = 1;
    while (j < a.len) : (j += 1) {
        if (std.mem.eql(u8, a[j], "-c") and j + 1 < a.len) { count_bytes = true; numstr = a[j + 1]; }
        if (std.mem.eql(u8, a[j], "-n") and j + 1 < a.len) numstr = a[j + 1];
        if (a[j].len > 2 and a[j][0] == '-' and a[j][1] == 'c') { count_bytes = true; numstr = a[j][2..]; }
        if (a[j].len > 2 and a[j][0] == '-' and a[j][1] == 'n') numstr = a[j][2..];
    }
    if (numstr) |ns| {
        if (ns.len > 0 and ns[0] == '+') { from_top = true; count = numSuffix(ns[1..]) orelse 10; }
        else { from_top = false; count = numSuffix(ns) orelse 10; }
    }
    const quiet = flagged(o, 3);
    const always = flagged(o, 4);
    var files = o.args;
    if (files.len == 0) files = &.{"-"};
    const headers = if (quiet) false else if (always) true else files.len > 1;
    var first = true;
    var status: c_int = 0;
    var opened: usize = 0;
    for (files) |name| {
        const fd = openRead(name) orelse { errOpen(name, @intCast(bb.process.errno)); status = 1; continue; };
        opened += 1;
        const data = readFd(fd) catch &.{};
        if (fd != 0) _ = linux.close(fd);
        if (headers) printHeader(if (std.mem.eql(u8, name, "-")) "<stdin>" else name, &first);
        if (count == 0 and !from_top) continue;
        if (count_bytes) {
            if (from_top) {
                const skip = @min(if (count > 0) count - 1 else 0, data.len);
                out(data[skip..]);
            } else {
                const skip = data.len - @min(count, data.len);
                out(data[skip..]);
            }
        } else {
            var lines: std.ArrayList([]const u8) = .empty;
            defer lines.deinit(A);
            var st: usize = 0;
            for (data, 0..) |ch, k| if (ch == '\n') { lines.append(A, data[st .. k + 1]) catch {}; st = k + 1; };
            if (st < data.len) lines.append(A, data[st..]) catch {};
            if (from_top) {
                const start = @min(if (count > 0) count - 1 else 0, lines.items.len);
                for (lines.items[start..]) |ln| out(ln);
            } else {
                const start = if (lines.items.len > count) lines.items.len - count else 0;
                for (lines.items[start..]) |ln| out(ln);
            }
        }
    }
    if (opened == 0) { plain("no files", .{}); return 1; }
    return status;
}

// --- wc ---------------------------------------------------------------------

const Counts = struct { lines: usize = 0, words: usize = 0, chars: usize = 0, bytes: usize = 0, longest: usize = 0 };

fn countData(data: []const u8) Counts {
    var c = Counts{ .bytes = data.len };
    var linepos: usize = 0;
    var in_word = false;
    for (data) |ch| {
        c.bytes += 0;
        if ((ch & 0xc0) != 0x80) c.chars += 1;
        if (ch == '\n') c.lines += 1;
        if (ch >= 32 and ch <= 126) {
            linepos += 1;
            if (!std.ascii.isWhitespace(ch)) { in_word = true; continue; }
        } else if (ch >= 9 and ch <= 13) {
            if (ch == '\t') linepos = (linepos | 7) + 1 else {
                if (linepos > c.longest) c.longest = linepos;
                if (ch != 11) linepos = 0;
            }
        } else continue;
        if (in_word) c.words += 1;
        in_word = false;
    }
    if (linepos > c.longest) c.longest = linepos;
    return c;
}

pub fn wcMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("wc", a, "lwmcL", &.{});
    var print_type = o.flags;
    if (print_type == 0) print_type = 0b01011; // lines, words, bytes
    var files = o.args;
    const stdin_mode = files.len == 0;
    if (stdin_mode) files = &.{"-"};
    var totals = Counts{};
    var status: c_int = 0;
    const one_opt = (print_type & (print_type - 1)) == 0;
    const one_file = files.len == 1;
    var data_store: []u8 = &.{};
    defer A.free(data_store);
    for (files) |name| {
        const fd = openRead(name) orelse { msg(bb.process.errno, "{s}", .{name}); status = 1; continue; };
        data_store = readFd(fd) catch &.{};
        if (fd != 0) _ = linux.close(fd);
        const c = countData(data_store);
        if (c.longest > totals.longest) totals.longest = c.longest;
        totals.lines += c.lines; totals.words += c.words; totals.chars += c.chars; totals.bytes += c.bytes;
        printCounts(print_type, c, name, one_opt and one_file, stdin_mode);
    }
    if (files.len > 1) printCounts(print_type, totals, "total", one_opt and one_file, false);
    return status;
}

fn printCounts(print_type: u32, c: Counts, name: []const u8, compact: bool, stdin_mode: bool) void {
    const vals = [_]usize{ c.lines, c.words, c.chars, c.bytes, c.longest };
    var first = true;
    for (vals, 0..) |v, k| {
        if ((print_type & (@as(u32, 1) << @as(u5, @intCast(k)))) == 0) continue;
        if (compact and first) put("{d}", .{v})
        else if (first) put("{d: >9}", .{v})
        else put(" {d: >9}", .{v});
        first = false;
    }
    if (stdin_mode) out("\n") else put(" {s}\n", .{name});
}

// --- tee --------------------------------------------------------------------

pub fn teeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("tee", a, "ia", &.{});
    var fds: [256]linux.fd_t = undefined;
    var n: usize = 0;
    fds[n] = 1; n += 1;
    var status: c_int = 0;
    for (o.args) |name| {
        if (std.mem.eql(u8, name, "-")) { fds[n] = 1; n += 1; continue; }
        const p = Path.init(name) catch { status = 1; continue; };
        const flags: linux.O = if (flagged(o, 1))
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
        else
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = openFd(p.z(), flags, 0o666) orelse {
            msg(bb.process.errno, "{s}", .{name});
            status = 1;
            continue;
        };
        fds[n] = fd; n += 1;
    }
    var buf: [16384]u8 = undefined;
    while (true) {
        const r = linux.read(0, &buf, buf.len);
        if (linux.errno(r) != .SUCCESS) { status = 1; break; }
        if (r == 0) break;
        for (fds[0..n]) |fd| {
            var done: usize = 0;
            while (done < r) {
                const w = linux.write(fd, buf[done..].ptr, r - done);
                if (linux.errno(w) != .SUCCESS) { status = 1; break; }
                done += w;
            }
        }
    }
    for (fds[1..n]) |fd| _ = linux.close(fd);
    return status;
}

// --- yes --------------------------------------------------------------------

pub fn yesMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const yword = [_][]const u8{"y"};
    const words: []const []const u8 = if (a.len > 1) a[1..] else yword[0..];
    while (true) {
        for (words, 0..) |w, k| {
            if (k != 0) out(" ");
            out(w);
        }
        out("\n");
    }
}

// --- sleep / usleep ---------------------------------------------------------

pub fn sleepMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len > 1 and std.mem.eql(u8, a[1], "--")) return sleepMain(argc - 1, argv + 1);
    if (a.len < 2) usageDie("sleep");
    if (std.mem.startsWith(u8, a[1], "inf")) while (true) sleepNs(std.math.maxInt(u64));
    var total: u64 = 0;
    for (a[1..]) |s| total += durationNs(s) orelse {
        { plain("invalid number '{s}'", .{s}); std.process.exit(1); }
    };
    sleepNs(total);
    return 0;
}

pub fn usleepMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len < 2) usageDie("usleep");
    const n = std.fmt.parseInt(u64, a[1], 10) catch {
        { plain("invalid number '{s}'", .{a[1]}); std.process.exit(1); }
    };
    sleepNs(n * 1000);
    return 0;
}

// --- nproc ------------------------------------------------------------------

pub fn nprocMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const longs = [_]LongOpt{
        .{ .name = "all", .val = 'a' },
        .{ .name = "ignore", .has_arg = .required, .val = 'i' },
    };
    const o = opts("nproc", a, "", &longs);
    var count = bb.util.get_cpu_count();
    var ignore: usize = 0;
    if (flagged(o, 0)) count = bb.util.get_cpu_count();
    if (flagged(o, 1)) {
        const v = o.optarg orelse "";
        ignore = std.fmt.parseInt(usize, v, 10) catch usageDie("nproc");
    }
    count = if (ignore >= count) 1 else count - ignore;
    put("{d}\n", .{count});
    return 0;
}

// --- sync / fsync -----------------------------------------------------------

fn syncFiles(files: []const []const u8, datasync: bool) c_int {
    var status: c_int = 0;
    if (files.len == 0) { linux.sync(); return 0; }
    for (files) |name| {
        const p = Path.init(name) catch { status = 1; continue; };
        const fd = openFd(p.z(), .{ .ACCMODE = .RDONLY, .NOCTTY = true, .NONBLOCK = true }, 0) orelse {
            errOpen(name, bb.process.errno);
            status = 1; continue;
        };
        const rc = if (datasync) linux.fdatasync(fd) else linux.fsync(fd);
        if (linux.errno(rc) != .SUCCESS) {
            msg(@intCast(@intFromEnum(linux.errno(rc))), "{s}", .{name});
            status = 1;
        }
        _ = linux.close(fd);
    }
    return status;
}

pub fn syncMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("sync", a, "df", &.{});
    if (flagged(o, 0) and flagged(o, 1)) usageDie("sync");
    return syncFiles(o.args, flagged(o, 0));
}

pub fn fsyncMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("fsync", a, "d", &.{});
    if (o.args.len == 0) usageDie("fsync");
    return syncFiles(o.args, flagged(o, 0));
}

// --- link / unlink / rmdir --------------------------------------------------

pub fn linkMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("link", a, "", &.{});
    if (o.args.len != 2) usageDie("link");
    const src = Path.init(o.args[0]) catch usageDie("link");
    const dst = Path.init(o.args[1]) catch usageDie("link");
    const rc = linux.link(src.z(), dst.z());
    if (linux.errno(rc) != .SUCCESS) {
        msgDie(@intCast(@intFromEnum(linux.errno(rc))), "can't create hardlink '{s}' to '{s}'", .{ o.args[1], o.args[0] });
    }
    return 0;
}

pub fn unlinkMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("unlink", a, "", &.{});
    if (o.args.len != 1) usageDie("unlink");
    const p = Path.init(o.args[0]) catch usageDie("unlink");
    const rc = linux.unlink(p.z());
    if (linux.errno(rc) != .SUCCESS) {
        msgDie(@intCast(@intFromEnum(linux.errno(rc))), "can't remove file '{s}'", .{o.args[0]});
    }
    return 0;
}

pub fn rmdirMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const longs = [_]LongOpt{
        .{ .name = "parents", .val = 'p' },
        .{ .name = "ignore-fail-on-non-empty", .val = 'i' },
    };
    const o = opts("rmdir", a, "pv", &longs);
    if (o.args.len == 0) usageDie("rmdir");
    var status: c_int = 0;
    for (o.args) |name| {
        var path = A.dupe(u8, name) catch { status = 1; continue; };
        while (true) {
            const p = Path.init(path) catch { A.free(path); status = 1; break; };
            const rc = linux.rmdir(p.z());
            const e = linux.errno(rc);
            if (e != .SUCCESS) {
                if (flagged(o, 2) and e == .NOTEMPTY) { A.free(path); break; }
                msg(@intFromEnum(e), "'{s}'", .{path});
                A.free(path);
                status = 1;
                break;
            }
            if (!flagged(o, 0)) { A.free(path); break; }
            const parent = stripLastComponent(path);
            if (std.mem.eql(u8, parent, ".") or std.mem.eql(u8, parent, "/")) { A.free(path); break; }
            const next = A.dupe(u8, parent) catch { A.free(path); status = 1; break; };
            A.free(path);
            path = next;
        }
    }
    return status;
}

// --- mkdir / mkfifo / mknod -------------------------------------------------

fn makeDirRecursive(path: []const u8, mode: linux.mode_t) !void {
    if (path.len == 0) return;
    var buf: [4096:0]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var i: usize = if (path[0] == '/') 1 else 0;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        if (i > 0 and i < path.len) {
            buf[i] = 0;
            const rc = linux.mkdir(@ptrCast(&buf), 0o777);
            const e = linux.errno(rc);
            if (e != .SUCCESS and e != .EXIST) return error.MkdirFailed;
            buf[i] = '/';
        }
    }
    const rc = linux.mkdir(@ptrCast(&buf), mode);
    const e = linux.errno(rc);
    if (e != .SUCCESS and e != .EXIST) return error.MkdirFailed;
}

pub fn mkdirMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const longs = [_]LongOpt{
        .{ .name = "mode", .has_arg = .required, .val = 'm' },
        .{ .name = "parents", .val = 'p' },
    };
    const o = opts("mkdir", a, "m:p", &longs);
    if (o.args.len == 0) usageDie("mkdir");
    var mode: linux.mode_t = 0o777;
    if (flagged(o, 0)) {
        const ms = o.optarg orelse "";
        mode = @intCast(bb.util.parse_mode(ms) catch {
            { plain("invalid mode '{s}'", .{ms}); std.process.exit(1); }
        });
    }
    var status: c_int = 0;
    for (o.args) |name| {
        const p = Path.init(name) catch { status = 1; continue; };
        const rc = if (flagged(o, 1)) blk: {
            makeDirRecursive(name, mode) catch break :blk @as(usize, 1);
            break :blk @as(usize, 0);
        } else linux.mkdir(p.z(), mode);
        if (linux.errno(rc) != .SUCCESS) {
            msg(@intFromEnum(linux.errno(rc)), "can't create directory '{s}'", .{name});
            status = 1;
        }
    }
    return status;
}

fn fifoMode(o: Options) linux.mode_t {
    if (!flagged(o, 0)) return 0o666;
    const ms = o.optarg orelse "";
    return @intCast(bb.util.parse_mode(ms) catch 0o666);
}

pub fn mkfifoMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("mkfifo", a, "m:", &.{});
    if (o.args.len == 0) usageDie("mkfifo");
    const mode = fifoMode(o);
    var status: c_int = 0;
    for (o.args) |name| {
        const p = Path.init(name) catch { status = 1; continue; };
        const rc = linux.mknod(p.z(), mode | linux.S.IFIFO, 0);
        if (linux.errno(rc) != .SUCCESS) {
            msg(@intFromEnum(linux.errno(rc)), "{s}", .{name});
            status = 1;
        }
    }
    return status;
}

pub fn mknodMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("mknod", a, "m:", &.{});
    if (o.args.len < 2) usageDie("mknod");
    const name = o.args[0];
    const typ = o.args[1];
    if (typ.len == 0) usageDie("mknod");
    var kind: linux.mode_t = undefined;
    switch (typ[0]) {
        'p' => kind = linux.S.IFIFO,
        'c', 'u' => kind = linux.S.IFCHR,
        'b' => kind = linux.S.IFBLK,
        else => usageDie("mknod"),
    }
    var dev: linux.dev_t = 0;
    var extra: usize = 2;
    if (typ[0] != 'p') {
        if (o.args.len < 4) usageDie("mknod");
        const maj = std.fmt.parseInt(u32, o.args[2], 10) catch usageDie("mknod");
        const min = std.fmt.parseInt(u32, o.args[3], 10) catch usageDie("mknod");
        dev = @intCast((@as(u64, maj) << 8) | min);
        extra = 4;
    }
    if (o.args.len > extra) usageDie("mknod");
    const p = Path.init(name) catch usageDie("mknod");
    const rc = linux.mknod(p.z(), fifoMode(o) | kind, dev);
    if (linux.errno(rc) != .SUCCESS) {
        msgDie(@intFromEnum(linux.errno(rc)), "{s}", .{name});
    }
    return 0;
}

// --- mktemp -----------------------------------------------------------------

fn randomSuffix(buf: *[6]u8) void {
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var seed: u64 = @as(u64, @intCast(bb.process.getpid())) *% 2654435761;
    seed ^= @intFromPtr(&seed);
    for (buf) |*c| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        c.* = chars[@intCast((seed >> 33) % chars.len)];
    }
}

fn makeTemp(template: []const u8, directory: bool, no_create: bool, quiet: bool) ?[]u8 {
    const xcount = std.mem.lastIndexOf(u8, template, "XXXXXX") orelse {
        if (!quiet) msgDie(@intFromEnum(linux.E.INVAL), "", .{});
        return null;
    };
    var path = A.dupe(u8, template) catch return null;
    defer A.free(path);
    randomSuffix(path[xcount..][0..6]);
    if (no_create) return A.dupe(u8, path) catch null;
    const p = Path.init(path) catch return null;
    if (directory) {
        const rc = linux.mkdir(p.z(), 0o700);
        if (linux.errno(rc) != .SUCCESS) { if (!quiet) msgDie(@intCast(@intFromEnum(linux.errno(rc))), "", .{}); return null; }
    } else {
        const fd = openFd(p.z(), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600) orelse {
            if (!quiet) msgDie(bb.process.errno, "", .{});
            return null;
        };
        _ = linux.close(fd);
    }
    return A.dupe(u8, path) catch null;
}

pub fn mktempMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("mktemp", a, "^dqtp:u", &.{});
    if (o.args.len > 1) usageDie("mktemp");
    var base = bb.env.get("TMPDIR") orelse "/tmp";
    if (base.len == 0) base = "/tmp";
    if (flagged(o, 3)) base = o.optarg orelse base;
    var tmpl: []const u8 = if (o.args.len == 1) o.args[0] else "tmp.XXXXXX";
    const with_t = flagged(o, 2) or flagged(o, 3) or o.args.len == 0;
    if (with_t) {
        tmpl = std.fmt.allocPrint(A, "{s}/{s}", .{ base, tmpl }) catch return 1;
    }
    const result = makeTemp(tmpl, flagged(o, 0), flagged(o, 4), flagged(o, 1)) orelse return 1;
    defer A.free(result);
    put("{s}\n", .{result});
    return 0;
}

// --- realpath / readlink ----------------------------------------------------

fn resolveLink(path: []const u8) ?[]u8 {
    var buf: [4096]u8 = undefined;
    const p = Path.init(path) catch return null;
    const n = linux.readlink(p.z(), &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return A.dupe(u8, buf[0..n]) catch null;
}

fn canonicalize(path: []const u8) ?[]u8 {
    var full: []const u8 = undefined;
    var owned_full: ?[]u8 = null;
    defer if (owned_full) |s| A.free(s);
    if (path.len > 0 and path[0] == '/') {
        full = path;
    } else {
        const got = bb.path.xgetcwd(A) catch return null;
        var cwd: []const u8 = got;
        while (cwd.len > 0 and cwd[cwd.len - 1] == 0) cwd = cwd[0 .. cwd.len - 1];
        owned_full = std.fmt.allocPrint(A, "{s}/{s}", .{ cwd, path }) catch { A.free(got); return null; };
        A.free(got);
        full = owned_full.?;
    }
    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (parts.items) |p| A.free(p);
        parts.deinit(A);
    }
    var it = std.mem.splitScalar(u8, full, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) A.free(parts.pop().?);
            continue;
        }
        const prefix = std.mem.join(A, "/", parts.items) catch return null;
        defer A.free(prefix);
        const candidate = if (prefix.len == 0)
            std.fmt.allocPrint(A, "/{s}", .{part}) catch return null
        else
            std.fmt.allocPrint(A, "/{s}/{s}", .{ prefix, part }) catch return null;
        defer A.free(candidate);
        if (resolveLink(candidate)) |target| {
            defer A.free(target);
            if (target.len > 0 and target[0] == '/') {
                for (parts.items) |p| A.free(p);
                parts.clearRetainingCapacity();
            }
            var tit = std.mem.splitScalar(u8, if (target.len > 0 and target[0] == '/') target[1..] else target, '/');
            while (tit.next()) |p| {
                if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
                if (std.mem.eql(u8, p, "..")) {
                    if (parts.items.len > 0) A.free(parts.pop().?);
                    continue;
                }
                parts.append(A, A.dupe(u8, p) catch return null) catch return null;
            }
        } else {
            parts.append(A, A.dupe(u8, part) catch return null) catch return null;
        }
    }
    if (parts.items.len == 0) return A.dupe(u8, "/") catch null;
    const joined = std.mem.join(A, "/", parts.items) catch return null;
    defer A.free(joined);
    return std.fmt.allocPrint(A, "/{s}", .{joined}) catch null;
}

pub fn realpathMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len < 2) usageDie("realpath");
    var status: c_int = 0;
    for (a[1..]) |name| {
        if (!pathExists(name)) {
            msg(@intFromEnum(linux.E.NOENT), "{s}", .{name});
            status = 1;
            continue;
        }
        const r = canonicalize(name) orelse { msg(@intFromEnum(linux.E.NOENT), "{s}", .{name}); status = 1; continue; };
        defer A.free(r);
        put("{s}\n", .{r});
    }
    return status;
}

pub fn readlinkMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("readlink", a, "^nfvsq", &.{});
    if (o.args.len != 1) usageDie("readlink");
    const verbose = flagged(o, 2);
    const target = if (flagged(o, 1)) canonicalize(o.args[0]) else resolveLink(o.args[0]);
    if (target == null) {
        if (verbose) msg(@intFromEnum(linux.E.INVAL), "{s}", .{o.args[0]});
        return 1;
    }
    defer A.free(target.?);
    out(target.?);
    if (!flagged(o, 0)) out("\n");
    return 0;
}

// --- truncate ---------------------------------------------------------------

pub fn truncateMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("truncate", a, "^cs:", &.{});
    if (!flagged(o, 1) or o.args.len == 0) usageDie("truncate");
    const size_str = o.optarg orelse usageDie("truncate");
    const size = numSuffix(size_str) orelse blk: { plain("invalid number '{s}'", .{size_str}); std.process.exit(1); break :blk @as(u64, 0); };
    var status: c_int = 0;
    for (o.args) |name| {
        const p = Path.init(name) catch { status = 1; continue; };
        const flags: linux.O = if (flagged(o, 0))
            .{ .ACCMODE = .WRONLY, .NONBLOCK = true }
        else
            .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CREAT = true };
        const fd = openFd(p.z(), flags, 0o666) orelse {
            if (!(bb.process.errno == 2 and flagged(o, 0))) {
                msg(bb.process.errno, "{s}: open", .{name});
                status = 1;
            }
            continue;
        };
        const rc = linux.ftruncate(fd, @intCast(size));
        if (linux.errno(rc) != .SUCCESS) {
            msg(@intFromEnum(linux.errno(rc)), "{s}: truncate", .{name});
            status = 1;
        }
        _ = linux.close(fd);
    }
    return status;
}

// --- install ----------------------------------------------------------------

pub fn installMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("install", a, "^cvbDdps:g:m:o:t:", &.{});
    const directory = flagged(o, 4);
    const target = flagged(o, 10);
    const mkdir_leading = flagged(o, 3);
    var mode: linux.mode_t = 0o755;
    if (flagged(o, 8)) mode = @intCast(bb.util.parse_mode(o.optarg orelse "") catch 0o755);
    var dest_dir: ?[]const u8 = if (target) o.optarg else null;
    var files = o.args;
    var dest: []const u8 = "";
    if (!directory and !target) {
        if (files.len < 2) usageDie("install");
        dest = files[files.len - 1];
        files = files[0 .. files.len - 1];
        if (isDir(dest)) dest_dir = dest;
    }
    var status: c_int = 0;
    for (files) |src| {
        const d = if (directory) src else if (dest_dir) |dd|
            std.fmt.allocPrint(A, "{s}/{s}", .{ dd, baseNameStrip(src) }) catch { status = 1; continue; }
        else dest;
        defer if (dest_dir != null and !directory) A.free(@constCast(d));
        if (directory) {
            makeDirRecursive(src, mode) catch { status = 1; continue; };
        } else {
            if (mkdir_leading) {
                const parent = if (target) d else stripLastComponent(d);
                makeDirRecursive(parent, 0o755) catch {};
            }
            const sp = Path.init(src) catch { status = 1; continue; };
            const dp = Path.init(d) catch { status = 1; continue; };
            const infd = openFd(sp.z(), .{ .ACCMODE = .RDONLY }, 0) orelse {
                msg(bb.process.errno, "can't create '{s}'", .{d});
                status = 1; continue;
            };
            const outfd = openFd(dp.z(), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600) orelse {
                msg(bb.process.errno, "can't create '{s}'", .{d});
                _ = linux.close(infd);
                status = 1; continue;
            };
            var buf: [16384]u8 = undefined;
            while (true) {
                const n = linux.read(infd, &buf, buf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                var off: usize = 0;
                while (off < n) {
                    const w = linux.write(outfd, buf[off..].ptr, n - off);
                    if (linux.errno(w) != .SUCCESS) break;
                    off += w;
                }
            }
            _ = linux.close(infd);
            _ = linux.close(outfd);
        }
        const dp = Path.init(d) catch { status = 1; continue; };
        if (linux.errno(linux.chmod(dp.z(), mode)) != .SUCCESS) status = 1;
    }
    return status;
}

// --- printenv / env ---------------------------------------------------------

pub fn printenvMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const map = bb.env.map orelse return 0;
    if (a.len == 1) {
        const keys = map.keys();
        const vals = map.values();
        for (keys, vals) |k, v| put("{s}={s}\n", .{ k, v });
        return 0;
    }
    var status: c_int = 0;
    for (a[1..]) |name| {
        if (map.get(name)) |v| put("{s}\n", .{v}) else status = 1;
    }
    return status;
}

fn zstr(s: []const u8) [*:0]const u8 {
    return A.dupeSentinel(u8, s, 0) catch @as([*:0]const u8, "");
}

fn findExecutable(name: []const u8, envp: []const ?[*:0]const u8) ?[]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (linux.errno(linux.access(zstr(name), 1)) == .SUCCESS) return A.dupe(u8, name) catch null;
        return null;
    }
    var path: []const u8 = "/bin:/usr/bin";
    for (envp) |e| {
        const es = std.mem.span(e orelse continue);
        if (std.mem.startsWith(u8, es, "PATH=")) { path = es[5..]; break; }
    }
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fmt.allocPrint(A, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
        if (linux.errno(linux.access(zstr(full), 1)) == .SUCCESS) return full;
        A.free(full);
    }
    return null;
}

fn buildEnvp(clear: bool, unset: []const []const u8, assign: []const []const u8) []const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    if (!clear) {
        if (bb.env.map) |m| {
            const keys = m.keys();
            const vals = m.values();
            for (keys, vals) |k, v| {
                var skip = false;
                for (unset) |u| if (std.mem.eql(u8, u, k)) { skip = true; break; };
                if (skip) continue;
                list.append(A, zstr(std.fmt.allocPrint(A, "{s}={s}", .{ k, v }) catch continue)) catch {};
            }
        }
    }
    for (assign) |a| {
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse continue;
        const name = a[0..eq];
        var i: usize = 0;
        while (i < list.items.len) {
            const e = std.mem.span(list.items[i].?);
            if (std.mem.startsWith(u8, e, name) and e.len > name.len and e[name.len] == '=') {
                _ = list.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        list.append(A, zstr(a)) catch {};
    }
    list.append(A, null) catch {};
    return list.toOwnedSlice(A) catch &.{};
}

fn runProgram(av: []const []const u8, envp: []const ?[*:0]const u8) c_int {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return 1;
    const cpid: linux.pid_t = @intCast(pid);
    if (cpid == 0) {
        var args: [256]?[*:0]const u8 = undefined;
        for (av, 0..) |s, i| args[i] = if (i < args.len) zstr(s) else null;
        args[@min(av.len, args.len - 1)] = null;
        const path = findExecutable(av[0], envp) orelse std.process.exit(127);
        _ = linux.execve(zstr(path), @ptrCast(&args), @ptrCast(envp.ptr));
        std.process.exit(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(cpid, &status, 0);
    if ((status & 0x7f) == 0) return @intCast((status >> 8) & 0xff);
    return 128 + @as(c_int, @intCast(status & 0x7f));
}

pub fn envMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const longs = [_]LongOpt{
        .{ .name = "ignore-environment", .val = 'i' },
        .{ .name = "null", .val = '0' },
        .{ .name = "unset", .has_arg = .required, .val = 'u' },
    };
    const o = opts("env", a, "+i0u:*", &longs);
    var rest = o.args;
    var clear = flagged(o, 0);
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "-")) { clear = true; rest = rest[1..]; }
    var unsets: std.ArrayList([]const u8) = .empty;
    defer unsets.deinit(A);
    // Re-scan argv for repeated -u/--unset because getopt32 stores one optarg.
    var i: usize = 1;
    while (i < a.len) : (i += 1) {
        if (std.mem.eql(u8, a[i], "-u") or std.mem.eql(u8, a[i], "--unset")) {
            if (i + 1 < a.len) { unsets.append(A, a[i + 1]) catch {}; i += 1; }
        } else if (std.mem.startsWith(u8, a[i], "--unset=")) {
            unsets.append(A, a[i][8..]) catch {};
        } else if (a[i].len > 2 and a[i][0] == '-' and a[i][1] == 'u') {
            unsets.append(A, a[i][2..]) catch {};
        }
    }
    var assigns: std.ArrayList([]const u8) = .empty;
    defer assigns.deinit(A);
    while (rest.len > 0 and std.mem.indexOfScalar(u8, rest[0], '=') != null) {
        assigns.append(A, rest[0]) catch {};
        rest = rest[1..];
    }
    if (rest.len > 0) {
        const envp = buildEnvp(clear, unsets.items, assigns.items);
        return runProgram(rest, envp);
    }
    const envp = buildEnvp(clear, unsets.items, assigns.items);
    const sep: u8 = if (flagged(o, 1)) 0 else '\n';
    for (envp) |e| {
        const z = e orelse break;
        const s = std.mem.span(z);
        out(s);
        out(&.{sep});
    }
    return 0;
}

// --- identity applets -------------------------------------------------------

fn passwdName(uid: linux.uid_t) ?[]u8 {
    const data = readFile("/etc/passwd") catch return null;
    defer A.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next() orelse continue;
        const ids = f.next() orelse continue;
        const n = std.fmt.parseInt(linux.uid_t, ids, 10) catch continue;
        if (n == uid) return A.dupe(u8, name) catch null;
    }
    return null;
}

fn groupName(gid: linux.gid_t) ?[]u8 {
    const data = readFile("/etc/group") catch return null;
    defer A.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next() orelse continue;
        const ids = f.next() orelse continue;
        const n = std.fmt.parseInt(linux.gid_t, ids, 10) catch continue;
        if (n == gid) return A.dupe(u8, name) catch null;
    }
    return null;
}

fn uidForName(name: []const u8) ?linux.uid_t {
    const data = readFile("/etc/passwd") catch return null;
    defer A.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        _ = f.next() orelse continue;
        const ids = f.next() orelse continue;
        return std.fmt.parseInt(linux.uid_t, ids, 10) catch null;
    }
    return null;
}

fn groupsForUser(name: []const u8, gid: linux.gid_t) []linux.gid_t {
    var list: std.ArrayList(linux.gid_t) = .empty;
    list.append(A, gid) catch return list.toOwnedSlice(A) catch &.{};
    const data = readFile("/etc/group") catch return list.toOwnedSlice(A) catch &.{};
    defer A.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        const idstr = f.next() orelse continue;
        const members = f.next() orelse continue;
        const g = std.fmt.parseInt(linux.gid_t, idstr, 10) catch continue;
        var mit = std.mem.splitScalar(u8, members, ',');
        while (mit.next()) |m| {
            if (std.mem.eql(u8, m, name)) { list.append(A, g) catch {}; break; }
        }
    }
    return list.toOwnedSlice(A) catch &.{};
}

fn printId(id: u32, name: ?[]const u8, prefix: []const u8, numeric: bool, default_mode: bool) void {
    put("{s}", .{prefix});
    if (default_mode) {
        put("{d}", .{id});
        if (name) |n| put("({s})", .{n});
    } else if (!numeric) {
        if (name) |n| put("{s}", .{n}) else put("{d}", .{id});
    } else {
        put("{d}", .{id});
    }
}

pub fn idMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const groups_applet = std.mem.eql(u8, name, "groups");
    var opt: Options = undefined;
    if (groups_applet) {
        opt = opts(name, a, "", &.{});
    } else {
        opt = opts(name, a, "^rnugG", &.{});
        const count = @popCount(@as(u8, @truncate(opt.flags & 0b11100)));
        if (count > 1) usageDie(name);
        if (opt.args.len > 1) usageDie(name);
    }
    var ruid = bb.process.getuid();
    var rgid = bb.process.getgid();
    var euid = bb.process.geteuid();
    var egid = bb.process.getegid();
    var user: ?[]const u8 = null;
    if (opt.args.len == 1) {
        user = opt.args[0];
        const u = uidForName(user.?) orelse {
            plain("unknown user {s}", .{user.?});
            return 1;
        };
        ruid = u; euid = u;
        const data = readFile("/etc/passwd") catch return 1;
        defer A.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const n = f.next() orelse continue;
            if (!std.mem.eql(u8, n, user.?)) continue;
            _ = f.next() orelse continue;
            const ids = f.next() orelse continue;
            const gid = f.next() orelse continue;
            _ = ids;
            rgid = std.fmt.parseInt(linux.gid_t, gid, 10) catch 0;
            egid = rgid;
            break;
        }
    }
    const numeric = if (groups_applet) false else !flagged(opt, 1);
    const default_mode = !groups_applet and opt.flags == 0;
    const real = flagged(opt, 0);
    if (real) { euid = ruid; egid = rgid; }
    const just_user = flagged(opt, 2);
    const just_group = flagged(opt, 3);
    const just_groups = flagged(opt, 4) or groups_applet;
    var gids: [256]linux.gid_t = undefined;
    var owned_gids: ?[]linux.gid_t = null;
    defer if (owned_gids) |g| A.free(g);
    var ngids: usize = undefined;
    if (user) |u| {
        const gl = groupsForUser(u, rgid);
        owned_gids = gl;
        ngids = @min(gl.len, gids.len);
        @memcpy(gids[0..ngids], gl[0..ngids]);
    } else {
        ngids = bb.process.getgroups(gids.len, &gids) catch 0;
    }
    if (just_user) {
        printId(euid, passwdName(euid), "", numeric, default_mode);
    } else if (just_group) {
        printId(egid, groupName(egid), "", numeric, default_mode);
    } else if (just_groups) {
        printId(rgid, groupName(rgid), "", numeric, default_mode);
        if (egid != rgid) printId(egid, groupName(egid), " ", numeric, default_mode);
        for (gids[0..ngids]) |g| {
            if (g == rgid or g == egid) continue;
            printId(g, groupName(g), " ", numeric, default_mode);
        }
    } else {
        printId(ruid, passwdName(ruid), "uid=", numeric, default_mode);
        printId(rgid, groupName(rgid), " gid=", numeric, default_mode);
        if (euid != ruid) printId(euid, passwdName(euid), " euid=", numeric, default_mode);
        if (egid != rgid) printId(egid, groupName(egid), " egid=", numeric, default_mode);
        for (gids[0..ngids], 0..) |g, k| {
            printId(g, groupName(g), if (k == 0) " groups=" else ",", numeric, default_mode);
        }
    }
    out("\n");
    return 0;
}

pub fn whoamiMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len > 1) usageDie("whoami");
    const uid = bb.process.geteuid();
    const name = passwdName(uid) orelse msgDie(@intFromEnum(linux.E.NOENT), "unknown uid {d}", .{uid});
    defer A.free(name);
    put("{s}\n", .{name});
    return 0;
}

pub fn lognameMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len > 1) usageDie("logname");
    const uid = bb.process.geteuid();
    const name = passwdName(uid) orelse msgDie(@intFromEnum(linux.E.NOENT), "getlogin", .{});
    defer A.free(name);
    put("{s}\n", .{name});
    return 0;
}

// --- utmp applets -----------------------------------------------------------

const Utmp = extern struct {
    type: i16,
    pid: i32,
    line: [32]u8,
    id: [4]u8,
    user: [32]u8,
    host: [256]u8,
    exit: extern struct { exit_code: i16, termination: i16 },
    session: i32,
    tv: extern struct { sec: i64, usec: i64 },
    addr_v6: [4]u32,
    unused: [20]u8,
};

fn utmpUsers() std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    const data = readFile("/var/run/utmp") catch return result;
    var remaining = data;
    while (remaining.len >= @sizeOf(Utmp)) {
        const u: *const Utmp = @ptrCast(@alignCast(remaining.ptr));
        if (u.type == 7) {
            const n = std.mem.indexOfScalar(u8, &u.user, 0) orelse u.user.len;
            if (n > 0) result.append(A, A.dupe(u8, u.user[0..n]) catch "") catch {};
        }
        remaining = remaining[@sizeOf(Utmp)..];
    }
    return result;
}

pub fn usersMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len > 1) usageDie("users");
    var names = utmpUsers();
    defer { for (names.items) |n| A.free(n); names.deinit(A); }
    for (names.items, 0..) |n, i| { if (i != 0) out(" "); out(n); }
    out("\n");
    return 0;
}

pub fn whoMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = opts(name, a, "^aH", &.{});
    if (o.args.len > 0) usageDie(name);
    if (flagged(o, 1) or std.mem.eql(u8, name, "w")) out("USER\t\tTTY\t\tIDLE\tTIME\t\t HOST\n");
    if (std.mem.eql(u8, name, "w")) return 0;
    var names = utmpUsers();
    defer { for (names.items) |n| A.free(n); names.deinit(A); }
    for (names.items) |n| put("{s: <15} {s: <15} {s: <7} {s: <16} {s}\n", .{ n, "", "?", "", "" });
    return 0;
}

// --- tty / hostid / uname / arch --------------------------------------------

pub fn ttyMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = bb.getopt.getopt32(a, "+s", &.{}) catch {
        bb.usage.show("tty", 2);
        return 2;
    };
    // /proc/self/fd/0 is a symlink even for redirected input (e.g. /dev/null),
    // so probe for a real terminal first, as ttyname(3) does.
    var tbuf: [256]u8 align(8) = undefined;
    const tcgets: u32 = 0x5401;
    const is_tty = linux.errno(linux.ioctl(0, tcgets, @intFromPtr(&tbuf))) == .SUCCESS;
    var buf: [4096]u8 = undefined;
    const n = if (is_tty) linux.readlink("/proc/self/fd/0", &buf, buf.len) else 0;
    const tty = if (is_tty and linux.errno(n) == .SUCCESS and n > 0 and n < buf.len) buf[0..n] else null;
    if (tty == null) {
        if (!flagged(o, 0)) out("not a tty\n");
        return 1;
    }
    if (!flagged(o, 0)) put("{s}\n", .{tty.?});
    return 0;
}

pub fn hostidMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len > 1) usageDie("hostid");
    var id: u32 = 0x007f0101;
    const data = readFile("/etc/hostid") catch &.{};
    defer if (data.len > 0) A.free(data);
    if (data.len >= 4) {
        id = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16) | (@as(u32, data[3]) << 24);
    }
    put("{x:0>8}\n", .{id});
    return 0;
}

pub fn unameMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const is_arch = std.mem.eql(u8, name, "arch");
    const u = std.posix.uname();
    if (is_arch) {
        put("{s}\n", .{std.mem.sliceTo(&u.machine, 0)});
        return 0;
    }
    const longs = [_]LongOpt{
        .{ .name = "all", .val = 'a' }, .{ .name = "kernel-name", .val = 's' },
        .{ .name = "nodename", .val = 'n' }, .{ .name = "kernel-release", .val = 'r' },
        .{ .name = "release", .val = 'r' }, .{ .name = "kernel-version", .val = 'v' },
        .{ .name = "machine", .val = 'm' }, .{ .name = "processor", .val = 'p' },
        .{ .name = "hardware-platform", .val = 'i' }, .{ .name = "operating-system", .val = 'o' },
    };
    const o = opts(name, a, "snrvmpioa", &longs);
    if (o.args.len > 0) usageDie(name);
    var bits = o.flags;
    const all = flagged(o, 8);
    if (all) bits = 0xff;
    if (bits == 0) bits = 1;
    const unknown: []const u8 = if (all) "" else "unknown";
    const vals = [_][]const u8{
        std.mem.sliceTo(&u.sysname, 0), std.mem.sliceTo(&u.nodename, 0),
        std.mem.sliceTo(&u.release, 0), std.mem.sliceTo(&u.version, 0),
        std.mem.sliceTo(&u.machine, 0), unknown, unknown, "GNU/Linux",
    };
    var first = true;
    for (vals, 0..) |v, k| {
        if (bits & (@as(u32, 1) << @intCast(k)) == 0 or v.len == 0) continue;
        if (first) { out(v); first = false; } else { put(" {s}", .{v}); }
    }
    out("\n");
    return 0;
}

// --- nice / nohup / timeout -------------------------------------------------

fn exitStatus(status: i32) c_int {
    if ((status & 0x7f) == 0) return @intCast((status >> 8) & 0xff);
    return 128 + @as(c_int, @intCast(status & 0x7f));
}

pub fn niceMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len == 1) {
        const raw: i32 = @bitCast(@as(u32, @truncate(linux.syscall2(linux.SYS.getpriority, 0, 0))));
        put("{d}\n", .{20 - raw});
        return 0;
    }
    var i: usize = 1;
    var adjust: i32 = 10;
    if (a[i][0] == '-') {
        var num = a[i][1..];
        if (num.len > 0 and num[0] == 'n') {
            num = num[1..];
            if (num.len == 0) { i += 1; if (i >= a.len) usageDie("nice"); num = a[i]; }
        }
        adjust = std.fmt.parseInt(i32, num, 10) catch blk: { plain("invalid number '{s}'", .{num}); std.process.exit(1); break :blk @as(i32, 0); };
        i += 1;
        if (i >= a.len) usageDie("nice");
    }
    const raw: i32 = @bitCast(@as(u32, @truncate(linux.syscall2(linux.SYS.getpriority, 0, 0))));
    const prio: i32 = 20 - raw;
    const rc = linux.syscall3(linux.SYS.setpriority, 0, 0, @as(usize, @bitCast(@as(i64, prio + adjust))));
    if (@as(isize, @bitCast(rc)) < 0) msgDie(@intCast(@intFromEnum(linux.errno(rc))), "setpriority({d})", .{prio + adjust});
    const envp = buildEnvp(false, &.{}, &.{});
    return runProgram(a[i..], envp);
}

pub fn nohupMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    if (a.len < 2) {
        bb.usage.show("nohup", 2);
        return 127;
    }
    // The harness never connects a tty; a real tty would be redirected here.
    const envp = buildEnvp(false, &.{}, &.{});
    if (findExecutable(a[1], envp) == null) {
        msg(@intFromEnum(linux.E.NOENT), "can't execute '{s}'", .{a[1]});
        return 127;
    }
    return runProgram(a[1..], envp);
}

fn signalNumber(s: []const u8) ?linux.SIG {
    if (std.mem.eql(u8, s, "TERM")) return .TERM;
    if (std.mem.eql(u8, s, "KILL")) return .KILL;
    if (std.mem.eql(u8, s, "INT")) return .INT;
    if (std.mem.eql(u8, s, "HUP")) return .HUP;
    if (std.mem.eql(u8, s, "STOP")) return .STOP;
    if (std.mem.eql(u8, s, "CONT")) return .CONT;
    const n = std.fmt.parseInt(u8, s, 10) catch return null;
    return @enumFromInt(n);
}

pub fn timeoutMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const a = avFrom(argv, argc);
    const o = opts("timeout", a, "+s:k:", &.{});
    _ = o;
    var sig: linux.SIG = .TERM;
    var kstr: ?[]const u8 = null;
    var pos: usize = 1;
    while (pos < a.len and a[pos].len > 1 and a[pos][0] == '-') {
        if (std.mem.eql(u8, a[pos], "-s") and pos + 1 < a.len) {
            sig = signalNumber(a[pos + 1]) orelse blk: { plain("unknown signal '{s}'", .{a[pos + 1]}); std.process.exit(1); break :blk .TERM; };
            pos += 2; continue;
        }
        if (std.mem.eql(u8, a[pos], "-k") and pos + 1 < a.len) { kstr = a[pos + 1]; pos += 2; continue; }
        if (a[pos].len > 2 and a[pos][1] == 's') {
            sig = signalNumber(a[pos][2..]) orelse blk: { plain("unknown signal '{s}'", .{a[pos][2..]}); std.process.exit(1); break :blk .TERM; };
            pos += 1; continue;
        }
        pos += 1;
    }
    if (pos >= a.len) usageDie("timeout");
    const limit_ns = durationNs(a[pos]) orelse usageDie("timeout");
    pos += 1;
    if (pos >= a.len) usageDie("timeout");
    const envp_for_check = buildEnvp(false, &.{}, &.{});
    if (findExecutable(a[pos], envp_for_check) == null) {
        msg(@intFromEnum(linux.E.NOENT), "can't execute '{s}'", .{a[pos]});
        return 127;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return 1;
    const cpid: linux.pid_t = @intCast(pid);
    if (cpid == 0) {
        const envp = buildEnvp(false, &.{}, &.{});
        var args: [256]?[*:0]const u8 = undefined;
        for (a[pos..], 0..) |s, k| args[k] = if (k < args.len) zstr(s) else null;
        args[@min(a[pos..].len, args.len - 1)] = null;
        const path = findExecutable(a[pos], envp) orelse std.process.exit(127);
        _ = linux.execve(zstr(path), @ptrCast(&args), @ptrCast(envp.ptr));
        std.process.exit(127);
    }
    var elapsed: u64 = 0;
    var status: i32 = 0;
    while (elapsed < limit_ns) {
        const r = linux.waitpid(cpid, &status, 1);
        if (r == @as(usize, @intCast(cpid))) return exitStatus(status);
        sleepNs(10 * 1_000_000);
        elapsed += 10 * 1_000_000;
    }
    _ = linux.kill(cpid, sig);
    // BusyBox uses a watchdog grandchild which signals the timeout process
    // itself; its exit status is therefore the signal, not 124.
    const self: linux.pid_t = @intCast(linux.getpid());
    if (kstr != null) {
        sleepNs(1_000_000);
        _ = linux.kill(cpid, .KILL);
    }
    _ = linux.kill(self, sig);
    _ = linux.waitpid(cpid, &status, 0);
    return 124;
}

