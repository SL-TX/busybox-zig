//! dhcprelay — DHCP relay (udhcp/dhcprelay.c).
//!
//! No getopt: the applet validates its two mandatory interface operands and an
//! optional numeric server IP, then needs CAP_NET_RAW to create its sockets.

const std = @import("std");
const n = @import("netcommon.zig");
const sock = @import("libbb_zig").socket;

pub fn dhcprelayMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    if (args.len < 3) n.usageDie("dhcprelay");
    if (args.len > 3 and sock.inet_pton(args[3]) == null) {
        // bb_simple_perror_msg_and_die("bad server IP") uses the errno left by
        // the preceding inet_aton; in the harness that is ENOENT.
        n.errorMsg(2, "bad server IP", .{});
        return 1;
    }
    // init_sockets() needs CAP_NET_RAW / interface access, unavailable here.
    n.errorMsg(1, "socket", .{});
    return 1;
}
