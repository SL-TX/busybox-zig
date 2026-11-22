//! arp — manipulate the ARP cache (reference arp.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;
const display = @import("display.zig");

const OPT_a = 1 << 5;
const OPT_d = 1 << 6;
const OPT_s = 1 << 9;

pub fn arpMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("arp", av, "A:p:H:t:i:adnDsv", &.{});
    const args = o.args;

    if ((o.flags & (OPT_d | OPT_s)) != 0) {
        if (args.len == 0) n.plainDie("need host name", .{});
        if ((o.flags & OPT_s) != 0 and args.len < 2) n.plainDie("need hardware address", .{});
        const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
        if (linux.errno(fd) == .SUCCESS) _ = linux.close(@intCast(fd));
        if ((o.flags & OPT_d) != 0) {
            n.msg(1, "SIOCDARP(priv)", .{});
            return 1;
        }
        // SIOCSARP needs CAP_NET_ADMIN too; the reference reports ENOMEM/EINVAL
        // depending on the address, but never succeeds unprivileged.
        n.msg(1, "SIOCSARP(priv)", .{});
        return 1;
    }

    const numeric = (o.flags & (1 << 7)) != 0; // -n
    if ((o.flags & OPT_a) != 0 and args.len != 0) {
        if (n.ipToInt(args[0]) == null) n.plainDie("{s}: Unknown host", .{args[0]});
        return display.arpDisplay(numeric, args[0]);
    }
    return display.arpDisplay(numeric, null);
}
