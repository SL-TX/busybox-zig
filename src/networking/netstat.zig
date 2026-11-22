//! netstat — display networking information (reference netstat.c).

const std = @import("std");
const n = @import("netcommon.zig");
const display = @import("display.zig");

pub fn netstatMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("netstat", av, "laentuwxrWp", &.{});
    const f = o.flags;
    const show_routes = (f & (1 << 8)) != 0; // -r
    const numeric = (f & (1 << 3)) != 0; // -n
    var tcp = (f & (1 << 4)) != 0;
    var udp = (f & (1 << 5)) != 0;
    var raw = (f & (1 << 6)) != 0;
    var unix = (f & (1 << 7)) != 0;
    if (!tcp and !udp and !raw and !unix and !show_routes) {
        tcp = true;
        udp = true;
        raw = true;
        unix = true;
    }
    if (f & (1 << 10) != 0) {
        n.plain("showing only processes with your user ID", .{});
    }
    return display.netstatDisplay(show_routes, numeric, tcp, udp, raw, unix, (f & (1 << 0)) != 0 or (f & (1 << 1)) != 0);
}
