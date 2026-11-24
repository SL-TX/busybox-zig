//! klibc resume — restore system state from suspend-to-disk data.

const std = @import("std");
const c = @import("common.zig");
const linux = c.linux;
const bb = c.bb;

fn nameToDev(allocator: std.mem.Allocator, devname: []const u8) u64 {
    if (!std.mem.startsWith(u8, devname, "/dev/")) {
        if (std.mem.indexOfScalar(u8, devname, ':')) |colon| {
            const major = std.fmt.parseInt(u32, devname[0..colon], 10) catch 0xffffffff;
            const minor = std.fmt.parseInt(u32, devname[colon + 1 ..], 10) catch 0xffffffff;
            if (major != 0xffffffff and minor != 0xffffffff)
                return (@as(u64, major) << 8) | minor;
        } else {
            const hex = std.fmt.parseInt(u64, devname, 16) catch 0;
            if (hex != 0) return hex;
        }
    }
    // /dev/NAME or sysfs fallback
    var devpath: []const u8 = devname;
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    if (!std.mem.startsWith(u8, devname, "/dev/")) {
        owned = std.fmt.allocPrint(allocator, "/dev/{s}", .{devname}) catch return 0;
        devpath = owned.?;
    }
    if (c.fileInfo(devpath)) |st| {
        if ((st.mode & linux.S.IFMT) == linux.S.IFBLK) return @as(u64, @intCast(st.rdev));
    }
    // sysfs: /sys/class/block/<name>/dev contains "major:minor"
    const sysname = std.fmt.allocPrint(allocator, "/sys/class/block/{s}/dev", .{devpath[5..]}) catch return 0;
    defer allocator.free(sysname);
    const data = c.readFile(allocator, sysname) catch return 0;
    defer allocator.free(data);
    if (std.mem.indexOfScalar(u8, data, ':')) |p| {
        const major = std.fmt.parseInt(u32, std.mem.trim(u8, data[0..p], " \n\t"), 10) catch return 0;
        const minor = std.fmt.parseInt(u32, std.mem.trim(u8, data[p + 1 ..], " \n\t"), 10) catch return 0;
        return (@as(u64, major) << 8) | minor;
    }
    return 0;
}

pub fn resumeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const allocator = std.heap.page_allocator;
    const args = c.argsFrom(allocator, argv, argc) catch return 1;
    defer allocator.free(args);
    bb.env.setProgramName(c.basename(args[0]));
    if (args.len < 2) c.bb.usage.die(c.basename(args[0]));

    const dev = nameToDev(allocator, args[1]);
    const major = (dev >> 8) & 0xfff;
    if (major == 0) {
        bb.messages.plainMsg("invalid resume device: {s}", .{args[1]});
        return 1;
    }

    var ofs: u64 = 0;
    if (args.len > 2) {
        ofs = std.fmt.parseInt(u64, args[2], 0) catch {
            bb.messages.errorMsgAndDie(22, "invalid number '{s}'", .{args[2]});
        };
    }
    if (ofs != 0) {
        // Writing resume_offset would touch /sys; the sandbox never has it.
        const fd = linux.open("/sys/power/resume_offset", .{ .ACCMODE = .WRONLY }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            bb.messages.errorMsgAndDie(2, "cannot open '/sys/power/resume_offset'", .{});
        }
        var numbuf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&numbuf, "{d}", .{ofs}) catch "";
        c.writeAll(@intCast(fd), s);
        _ = linux.close(@intCast(fd));
    }
    const fd = linux.open("/sys/power/resume", .{ .ACCMODE = .WRONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) {
        bb.messages.errorMsgAndDie(2, "cannot open '/sys/power/resume'", .{});
    }
    var mb: [32]u8 = undefined;
    const s2 = std.fmt.bufPrint(&mb, "{d}:{d}", .{ major, dev & 0xfff }) catch "";
    c.writeAll(@intCast(fd), s2);
    _ = linux.close(@intCast(fd));
    return 1; // klibc-utils exits 255; truncated by dispatcher to 255.
}
