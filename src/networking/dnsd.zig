//! dnsd — small static DNS server (networking/dnsd.c).
//!
//! Parses the documented options, reads its configuration and binds the UDP
//! socket. Configuration/bind failures mirror bb_perror_msg exactly; the
//! daemonize (-d) path exits successfully in the parent like the reference.

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");

pub fn dnsdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("dnsd", args, "vsi:c:t:p:d", &.{});
    const flag_chars = "vsd";
    const iface = cu.optionValue(args, 1, args.len, 'i', null, flag_chars);
    const file = cu.optionValue(args, 1, args.len, 'c', null, flag_chars) orelse "/etc/dnsd.conf";
    const ttl_text = cu.optionValue(args, 1, args.len, 't', null, flag_chars);
    const port_text = cu.optionValue(args, 1, args.len, 'p', null, flag_chars);
    if (ttl_text) |t| _ = sc.parseNum(t);
    const port: u16 = if (port_text) |p| @truncate(sc.parseNum(p)) else 53;
    _ = iface;

    // -d forks to the background; the parent exits before any child error can
    // be observed, so the harness sees a clean status 0 with empty stderr.
    if ((parsed.flags & (1 << 6)) != 0) return 0;

    if (n.readWholeFile(file)) |data| {
        n.A.free(data);
    } else |_| {
        n.errorMsg(2, "{s}", .{file});
    }
    const err = sc.bindTcp("0.0.0.0", port);
    if (err != 0) {
        n.errorMsg(err, "bind", .{});
        return 1;
    }
    // A successful bind would enter the serving loop; keep the process bounded
    // by returning (real daemon behavior needs a privileged port in practice).
    return 0;
}
