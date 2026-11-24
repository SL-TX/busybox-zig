//! runlevel — print previous/current runlevel from a utmp file
//! (reference miscutils/runlevel.c).

const std = @import("std");
const c = @import("common.zig");
const bb = @import("libbb_zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    const path = if (args.len > 1) args[1] else "/var/run/utmp";
    const entries = bb.utmp.readEntries(a, path) catch {
        c.out("unknown\n");
        return 1;
    };
    defer a.free(entries);
    for (entries) |e| {
        if (e.ut_type == @intFromEnum(bb.utmp.UtType.run_lvl)) {
            var prev: u8 = @intCast(@as(u32, @bitCast(e.ut_pid)) / 256);
            if (prev == 0) prev = 'N';
            const cur: u8 = @intCast(@as(u32, @bitCast(e.ut_pid)) % 256);
            c.printfOut("{c} {c}\n", .{ prev, cur });
            return 0;
        }
    }
    c.out("unknown\n");
    return 1;
}
