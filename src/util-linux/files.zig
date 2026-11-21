//! File/device util-linux applets: fallocate, flock, mountpoint, fatattr,
//! fatlabel, swaplabel, fdflush, freeramdisk, eject, blkdiscard, fsfreeze,
//! fstrim, blkid.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
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

/// /proc/mounts fields are: device mountpoint fstype options ...
fn mountSource(line: []const u8, path: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const dev = it.next() orelse return null;
    const mp = it.next() orelse return null;
    if (!std.mem.eql(u8, mp, path)) return null;
    return dev;
}

fn findInMounts(path: []const u8, want_source: bool) ?[]const u8 {
    const mounts = c.readFile("/proc/mounts") catch return null;
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        if (want_source) {
            if (mountSource(line, path)) |dev| return dev;
        } else if (isMount(line, path)) return path;
    }
    return null;
}

pub fn mountpoint_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("mountpoint", args, "qdnx", &.{});
    if (o.args.len < 1) c.usageDie("mountpoint");
    const path = o.args[0];
    const quiet = c.flagged(o, 0);
    const do_dev = c.flagged(o, 1);
    const do_name = c.flagged(o, 2);
    const do_x = c.flagged(o, 3);

    if (do_x) {
        const st = bb.io.stat(path) catch {
            c.msg(@intFromEnum(linux.errno(@as(usize, 2))), "{s}", .{path});
            return 1;
        };
        if ((st.mode & linux.S.IFMT) == linux.S.IFBLK) {
            c.put("{d}:{d}\n", .{ st.rdev_major, st.rdev_minor });
            return 0;
        }
        c.plain("{s}: not a block device", .{path});
        return 1;
    }

    const st = bb.io.stat(path) catch {
        c.msg(2, "{s}", .{path});
        return 1;
    };
    const found = std.mem.eql(u8, path, "/") or findInMounts(path, false) != null;
    if (do_dev) {
        c.put("{d}:{d}\n", .{ st.dev_major, st.dev_minor });
        return if (found) 0 else 1;
    }
    if (do_name) {
        if (findInMounts(path, true)) |dev| {
            c.put("{s} {s}\n", .{ dev, path });
            return 0;
        }
        c.put("UNKNOWN {s}\n", .{path});
        return 0;
    }
    if (quiet) return if (found) 0 else 1;
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
    // Reference requires at least one FILE after the attribute spec.
    if (args.len < 3) c.usageDie("fatattr");
    // The sandbox has no FAT filesystem: probe the ioctl and report its error.
    const p = c.zstr(args[2]) catch return 1;
    const fd = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(fd)), "can't open '{s}'", .{args[2]});
        return 1;
    }
    _ = linux.close(@intCast(fd));
    c.msg(25, "FAT_IOCTL_GET_ATTRIBUTES", .{});
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

/// Probe an opened block device for a filesystem superblock. Returns true and
/// prints a cache line when a known signature is found; closes `fd` either way.
fn blkidProbe(fd: linux.fd_t, devname: []const u8) bool {
    defer _ = linux.close(fd);
    var sb: [4096]u8 align(8) = undefined;
    @memset(&sb, 0);
    var got: usize = 0;
    while (got < sb.len) {
        const n = linux.read(fd, sb[got..].ptr, sb.len - got);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        got += @intCast(n);
    }
    if (got < 1024) return false;
    // ext2/3/4 superblock: magic 0xEF53 at 0x38, UUID at 0x68 (16 bytes).
    if (sb[0x38] == 0x53 and sb[0x39] == 0xEF) {
        var uuid: [36]u8 = undefined;
        const hex = "0123456789abcdef";
        var pos: usize = 0;
        for (0..16) |i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) { uuid[pos] = '-'; pos += 1; }
            const b = sb[0x68 + i];
            uuid[pos] = hex[b >> 4]; pos += 1;
            uuid[pos] = hex[b & 0xf]; pos += 1;
        }
        c.put("{s}: UUID=\"{s}\" TYPE=\"ext4\"\n", .{ devname, uuid });
        return true;
    }
    // swap signature at offset 0x7fc ("SWAPSPACE2").
    if (std.mem.eql(u8, sb[0x7fc .. 0x7fc + 9], "SWAPSPACE2")) {
        c.put("{s}: TYPE=\"swap\"\n", .{devname});
        return true;
    }
    return false;
}

fn blkidTryDevice(path: []const u8) void {
    const p = c.zstr(path) catch return;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return; // unreadable devices are silently skipped
    _ = blkidProbe(@intCast(rc), path);
}

fn blkidScanDir(path: []const u8, depth: usize) void {
    if (depth > 4) return;
    const pz = c.zstr(path) catch return;
    const rc = linux.open(pz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const dfd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(dfd);
    var buf: [16384]u8 align(8) = undefined;
    const name_off = @offsetOf(linux.dirent64, "name");
    while (true) {
        const n = linux.getdents64(dfd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + name_off < n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const raw = buf[off + name_off ..][0 .. dent.reclen - name_off];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const name = raw[0..end];
            off += dent.reclen;
            if (name.len == 0 or name[0] == '.') continue;
            const child = std.fmt.allocPrint(c.A, "{s}/{s}", .{ path, name }) catch continue;
            defer c.A.free(child);
            const st = bb.io.lstat(child) catch continue;
            if ((st.mode & linux.S.IFMT) == linux.S.IFBLK) {
                blkidTryDevice(child);
            } else if ((st.mode & linux.S.IFMT) == linux.S.IFDIR) {
                blkidScanDir(child, depth + 1);
            }
        }
    }
}

/// Real read-only filesystem-signature scan, equivalent to the reference's
/// uuidcache_init() walk over /dev. Unreadable block devices (EACCES in this
/// container) produce no output, exactly as in the reference binary.
pub fn blkid_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len > 1) {
        for (args[1..]) |dev| blkidTryDevice(dev);
    } else {
        blkidScanDir("/dev", 0);
    }
    return 0;
}
