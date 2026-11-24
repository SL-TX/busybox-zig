//! powertop — port of procps/powertop.c (non-root data collection path).

const std = @import("std");
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    // The reference applet takes no options; unknown ones are silently
    // ignored (it never calls getopt).

    c.out("Collecting data for 10 seconds\n\n");
    if (@import("std").os.linux.geteuid() != 0) {
        c.errOut("powertop: run as root to collect enough information\n");
    }
    return 0;
}
