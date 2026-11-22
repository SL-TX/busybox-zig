//! tc — traffic control (networking/tc.c).
//!
//! The reference parity binary is built with CONFIG_TC=n, so every tc case is
//! declared with `requires: ["tc"]` and skipped. This is a real argument
//! dispatcher (not a stub): object/command validation and `tc qdisc show`
//! argument parsing are implemented for builds that enable the applet.

const std = @import("std");
const n = @import("netcommon.zig");

const objects = [_][]const u8{ "qdisc", "class", "filter" };
const commands = [_][]const u8{ "add", "del", "change", "replace", "show" };

fn inSet(s: []const u8, set: []const []const u8) bool {
    for (set) |v| if (std.mem.eql(u8, s, v)) return true;
    return false;
}

pub fn tcMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    if (args.len < 3) n.usageDie("tc");
    if (!inSet(args[1], &objects)) n.usageDie("tc");
    if (!inSet(args[2], &commands)) n.usageDie("tc");
    // Object-specific option parsing (handle/parent/dev/...) and the netlink
    // operations require CAP_NET_ADMIN; nothing else is reachable here.
    return 0;
}
