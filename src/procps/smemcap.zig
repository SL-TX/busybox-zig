//! smemcap — port of procps/smemcap.c (tar of /proc memory files).

const std = @import("std");
const c = @import("common.zig");

const BLOCK = 512;

fn octal(field: []u8, value: u64) void {
    var tmp: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{o}", .{value}) catch return;
    @memset(field, '0');
    if (field.len == 0) return;
    const start = field.len - 1 - @min(text.len, field.len - 1);
    const body = text[0..@min(text.len, field.len - 1)];
    @memcpy(field[start .. start + body.len], body);
}

fn header(path: []const u8, size: u64, kind: u8) void {
    var block: [BLOCK]u8 = std.mem.zeroes([BLOCK]u8);
    const name_len = @min(path.len, block[0..100].len);
    @memcpy(block[0..name_len], path[0..name_len]);
    octal(block[100..108], 0o644);
    octal(block[108..116], 0);
    octal(block[116..124], 0);
    octal(block[124..136], size);
    octal(block[136..148], 0);
    @memset(block[148..156], ' ');
    block[156] = kind;
    @memcpy(block[257..263], "ustar ");
    @memcpy(block[263..265], "00");
    // Compute the POSIX checksum.
    var sum: u64 = 0;
    for (block) |byte| sum += byte;
    octal(block[148..156], sum);
    block[155] = 0;
    block[156] = ' ';
    c.out(&block);
}

fn archive(a: std.mem.Allocator, path: []const u8) void {
    const data = c.readFile(a, path) orelse return;
    defer a.free(data);
    header(path, data.len, '0');
    c.out(data);
    const rem = data.len % BLOCK;
    if (rem != 0) {
        var pad: [BLOCK]u8 = std.mem.zeroes([BLOCK]u8);
        c.out(pad[0 .. BLOCK - rem]);
    }
    var extra: [BLOCK]u8 = std.mem.zeroes([BLOCK]u8);
    c.out(&extra);
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    archive(a, "/proc/meminfo");
    archive(a, "/proc/version");
    const pids = c.listPids(a, "/proc") catch return 0;
    defer a.free(pids);
    for (pids) |pid| {
        header(std.fmt.allocPrint(a, "{d}", .{pid}) catch continue, 0, '5');
        const tails = [_][]const u8{ "smaps", "cmdline", "stat" };
        for (tails) |name| {
            const path = std.fmt.allocPrint(a, "/proc/{d}/{s}", .{ pid, name }) catch continue;
            defer a.free(path);
            archive(a, path);
        }
    }
    return 0;
}
