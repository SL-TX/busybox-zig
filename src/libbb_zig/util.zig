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
