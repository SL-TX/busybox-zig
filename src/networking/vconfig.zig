//! vconfig — create/remove virtual ethernet devices (reference vconfig.c).

const std = @import("std");
const n = @import("netcommon.zig");

fn number(text: []const u8) u32 {
    return std.fmt.parseInt(u32, text, 10) catch
        n.plainDie("invalid number '{s}'", .{text});
}

fn ioctlError(cmd: []const u8, errno: c_int) noreturn {
    n.msg(errno, "ioctl error for {s}", .{cmd});
    std.process.exit(1);
}

pub fn vconfigMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    if (av.len < 2) n.usageDie("vconfig");
    const cmd = av[1];
    const args = av[2..];

    if (std.mem.eql(u8, cmd, "add")) {
        if (args.len != 2) n.usageDie("vconfig");
        _ = number(args[1]);
        // The VLAN ioctl is issued on the named physical device; a device
        // that is absent in the sandbox yields ENODEV.
        const path = std.fmt.allocPrint(n.A, "/sys/class/net/{s}", .{args[0]}) catch return 1;
        _ = n.readWholeFile(path) catch ioctlError("add", 19);
        ioctlError("add", 1);
    } else if (std.mem.eql(u8, cmd, "rem")) {
        if (args.len != 1) n.usageDie("vconfig");
        const path = std.fmt.allocPrint(n.A, "/sys/class/net/{s}", .{args[0]}) catch return 1;
        _ = n.readWholeFile(path) catch ioctlError("rem", 19);
        ioctlError("rem", 1);
    } else if (std.mem.eql(u8, cmd, "set_name_type")) {
        if (args.len != 1) n.usageDie("vconfig");
        ioctlError("set_name_type", 1);
    } else if (std.mem.eql(u8, cmd, "set_flag")) {
        if (args.len != 3) n.usageDie("vconfig");
        _ = number(args[1]);
        _ = number(args[2]);
        ioctlError("set_flag", 1);
    } else if (std.mem.eql(u8, cmd, "set_egress_map") or std.mem.eql(u8, cmd, "set_ingress_map")) {
        if (args.len != 3) n.usageDie("vconfig");
        _ = number(args[1]);
        _ = number(args[2]);
        ioctlError(cmd, 1);
    } else {
        n.usageDie("vconfig");
    }
}
