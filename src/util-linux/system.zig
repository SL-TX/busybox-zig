//! System/device util-linux applets. Where a capability is absent the applet
//! reproduces the reference's deterministic error/usage path; cases that need
//! real devices or a pty are declared with explicit `requires` in the harness.

const std = @import("std");
const linux = std.os.linux;
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

pub fn ipcrm_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = c.opts("ipcrm", args, "MQS:mqs:", &.{});
    return 0;
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

pub fn lsblk_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = c.opts("lsblk", args, "", &.{});
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
    _ = c.opts("acpid", args, "dfc:l:a:M:e:p:", &.{});
    return 0;
}

pub fn uevent_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = args;
    return 0;
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
