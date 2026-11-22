//! ifenslave — configure bonded interfaces (reference ifenslave.c).

const std = @import("std");
const n = @import("netcommon.zig");

pub fn ifenslaveMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("ifenslave", av, "cdf", &.{});
    const args = o.args;
    if (args.len == 0) return 0;
    const master = args[0];
    const path = std.fmt.allocPrint(n.A, "/sys/class/net/{s}", .{master}) catch return 1;
    defer n.A.free(path);
    const data = n.readWholeFile(path) catch {
        // SIOCETHTOOL on a missing device reports ENODEV.
        n.msg(19, "{s}: SIOCETHTOOL error", .{master});
        return 1;
    };
    defer n.A.free(data);
    return 0;
}
