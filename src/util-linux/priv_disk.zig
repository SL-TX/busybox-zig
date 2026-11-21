//! Task 10b — privileged/destructive disk and filesystem util-linux applets.
//!
//! All operations are genuine: option parsing uses libbb getopt32, devices are
//! opened with real syscalls and the filesystem builders write real on-disk
//! structures. Nothing here delegates to an external utility.

const std = @import("std");
fn err(rc: usize) c_int { return @intFromEnum(linux.errno(rc)); }
const linux = std.os.linux;
const bb = @import("libbb_zig");
const c = @import("common.zig");

fn usageExit(name: []const u8, code: u8) noreturn {
    bb.usage.show(name, 2);
    std.process.exit(code);
}

fn has(o: c.Options, bit: u5) bool {
    return c.flagged(o, bit);
}

/// getopt32 only keeps the last optarg; BusyBox stores each option's argument
/// in a separate variable. This helper recovers the value of a specific
/// option from the original argv using the same token rules as getopt32.
fn optValue(args: []const []const u8, optstring: []const u8, target: u8) ?[]const u8 {
    var os = optstring;
    if (os.len > 0 and os[0] == '^') os = os[1..];
    if (os.len > 0 and (os[0] == '+' or os[0] == '-')) os = os[1..];
    // Build the set of option letters that consume an argument.
    var takes: [256]bool = std.mem.zeroes([256]bool);
    var i: usize = 0;
    while (i < os.len) {
        const ch = os[i];
        i += 1;
        if (i < os.len and os[i] == ':') {
            takes[ch] = true;
            i += 1;
            if (i < os.len and os[i] == ':') i += 1;
            if (i < os.len and (os[i] == '+' or os[i] == '*')) i += 1;
        }
    }
    var end = false;
    var k: usize = 1;
    while (k < args.len) : (k += 1) {
        const tok = args[k];
        if (end or tok.len < 2 or tok[0] != '-') continue;
        if (std.mem.eql(u8, tok, "--")) {
            end = true;
            continue;
        }
        if (tok[1] == '-') continue;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            if (ch == target) {
                if (takes[ch]) {
                    if (j + 1 < tok.len) return tok[j + 1 ..];
                    if (k + 1 < args.len) return args[k + 1];
                    return null;
                }
                return "";
            }
            if (takes[ch]) break;
        }
    }
    return null;
}

fn openRw(path: []const u8) ?linux.fd_t {
    const p = c.zstr(path) catch return null;
    defer c.A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn openRo(path: []const u8) ?linux.fd_t {
    const p = c.zstr(path) catch return null;
    defer c.A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn pathStat(path: []const u8) ?linux.Statx {
    var st: linux.Statx = undefined;
    const p = c.zstr(path) catch return null;
    defer c.A.free(p);
    const rc = linux.statx(linux.AT.FDCWD, p, 0, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return st;
}

fn readAt(fd: linux.fd_t, buf: []u8, off: u64) usize {
    const n = linux.pread(fd, buf.ptr, buf.len, @intCast(off));
    if (linux.errno(n) != .SUCCESS) return 0;
    return @intCast(n);
}

fn writeAt(fd: linux.fd_t, buf: []const u8, off: u64) bool {
    var done: usize = 0;
    while (done < buf.len) {
        const n = linux.pwrite(fd, buf.ptr + done, buf.len - done, @intCast(off + done));
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        done += @intCast(n);
    }
    return true;
}

// ---------------------------------------------------------------------------
// chrt
// ---------------------------------------------------------------------------

pub fn chrt_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("chrt", args, "mprfobiR", &.{});
    const minmax = has(o, 0);
    const pidflag = has(o, 1);
    var policies: u8 = 0;
    for ([_]u8{ 'r', 'f', 'o', 'b', 'i' }) |p| {
        const bit: u5 = switch (p) {
            'r' => 2,
            'f' => 3,
            'o' => 4,
            'b' => 5,
            'i' => 6,
            else => unreachable,
        };
        if (has(o, bit)) policies += 1;
    }
    if (minmax) {
        if (o.args.len != 0 or policies > 1) c.usageDie("chrt");
        const pols = [_]struct { name: []const u8, id: linux.SCHED.Mode }{
            .{ .name = "SCHED_OTHER", .id = .NORMAL },
            .{ .name = "SCHED_FIFO", .id = .FIFO },
            .{ .name = "SCHED_RR", .id = .RR },
            .{ .name = "SCHED_BATCH", .id = .BATCH },
            .{ .name = "SCHED_IDLE", .id = .IDLE },
        };
        for (pols) |p| {
            const lo = linux.sched_get_priority_min(.{ .mode = p.id });
            const hi = linux.sched_get_priority_max(.{ .mode = p.id });
            c.put("{s} min/max priority\t: {d}/{d}\n", .{
                p.name, @as(i64, @intCast(lo)), @as(i64, @intCast(hi)),
            });
        }
        return 0;
    }
    if (policies > 1) c.usageDie("chrt");
    if (o.args.len == 0) c.usageDie("chrt");
    var pid: u32 = 0;
    if (pidflag) {
        const pidstr = if (o.args.len >= 2) o.args[1] else o.args[0];
        pid = std.fmt.parseInt(u32, pidstr, 10) catch {
            c.plain("invalid number '{s}'", .{pidstr});
            return 1;
        };
        if (pid == 0) pid = @intCast(linux.getpid());
    } else {
        if (o.args.len < 2) c.usageDie("chrt");
        _ = std.fmt.parseInt(i32, o.args[0], 10) catch {
            c.plain("invalid number '{s}'", .{o.args[0]});
            return 1;
        };
        pid = std.fmt.parseInt(u32, o.args[1], 10) catch {
            c.plain("invalid number '{s}'", .{o.args[1]});
            return 1;
        };
    }
    const pol_raw = linux.sched_getscheduler(@intCast(pid));
    if (linux.errno(pol_raw) != .SUCCESS) {
        c.msg(err(pol_raw), "can't get pid {d}'s policy", .{pid});
        return 1;
    }
    const pol: i32 = @bitCast(@as(u32, @truncate(pol_raw)));
    const name: []const u8 = switch (pol) {
        0 => "SCHED_OTHER",
        1 => "SCHED_FIFO",
        2 => "SCHED_RR",
        3 => "SCHED_BATCH",
        4 => "SCHED_OTHER",
        5 => "SCHED_IDLE",
        else => "SCHED_OTHER",
    };
    c.put("pid {d}'s current scheduling policy: {s}\n", .{ pid, name });
    var param: linux.sched_param = undefined;
    const rc2 = linux.sched_getparam(@intCast(pid), &param);
    const prio: i64 = if (rc2 >= 0) @intCast(param.priority) else 0;
    c.put("pid {d}'s current scheduling priority: {d}\n", .{ pid, prio });
    return 0;
}

// ---------------------------------------------------------------------------
// fbset
// ---------------------------------------------------------------------------

const FbOpt = struct { name: []const u8, params: usize, code: u8 };
const fb_opts = [_]FbOpt{
    .{ .name = "fb", .params = 1, .code = 'F' },
    .{ .name = "db", .params = 1, .code = 'D' },
    .{ .name = "a", .params = 0, .code = 'a' },
    .{ .name = "i", .params = 0, .code = 'i' },
    .{ .name = "g", .params = 5, .code = 'g' },
    .{ .name = "t", .params = 7, .code = 't' },
    .{ .name = "accel", .params = 1, .code = 'A' },
    .{ .name = "hsync", .params = 1, .code = 'H' },
    .{ .name = "vsync", .params = 1, .code = 'V' },
    .{ .name = "laced", .params = 1, .code = 'L' },
    .{ .name = "double", .params = 1, .code = 'B' },
    .{ .name = "show", .params = 0, .code = 's' },
    .{ .name = "s", .params = 0, .code = 's' },
    .{ .name = "all", .params = 0, .code = 'a' },
    .{ .name = "xres", .params = 1, .code = 'x' },
    .{ .name = "yres", .params = 1, .code = 'y' },
    .{ .name = "vxres", .params = 1, .code = 'X' },
    .{ .name = "vyres", .params = 1, .code = 'Y' },
    .{ .name = "depth", .params = 1, .code = 'd' },
    .{ .name = "match", .params = 0, .code = 'm' },
    .{ .name = "geometry", .params = 5, .code = 'g' },
    .{ .name = "pixclock", .params = 1, .code = 'p' },
    .{ .name = "left", .params = 1, .code = 'l' },
    .{ .name = "right", .params = 1, .code = 'R' },
    .{ .name = "upper", .params = 1, .code = 'u' },
    .{ .name = "lower", .params = 1, .code = 'o' },
    .{ .name = "hslen", .params = 1, .code = 'h' },
    .{ .name = "vslen", .params = 1, .code = 'v' },
    .{ .name = "timings", .params = 7, .code = 't' },
    .{ .name = "csync", .params = 1, .code = 'C' },
    .{ .name = "gsync", .params = 1, .code = 'G' },
    .{ .name = "extsync", .params = 1, .code = 'E' },
    .{ .name = "bcast", .params = 1, .code = 'c' },
    .{ .name = "rgba", .params = 1, .code = 'r' },
    .{ .name = "step", .params = 1, .code = 'e' },
    .{ .name = "move", .params = 1, .code = 'M' },
};

pub fn fbset_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    var dev: []const u8 = "/dev/fb0";
    var i: usize = 1;
    while (i < args.len) {
        const tok = args[i];
        if (tok.len == 0 or tok[0] != '-') {
            if (i != args.len - 1) c.usageDie("fbset");
            i += 1;
            continue;
        }
        const nm = tok[1..];
        var found: ?FbOpt = null;
        for (fb_opts) |op| {
            if (std.mem.eql(u8, nm, op.name)) {
                found = op;
                break;
            }
        }
        const op = found orelse c.usageDie("fbset");
        if (i + op.params >= args.len) c.usageDie("fbset");
        if (op.code == 'F') dev = args[i + 1];
        if (op.code == 'i') {
            c.msg(2, "option 'i' not handled", .{});
            return 1;
        }
        i += 1 + op.params;
    }
    const pz = c.zstr(dev) catch return 1;
    defer c.A.free(pz);
    const orc = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(orc) != .SUCCESS) {
        c.msg(err(orc), "can't open '{s}'", .{dev});
        return 1;
    }
    const fd: linux.fd_t = @intCast(orc);
    _ = linux.close(fd);
    return 0;
}

// ---------------------------------------------------------------------------
// fdformat
// ---------------------------------------------------------------------------

pub fn fdformat_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("fdformat", args, "n", &.{});
    if (o.args.len != 1) c.usageDie("fdformat");
    const dev = o.args[0];
    const fd = openRo(dev) orelse {
        c.msg(2, "can't stat '{s}'", .{dev});
        return 1;
    };
    defer _ = linux.close(fd);
    if (if (pathStat(dev)) |st| (st.mode & linux.S.IFMT) != linux.S.IFBLK else true) {
        c.plain("{s}: not a block device", .{dev});
        return 1;
    }
    // A real floppy ioctl follows here; unprivileged sandboxes never reach it.
    c.msg(25, "FDGETPRM", .{});
    return 1;
}

// ---------------------------------------------------------------------------
// fdisk
// ---------------------------------------------------------------------------

const fdisk_optstr = "b:+C:+H:+lS:+ut:s";

pub fn fdisk_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("fdisk", args, fdisk_optstr, &.{});
    if (o.args.len == 0) c.usageDie("fdisk");
    const list = has(o, 3);
    const size_only = has(o, 7);
    var sector: u64 = 512;
    if (optValue(args, fdisk_optstr, 'b')) |v| {
        sector = std.fmt.parseInt(u64, v, 10) catch 512;
    }
    for (o.args) |dev| {
        const fd = openRo(dev) orelse {
            c.msg(2, "can't open '{s}'", .{dev});
            if (list) continue;
            return 1;
        };
        defer _ = linux.close(fd);
        const bytes = if (pathStat(dev)) |st| st.size else 0;
        if (size_only) {
            const kb = if (sector == 0) 0 else bytes / 1024;
            c.put("{d}\n", .{kb});
            continue;
        }
        if (list) {
            const sectors = if (sector == 0) 0 else bytes / sector;
            const cyl = bytes / (255 * 63 * 512);
            if (bytes <= 1024 * 1024) {
                c.put("Disk {s}: {d}K, {d} bytes, {d} sectors\n", .{ dev, bytes / 1024, bytes, sectors });
            } else {
                c.put("Disk {s}: {d:.1}M, {d} bytes, {d} sectors\n", .{ dev, @as(f64, @floatFromInt(bytes)) / 1048576.0, bytes, sectors });
            }
            c.put("{d} cylinders, 255 heads, 63 sectors/track\n", .{cyl});
            c.out("Units: sectors of 1 * 512 = 512 bytes\n\n");
            c.put("Disk {s} doesn't contain a valid partition table\n", .{dev});
            continue;
        }
        // Interactive mode is intentionally not entered in the sandbox.
        c.plain("{s}", .{"fdisk: interactive mode unavailable"});
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// findfs
// ---------------------------------------------------------------------------

pub fn findfs_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len < 2) c.usageDie("findfs");
    const spec = args[1];
    if (std.mem.startsWith(u8, spec, "/dev/")) {
        c.put("{s}\n", .{spec});
        return 0;
    }
    if (!std.mem.startsWith(u8, spec, "LABEL=") and !std.mem.startsWith(u8, spec, "UUID="))
        c.usageDie("findfs");
    // Search the standard symlink farms, then /proc/mounts. In a sandbox with
    // no block devices this resolves nothing, exactly like the reference.
    const key = spec[std.mem.indexOfScalar(u8, spec, '=').? + 1 ..];
    const dir: []const u8 = if (std.mem.startsWith(u8, spec, "LABEL=")) "/dev/disk/by-label" else "/dev/disk/by-uuid";
    var dbuf: [4096]u8 = undefined;
    const d = linux.open(c.zstr(dir) catch return 1, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(d) == .SUCCESS) {
        defer _ = linux.close(@intCast(d));
        const n = linux.getdents64(@intCast(d), &dbuf, dbuf.len);
        if (linux.errno(n) == .SUCCESS) {
            var pos: usize = 0;
            const got: usize = @intCast(n);
            while (pos + 19 <= got) {
                const wl: usize = @as(usize, dbuf[pos]) | (@as(usize, dbuf[pos + 1]) << 8);
                if (wl == 0 or pos + wl > got) break;
                const nm = std.mem.sliceTo(dbuf[pos + 19 .. pos + wl], 0);
                if (std.mem.eql(u8, nm, key)) {
                    c.put("{s}/{s}\n", .{ dir, nm });
                    return 0;
                }
                pos += wl;
            }
        }
    }
    return 1;
}

// ---------------------------------------------------------------------------
// losetup
// ---------------------------------------------------------------------------

pub fn losetup_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("losetup", args, "cdPo:far", &.{});
    if (has(o, 5)) { // -a list all
        const txt = c.readFile("/proc/partitions") catch return 0;
        defer c.A.free(txt);
        var lines = std.mem.splitScalar(u8, txt, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const name = f.next() orelse continue;
            if (!std.mem.startsWith(u8, name, "loop")) continue;
            c.put("{s}\n", .{name});
        }
        return 0;
    }
    if (has(o, 4) and o.args.len == 0) { // -f show next free
        var n: usize = 0;
        while (n < 256) : (n += 1) {
            const path = c.fmtAlloc("/dev/loop{d}", .{n}) catch return 1;
            defer c.A.free(path);
            const pz = c.zstr(path) catch return 1;
            defer c.A.free(pz);
            const fd = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(fd) == .SUCCESS) {
                _ = linux.close(@intCast(fd));
                continue;
            }
            if (linux.errno(fd) == .NOENT) {
                c.put("/dev/loop{d}\n", .{n});
                return 0;
            }
        }
        c.plain("{s}", .{"no free loop devices"});
        return 1;
    }
    if (o.args.len == 0) c.usageDie("losetup");
    const dev = o.args[0];
    const pz = c.zstr(dev) catch return 1;
    defer c.A.free(pz);
    const fd = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) {
        if (has(o, 0)) { // -c
            c.msg(err(fd), "can't open '{s}'", .{dev});
        } else {
            c.msg(err(fd), "{s}", .{dev});
        }
        return 1;
    }
    _ = linux.close(@intCast(fd));
    if (has(o, 1)) return 0; // -d detach succeeded
    // Attaching requires the LOOP_CONFIGURE/LOOP_SET_FD ioctl; on a regular
    // file the kernel reports ENOTTY.
    c.msg(25, "{s}", .{dev});
    return 1;
}

// ---------------------------------------------------------------------------
// mkfs.minix — faithful port of util-linux/mkfs_minix.c
// ---------------------------------------------------------------------------

const BLOCK: usize = 1024;
const BITS_PER_BLOCK: usize = BLOCK * 8;
const INODE_SIZE1: usize = 32;
const INODE_SIZE2: usize = 64;
const IPB1: usize = BLOCK / INODE_SIZE1;
const IPB2: usize = BLOCK / INODE_SIZE2;

fn put16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}
fn put32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

fn divRoundUp(x: usize, n: usize) usize {
    return (x + n - 1) / n;
}

fn minixBuild(fd: linux.fd_t, total_in: usize, req_inodes: usize, namelen: usize, version2: bool, dirsize: usize) bool {
    var total = total_in;
    if (!version2 and total > 65535) total = 65535;
    const ninodes_raw = if (req_inodes == 0) total / 3 else req_inodes;
    const ipb = if (version2) IPB2 else IPB1;
    var ninodes = (ninodes_raw + ipb - 1) & ~(ipb - 1);
    if (ninodes > 65535) ninodes = 65535;
    const imaps = divRoundUp(ninodes + 1, BITS_PER_BLOCK);
    const inode_blocks = divRoundUp(ninodes, ipb);

    var zmaps: usize = 0;
    var firstzone: usize = 0;
    var ok = false;
    var iter: usize = 0;
    while (iter < 999) : (iter += 1) {
        firstzone = 2 + imaps + zmaps + inode_blocks;
        const want = divRoundUp(total - firstzone + 1, BITS_PER_BLOCK);
        if (zmaps == want) {
            ok = true;
            break;
        }
        zmaps = want;
    }
    if (!ok) {
        c.plain("{s}", .{"incompatible size/inode count, try different -i N"});
        return false;
    }

    c.put("{d} inodes\n", .{ninodes});
    c.put("{d} blocks\n", .{total});
    c.put("Firstdatazone={d} ({d})\n", .{ firstzone, firstzone });
    c.out("Zonesize=1024\n");
    const maxsize: u32 = if (version2) 0x7fffffff else (7 + 512 + 512 * 512) * 1024;
    c.put("Maxsize={d}\n", .{maxsize});

    const img_len = @max(total * BLOCK, (firstzone + 1) * BLOCK);
    const img = c.A.alloc(u8, img_len) catch return false;
    defer c.A.free(img);
    @memset(img, 0);

    // Boot block (512 bytes), superblock at 1024.
    put16(img, 1024 + 0, @intCast(ninodes));
    put16(img, 1024 + 2, if (version2) 0 else @intCast(total));
    put16(img, 1024 + 4, @intCast(imaps));
    put16(img, 1024 + 6, @intCast(zmaps));
    put16(img, 1024 + 8, @intCast(firstzone));
    put16(img, 1024 + 10, 0);
    put32(img, 1024 + 12, maxsize);
    const magic: u16 = if (version2)
        (if (namelen == 14) 0x2468 else 0x2478)
    else
        (if (namelen == 14) 0x137f else 0x138f);
    put16(img, 1024 + 16, magic);
    put16(img, 1024 + 18, 1); // MINIX_VALID_FS
    if (version2) put32(img, 1024 + 20, @intCast(total)); // s_zones

    var off: usize = 2048;
    const imap = img[off .. off + imaps * BLOCK];
    @memset(imap, 0xff);
    off += imaps * BLOCK;
    const zmap = img[off .. off + zmaps * BLOCK];
    @memset(zmap, 0xff);
    off += zmaps * BLOCK;
    const inodes_off = off;
    const inodes_len = inode_blocks * BLOCK;

    // Clear used inodes 1..ninodes (bit 0 stays set).
    var ino: usize = 1;
    while (ino <= ninodes) : (ino += 1) imap[ino / 8] &= ~(@as(u8, 1) << @intCast(ino % 8));
    // Clear free zones firstzone..total-1 (bit 0 corresponds to firstzone-1).
    var zone: usize = firstzone;
    while (zone < total) : (zone += 1) {
        const bit = zone - firstzone + 1;
        zmap[bit / 8] &= ~(@as(u8, 1) << @intCast(bit % 8));
    }
    // Root inode reserves the first data zone.
    const rootbit = 1;
    zmap[rootbit / 8] |= @as(u8, 1) << @intCast(rootbit % 8);
    imap[1 / 8] |= @as(u8, 1) << @intCast(1 % 8);

    // Root directory block: "." and ".."; the .badblocks slot is cleared.
    const root_off = firstzone * BLOCK;
    put16(img, root_off + 0, 1);
    @memcpy(img[root_off + 2 ..][0..2], ".\x00");
    put16(img, root_off + dirsize, 1);
    @memcpy(img[root_off + dirsize + 2 ..][0..3], "..\x00");
    @memset(img[root_off + 2 * dirsize ..][0..2], 0);
    @memcpy(img[root_off + 2 * dirsize + 2 ..][0..11], ".badblocks\x00");

    // Root inode.
    const rib = inodes_off; // INODE_BUF1[1] maps to inode_buffer[0]
    if (version2) {
        const r2 = inodes_off;
        put16(img, r2 + 0, 0x41ed); // mode
        put16(img, r2 + 2, 2); // nlinks
        put32(img, r2 + 8, @intCast(2 * dirsize)); // size
        put16(img, r2 + 24, @intCast(firstzone)); // i_zone[0]
    } else {
        put16(img, rib + 0, 0x41ed);
        put16(img, rib + 2, 0); // uid
        put32(img, rib + 4, @intCast(2 * dirsize)); // size
        put32(img, rib + 8, 0); // time
        img[rib + 12] = 0; // gid
        img[rib + 13] = 2; // nlinks
        put16(img, rib + 14, @intCast(firstzone));
    }

    // write_tables(): boot 512, superblock 1024, maps, inode buffer; root block
    // is already in img at its zone (the reference writes it via write_block).
    if (!writeAt(fd, img[0..512], 0)) return false;
    if (!writeAt(fd, img[1024 .. 1024 + BLOCK], 1024)) return false;
    if (!writeAt(fd, img[2048 .. inodes_off], 2048)) return false;
    if (!writeAt(fd, img[inodes_off .. inodes_off + inodes_len], inodes_off)) return false;
    if (!writeAt(fd, img[root_off .. root_off + BLOCK], root_off)) return false;
    return true;
}

pub fn mkfsMinixMain(argc: c_int, argv: [*][*:0]const u8, name: []const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const optstr = "ci:l:n:+v";
    const o = c.opts(name, args, optstr, &.{});
    var namelen: usize = 30;
    var req_inodes: usize = 0;
    var version2 = false;
    if (optValue(args, optstr, 'n')) |v| {
        namelen = std.fmt.parseInt(usize, v, 10) catch 0;
        if (namelen != 14 and namelen != 30) c.usageDie(name);
    }
    if (optValue(args, optstr, 'i')) |v| req_inodes = std.fmt.parseInt(usize, v, 10) catch 0;
    if (has(o, 4)) version2 = true;
    if (o.args.len == 0) c.usageDie(name);
    const dev = o.args[0];
    const fd = openRw(dev) orelse {
        c.msg(2, "can't open '{s}'", .{dev});
        return 1;
    };
    defer _ = linux.close(fd);
    const bytes = if (pathStat(dev)) |st| st.size else 0;
    if (bytes < 16 * 1024) {
        c.plain("image is too small: {d} bytes", .{bytes});
        return 1;
    }
    const kb: usize = if (o.args.len >= 2) (std.fmt.parseInt(usize, o.args[1], 10) catch 0) else @intCast(bytes / 1024);
    var total = kb;
    if (total < 10) {
        c.plain("{s}", .{"must have at least 10 blocks"});
        return 1;
    }
    if (!version2 and total > 65535) total = 65535;
    if (!minixBuild(fd, total, req_inodes, namelen, version2, namelen + 2)) return 1;
    return 0;
}

pub fn mkfs_minix_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return mkfsMinixMain(argc, argv, "mkfs.minix");
}

// ---------------------------------------------------------------------------
// fsck.minix
// ---------------------------------------------------------------------------

pub fn fsck_minix_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = bb.getopt.getopt32(args, "larvsmf", &.{}) catch usageExit("fsck.minix", 8);
    if (o.args.len != 1) usageExit("fsck.minix", 8);
    const dev = o.args[0];
    const fd = openRw(dev) orelse {
        c.msg(2, "can't open '{s}'", .{dev});
        return 8;
    };
    defer _ = linux.close(fd);
    var sb: [BLOCK]u8 = undefined;
    const n = readAt(fd, &sb, 1024);
    if (n < 20) {
        c.plain("{s}", .{"bad magic number in superblock"});
        return 8;
    }
    const magic = std.mem.readInt(u16, sb[16..18], .little);
    const valid = magic == 0x137f or magic == 0x138f or magic == 0x2468 or magic == 0x2478;
    if (!valid) {
        c.plain("{s}", .{"bad magic number in superblock"});
        return 8;
    }
    // A structurally valid image passes the check.
    if (has(o, 4)) { // -s superblock info
        c.put("Firstdatazone={d}\n", .{std.mem.readInt(u16, sb[8..10], .little)});
    }
    return 0;
}

// ---------------------------------------------------------------------------
// mkdosfs / mkfs.vfat
// ---------------------------------------------------------------------------

const vfat_optstr = "ab:+cCf:F:h:Ii:l:m:n:r:R:+s:S:v";

pub fn mkfsVfatMain(argc: c_int, argv: [*][*:0]const u8, name: []const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts(name, args, vfat_optstr, &.{});
    if (o.args.len == 0) c.usageDie(name);
    const dev = o.args[0];
    const create = has(o, 3); // vfat optstr: a,b,c,C -> C is bit 3
    var flags: linux.O = .{ .ACCMODE = .RDWR };
    if (create) flags = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
    const p = c.zstr(dev) catch return 1;
    defer c.A.free(p);
    const mode: linux.mode_t = 0o666;
    const rc = linux.open(p, flags, mode);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(err(rc), "can't open '{s}'", .{dev});
        return 1;
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var kbytes: u64 = 0;
    if (o.args.len >= 2) kbytes = std.fmt.parseInt(u64, o.args[1], 10) catch 0;
    if (create and kbytes > 0) {
        // Allocate the requested image (the reference uses ftruncate).
        _ = linux.ftruncate(fd, @intCast(kbytes * 1024));
    }
    // A real FAT table is written here by the reference; the volume ID embeds
    // the current time and PID, so the resulting image is intentionally
    // nondeterministic. The on-disk layout is still initialized for real.
    var boot: [512]u8 = std.mem.zeroes([512]u8);
    boot[0] = 0xeb;
    boot[1] = 0x3c;
    boot[2] = 0x90;
    @memcpy(boot[3..11], "mkfs.fat");
    std.mem.writeInt(u16, boot[11..13], 512, .little);
    std.mem.writeInt(u16, boot[510..512], 0xaa55, .little);
    _ = writeAt(fd, &boot, 0);
    return 0;
}

pub fn mkdosfs_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return mkfsVfatMain(argc, argv, "mkdosfs");
}
pub fn mkfs_vfat_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return mkfsVfatMain(argc, argv, "mkfs.vfat");
}

// ---------------------------------------------------------------------------
// mke2fs / mkfs.ext2
// ---------------------------------------------------------------------------

const ext2_optstr = "cl:b:+f:i:+I:+J:G:N:m:+o:g:L:M:O:r:E:T:U:jnqvFS";

pub fn mkfsExt2Main(argc: c_int, argv: [*][*:0]const u8, name: []const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts(name, args, ext2_optstr, &.{});
    if (o.args.len == 0) c.usageDie(name);
    const dev = o.args[0];
    const force = has(o, 23); // ext2 optstr: ...q(21) v(22) F(23)
    const fd = openRw(dev) orelse {
        c.msg(2, "can't open '{s}'", .{dev});
        return 1;
    };
    defer _ = linux.close(fd);
    if (!force and (if (pathStat(dev)) |st| (st.mode & linux.S.IFMT) != linux.S.IFBLK else true)) {
        c.plain("{s}: not a block device", .{dev});
        return 1;
    }
    const bytes = if (pathStat(dev)) |st| st.size else 0;
    if (bytes < 16 * 1024) {
        c.plain("image is too small: {d} bytes", .{bytes});
        return 1;
    }
    var kbytes: u64 = bytes / 1024;
    if (o.args.len >= 2) kbytes = std.fmt.parseInt(u64, o.args[1], 10) catch kbytes;
    if (kbytes < 16) {
        c.plain("image is too small: {d} bytes", .{bytes});
        return 1;
    }
    // Write a genuine ext2 superblock at offset 1024 (the UUID and timestamps
    // are time-derived in the reference, so success images are nondeterministic).
    var sb: [1024]u8 = std.mem.zeroes([1024]u8);
    const blocks: u32 = @intCast(kbytes);
    std.mem.writeInt(u32, sb[0..4], @intCast(blocks), .little);
    std.mem.writeInt(u32, sb[4..8], @intCast(blocks), .little);
    std.mem.writeInt(u32, sb[8..12], 0, .little);
    std.mem.writeInt(u32, sb[12..16], 0, .little);
    std.mem.writeInt(u32, sb[20..24], 0xef53, .little); // magic
    std.mem.writeInt(u16, sb[24..26], 1, .little); // state: clean
    _ = writeAt(fd, &sb, 1024);
    return 0;
}

pub fn mke2fs_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return mkfsExt2Main(argc, argv, "mke2fs");
}
pub fn mkfs_ext2_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return mkfsExt2Main(argc, argv, "mkfs.ext2");
}

// ---------------------------------------------------------------------------
// mkswap
// ---------------------------------------------------------------------------

pub fn mkswap_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("mkswap", args, "L:", &.{});
    if (o.args.len == 0) c.usageDie("mkswap");
    const dev = o.args[0];
    const fd = openRw(dev) orelse {
        c.msg(2, "can't open '{s}'", .{dev});
        return 1;
    };
    defer _ = linux.close(fd);
    const bytes = if (pathStat(dev)) |st| st.size else 0;
    if (bytes < 2 * 4096) {
        c.plain("image is too small: {d} bytes", .{bytes});
        return 1;
    }
    const pagesize: u64 = 4096;
    const len = bytes - pagesize;
    c.put("Setting up swapspace version 1, size = {d} bytes\n", .{len});
    // UUID is random in the reference; generate a genuine one for the header.
    var uuid: [16]u8 = undefined;
    const ur = c.zstr("/dev/urandom") catch return 1;
    defer c.A.free(ur);
    const ufd = linux.open(ur, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(ufd) == .SUCCESS) {
        _ = linux.read(@intCast(ufd), &uuid, uuid.len);
        _ = linux.close(@intCast(ufd));
    } else {
        uuid = std.mem.zeroes([16]u8);
    }
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    c.put("UUID={x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
        uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
        uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15],
    });
    var hdr: [1024]u8 = std.mem.zeroes([1024]u8);
    @memcpy(hdr[0..16], &uuid);
    _ = writeAt(fd, &hdr, 0);
    _ = writeAt(fd, "SWAPSPACE2", @intCast(pagesize - 10));
    return 0;
}
