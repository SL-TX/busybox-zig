//! route — show or edit the kernel routing tables (reference route.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;
const display = @import("display.zig");

pub fn routeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("route", av, "A:ne", &.{});
    const args = o.args;
    if ((o.flags & (1 << 0)) != 0) {
        const family = o.optarg orelse "";
        if (!std.mem.eql(u8, family, "inet") and !std.mem.eql(u8, family, "inet6")) n.usageDie("route");
    }
    if (args.len == 0) {
        return display.routeDisplay(false, (o.flags & (1 << 1)) != 0);
    }
    const verb = args[0];
    if (!std.mem.eql(u8, verb, "add") and !std.mem.eql(u8, verb, "del") and !std.mem.eql(u8, verb, "delete"))
        n.usageDie("route");
    if (args.len < 2) n.usageDie("route");
    const target = args[1];
    if (!std.mem.eql(u8, target, "default") and n.ipToInt(target) == null and
        !std.mem.eql(u8, verb, "del") and !std.mem.eql(u8, verb, "delete"))
    {
        n.plainDie("resolving {s}", .{target});
    }
    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (linux.errno(fd) == .SUCCESS) _ = linux.close(@intCast(fd));
    const op = if (std.mem.eql(u8, verb, "add")) "SIOCADDRT" else "SIOCDELRT";
    n.msg(1, "{s}", .{op});
    return 1;
}
