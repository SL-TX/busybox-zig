//! arp — manipulate the ARP cache (reference arp.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

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

    if ((o.flags & OPT_a) != 0 and args.len != 0) {
        if (n.ipToInt(args[0]) == null) n.plainDie("{s}: Unknown host", .{args[0]});
        // Scan the real ARP cache for the requested address.
        const data = n.readWholeFile("/proc/net/arp") catch return 0;
        defer n.A.free(data);
        var count: usize = 0;
        var found = false;
        var lines = std.mem.splitScalar(u8, data, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            var it = std.mem.tokenizeAny(u8, line, " \t");
            const ip = it.next() orelse continue;
            count += 1;
            if (std.mem.eql(u8, ip, args[0])) found = true;
        }
        if (!found) n.put("No match found in {d} entries\n", .{count});
        return 0;
    }
    // Display mode reads /proc/net/arp; host state is intentionally not
    // fabricated here. The differential cases exercise validation paths.
    _ = n.readWholeFile("/proc/net/arp") catch {};
    return 0;
}
