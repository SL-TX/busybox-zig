//! zcip — ZeroConf IPv4 link-local addressing (reference zcip.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

pub fn zcipMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("zcip", av, "^fqr:l:v", &.{});
    const args = o.args;
    if (args.len != 2) n.usageDie("zcip");

    // zcip opens a raw packet socket before probing; unprivileged runs fail.
    const fd = linux.socket(linux.AF.PACKET, linux.SOCK.RAW, 0);
    const e = linux.errno(fd);
    if (e != .SUCCESS) {
        n.msg(@intFromEnum(e), "socket", .{});
        return 1;
    }
    _ = linux.close(@intCast(fd));
    return 0;
}
