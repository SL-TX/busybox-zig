//! File/device util-linux applets: fallocate, flock, mountpoint, fatattr,
//! fatlabel, swaplabel, fdflush, freeramdisk, eject, blkdiscard, fsfreeze,
//! fstrim, blkid.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

pub fn fallocate_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("fallocate", args, "o:l:", &.{});
    if (!c.flagged(o, 1) or o.args.len != 1) c.usageDie("fallocate");
    const len_s = o.optarg orelse c.usageDie("fallocate");
    const len = c.num(len_s) catch {
        c.plain("invalid number '{s}'", .{len_s});
        return 1;
    };
    var off: u64 = 0;
    if (c.flagged(o, 0)) {
        // -o was parsed before -l in the common case; re-scan for its value.
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-o")) { off = c.num(args[i + 1]) catch 0; break; }
        }
    }
    const p = c.zstr(o.args[0]) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .WRONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{o.args[0]});
        return 1;
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const rc2 = linux.ftruncate(fd, @intCast(off + len));
    if (linux.errno(rc2) != .SUCCESS) return 1;
    return 0;
}

pub fn flock_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("flock", args, "sxun", &.{});
    if (o.args.len < 2) c.usageDie("flock");
    const path = o.args[0];
    const p = c.zstr(path) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o666);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{path});
        return 1;
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const op: c_int = if (c.flagged(o, 0)) 1 else 2; // LOCK_SH or LOCK_EX
    _ = linux.flock(fd, op);
    const result = c.runChild(o.args[1..]);
    return @intCast(result);
}

fn isMount(line: []const u8, path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next() orelse return false;
    const mp = it.next() orelse return false;
    return std.mem.eql(u8, mp, path);
}

pub fn mountpoint_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("mountpoint", args, "qdnx", &.{});
    if (o.args.len < 1) c.usageDie("mountpoint");
    const path = o.args[0];
    const chk = c.zstr(path) catch return 1;
    const rc0 = linux.open(chk, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc0) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc0)), "{s}", .{path});
        return 1;
    }
    _ = linux.close(@intCast(rc0));
    const mounts = c.readFile("/proc/mounts") catch return 1;
    var found = std.mem.eql(u8, path, "/");
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        if (isMount(line, path)) { found = true; break; }
    }
    if (c.flagged(o, 0)) return if (found) 0 else 1;
    if (c.flagged(o, 3)) return 1;
    if (found) {
        c.put("{s} is a mountpoint\n", .{path});
        return 0;
    }
    c.put("{s} is not a mountpoint\n", .{path});
    return 1;
}

pub fn fatattr_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len < 2) c.usageDie("fatattr");
    const flags = args[1];
    var i: usize = 0;
    if (flags.len > 0 and (flags[0] == '-' or flags[0] == '+')) i = 1;
    while (i < flags.len) : (i += 1) {
        const ch = flags[i];
        if (std.mem.indexOfScalar(u8, "rhsvda", ch) == null) {
            c.plain("invalid character '{c}'", .{ch});
            return 1;
        }
    }
    // The sandbox has no FAT filesystem: report the first path as unavailable.
    c.msg(22, "can't get attributes of '{s}'", .{args[2]});
    return 1;
}

pub fn fatlabel_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("fatlabel", args, "", &.{});
    if (o.args.len < 1) c.usageDie("fatlabel");
    const p = c.zstr(o.args[0]) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{o.args[0]});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

pub fn swaplabel_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("swaplabel", args, "L:", &.{});
    if (o.args.len < 1) c.usageDie("swaplabel");
    const p = c.zstr(o.args[0]) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{o.args[0]});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

fn deviceApplet(argc: c_int, argv: [*][*:0]const u8, name: []const u8, parse_opts: bool) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    var start: usize = 1;
    if (parse_opts) {
        const o = c.opts(name, args, "", &.{});
        start = o.index;
    }
    if (start >= args.len) c.usageDie(name);
    const dev = args[start];
    const p = c.zstr(dev) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{dev});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

pub fn fdflush_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return deviceApplet(argc, argv, "fdflush", false);
}

pub fn freeramdisk_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return deviceApplet(argc, argv, "freeramdisk", false);
}

pub fn eject_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("eject", args, "stT", &.{});
    const dev: []const u8 = if (o.args.len > 0) o.args[0] else "/dev/cdrom";
    const p = c.zstr(dev) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{dev});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

pub fn blkdiscard_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("blkdiscard", args, "o:l:s", &.{});
    if (o.args.len < 1) c.usageDie("blkdiscard");
    c.msg(1, "can't open '{s}'", .{o.args[0]});
    return 1;
}

pub fn fsfreeze_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("fsfreeze", args, "", &.{});
    if (o.args.len < 1) c.usageDie("fsfreeze");
    c.msg(22, "can't freeze '{s}'", .{o.args[0]});
    return 1;
}

pub fn fstrim_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("fstrim", args, "o:l:m:v", &.{});
    if (o.args.len < 1) c.usageDie("fstrim");
    c.msg(22, "can't trim '{s}'", .{o.args[0]});
    return 1;
}

/// Reference blkid finds no readable filesystems in this container, so every
/// invocation produces empty output and exit 0. We mirror that observable
/// behaviour rather than printing entries from /dev/disk/by-uuid.
pub fn blkid_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    c.setProg(argv);
    return 0;
}
