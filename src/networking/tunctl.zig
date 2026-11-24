//! tunctl — create or delete TUN/TAP interfaces (reference tunctl.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

const TUNSETIFF: u32 = 0x400454CA;

pub fn tunctlMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    _ = n.opts("tunctl", av, "^f:t:d:u:g:b", &.{});

    const device = "/dev/net/tun";
    const path = n.zstr(device) catch return 1;
    const fd = linux.open(path, .{ .ACCMODE = .RDWR }, 0);
    const e = linux.errno(fd);
    if (e != .SUCCESS) {
        n.msg(@intFromEnum(e), "can't open '{s}'", .{device});
        return 1;
    }
    const fdi: linux.fd_t = @intCast(fd);
    defer _ = linux.close(fdi);

    var ifr: [40]u8 = std.mem.zeroes([40]u8);
    const rc = linux.ioctl(fdi, TUNSETIFF, @intFromPtr(&ifr));
    const ie = linux.errno(rc);
    if (ie != .SUCCESS) {
        n.errnoOnly(@intFromEnum(ie));
        return 1;
    }
    return 0;
}
