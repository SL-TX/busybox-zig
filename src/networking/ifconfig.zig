//! ifconfig — configure or display network interfaces (reference ifconfig.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;
const display = @import("display.zig");

const SIOCGIFFLAGS: u32 = 0x8913;

pub fn ifconfigMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const args = av[1..];

    // The reference recognizes only the exact token "-a"; any other leading
    // dash is simply an (invalid) interface name.
    const show_all = args.len == 1 and std.mem.eql(u8, args[0], "-a");
    if (args.len == 0 or show_all) return display.ifconfigDisplay(show_all, null);

    const pos: usize = 0;
    const name = args[pos];
    var ifr: [40]u8 = std.mem.zeroes([40]u8);
    if (name.len < 16) @memcpy(ifr[0..name.len], name);
    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (linux.errno(fd) != .SUCCESS) return 1;
    defer _ = linux.close(@intCast(fd));
    const rc = linux.ioctl(@intCast(fd), SIOCGIFFLAGS, @intFromPtr(&ifr));
    if (linux.errno(rc) != .SUCCESS) {
        if (args.len > pos + 1) {
            n.msg(19, "SIOCGIFFLAGS", .{});
        } else {
            n.plain("{s}: error fetching interface information: Device not found", .{name});
        }
        return 1;
    }
    return display.ifconfigDisplay(show_all, name);
}
