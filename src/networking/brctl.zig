//! brctl — manage ethernet bridges (reference brctl.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

const SIOCBRADDBR: u32 = 0x89a0;
const SIOCBRDELBR: u32 = 0x89a1;

fn isBridge(br: []const u8) bool {
    const path = std.fmt.allocPrint(n.A, "/sys/class/net/{s}/bridge", .{br}) catch return false;
    defer n.A.free(path);
    _ = n.readWholeFile(path) catch return false;
    return true;
}

fn needArg(args: []const []const u8, count: usize, name: []const u8) void {
    if (args.len < count) n.usageDie(name);
}

pub fn brctlMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    if (av.len < 2) n.usageDie("brctl");
    const cmd = av[1];
    const args = av[2..];

    if (std.mem.eql(u8, cmd, "show")) {
        if (args.len == 0) {
            n.usageDie("brctl");
        }
        var rc: c_int = 0;
        for (args) |br| {
            if (!isBridge(br)) {
                n.plain("bridge {s} does not exist", .{br});
                rc = 1;
            }
        }
        return rc;
    }

    if (std.mem.eql(u8, cmd, "addif") or std.mem.eql(u8, cmd, "delif")) {
        needArg(args, 2, "brctl");
        const br = args[0];
        if (!isBridge(br)) {
            n.plain("bridge {s} does not exist", .{br});
            return 1;
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd, "addbr") or std.mem.eql(u8, cmd, "delbr")) {
        needArg(args, 1, "brctl");
        const fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (linux.errno(fd) == .SUCCESS) {
            const z = n.zstr(args[0]) catch return 1;
            const req = linux.ioctl(@intCast(fd), if (std.mem.eql(u8, cmd, "addbr")) SIOCBRADDBR else SIOCBRDELBR, @intFromPtr(z.ptr));
            const e = linux.errno(req);
            _ = linux.close(@intCast(fd));
            if (e == .SUCCESS) return 0;
            n.msg(@intFromEnum(e), "bridge {s}", .{args[0]});
            return 1;
        }
        return 1;
    }

    const sysfs_files = .{
        .{ "showmacs", "showmacs" },
        .{ "showstp", "stp_state" },
        .{ "setageing", "ageing_time" },
        .{ "setfd", "forward_delay" },
        .{ "sethello", "hello_time" },
        .{ "setmaxage", "max_message_age" },
        .{ "setbridgeprio", "priority" },
        .{ "setportprio", "priority" },
        .{ "setpathcost", "path_cost" },
        .{ "stp", "stp_state" },
    };
    inline for (sysfs_files) |pair| {
        if (std.mem.eql(u8, cmd, pair[0])) {
            const need = if (std.mem.eql(u8, cmd, "showmacs") or std.mem.eql(u8, cmd, "showstp")) @as(usize, 1) else 2;
            needArg(args, need, "brctl");
            const br = args[0];
            if ((std.mem.eql(u8, cmd, "showmacs") or std.mem.eql(u8, cmd, "showstp")) and !isBridge(br)) {
                n.plain("bridge {s} does not exist", .{br});
                return 1;
            }
            const path = std.fmt.allocPrint(n.A, "{s}/bridge/{s}", .{ br, pair[1] }) catch return 1;
            defer n.A.free(path);
            const z = n.zstr(path) catch return 1;
            const fd = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(fd) != .SUCCESS) {
                n.msg(2, "can't open '{s}'", .{path});
                return 1;
            }
            _ = linux.close(@intCast(fd));
            return 0;
        }
    }

    n.plainDie("invalid argument '{s}' to 'brctl'", .{cmd});
}
