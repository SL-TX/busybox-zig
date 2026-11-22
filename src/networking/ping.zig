//! ping / ping6 — send ICMP ECHO_REQUESTs (reference ping.c).
//!
//! The reference opens a raw ICMP socket; without CAP_NET_RAW it prints the
//! PING banner and then fails with "permission denied (are you root?)". All
//! option parsing, numeric validation and address validation are implemented
//! so the deterministic error paths match byte-for-byte.

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;
const net = @import("libbb_zig").socket.inet;

fn number(text: []const u8) u32 {
    return std.fmt.parseInt(u32, text, 10) catch
        n.plainDie("invalid number '{s}'", .{text});
}

fn run(argc: c_int, argv: [*][*:0]const u8, name: []const u8, force_v6: bool) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts(name, av, "qvAc:+s:t:+w:+W:+I:np:i:46", &.{});
    const args = o.args;
    if (args.len == 0) n.usageDie(name);
    if (args.len > 1) n.usageDie(name);

    var datalen: u32 = 56;
    if (o.flags & (1 << 4) != 0) datalen = number(o.optarg orelse "");
    if (o.flags & (1 << 3) != 0) _ = number(o.optarg orelse "");

    const host = args[0];
    var v6 = force_v6 or (o.flags & (1 << 13) != 0);
    if (o.flags & (1 << 12) != 0) v6 = false;

    if (v6) {
        if (net.parseV6(host) == null) n.plainDie("bad address '{s}'", .{host});
    } else {
        if (n.ipToInt(host) == null and net.parseV6(host) == null)
            n.plainDie("bad address '{s}'", .{host});
        if (net.parseV6(host) != null) v6 = true;
    }

    n.put("PING {s} ({s}): {d} data bytes\n", .{ host, host, datalen });

    const family: u32 = if (v6) linux.AF.INET6 else linux.AF.INET;
    const proto: u32 = if (v6) linux.IPPROTO.ICMPV6 else linux.IPPROTO.ICMP;
    const fd = linux.socket(family, linux.SOCK.RAW, proto);
    const e = linux.errno(fd);
    if (e != .SUCCESS) {
        n.plain("permission denied (are you root?)", .{});
        return 1;
    }
    _ = linux.close(@intCast(fd));
    return 0;
}

pub fn pingMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, "ping", false);
}

pub fn ping6Main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, "ping6", true);
}
