//! smemcap — port of procps/smemcap.c (tar of /proc memory files).

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

const BLOCK = 512;

/// BusyBox writeheader() uses sprintf("%o"), i.e. digits then NUL -- no
/// leading zero padding in mode/uid/gid/size/mtime fields.
fn octal(field: []u8, value: u64) void {
    var tmp: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{o}", .{value}) catch return;
    @memset(field, 0);
    if (field.len == 0) return;
    const n = @min(text.len, field.len - 1);
    @memcpy(field[0..n], text[0..n]);
}

const StatInfo = struct { mode: u32, mtime: u64 };

/// The checksum field is fixed-width six octal digits with leading zeroes.
fn octalPadded6(field: []u8, value: u64) void {
    var tmp: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{o}", .{value}) catch return;
    @memset(field, '0');
    const n = @min(text.len, field.len);
    @memcpy(field[field.len - n ..], text[text.len - n ..]);
}

fn statInfo(path: []const u8) ?StatInfo {
    const z = c.zstr(std.heap.page_allocator, path) catch return null;
    defer std.heap.page_allocator.free(z);
    var buf: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z.ptr, 0, linux.STATX.BASIC_STATS, &buf);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .mode = buf.mode & 0o7777, .mtime = @intCast(@max(buf.mtime.sec, 0)) };
}

fn header(name: []const u8, size: u64, kind: u8, mode: u32, mtime: u64) void {
    var block: [BLOCK]u8 = std.mem.zeroes([BLOCK]u8);
    const name_len = @min(name.len, block[0..100].len);
    @memcpy(block[0..name_len], name[0..name_len]);
    octal(block[100..108], mode);
    octal(block[108..116], 0);
    octal(block[116..124], 0);
    octal(block[124..136], size);
    octal(block[136..148], mtime);
    @memset(block[148..156], ' ');
    block[156] = kind; // ustar typeflag: '0' regular file, '5' directory
    @memcpy(block[257..265], "ustar  \x00");
    // POSIX checksum: six octal digits, NUL, space. Compute with the checksum
    // field as spaces, then fill it; do not touch the typeflag afterwards.
    var sum: u64 = 0;
    for (block) |byte| sum += byte;
    octalPadded6(block[148..154], sum);
    block[154] = 0;
    block[155] = ' ';
    c.out(&block);
}

fn archive(a: std.mem.Allocator, path: []const u8, name: []const u8) void {
    const data = c.readFile(a, path) orelse return;
    defer a.free(data);
    const info: StatInfo = statInfo(path) orelse .{ .mode = 0o444, .mtime = 0 };
    header(name, data.len, '0', info.mode, info.mtime);
    c.out(data);
    const rem = data.len % BLOCK;
    if (rem != 0) {
        var pad: [BLOCK]u8 = std.mem.zeroes([BLOCK]u8);
        c.out(pad[0 .. BLOCK - rem]);
    }
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    // smemcap.c does xchdir("/proc") and archives relative names.
    archive(a, "/proc/meminfo", "meminfo");
    archive(a, "/proc/version", "version");
    const pids = c.listPids(a, "/proc") catch return 0;
    defer a.free(pids);
    for (pids) |pid| {
        const dirname = std.fmt.allocPrint(a, "{d}", .{pid}) catch continue;
        defer a.free(dirname);
        header(dirname, 0, '5', 0o555, 0);
        const tails = [_][]const u8{ "smaps", "cmdline", "stat" };
        for (tails) |tail| {
            const path = std.fmt.allocPrint(a, "/proc/{d}/{s}", .{ pid, tail }) catch continue;
            defer a.free(path);
            const name = std.fmt.allocPrint(a, "{d}/{s}", .{ pid, tail }) catch continue;
            defer a.free(name);
            archive(a, path, name);
        }
    }
    return 0;
}
