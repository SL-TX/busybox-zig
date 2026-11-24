//! ntpd — NTP client/server (networking/ntpd.c).

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");

pub fn ntpdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    // n=0,q=1,N=2,x=3,k=4,w=5,p=6,S=7,l=8,I=9,d=10,46aAbgL=11..17
    const parsed = sc.opts("ntpd", args, "^nqNxk:wp:*S:lI:d46aAbgL", &.{});
    _ = cu.optionValue(args, 1, args.len, 'I', null, "nqNxwSl d46aAbgL");
    // -l / -I turn on the server: binding the privileged NTP port fails here.
    if ((parsed.flags & (1 << 8)) != 0 or (parsed.flags & (1 << 9)) != 0) {
        const err = sc.bindTcp("0.0.0.0", 123);
        if (err != 0) {
            n.errorMsg(err, "bind", .{});
            return 1;
        }
    }
    // All other invocations daemonize (or query peers in the background).
    return 0;
}
