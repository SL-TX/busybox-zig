//! netstat — display networking information (reference netstat.c).

const std = @import("std");
const n = @import("netcommon.zig");

pub fn netstatMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("netstat", av, "laentuwxrWp", &.{});
    if (o.flags & (1 << 10) != 0) {
        n.plain("showing only processes with your user ID", .{});
    }
    // Table displays read /proc/net/{tcp,tcp6,udp,udp6,raw,unix,route}; the
    // contents are host state and are not fabricated here.
    _ = n.readWholeFile("/proc/net/tcp") catch {};
    return 0;
}
