//! lsmod — print /proc/modules verbatim (modprobe-small flavour).

const std = @import("std");
const c = @import("common.zig");

pub fn lsmodMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    const data = c.readFile("/proc/modules") orelse {
        c.msg(2, "can't open '/proc/modules'", .{});
        return 1;
    };
    c.out(data);
    return 0;
}
