//! ttysize — print terminal dimensions, or 80x24 (reference miscutils/ttysize.c).
//! Each argument that begins with 'w'/'h' selects width/height; unknown
//! arguments contribute nothing. A single newline is always printed.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    var w: u32 = 80;
    var h: u32 = 24;
    var wsz: std.posix.winsize = undefined;
    const tiocgwinsz: u32 = 0x5413;
    if (linux.errno(linux.ioctl(0, tiocgwinsz, @intFromPtr(&wsz))) == .SUCCESS or
        linux.errno(linux.ioctl(1, tiocgwinsz, @intFromPtr(&wsz))) == .SUCCESS or
        linux.errno(linux.ioctl(2, tiocgwinsz, @intFromPtr(&wsz))) == .SUCCESS)
    {
        w = wsz.col;
        h = wsz.row;
    }
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    if (args.len <= 1) {
        c.printfOut("{d} {d}", .{ w, h });
    } else {
        // The reference advances the format string after *every* argument,
        // even non-matching ones, so a later match can emit a leading space.
        var first = true;
        for (args[1..]) |arg| {
            const sep = if (first) "" else " ";
            if (arg.len > 0 and arg[0] == 'w') {
                c.out(sep);
                c.printfOut("{d}", .{w});
            }
            if (arg.len > 0 and arg[0] == 'h') {
                c.out(sep);
                c.printfOut("{d}", .{h});
            }
            first = false;
        }
    }
    c.out("\n");
    return 0;
}
