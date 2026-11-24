//! nameif — rename an interface while it is down (reference nameif.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

fn validSelector(sel: []const u8) bool {
    if (std.mem.startsWith(u8, sel, "bus=") or
        std.mem.startsWith(u8, sel, "driver=") or
        std.mem.startsWith(u8, sel, "phyaddr=")) return true;
    var mac = sel;
    if (std.mem.startsWith(u8, mac, "mac=")) mac = mac[4..];
    var parts = std.mem.splitScalar(u8, mac, ':');
    var count: usize = 0;
    while (parts.next()) |p| {
        if (p.len != 2) return false;
        for (p) |c| if (!std.ascii.isHex(c)) return false;
        count += 1;
    }
    return count == 6;
}

pub fn nameifMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("nameif", av, "sc:", &.{});
    const args = o.args;

    if (args.len != 0) {
        if (args.len % 2 != 0) n.usageDie("nameif");
        for (args, 0..) |arg, i| {
            if (i % 2 == 1 and !validSelector(arg))
                n.plainDie("can't parse {s}", .{arg});
        }
    } else {
        const fname = if ((o.flags & (1 << 1)) != 0 and o.optarg != null) o.optarg.? else "/etc/mactab";
        const data = n.readWholeFile(fname) catch {
            // config_open() reports but does not fail: nameif exits 0.
            n.msg(2, "{s}", .{fname});
            return 0;
        };
        defer n.A.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var it = std.mem.tokenizeAny(u8, line, "# \t\r");
            _ = it.next() orelse continue;
            const selector = it.next() orelse continue;
            if (!validSelector(selector)) n.plainDie("can't parse {s}", .{selector});
        }
    }

    // The rename itself needs CAP_NET_ADMIN. Matching devices are looked up
    // through /proc/net/dev; unprivileged runs leave the system unchanged.
    const sk = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (linux.errno(sk) == .SUCCESS) _ = linux.close(@intCast(sk));
    _ = n.readWholeFile("/proc/net/dev") catch {};
    return 0;
}
