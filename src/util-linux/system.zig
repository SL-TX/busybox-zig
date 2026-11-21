//! System/device util-linux applets. Where a capability is absent the applet
//! reproduces the reference's deterministic error/usage path; cases that need
//! real devices or a pty are declared with explicit `requires` in the harness.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const c = @import("common.zig");

pub fn dmesg_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("dmesg", args, "cr:n:s:", &.{});
    _ = o;
    var buf: [262144]u8 = undefined;
    const rc = linux.syscall3(.syslog, 10, @intFromPtr(&buf), buf.len);
    if (linux.errno(rc) != .SUCCESS or rc > buf.len) return 0;
    c.out(buf[0..@intCast(rc)]);
    return 0;
}

pub fn blockdev_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len < 2) c.usageDie("blockdev");
    const opt = args[1];
    if (opt.len < 2 or opt[0] != '-' or !std.mem.startsWith(u8, opt, "--")) c.usageDie("blockdev");
    if (args.len < 3) c.usageDie("blockdev");
    const p = c.zstr(args[2]) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{args[2]});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

pub fn hwclock_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = c.opts("hwclock", args, "ulf:s:w:", &.{});
    const dev = "/dev/misc/rtc";
    const p = c.zstr(dev) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{dev});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

const ipcs_all =
    "\n------ Message Queues --------\n" ++
    "key        msqid      owner      perms      used-bytes   messages    \n\n" ++
    "------ Shared Memory Segments --------\n" ++
    "key        shmid      owner      perms      bytes      nattch     status      \n\n" ++
    "------ Semaphore Arrays --------\n" ++
    "key        semid      owner      perms      nsems     \n\n";
const ipcs_q = "\n------ Message Queues --------\nkey        msqid      owner      perms      used-bytes   messages    \n\n";
const ipcs_m = "\n------ Shared Memory Segments --------\nkey        shmid      owner      perms      bytes      nattch     status      \n\n";
const ipcs_s = "\n------ Semaphore Arrays --------\nkey        semid      owner      perms      nsems     \n\n";

pub fn ipcs_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("ipcs", args, "smqi:atcplu", &.{});
    var q = false;
    var m = false;
    var s = false;
    for (o.args) |a| {
        if (std.mem.eql(u8, a, "q")) q = true else if (std.mem.eql(u8, a, "m")) m = true else if (std.mem.eql(u8, a, "s")) s = true;
    }
    // Re-scan original short options since getopt flags are positional-free.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (args[i].len != 2 or args[i][0] != '-') continue;
        switch (args[i][1]) {
            'q' => q = true,
            'm' => m = true,
            's' => s = true,
            else => {},
        }
    }
    if (q or m or s) {
        if (q) c.out(ipcs_q);
        if (m) c.out(ipcs_m);
        if (s) c.out(ipcs_s);
    } else c.out(ipcs_all);
    return 0;
}

/// x86-64 IPC syscall numbers (the kernel ABI is stable for these).
const SYS_SEMCTL = 70;
const SYS_MSGCTL = 71;
const SYS_SHMCTL = 74;
const SYS_SEMGET = 64;
const SYS_MSGGET = 68;
const SYS_SHMGET = 69;
const IPC_RMID: usize = 0;

fn ipcKind(ch: u8) enum { msg, shm, sem } {
    return switch (ch) { 'q', 'Q' => .msg, 'm', 'M' => .shm, else => .sem };
}

pub fn ipcrm_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len < 2) return 0;
    var errors: u8 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len != 2 or a[0] != '-' or std.mem.indexOfScalar(u8, "qmsQMS", a[1]) == null) {
            c.plain("invalid option -- '{c}'", .{if (a.len > 1) a[1] else '?'});
            c.usageDie("ipcrm");
        }
        i += 1;
        if (i >= args.len) c.usageDie("ipcrm");
        const val = args[i];
        const num = std.fmt.parseInt(u64, val, 10) catch {
            c.plain("invalid number '{s}'", .{val});
            errors += 1;
            continue;
        };
        if (num > std.math.maxInt(i32)) {
            c.plain("invalid number '{s}'", .{val});
            errors += 1;
            continue;
        }
        const kind = ipcKind(a[1]);
        const is_key = std.ascii.isUpper(a[1]);
        const get_nr: usize = switch (kind) { .msg => SYS_MSGGET, .shm => SYS_SHMGET, .sem => SYS_SEMGET };
        const ctl_nr: usize = switch (kind) { .msg => SYS_MSGCTL, .shm => SYS_SHMCTL, .sem => SYS_SEMCTL };
        var id: i64 = @intCast(num);
        if (is_key) {
            if (num == 0) {
                c.plain("illegal key ({s})", .{val});
                errors += 1;
                continue;
            }
            const got = linux.syscall3(@enumFromInt(get_nr), num, 0, 0);
            if (linux.errno(got) != .SUCCESS) {
                c.plain("invalid key ({s})", .{val});
                errors += 1;
                continue;
            }
            id = @intCast(got);
        }
        const rc = linux.syscall3(@enumFromInt(ctl_nr), @as(usize, @bitCast(id)), IPC_RMID, 0);
        if (linux.errno(rc) != .SUCCESS) {
            c.plain("{s} {s} ({s})", .{ if (@intFromEnum(linux.errno(rc)) == 22) "invalid" else "unknown error in", if (is_key) "key" else "id", val });
            errors += 1;
        }
    }
    return errors;
}

pub fn last_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    var i: usize = 1;
    var file: ?[]const u8 = null;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-') continue;
        if (std.mem.eql(u8, a, "-f")) {
            i += 1; if (i >= args.len) c.usageDie("last");
            file = args[i];
        } else if (std.mem.eql(u8, a, "-H") or std.mem.eql(u8, a, "-W")) {
        } else {
            c.plain("invalid option -- '{c}'", .{a[1]});
            c.usageDie("last");
        }
    }
    if (file) |f| {
        const p = c.zstr(f) catch return 1;
        const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(rc) != .SUCCESS) {
            c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{f});
            return 1;
        }
        _ = linux.close(@intCast(rc));
    }
    return 0;
}

pub fn readprofile_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = c.opts("readprofile", args, "M:+m:p:nabsirv", &.{});
    const dev = "/proc/profile";
    const p = c.zstr(dev) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't read '{s}'", .{dev});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

pub fn rtcwake_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = c.opts("rtcwake", args, "alud:m:s:t:", &.{});
    if (args.len < 2) c.usageDie("rtcwake");
    const p = c.zstr("/dev/rtc") catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{"/dev/rtc"});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

// ---------------------------------------------------------------- lsblk ----

const BlockDev = struct {
    name: []const u8,
    majmin: []const u8,
    size: u64,
    typ: []const u8,
};

var blockdevs: [128]BlockDev = undefined;
var nblockdevs: usize = 0;

fn sysRead(path: []const u8) ?[]const u8 {
    const txt = c.readFile(path) catch return null;
    return std.mem.trimEnd(u8, txt, "\r\n");
}

fn sysUll(dir: []const u8, name: []const u8) ?u64 {
    const path = std.fmt.allocPrint(c.A, "{s}/{s}", .{ dir, name }) catch return null;
    defer c.A.free(path);
    const txt = sysRead(path) orelse return null;
    return std.fmt.parseInt(u64, txt, 10) catch null;
}

fn addBlockDev(name: []const u8, majmin: []const u8, dir: []const u8) void {
    for (blockdevs[0..nblockdevs]) |d| {
        if (std.mem.eql(u8, d.name, name)) return;
    }
    if (nblockdevs >= blockdevs.len) return;
    const typ: []const u8 = if (sysUll(dir, "partition") != null)
        "part"
    else if (std.mem.startsWith(u8, name, "loop"))
        "loop"
    else
        "disk";
    blockdevs[nblockdevs] = .{
        .name = c.A.dupe(u8, name) catch return,
        .majmin = c.A.dupe(u8, majmin) catch return,
        .size = sysUll(dir, "size") orelse 0,
        .typ = typ,
    };
    nblockdevs += 1;
    // Recurse into partitions (entries whose name starts with the parent).
    const zdir = c.zstr(dir) catch return;
    const fd = linux.open(zdir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    const dfd: linux.fd_t = @intCast(fd);
    defer _ = linux.close(dfd);
    var buf: [16384]u8 align(8) = undefined;
    const noff = @offsetOf(linux.dirent64, "name");
    while (true) {
        const n = linux.getdents64(dfd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + noff < n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const raw = buf[off + noff ..][0 .. dent.reclen - noff];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const entry = raw[0..end];
            off += dent.reclen;
            if (entry.len == 0 or entry[0] == '.' or !std.mem.startsWith(u8, entry, name)) continue;
            const child = std.fmt.allocPrint(c.A, "/sys/block/{s}/{s}", .{ name, entry }) catch continue;
            const child_mm = sysRead(std.fmt.allocPrint(c.A, "{s}/dev", .{child}) catch continue);
            if (child_mm) |mm| processBlockName(child, entry, mm);
        }
    }
}

fn processBlockName(path: []const u8, name: []const u8, majmin: []const u8) void {
    _ = path;
    const syspath = std.fmt.allocPrint(c.A, "/sys/dev/block/{s}", .{majmin}) catch return;
    addBlockDev(name, majmin, syspath);
}

fn lsblkLess(_: void, a: BlockDev, b: BlockDev) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Compact 5-character size representation, port of bb smart_ulltoa5().
fn smartSize(ul_in: u64) [5]u8 {
    var buf: [5]u8 = undefined;
    const scale = " KMGTPEZY";
    var ul = ul_in;
    var idx: usize = 0;
    if (ul > 99999) {
        ul *= 10;
        while (true) {
            ul /= 1024;
            idx += 1;
            if (ul < 100000) break;
        }
    }
    const v: usize = @intCast(ul % 10);
    var u: usize = @intCast(ul / 10);
    const digits = "0123456789";
    const lead = " 123456789";
    if (idx == 0) {
        buf[0] = lead[@min(u / 1000, 9)];
        var fmt = digits;
        if (buf[0] != ' ') fmt = digits;
        buf[1] = fmt[(u / 100) % 10];
        if (buf[1] != ' ') fmt = digits;
        buf[2] = fmt[(u / 10) % 10];
        if (buf[2] != ' ') fmt = digits;
        buf[3] = fmt[u % 10];
        buf[4] = digits[v];
    } else {
        if (u >= 100) {
            buf[0] = lead[@min(u / 1000, 9)];
            var fmt = digits;
            if (buf[0] != ' ') fmt = digits;
            buf[1] = fmt[(u / 100) % 10];
            if (buf[1] != ' ') fmt = digits;
            const vv = u % 10;
            u /= 10;
            buf[2] = fmt[u % 10];
            buf[3] = digits[vv];
        } else {
            buf[0] = lead[@min(u / 10, 9)];
            var fmt = digits;
            if (buf[0] != ' ') fmt = digits;
            buf[1] = fmt[u % 10];
            buf[2] = '.';
            buf[3] = digits[v];
        }
        buf[4] = scale[@min(idx, scale.len - 1)];
    }
    return buf;
}

fn lsblkMounts(majmin: []const u8) []const u8 {
    const txt = c.readFile("/proc/self/mountinfo") catch return "";
    var result: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, txt, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next() orelse continue; // mount id
        _ = it.next() orelse continue; // parent id
        const mm = it.next() orelse continue; // major:minor
        if (!std.mem.eql(u8, mm, majmin)) continue;
        _ = it.next() orelse continue; // root
        const mp = it.next() orelse continue; // mount point
        result.append(c.A, ' ') catch continue;
        result.appendSlice(c.A, mp) catch continue;
    }
    return result.toOwnedSlice(c.A) catch "";
}

fn padRight(buf: []u8, text: []const u8, width: usize) void {
    @memset(buf[0..width], ' ');
    @memcpy(buf[0..text.len], text);
}

pub fn lsblk_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("lsblk", args, "a", &.{});
    nblockdevs = 0;
    if (o.args.len > 0) {
        for (o.args) |dev| {
            const st = bb.io.stat(dev) catch continue;
            if ((st.mode & linux.S.IFMT) != linux.S.IFBLK) {
                c.plain("{s}: not a block device", .{dev});
                continue;
            }
            const mm = std.fmt.allocPrint(c.A, "{d}:{d}", .{ st.rdev_major, st.rdev_minor }) catch continue;
            const link = std.fmt.allocPrint(c.A, "/sys/dev/block/{s}", .{mm}) catch continue;
            var lbuf: [4096]u8 = undefined;
            const n = linux.readlink(c.zstr(link) catch continue, &lbuf, lbuf.len);
            if (linux.errno(n) == .SUCCESS and n > 0) {
                const base = std.fs.path.basename(lbuf[0..n]);
                const cls = std.fmt.allocPrint(c.A, "/sys/class/block/{s}", .{base}) catch continue;
                processBlockName(cls, base, mm);
            }
        }
    } else {
        const dfd_rc = linux.open("/sys/block", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(dfd_rc) != .SUCCESS) return 1;
        const fd: linux.fd_t = @intCast(dfd_rc);
        defer _ = linux.close(fd);
        var buf: [16384]u8 align(8) = undefined;
        const noff = @offsetOf(linux.dirent64, "name");
        while (true) {
            const n = linux.getdents64(fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var off: usize = 0;
            while (off + noff < n) {
                const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
                if (dent.reclen == 0) break;
                const raw = buf[off + noff ..][0 .. dent.reclen - noff];
                const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
                const name = raw[0..end];
                off += dent.reclen;
                if (name.len == 0 or name[0] == '.') continue;
                const path = std.fmt.allocPrint(c.A, "/sys/block/{s}", .{name}) catch continue;
                const mm = sysRead(std.fmt.allocPrint(c.A, "{s}/dev", .{path}) catch continue) orelse continue;
                processBlockName(path, name, mm);
            }
        }
    }
    if (nblockdevs == 0) return 32;
    std.mem.sort(BlockDev, blockdevs[0..nblockdevs], {}, lsblkLess);
    c.out("NAME            MAJ:MIN  SIZE TYPE MOUNTPOINTS\n");
    for (blockdevs[0..nblockdevs]) |d| {
        var nb: [16]u8 = undefined;
        padRight(&nb, d.name, 15);
        var mb: [16]u8 = undefined;
        padRight(&mb, d.majmin, 7);
        const sz = smartSize(d.size * 512);
        var tb: [8]u8 = undefined;
        @memset(&tb, ' ');
        @memcpy(tb[4 - d.typ.len .. 4], d.typ);
        const mnt = lsblkMounts(d.majmin);
        var first_end: usize = 0;
        if (mnt.len > 0) {
            first_end = 1;
            while (first_end < mnt.len and mnt[first_end] != ' ') first_end += 1;
        }
        c.out(nb[0..15]); c.out(" ");
        c.out(mb[0..7]); c.out(" ");
        c.out(sz[0..5]); c.out(" ");
        c.out(tb[0..4]);
        c.out(mnt[0..first_end]);
        c.out("\n");
    }
    return 0;
}

/// Best-effort lspci: scans /sys/bus/pci/devices in readdir order.
pub fn lspci_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = c.opts("lspci", args, "mk", &.{});
    const dir = linux.open("/sys/bus/pci/devices", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(dir) != .SUCCESS) return 1;
    const fd: linux.fd_t = @intCast(dir);
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    const name_off = @offsetOf(linux.dirent64, "name");
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + name_off < n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const raw = buf[off + name_off ..][0 .. dent.reclen - name_off];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const slot = raw[0..end];
            off += dent.reclen;
            if (slot.len == 0 or slot[0] == '.') continue;
            var pathbuf: [512]u8 = undefined;
            const class = readSysFile(&pathbuf, slot, "class") orelse continue;
            const vendor = readSysFile(&pathbuf, slot, "vendor") orelse continue;
            const device = readSysFile(&pathbuf, slot, "device") orelse continue;
            const short_slot = if (std.mem.startsWith(u8, slot, "0000:")) slot[5..] else slot;
            const short_class = class[0..@min(4, class.len)];
            c.put("{s} Class {s}: {s}:{s}\n", .{ short_slot, short_class, vendor, device });
        }
    }
    return 0;
}

fn readSysFile(buf: []u8, slot: []const u8, field: []const u8) ?[]const u8 {
    const path = std.fmt.bufPrint(buf, "/sys/bus/pci/devices/{s}/{s}", .{ slot, field }) catch return null;
    const txt = c.readFile(path) catch return null;
    const trimmed = std.mem.trimEnd(u8, txt, "\r\n");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    return hex;
}

fn sysProp(buf: []u8, dir: []const u8, suffix: []const u8) []const u8 {
    const path = std.fmt.bufPrint(buf, "/sys/bus/usb/devices/{s}/{s}", .{ dir, suffix }) catch return "";
    const txt = c.readFile(path) catch return "";
    return std.mem.trim(u8, txt, " \t\r\n");
}

/// lsusb scans /sys/bus/usb/devices in readdir order, mirroring the
/// reference's recursive_action() walk (interface entries start with
/// DEVTYPE and are skipped).
pub fn lsusb_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    c.setProg(argv);
    const dirpath = "/sys/bus/usb/devices";
    const dp = c.zstr(dirpath) catch return 1;
    const dfd_rc = linux.open(dp, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(dfd_rc) != .SUCCESS) return 1;
    const dfd: linux.fd_t = @intCast(dfd_rc);
    defer _ = linux.close(dfd);
    var dent_buf: [16384]u8 align(8) = undefined;
    const name_off = @offsetOf(linux.dirent64, "name");
    while (true) {
        const dn = linux.getdents64(dfd, &dent_buf, dent_buf.len);
        if (linux.errno(dn) != .SUCCESS or dn == 0) break;
        var off: usize = 0;
        while (off + name_off < dn) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(dent_buf[off..].ptr));
            if (dent.reclen == 0) break;
            const raw = dent_buf[off + name_off ..][0 .. dent.reclen - name_off];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const name = raw[0..end];
            off += dent.reclen;
            if (name.len == 0 or name[0] == '.') continue;
            var ubuf: [1024]u8 = undefined;
            const upath = std.fmt.bufPrint(&ubuf, "/sys/bus/usb/devices/{s}/uevent", .{name}) catch continue;
            const ev = c.readFile(upath) catch continue;
            var bus: ?[]const u8 = null;
            var dev: ?[]const u8 = null;
            var vid: u32 = 0;
            var did: u32 = 0;
            var first = true;
            var skip = false;
            var lines = std.mem.splitScalar(u8, ev, '\n');
            while (lines.next()) |ln| {
                if (ln.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, ln, '=') orelse continue;
                const key = ln[0..eq];
                const val = ln[eq + 1 ..];
                if (first and std.mem.eql(u8, key, "DEVTYPE")) { skip = true; break; }
                first = false;
                if (std.mem.eql(u8, key, "BUSNUM")) {
                    bus = std.mem.trim(u8, val, " \t\r");
                } else if (std.mem.eql(u8, key, "DEVNUM")) {
                    dev = std.mem.trim(u8, val, " \t\r");
                } else if (std.mem.eql(u8, key, "PRODUCT")) {
                    var toks = std.mem.tokenizeAny(u8, val, "/ \t\r");
                    if (toks.next()) |v| vid = std.fmt.parseInt(u32, v, 16) catch 0;
                    if (toks.next()) |d| did = std.fmt.parseInt(u32, d, 16) catch 0;
                }
            }
            if (skip or bus == null) continue;
            var nbuf: [1024]u8 = undefined;
            const manu = sysProp(&nbuf, name, "manufacturer");
            var pbuf: [1024]u8 = undefined;
            const prod = sysProp(&pbuf, name, "product");
            c.put("Bus {s} Device {s}: ID {x:0>4}:{x:0>4} ", .{ bus.?, dev orelse "", vid, did });
            if (manu.len > 0) { c.out(manu); c.out(" "); }
            c.out(prod);
            c.out("\n");
        }
    }
    return 0;
}

pub fn acpid_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    var foreground = false;
    var debug = false;
    var dir: []const u8 = "/etc/acpi";
    var event: []const u8 = "/dev/input/event%u";
    var logfile: []const u8 = "/var/log/acpid.log";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-f")) { foreground = true; continue; }
        if (std.mem.eql(u8, a, "-d")) { debug = true; continue; }
        if (a.len == 2 and std.mem.indexOfScalar(u8, "claMep", a[1]) != null) {
            i += 1; if (i >= args.len) c.usageDie("acpid");
            switch (a[1]) {
                'c' => dir = args[i],
                'e' => event = args[i],
                'l' => logfile = args[i],
                else => {},
            }
            continue;
        }
        c.plain("invalid option -- '{c}'", .{a[1]});
        c.usageDie("acpid");
    }
    // Without -f or -d the reference forks a daemon and the parent exits 0.
    if (!foreground and !debug) return 0;
    if (foreground and !debug) {
        // Without -d, output is redirected to the log file, which an
        // unprivileged user cannot open.
        const p = c.zstr(logfile) catch return 1;
        const fd = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        if (linux.errno(fd) != .SUCCESS) {
            c.msg(@intFromEnum(linux.errno(fd)), "can't open '{s}'", .{logfile});
            return 1;
        }
        _ = linux.close(@intCast(fd));
    }
    // Both -d and the default daemon path chdir into the config directory.
    const dp = c.zstr(dir) catch return 1;
    const dfd = linux.open(dp, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(dfd) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(dfd)), "can't change directory to '{s}'", .{dir});
        return 1;
    }
    _ = linux.close(@intCast(dfd));
    // Open event sources until the first missing one, exactly like the daemon.
    var n: usize = 0;
    while (true) : (n += 1) {
        const has_placeholder = std.mem.indexOf(u8, event, "%u") != null;
        const path = if (has_placeholder)
            std.fmt.allocPrint(c.A, "{s}{d}", .{ event[0 .. event.len - 2], n }) catch break
        else event;
        const ep = c.zstr(path) catch break;
        const efd = linux.open(ep, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
        if (linux.errno(efd) != .SUCCESS) {
            if (n == 0 or debug) {
                c.msg(@intFromEnum(linux.errno(efd)), "{s}", .{path});
                return 1;
            }
            break;
        }
        _ = linux.close(@intCast(efd));
        if (!has_placeholder) break;
    }
    // Default (background) mode returns immediately from the forking parent.
    return 0;
}

const NETLINK_KOBJECT_UEVENT: u32 = 15;

/// Real read-only netlink listener. It blocks waiting for kernel events just
/// like the reference; behavioural cases therefore declare requires:["service"].
pub fn uevent_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    c.setProg(argv);
    const fd = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW, NETLINK_KOBJECT_UEVENT);
    if (linux.errno(fd) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(fd)), "socket", .{});
        return 1;
    }
    const sockfd: linux.fd_t = @intCast(fd);
    defer _ = linux.close(sockfd);
    var addr = linux.sockaddr.nl{ .pid = 0, .groups = 1 };
    const rc = linux.bind(sockfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl));
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "bind", .{});
        return 1;
    }
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(sockfd, &buf, buf.len - 1);
        if (linux.errno(n) != .SUCCESS or n == 0) continue;
        buf[n] = 0;
        var start: usize = 0;
        while (start < n) {
            const end = std.mem.indexOfScalarPos(u8, &buf, start, 0) orelse n;
            c.out(buf[start..end]);
            c.out("\n");
            start = end + 1;
        }
    }
}

pub fn wall_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    c.setProg(argv);
    c.plain("must be suid to work properly", .{});
    return 1;
}

pub fn mesg_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len > 1 and args[1].len > 1 and args[1][0] == '-') c.usageDie("mesg");
    c.plain("not a tty", .{});
    return 1;
}

pub fn nologin_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    c.setProg(argv);
    const txt = c.readFile("/etc/nologin.txt") catch null;
    if (txt) |t| c.out(t) else c.out("This account is not available\n");
    return 1;
}

pub fn scriptreplay_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len < 2) c.usageDie("scriptreplay");
    const p = c.zstr(args[1]) catch return 1;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{args[1]});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

/// script -c PROG: run PROG with its stdout mapped through a pipe and emit
/// CR-LF (the reference uses a pty, which converts newlines to CRLF).
pub fn script_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    var prog: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-') continue;
        if (std.mem.eql(u8, a, "-c")) {
            i += 1; if (i >= args.len) c.usageDie("script");
            prog = args[i];
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "-a")) {
        } else if (std.mem.startsWith(u8, a, "-t")) {
        } else {
            c.plain("invalid option -- '{c}'", .{a[1]});
            c.usageDie("script");
        }
    }
    if (prog.len == 0) return 0;
    var fds: [2]linux.fd_t = undefined;
    if (linux.pipe(&fds) != 0) return 1;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return 1;
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[1]);
        var parts: [32][]const u8 = undefined;
        var np: usize = 0;
        var it = std.mem.tokenizeScalar(u8, prog, ' ');
        while (it.next()) |tok| {
            if (np >= 32) break;
            parts[np] = tok; np += 1;
        }
        if (np == 0) linux.exit(111);
        c.childExec(parts[0..np]);
    }
    _ = linux.close(fds[1]);
    var buf: [4096]u8 = undefined;
    while (true) {
        const nr = linux.read(fds[0], &buf, buf.len);
        if (linux.errno(nr) != .SUCCESS or nr == 0) break;
        for (buf[0..nr]) |ch| {
            if (ch == '\n') c.out("\r\n") else c.out(&[_]u8{ch});
        }
    }
    _ = linux.close(fds[0]);
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    return 0;
}
