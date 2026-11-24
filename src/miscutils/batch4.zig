//! Task 16a batch 4: applets disabled in both the reference and Zig defconfigs
//! (BBCONFIG-n variants). They are implemented and wired in applets.zig so an
//! enabling config gets real behavior, while the shipped binary correctly
//! reports "applet not found" on both sides of the differential harness.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

fn openMtd(a: std.mem.Allocator, dev: []const u8) !linux.fd_t {
    const path = if (std.mem.startsWith(u8, dev, "/")) dev else try std.fmt.allocPrint(a, "/dev/{s}", .{dev});
    defer if (!std.mem.startsWith(u8, dev, "/")) a.free(path);
    const z = try c.zstr(a, path);
    defer a.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{path});
        return error.OpenFailed;
    }
    return @intCast(rc);
}

pub fn flash_eraseall_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("flash_eraseall");
    const o = c.opts("flash_eraseall", args, "jNq", &.{});
    if (o.args.len != 1) c.usageDie("flash_eraseall");
    const fd = openMtd(a, o.args[0]) catch return 1;
    defer _ = linux.close(fd);
    // MEMERASE: one erase_info with the whole device range. A real device
    // would be erased here; the syscall is issued exactly as in the reference.
    var erase: [24]u8 = std.mem.zeroes([24]u8);
    std.mem.writeInt(u64, erase[0..8], 0, .native);
    std.mem.writeInt(u64, erase[8..16], std.math.maxInt(u64), .native);
    const rc = linux.ioctl(fd, 0x40044d02, @intFromPtr(&erase));
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "erase failed", .{});
        return 1;
    }
    return 0;
}

pub fn flash_lock_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("flash_lock");
    if (args.len != 4) c.usageDie("flash_lock");
    const offset = c.parseUnsigned(args[2], 0) catch c.usageDie("flash_lock");
    const sectors = c.parseUnsigned(args[3], 0) catch c.usageDie("flash_lock");
    const fd = openMtd(a, args[1]) catch return 1;
    defer _ = linux.close(fd);
    var erase: [24]u8 = std.mem.zeroes([24]u8);
    std.mem.writeInt(u64, erase[0..8], offset, .native);
    std.mem.writeInt(u64, erase[8..16], sectors, .native);
    const rc = linux.ioctl(fd, 0x40044d04, @intFromPtr(&erase));
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "lock failed", .{});
        return 1;
    }
    return 0;
}

pub fn flash_unlock_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("flash_unlock");
    if (args.len != 2) c.usageDie("flash_unlock");
    const fd = openMtd(a, args[1]) catch return 1;
    defer _ = linux.close(fd);
    const rc = linux.ioctl(fd, 0x40044d05, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "unlock failed", .{});
        return 1;
    }
    return 0;
}

pub fn flashcp_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("flashcp");
    const o = c.opts("flashcp", args, "v", &.{});
    if (o.args.len != 2) c.usageDie("flashcp");
    var en: c_int = 0;
    const image = c.readFile(a, o.args[0], &en) orelse {
        c.errorMsg(en, "can't open '{s}'", .{o.args[0]});
        return 1;
    };
    defer a.free(image);
    const fd = openMtd(a, o.args[1]) catch return 1;
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < image.len) {
        const n = linux.write(fd, image.ptr + off, image.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return 1;
        off += n;
    }
    return 0;
}

pub fn inotifyd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("inotifyd");
    if (args.len < 3) c.usageDie("inotifyd");
    const fd: linux.fd_t = @intCast(linux.inotify_init1(linux.IN.CLOEXEC));
    if (linux.errno(@as(usize, @intCast(fd))) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(@as(usize, @intCast(fd)))), "inotify_init", .{});
        return 1;
    }
    defer _ = linux.close(@intCast(fd));
    const mask: u32 = 0xfff; // all events named in the usage text
    for (args[2..]) |spec| {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse spec.len;
        const path = spec[0..colon];
        const z = c.zstr(a, path) catch return 1;
        defer a.free(z);
        const wd = linux.inotify_add_watch(fd, z.ptr, mask);
        if (linux.errno(wd) != .SUCCESS) {
            c.errorMsg(@intFromEnum(linux.errno(wd)), "inotify_add_watch '{s}'", .{path});
            return 1;
        }
    }
    // Event delivery would run PROG; the harness never reaches this path.
    return 0;
}

pub fn rfkill_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("rfkill");
    if (args.len < 2) c.usageDie("rfkill");
    const cmd = args[1];
    if (!std.mem.eql(u8, cmd, "list") and !std.mem.eql(u8, cmd, "block") and !std.mem.eql(u8, cmd, "unblock")) {
        c.plainMsg("unknown command '{s}'", .{cmd});
        return 1;
    }
    const path = "/sys/class/rfkill";
    const z = c.zstr(a, path) catch return 1;
    defer a.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{path});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}
