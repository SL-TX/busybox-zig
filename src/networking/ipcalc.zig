//! ipcalc — calculate network settings from an IPv4 address (reference ipcalc.c).
//! Pure computation: no system state, so fully deterministic.

const std = @import("std");
const n = @import("netcommon.zig");

const NETMASK: u32 = 0x01;
const BROADCAST: u32 = 0x02;
const NETWORK: u32 = 0x04;
const NETPREFIX: u32 = 0x08;
const HOSTNAME: u32 = 0x10;
const SILENT: u32 = 0x20;

const longopts = [_]n.LongOpt{
    .{ .name = "netmask", .val = 'm' },
    .{ .name = "broadcast", .val = 'b' },
    .{ .name = "network", .val = 'n' },
    .{ .name = "prefix", .val = 'p' },
    .{ .name = "hostname", .val = 'h' },
    .{ .name = "silent", .val = 's' },
};

fn classfulNetmask(ip: u32) u32 {
    if ((ip & 0xC0000000) == 0xC0000000) return 0xFFFFFF00;
    if ((ip & 0x80000000) == 0x80000000) return 0xFFFF0000;
    if ((ip & 0x80000000) == 0) return 0xFF000000;
    return 0;
}

fn prefixToMask(p: u32) u32 {
    if (p == 0) return 0;
    const shift: u5 = @intCast(32 - p);
    return @as(u32, 0xFFFFFFFF) << shift;
}

fn die(silent: bool, comptime fmt: []const u8, args: anytype) noreturn {
    if (!silent) n.plain(fmt, args);
    std.process.exit(1);
}

pub fn ipcalcMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("ipcalc", av, "mbnphs", &longopts);
    const opt = o.flags;
    const args = o.args;
    const silent = (opt & SILENT) != 0;

    if ((opt & (BROADCAST | NETWORK | NETPREFIX)) == 0) {
        if (opt == 0 or args.len >= 2) n.usageDie("ipcalc");
    }

    if (args.len == 0) n.usageDie("ipcalc");

    // Split ADDRESS[/PREFIX] exactly like the reference.
    var ipstr = args[0];
    var netmask: u32 = 0;
    var have_netmask = false;
    if (std.mem.indexOfScalar(u8, ipstr, '/')) |slash| {
        const pstr = ipstr[slash + 1 ..];
        ipstr = ipstr[0..slash];
        if (pstr.len != 0) {
            const p = std.fmt.parseInt(u32, pstr, 10) catch
                die(silent, "invalid number '{s}'", .{pstr});
            if (p > 32) die(silent, "number {d} is not in 0..32 range", .{p});
            netmask = prefixToMask(p);
            have_netmask = true;
        }
    }

    const ip = n.ipToInt(ipstr) orelse die(silent, "bad IP address: {s}", .{args[0]});

    if (args.len >= 2) {
        if (have_netmask) die(silent, "use prefix or netmask, not both", .{});
        netmask = n.ipToInt(args[1]) orelse die(silent, "bad netmask: {s}", .{args[1]});
    } else if (!have_netmask) {
        netmask = classfulNetmask(ip);
    }

    var b: [16]u8 = undefined;
    if ((opt & NETMASK) != 0) n.put("NETMASK={s}\n", .{n.intToIp(netmask, &b)});

    if ((opt & BROADCAST) != 0) {
        const bc = (ip & netmask) | ~netmask;
        n.put("BROADCAST={s}\n", .{n.intToIp(bc, &b)});
    }
    if ((opt & NETWORK) != 0) {
        const net = ip & netmask;
        n.put("NETWORK={s}\n", .{n.intToIp(net, &b)});
    }
    if ((opt & NETPREFIX) != 0) {
        n.put("PREFIX={d}\n", .{@popCount(netmask)});
    }
    if ((opt & HOSTNAME) != 0) {
        // 127.0.0.1 is the only address with a guaranteed local answer
        // (/etc/hosts). For any other address the reference performs a
        // reverse lookup which is system dependent.
        if (ip == 0x7F000001) {
            n.put("HOSTNAME=localhost\n", .{});
        } else {
            die(silent, "can't find hostname for {s}", .{args[0]});
        }
    }
    return 0;
}
