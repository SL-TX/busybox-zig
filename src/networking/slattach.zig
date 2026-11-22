//! slattach — configure a serial line as a SLIP interface (reference slattach.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

pub fn slattachMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts("slattach", av, "^p:s:c:ehmLF", &.{});
    const args = o.args;
    if (args.len != 1) n.usageDie("slattach");

    const dev = args[0];
    const path = if (dev.len > 0 and dev[0] == '/') dev else std.fmt.allocPrint(n.A, "/dev/{s}", .{dev}) catch return 1;
    const z = n.zstr(path) catch return 1;
    const fd = linux.open(z, .{ .ACCMODE = .RDWR }, 0);
    const e = linux.errno(fd);
    if (e != .SUCCESS) {
        n.msg(@intFromEnum(e), "can't open '{s}'", .{path});
        return 1;
    }
    _ = linux.close(@intCast(fd));
    return 0;
}
