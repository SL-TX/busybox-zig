//! Task 10b — mount/swap/hotplug util-linux applets.

const std = @import("std");
fn err(rc: usize) c_int { return @intFromEnum(linux.errno(rc)); }
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

fn has(o: c.Options, bit: u5) bool {
    return c.flagged(o, bit);
}

fn pathStat(path: []const u8) ?linux.Statx {
    var st: linux.Statx = undefined;
    const p = c.zstr(path) catch return null;
    defer c.A.free(p);
    const rc = linux.statx(linux.AT.FDCWD, p, 0, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return st;
}

fn unescape(s: []const u8) []const u8 {
    // /proc/mounts encodes special characters as \0NN octal sequences.
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out = c.A.alloc(u8, s.len) catch return s;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 3 < s.len and s[i] == '\\' and s[i + 1] >= '0' and s[i + 1] <= '7' and
            s[i + 2] >= '0' and s[i + 2] <= '7' and s[i + 3] >= '0' and s[i + 3] <= '7')
        {
            out[n] = @intCast((s[i + 1] - '0') * 64 + (s[i + 2] - '0') * 8 + (s[i + 3] - '0'));
            n += 1;
            i += 4;
        } else {
            out[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

fn printMountTable(filter: ?[]const u8) c_int {
    const txt = c.readFile("/proc/mounts") catch return 1;
    defer c.A.free(txt);
    var lines = std.mem.splitScalar(u8, txt, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = f.next() orelse continue;
        const mp = f.next() orelse continue;
        const ty = f.next() orelse continue;
        const opts = f.next() orelse "";
        if (filter) |ft| {
            var hit = false;
            var it = std.mem.splitScalar(u8, ft, ',');
            while (it.next()) |t| {
                if (std.mem.eql(u8, t, ty)) hit = true;
            }
            if (!hit) continue;
        }
        c.put("{s} on {s} type {s} ({s})\n", .{ unescape(dev), unescape(mp), ty, unescape(opts) });
    }
    return 0;
}

const mount_optstr = "o:*t:rwanfvsiO:T:";

pub fn mount_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("mount", args, mount_optstr, &.{});
    if (o.args.len == 0) return printMountTable(optValue(args, mount_optstr, 't'));
    if (o.args.len < 2) c.usageDie("mount");
    const dev = o.args[0];
    const dir = o.args[1];
    const dry = has(o, 6);
    if (dry) return 0;
    const dp = c.zstr(dev) catch return 1;
    defer c.A.free(dp);
    const mp = c.zstr(dir) catch return 1;
    defer c.A.free(mp);
    var flags: u32 = 0;
    if (has(o, 2)) flags |= linux.MS.RDONLY;
    const tp = optValue(args, mount_optstr, 't');
    const tz: ?[*:0]const u8 = if (tp) |t| (c.zstr(t) catch return 1).ptr else null;
    const rc = linux.mount(dp, mp, tz, flags, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.plain("{s}", .{"permission denied (are you root?)"});
        return 1;
    }
    return 0;
}

fn optValue(args: []const []const u8, optstring: []const u8, target: u8) ?[]const u8 {
    var os = optstring;
    if (os.len > 0 and os[0] == '^') os = os[1..];
    if (os.len > 0 and (os[0] == '+' or os[0] == '-')) os = os[1..];
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
    var k: usize = 1;
    while (k < args.len) : (k += 1) {
        const tok = args[k];
        if (tok.len < 2 or tok[0] != '-' or tok[1] == '-') continue;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            if (ch == target) {
                if (!takes[ch]) return "";
                if (j + 1 < tok.len) return tok[j + 1 ..];
                if (k + 1 < args.len) return args[k + 1];
                return null;
            }
            if (takes[ch]) break;
        }
    }
    return null;
}

const umount_optstr = "fldnrat:cvi";

pub fn umount_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("umount", args, umount_optstr, &.{});
    if (o.args.len == 0 and !has(o, 5)) c.usageDie("umount");
    if (has(o, 5)) { // -a
        const txt = c.readFile("/proc/mounts") catch return 1;
        defer c.A.free(txt);
        var lines = std.mem.splitScalar(u8, txt, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            _ = f.next() orelse continue;
            const mp = f.next() orelse continue;
            const p = c.zstr(mp) catch continue;
            defer c.A.free(p);
            _ = linux.umount2(p, 0);
        }
        return 0;
    }
    for (o.args) |target| {
        const p = c.zstr(target) catch return 1;
        defer c.A.free(p);
        var flags: u32 = 0;
        if (has(o, 0)) flags |= linux.MNT.FORCE;
        if (has(o, 1)) flags |= linux.MNT.DETACH;
        const rc = linux.umount2(p, flags);
        if (linux.errno(rc) != .SUCCESS) {
            c.msg(err(rc), "can't unmount {s}", .{target});
            return 1;
        }
    }
    return 0;
}

pub fn rdev_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    c.setProg(argv);
    const txt = c.readFile("/proc/mounts") catch return 1;
    defer c.A.free(txt);
    var lines = std.mem.splitScalar(u8, txt, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = f.next() orelse continue;
        const mp = f.next() orelse continue;
        if (std.mem.eql(u8, mp, "/")) {
            c.put("{s} /\n", .{dev});
            return 0;
        }
    }
    return 1;
}

pub fn swapon_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("swapon", args, "aed::p:", &.{});
    if (o.args.len == 0) {
        const txt = c.readFile("/proc/swaps") catch return 1;
        defer c.A.free(txt);
        c.out(txt);
        return 0;
    }
    const ifexists = has(o, 1);
    for (o.args) |dev| {
        if (pathStat(dev) == null) {
            if (ifexists) continue;
            c.msg(2, "{s}", .{dev});
            return 1;
        }
        const p = c.zstr(dev) catch return 1;
        defer c.A.free(p);
        const rc = linux.syscall2(linux.SYS.swapon, @intFromPtr(p.ptr), 0);
        if (linux.errno(rc) != .SUCCESS) {
            const e = err(rc);
            if (ifexists and e == 2) continue;
            c.msg(e, "{s}", .{dev});
            return 1;
        }
    }
    return 0;
}

pub fn swapoff_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("swapoff", args, "ae", &.{});
    if (o.args.len == 0 and !has(o, 0)) c.usageDie("swapoff");
    if (has(o, 0)) {
        const txt = c.readFile("/proc/swaps") catch return 1;
        defer c.A.free(txt);
        var lines = std.mem.splitScalar(u8, txt, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const dev = f.next() orelse continue;
            const p = c.zstr(dev) catch continue;
            defer c.A.free(p);
            _ = linux.syscall2(linux.SYS.swapoff, @intFromPtr(p.ptr), 0);
        }
        return 0;
    }
    for (o.args) |dev| {
        const p = c.zstr(dev) catch return 1;
        defer c.A.free(p);
        const rc = linux.syscall2(linux.SYS.swapoff, @intFromPtr(p.ptr), 0);
        if (linux.errno(rc) != .SUCCESS) {
            c.msg(err(rc), "{s}", .{dev});
            return 1;
        }
    }
    return 0;
}


var mdev_verbose: u8 = 0;
var mdev_subsystem: []const u8 = "";

fn mdevDbg(comptime fmt: []const u8, args: anytype) void {
    if (mdev_verbose == 0) return;
    c.plain(fmt, args);
}

fn mdevCurtime(buf: []u8) []const u8 {
    var tv: linux.timeval = undefined;
    _ = linux.gettimeofday(&tv, null);
    const sec: i64 = @mod(@as(i64, @intCast(tv.sec)), 86400);
    const hh: u64 = @intCast(@divFloor(sec, 3600));
    const mm: u64 = @intCast(@divFloor(@mod(sec, 3600), 60));
    const ss: u64 = @intCast(@mod(sec, 60));
    const us: u64 = @intCast(tv.usec);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ hh, mm, ss, us }) catch "";
}

/// glibc's makedev() encoding, used for the Linux device-node number.
fn makedev(major: u32, minor: u32) linux.dev_t {
    return @as(linux.dev_t, major & 0xfff) << 8 |
        @as(linux.dev_t, minor & 0xff) |
        (@as(linux.dev_t, minor & ~@as(u32, 0xff)) << 12);
}

/// Port of mdev.c:make_device(): read the sysfs "dev" file, derive the node
/// name (from uevent's DEVNAME or the basename), then create/remove the node.
fn mdevMakeDevice(device_name_opt: ?[]const u8, sys_path: []const u8, remove: bool) void {
    const devfile = c.fmtAlloc("{s}/dev", .{sys_path}) catch return;
    defer c.A.free(devfile);
    const devtxt = c.readFile(devfile) catch return;
    defer c.A.free(devtxt);
    const colon = std.mem.indexOfScalar(u8, devtxt, ':') orelse return;
    const major = std.fmt.parseInt(u32, std.mem.trim(u8, devtxt[0..colon], " \t\r\n"), 10) catch return;
    const minor = std.fmt.parseInt(u32, std.mem.trim(u8, devtxt[colon + 1 ..], " \t\r\n"), 10) catch return;
    mdevDbg("dev {d},{d}", .{ major, minor });

    const derived = c.fmtAlloc("{s}/uevent", .{sys_path}) catch return;
    defer c.A.free(derived);
    const uevent_opt = c.readFile(derived) catch null;
    defer if (uevent_opt) |u| c.A.free(u);
    var derived_name: []const u8 = std.fs.path.basename(sys_path);
    if (device_name_opt == null) {
        if (uevent_opt) |uevent| {
            if (std.mem.indexOf(u8, uevent, "\nDEVNAME=")) |at| {
                const rest = uevent[at + 9 ..];
                const stop = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                derived_name = rest[0..stop];
            }
        }
    }
    const node_name = device_name_opt orelse derived_name;

    const is_block = std.mem.indexOf(u8, sys_path, "/block/") != null or
        std.mem.startsWith(u8, mdev_subsystem, "block");
    const base_mode: linux.mode_t = if (is_block) linux.S.IFBLK else linux.S.IFCHR;
    const mode: linux.mode_t = base_mode | 0o660;
    mdevDbg("mknod {s} ({d},{d}) {o} 0:0", .{ node_name, major, minor, mode });

    const np = c.zstr(node_name) catch return;
    defer c.A.free(np);
    if (remove) {
        _ = linux.unlink(np);
        mdevDbg("unlink: {s}", .{node_name});
        return;
    }
    if (std.mem.lastIndexOfScalar(u8, node_name, '/')) |slash| {
        const dir = c.A.dupe(u8, node_name[0..slash]) catch return;
        defer c.A.free(dir);
        var i: usize = 1;
        while (i < dir.len) : (i += 1) {
            if (dir[i] != '/') continue;
            const part = c.A.dupe(u8, dir[0..i]) catch return;
            defer c.A.free(part);
            const zp = c.zstr(part) catch return;
            defer c.A.free(zp);
            _ = linux.mkdir(zp, 0o755);
        }
    }
    const rc = linux.mknod(np, mode, makedev(major, minor));
    if (linux.errno(rc) != .SUCCESS and linux.errno(rc) != .EXIST)
        c.msg(err(rc), "can't create '{s}'", .{node_name});
}

fn mdevScanDir(path: []const u8, depth: u32) void {
    if (depth >= 3) return;
    const zp = c.zstr(path) catch return;
    defer c.A.free(zp);
    const fd = linux.open(zp, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var buf: [8192]u8 = undefined;
    while (true) {
        const got = linux.getdents64(@intCast(fd), &buf, buf.len);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        var off: usize = 0;
        const total: usize = @intCast(got);
        while (off + @sizeOf(linux.dirent64) <= total) {
            const ent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (ent.reclen == 0) break;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            off += ent.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const full = c.fmtAlloc("{s}/{s}", .{ path, name }) catch continue;
            defer c.A.free(full);
            var st: linux.Statx = undefined;
            if (linux.errno(linux.statx(linux.AT.FDCWD, c.zstr(full) catch continue, 0, .BASIC_STATS, &st)) != .SUCCESS) continue;
            if (std.mem.eql(u8, name, "dev") and (st.mode & linux.S.IFMT) == linux.S.IFREG) {
                const parent = full[0 .. full.len - 4];
                // Derive SUBSYSTEM from the "subsystem" symlink next to "dev".
                mdev_subsystem = "";
                const sub = c.fmtAlloc("{s}/subsystem", .{parent}) catch parent;
                defer if (sub.ptr != parent.ptr) c.A.free(sub);
                var sbuf: [512]u8 = undefined;
                const subz = c.zstr(sub) catch parent;
                defer c.A.free(subz);
                const sl = linux.readlink(@as([*:0]const u8, @ptrCast(subz.ptr)), &sbuf, sbuf.len);
                if (linux.errno(sl) != .SUCCESS) {
                    // fall back: no subsystem symlink
                } else {
                    const link: usize = @intCast(sl);
                    mdev_subsystem = std.fs.path.basename(sbuf[0..link]);
                }
                mdevMakeDevice(null, parent, false);
            } else if ((st.mode & linux.S.IFMT) == linux.S.IFDIR) {
                mdevScanDir(full, depth + 1);
            }
        }
    }
}

fn mdevInitialScan() void {
    mdevScanDir("/sys/dev", 0);
}

/// Shared event dispatcher for both the hotplug-helper and netlink daemon.
fn mdevDispatch(action: []const u8, devpath: []const u8, subsys_opt: ?[]const u8, devname_opt: ?[]const u8, seq_opt: ?[]const u8, fw_opt: ?[]const u8) void {
    const seq = seq_opt orelse "(null)";
    const subsys = subsys_opt orelse "(null)";
    const devname = devname_opt orelse "(null)";
    mdev_subsystem = subsys_opt orelse "";
    var tbuf: [40]u8 = undefined;
    mdevDbg("{s} ACTION:{s} SEQNUM:{s} SUBSYSTEM:{s} DEVNAME:{s} DEVPATH:{s}{s}{s}", .{
        mdevCurtime(&tbuf), action, seq, subsys, devname, devpath,
        if (fw_opt != null) " FW:" else "", if (fw_opt) |f| f else "",
    });
    const sys_path = c.fmtAlloc("/sys{s}", .{devpath}) catch return;
    defer c.A.free(sys_path);
    const is_remove = std.mem.eql(u8, action, "remove");
    if (is_remove and fw_opt == null) {
        mdevMakeDevice(devname_opt, sys_path, true);
    } else if (!is_remove) {
        mdevMakeDevice(devname_opt, sys_path, false);
    }
}

/// Hotplug-helper invocation: ACTION/DEVPATH come from the environment.
fn mdevProcessAction() void {
    const action = bb.env.get("ACTION") orelse c.usageDie("mdev");
    const devpath = bb.env.get("DEVPATH") orelse c.usageDie("mdev");
    mdevDispatch(action, devpath, bb.env.get("SUBSYSTEM"), bb.env.get("DEVNAME"), bb.env.get("SEQNUM"), bb.env.get("FIRMWARE"));
}

/// Netlink daemon: subscribe to kernel uevents and dispatch each one. Only
/// entered by -d; no test drives the infinite loop.
fn mdevDaemon(foreground: bool) c_int {
    const fd = linux.syscall3(.socket, 16, 2, 9); // AF_NETLINK, SOCK_DGRAM, KOBJECT_UEVENT
    if (linux.errno(fd) != .SUCCESS) {
        c.msg(err(fd), "can't open netlink socket", .{});
        return 1;
    }
    const Nl = extern struct { family: u16, pad: u16, pid: u32, groups: u32 };
    var addr = Nl{ .family = 16, .pad = 0, .pid = 0, .groups = 1 };
    const brc = linux.syscall3(.bind, fd, @intFromPtr(&addr), @sizeOf(Nl));
    if (linux.errno(brc) != .SUCCESS) {
        c.msg(err(brc), "can't bind netlink socket", .{});
        _ = linux.close(@intCast(fd));
        return 1;
    }
    if (!foreground) {
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return 1;
        if (pid != 0) return 0;
    }
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.recvfrom(@intCast(fd), &buf, buf.len, 0, null, null);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        // Uevent messages are NUL-separated "KEY=value" strings. Dispatch
        // the same way the kernel hotplug helper would.
        const total: usize = @intCast(n);
        var i: usize = 0;
        var action: ?[]const u8 = null;
        var devpath: ?[]const u8 = null;
        var subsys: ?[]const u8 = null;
        var devname: ?[]const u8 = null;
        var seq: ?[]const u8 = null;
        var fw: ?[]const u8 = null;
        while (i < total) {
            const msg = std.mem.sliceTo(buf[i..total].ptr, 0);
            i += msg.len + 1;
            if (std.mem.startsWith(u8, msg, "ACTION=")) action = msg[7..];
            if (std.mem.startsWith(u8, msg, "DEVPATH=")) devpath = msg[8..];
            if (std.mem.startsWith(u8, msg, "SUBSYSTEM=")) subsys = msg[10..];
            if (std.mem.startsWith(u8, msg, "DEVNAME=")) devname = msg[8..];
            if (std.mem.startsWith(u8, msg, "SEQNUM=")) seq = msg[7..];
            if (std.mem.startsWith(u8, msg, "FIRMWARE=")) fw = msg[9..];
        }
        if (action) |a| {
            if (devpath) |d| mdevDispatch(a, d, subsys, devname, seq, fw);
        }
    }
    _ = linux.close(@intCast(fd));
    return 0;
}

pub fn mdev_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("mdev", args, "sSdfv", &.{});
    const scan = has(o, 0);
    const daemon = has(o, 2);
    mdev_verbose = if (has(o, 4)) 1 else 0;
    mdev_subsystem = "";

    // mdev.c:xchdir("/dev") is unconditional.
    const devz = c.zstr("/dev") catch return 1;
    defer c.A.free(devz);
    if (linux.errno(linux.chdir(devz)) != .SUCCESS) {
        c.msg(err(linux.chdir(devz)), "can't chdir to /dev", .{});
        return 1;
    }

    if (daemon) return mdevDaemon(has(o, 3));
    if (scan) {
        mdevInitialScan();
    } else {
        mdevProcessAction();
        var tbuf: [40]u8 = undefined;
        mdevDbg("{s} exiting", .{mdevCurtime(&tbuf)});
    }
    return 0;
}
