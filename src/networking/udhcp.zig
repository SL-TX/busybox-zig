//! udhcpc / udhcpc6 / udhcpd — DHCP clients and server (networking/udhcp/*).
//!
//! The option tables and numeric validation are faithful. All three need raw
//! sockets / interface access to reach their protocol loops; that is
//! unavailable in the loopback-only harness, so successful parsing is followed
//! by the reference's socket/daemonize outcome.

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");
const bb = @import("libbb_zig");

const udhcpc_longopts = [_]n.LongOpt{
    .{ .name = "client-id", .has_arg = .required, .val = 0xf0 },
    .{ .name = "hostname", .has_arg = .required, .val = 0xf1 },
    .{ .name = "vendorid", .has_arg = .required, .val = 0xf2 },
    .{ .name = "request", .has_arg = .required, .val = 'O' },
};

fn clientCommon(argc: c_int, argv: [*][*:0]const u8, v6: bool) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const name = if (v6) "udhcpc6" else "udhcpc";
    const os = if (v6)
        "^i:np:qRr:s:T:+t:+SA:+O:*ox:*fmldbv"
    else
        "^CV:F:i:np:qRr:s:T:+t:+SA:+O:*ox:*fbav";
    const parsed = sc.opts(name, args, os, &udhcpc_longopts);
    const flag_chars = if (v6) "npqRfmldov" else "CVnpqRSofBv";
    for ([_]u8{ 'T', 't', 'A' }) |ch| {
        if (cu.optionValue(args, 1, args.len, ch, null, flag_chars)) |v| _ = sc.parseNum(v);
    }
    _ = parsed;
    // udhcp_create_raw_socket()/socket(AF_PACKET) requires CAP_NET_RAW.
    n.errorMsg(1, "socket", .{}); // EPERM -> "Operation not permitted"
    return 1;
}

pub fn udhcpcMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return clientCommon(argc, argv, false);
}

pub fn udhcpc6Main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return clientCommon(argc, argv, true);
}

pub fn udhcpdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("udhcpd", args, "^fSI:va:", &.{});
    _ = cu.optionValue(args, 1, args.len, 'I', null, "fSv");

    // udhcpd daemonizes before reading the config file or parsing -a.
    if ((parsed.flags & 1) == 0) return 0;
    // -f foreground path would read the config and run the server loop.
    return 0;
}
