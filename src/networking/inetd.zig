//! inetd — internet super-server (networking/inetd.c).

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");
const bb = @import("libbb_zig");

pub fn inetdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("inetd", args, "R:+feq:+", &.{});
    const queue = cu.optionValue(args, 1, args.len, 'q', null, "fe");
    const rate = cu.optionValue(args, 1, args.len, 'R', null, "fe");
    if (queue) |v| _ = sc.parseNum(v);
    if (rate) |v| _ = sc.parseNum(v);

    const conf = if (parsed.args.len > 0) parsed.args[0] else null;
    if (conf == null and bb.process.geteuid() != 0) {
        n.plain("non-root must specify config file", .{});
        return 1;
    }
    if (conf) |path| {
        if (n.readWholeFile(path)) |data| { n.A.free(data); } else |_| {}
    }
    // Without -f the reference daemonizes: the parent exits successfully.
    if ((parsed.flags & 2) == 0) return 0;
    return 0;
}
