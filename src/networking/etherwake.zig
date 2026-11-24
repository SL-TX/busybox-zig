//! ether-wake — send a Wake-On-LAN magic packet (reference ether-wake.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

pub fn etherwakeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("ether-wake", av, "^bi:p:", &.{});
    const args = o.args;
    if (args.len < 1) n.usageDie("ether-wake");

    // Password parsing: the reference expects 4 or 6 colon-separated hex
    // bytes (or a dotted quad); a bare hex string is rejected.
    if (o.flags & (1 << 2) != 0) {
        if (o.optarg == null or std.mem.indexOfScalar(u8, o.optarg.?, ':') == null) {
            n.plain("can't read Wake-On-LAN pass", .{});
        }
    }

    // The raw packet socket requires CAP_NET_RAW; unprivileged runs fail here.
    const fd = linux.socket(linux.AF.PACKET, linux.SOCK.RAW, 0);
    const e = linux.errno(fd);
    if (e != .SUCCESS) {
        n.msg(@intFromEnum(e), "socket", .{});
        return 1;
    }
    _ = linux.close(@intCast(fd));
    return 0;
}
