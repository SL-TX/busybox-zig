//! Miscellaneous utility helpers ported from busybox libbb.

const std = @import("std");
const linux = std.os.linux;

pub fn isqrt(n: u64) u64 {
    if (n == 0) return 0;
    var x: u64 = n;
    var y: u64 = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}

pub fn human_readable(a: std.mem.Allocator, n: u64, decimal: bool) ![]u8 {
    const base: u64 = if (decimal) 1000 else 1024;
    const units = if (decimal) " KMGPT" else " KMGTPE";
    const suffixes = if (decimal) "kmgtp" else "kmgtep";
    var unit: usize = 0;
    var scaled: u128 = n;
    while (unit + 1 < units.len and scaled >= base) {
        scaled /= base;
        unit += 1;
    }
    if (unit == 0) return std.fmt.allocPrint(a, "{d}", .{n});
    const whole: u128 = scaled;
    const rem: u128 = n - (whole * std.math.pow(u128, base, unit));
    const frac: u128 = if (base == 1024) (rem * 10) / std.math.pow(u128, base, unit) else (rem * 10) / std.math.pow(u128, base, unit);
    if (frac != 0) return std.fmt.allocPrint(a, "{d}.{d}{c}", .{ whole, frac, if (decimal) suffixes[unit - 1] else units[unit] });
    return std.fmt.allocPrint(a, "{d}{c}", .{ whole, if (decimal) suffixes[unit - 1] else units[unit] });
}

pub fn mode_string(mode: u32, buf: []u8) []const u8 {
    const kind: u8 = switch (mode & linux.S.IFMT) {
        linux.S.IFDIR => 'd',
        linux.S.IFLNK => 'l',
        linux.S.IFCHR => 'c',
        linux.S.IFBLK => 'b',
        linux.S.IFIFO => 'p',
        linux.S.IFSOCK => 's',
        else => '-',
    };
    buf[0] = kind;
    const bits = [_]u32{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001 };
    const chars = "rwxrwxrwx";
    for (bits, 0..) |bit, i| buf[i + 1] = if (mode & bit != 0) chars[i] else '-';
    return buf[0..10];
}

pub fn parse_mode(text: []const u8) !u32 {
    return std.fmt.parseInt(u32, text, 8);
}

pub fn process_escape_sequence(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => try out.append(a, '\n'),
            't' => try out.append(a, '\t'),
            'r' => try out.append(a, '\r'),
            '0' => try out.append(a, 0),
            'a' => try out.append(a, 7),
            'b' => try out.append(a, 8),
            'v' => try out.append(a, 11),
            'f' => try out.append(a, 12),
            'e' => try out.append(a, 27),
            '\\' => try out.append(a, '\\'),
            'x' => {
                var value: u8 = 0;
                var digits: usize = 0;
                while (i + 1 < s.len and digits < 2) : (i += 1) {
                    const c = s[i + 1];
                    const d = std.fmt.charToDigit(c, 16) catch break;
                    value = value * 16 + d;
                    digits += 1;
                }
                if (digits == 0) try out.append(a, 'x') else try out.append(a, value);
            },
            else => try out.append(a, s[i]),
        }
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// camelCase aliases matching the shared libbb interface.
pub const humanReadable = human_readable;
pub const processEscapeSequence = process_escape_sequence;

/// Strict decimal number parsers. BusyBox's xatou/xatoi/xatol terminate the
/// process on bad input; these return an error so callers can decide.
pub fn xatou(s: []const u8) !u64 {
    if (s.len == 0 or s[0] == '-') return error.InvalidCharacter;
    return std.fmt.parseInt(u64, s, 10);
}

pub fn xatoi(s: []const u8) !i64 {
    return std.fmt.parseInt(i64, s, 10);
}

pub fn xatol(s: []const u8) !i64 {
    return std.fmt.parseInt(i64, s, 10);
}

pub fn signal_names(sig: u8) []const u8 {
    return switch (sig) {
        1 => "HUP", 2 => "INT", 3 => "QUIT", 4 => "ILL", 6 => "ABRT",
        8 => "FPE", 9 => "KILL", 11 => "SEGV", 13 => "PIPE", 14 => "ALRM",
        15 => "TERM", 17 => "CHLD", 18 => "CONT", 19 => "STOP", 20 => "TSTP",
        else => "",
    };
}

pub fn get_cpu_count() usize {
    return std.Thread.getCpuCount() catch 1;
}

// --- deferred libbb helpers -------------------------------------------------

pub const Action = enum { continue_walk, skip_dir, abort };

fn pathJoin(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, dir, "/")) return std.mem.concat(a, u8, &.{ dir, name });
    return std.mem.concat(a, u8, &.{ dir, "/", name });
}

fn walk(a: std.mem.Allocator, dir: []const u8, cb: *const fn ([]const u8, bool, ?*anyopaque) Action, ctx: ?*anyopaque) !Action {
    var zp: [4096:0]u8 = undefined;
    if (dir.len >= zp.len) return error.NameTooLong;
    @memcpy(zp[0..dir.len], dir);
    zp[dir.len] = 0;
    const rc = std.os.linux.open(@ptrCast(&zp), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: std.os.linux.fd_t = @intCast(rc);
    defer _ = std.os.linux.close(fd);

    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = std.os.linux.getdents64(fd, &buf, buf.len);
        if (std.os.linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + @offsetOf(std.os.linux.dirent64, "name") <= n) {
            const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const raw = buf[off + @offsetOf(std.os.linux.dirent64, "name") ..][0 .. dent.reclen - @offsetOf(std.os.linux.dirent64, "name")];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const name = raw[0..end];
            off += dent.reclen;
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const child = try pathJoin(a, dir, name);
            defer a.free(child);
            const is_dir = dent.type == std.os.linux.DT.DIR;
            const action = cb(child, is_dir, ctx);
            if (is_dir and action == .continue_walk) {
                const sub = try walk(a, child, cb, ctx);
                if (sub == .abort) return .abort;
            }
            if (action == .abort) return .abort;
        }
    }
    return .continue_walk;
}

pub fn recursiveAction(a: std.mem.Allocator, root: []const u8, cb: *const fn ([]const u8, bool, ?*anyopaque) Action, ctx: ?*anyopaque) !void {
    _ = try walk(a, root, cb, ctx);
}

pub const GetoptResult = struct {
    flags: u64 = 0,
    optarg: ?[]const u8 = null,
    args: [][]const u8 = &.{},
};

/// Legacy convenience wrapper kept for existing callers. The canonical
/// implementation (with long options, permutation and reference-compatible
/// error messages) lives in getopt.zig; this just adapts its result shape.
pub fn getopt32(a: std.mem.Allocator, argv: []const []const u8, optstring: []const u8) !GetoptResult {
    const opts = try @import("getopt.zig").getopt32(argv, optstring, &.{});
    return .{
        .flags = opts.flags,
        .optarg = opts.optarg,
        .args = try a.dupe([]const u8, opts.args),
    };
}

fn statPath(path: []const u8) ?std.os.linux.Statx {
    var z: [4096:0]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    var stx: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, @ptrCast(&z), 0, .BASIC_STATS, &stx);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    return stx;
}

pub fn is_directory(path: []const u8) bool {
    const st = statPath(path) orelse return false;
    return (st.mode & std.os.linux.S.IFMT) == std.os.linux.S.IFDIR;
}

pub fn executable(path: []const u8) bool {
    const st = statPath(path) orelse return false;
    return (st.mode & std.os.linux.S.IFMT) == std.os.linux.S.IFREG and (st.mode & 0o111) != 0;
}

pub fn find_mount_point(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = std.os.linux.open("/proc/mounts", .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(fd) != .SUCCESS) return error.FileNotFound;
    defer _ = std.os.linux.close(@intCast(fd));
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.os.linux.read(@intCast(fd), &buf, buf.len);
        if (std.os.linux.errno(n) != .SUCCESS or n == 0) break;
        try content.appendSlice(a, buf[0..n]);
    }
    var best: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content.items, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const mp = fields.next() orelse continue;
        if (mp.len == 0) continue;
        const matches = std.mem.eql(u8, mp, "/") or
            (std.mem.startsWith(u8, path, mp) and (path.len == mp.len or path[mp.len] == '/'));
        if (matches and mp.len > best.len) best = mp;
    }
    if (best.len == 0) return error.FileNotFound;
    return a.dupe(u8, best);
}
