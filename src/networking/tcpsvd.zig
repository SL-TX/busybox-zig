//! tcpsvd / udpsvd — TCP/UDP super-servers (networking/tcpudp.c).

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");

fn run(argc: c_int, argv: [*][*:0]const u8, tcp: bool) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const os = if (tcp) "^+c:+C:i:x:u:l:Eb:+hpt:v" else "^+hEc:u:l:v";
    const parsed = sc.opts(if (tcp) "tcpsvd" else "udpsvd", args, os, &.{});
    const flag_chars = if (tcp) "iEhptv" else "hEv";
    const cmax = cu.optionValue(args, 1, args.len, 'c', null, flag_chars);
    const backlog = cu.optionValue(args, 1, args.len, 'b', null, flag_chars);
    if (cmax) |v| _ = sc.parseNum(v);
    if (backlog) |v| _ = sc.parseNum(v);
    if (parsed.args.len < 3) n.usageDie(if (tcp) "tcpsvd" else "udpsvd");

    const ip = parsed.args[0];
    const port_text = parsed.args[1];
    sc.numericHost(ip);
    const port = sc.lookupPort(port_text);

    // Binding a low port without privileges fails before the accept loop; high
    // ports would enter the (unbounded) serving loop, which parity cases avoid.
    const err = sc.bindTcp(ip, port);
    if (err != 0) {
        n.errorMsg(err, "bind", .{});
        return 1;
    }
    return 0;
}

pub fn tcpsvdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, true);
}

pub fn udpsvdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, false);
}
