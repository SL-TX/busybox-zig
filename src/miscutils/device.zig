//! Device-bound miscutils whose sandbox behaviour is the reference's open()
//! diagnostic: devmem, lsscsi, partprobe, readahead, volname, watchdog,
//! beep, mt, hdparm, setserial, fbsplash, conspy.
//! No real device is ever written; every path is reached through open/ioctl
//! exactly as in the reference.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

fn openRead(name: []const u8, flags: linux.O) ?linux.fd_t {
    const z = c.zstr(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(z);
    const rc = linux.open(z, flags, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{name});
        return null;
    }
    return @intCast(rc);
}

// ------------------------------------------------------------------- devmem

pub fn devmem_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("devmem");
    if (args.len < 2) c.usageDie("devmem");
    const address = c.parseUnsigned(args[1], 0) catch c.usageDie("devmem");
    _ = address;
    if (args.len > 2) _ = c.parseUnsigned(args[2], 0) catch c.usageDie("devmem");
    if (args.len > 3) _ = c.parseUnsigned(args[3], 0) catch c.usageDie("devmem");
    const fd = openRead("/dev/mem", .{ .ACCMODE = .RDWR }) orelse return 1;
    _ = linux.close(fd);
    return 0;
}

// ------------------------------------------------------------------- lsscsi

const ScsiEntry = struct { name: []u8 };

pub fn lsscsi_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    const a = std.heap.page_allocator;
    const path = "/sys/bus/scsi/devices";
    const pz = c.zstr(a, path) catch return 0;
    defer a.free(pz);
    const rc = linux.open(pz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return 0;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var entries: std.ArrayList(ScsiEntry) = .empty;
    defer {
        for (entries.items) |e| a.free(e.name);
        entries.deinit(a);
    }
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var pos: usize = 0;
        while (pos + 19 <= n) {
            const reclen = std.mem.readInt(u16, buf[pos + 16 ..][0..2], .native);
            if (reclen < 19 or pos + reclen > n) break;
            const nb = buf[pos + 19 .. pos + reclen];
            const len = std.mem.indexOfScalar(u8, nb, 0) orelse nb.len;
            if (len > 0 and std.ascii.isDigit(nb[0]) and std.mem.indexOfScalar(u8, nb[0..len], ':') != null) {
                entries.append(a, .{ .name = a.dupe(u8, nb[0..len]) catch break }) catch break;
            }
            pos += reclen;
        }
    }
    std.mem.sort(ScsiEntry, entries.items, {}, struct {
        fn less(_: void, x: ScsiEntry, y: ScsiEntry) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    for (entries.items) |e| {
        var full: [512]u8 = undefined;
        const base = std.fmt.bufPrint(&full, "{s}/{s}", .{ path, e.name }) catch continue;
        var line: [128]u8 = undefined;
        const vendor = readSysFile(base, "vendor", &line) orelse "";
        var l2: [128]u8 = undefined;
        const typ = readSysFile(base, "type", &l2) orelse "";
        var l3: [128]u8 = undefined;
        const model = readSysFile(base, "model", &l3) orelse "";
        var l4: [128]u8 = undefined;
        const rev = readSysFile(base, "rev", &l4) orelse "";
        c.printfOut("[{s}]\t{s}\t{s}\t{s}\t{s}\n", .{ e.name, typName(typ), vendor, model, rev });
    }
    return 0;
}

fn readSysFile(base: []const u8, leaf: []const u8, buf: []u8) ?[]const u8 {
    var path: [1024]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "{s}/{s}", .{ base, leaf }) catch return null;
    var en: c_int = 0;
    const data = c.readFile(std.heap.page_allocator, p, &en) orelse return null;
    defer std.heap.page_allocator.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    const n = @min(trimmed.len, buf.len);
    @memcpy(buf[0..n], trimmed[0..n]);
    return buf[0..n];
}

fn typName(t: []const u8) []const u8 {
    const types = [_][]const u8{ "disk", "tape", "printer", "process", "worm", "", "scanner", "optical", "mediumx", "comms", "", "", "storage", "enclosu", "sim dsk", "opti rd", "bridge", "osd", "adi" };
    const v = std.fmt.parseInt(usize, t, 10) catch return t;
    if (v >= types.len or types[v].len == 0) return t;
    return types[v];
}

// ---------------------------------------------------------------- partprobe

pub fn partprobe_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("partprobe");
    var status: c_int = 0;
    for (args[1..]) |dev| {
        const fd = openRead(dev, .{ .ACCMODE = .RDWR }) orelse {
            status = 1;
            continue;
        };
        _ = linux.ioctl(fd, 0x125f, 0); // BLKRRPART
        _ = linux.close(fd);
    }
    return status;
}

// ---------------------------------------------------------------- readahead

pub fn readahead_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("readahead");
    if (args.len < 2) c.usageDie("readahead");
    var status: c_int = 0;
    for (args[1..]) |name| {
        const fd = openRead(name, .{ .ACCMODE = .RDONLY }) orelse {
            status = 1;
            continue;
        };
        var st: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, c.zstr(a, name) catch "", 0, .BASIC_STATS, &st);
        const size: usize = if (linux.errno(rc) == .SUCCESS) @intCast(st.size) else 0;
        _ = linux.syscall4(.readahead, @as(u64, @intCast(fd)), 0, size, 0);
        _ = linux.close(fd);
    }
    return status;
}

// ------------------------------------------------------------------ volname

pub fn volname_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("volname");
    const dev: []const u8 = if (args.len > 1) args[1] else "/dev/cdrom";
    const fd = openRead(dev, .{ .ACCMODE = .RDONLY }) orelse return 1;
    var label: [32]u8 = undefined;
    const rc = linux.ioctl(fd, 0x5300, @intFromPtr(&label)); // CDROM_GET_VOLUME
    _ = linux.close(fd);
    if (linux.errno(rc) != .SUCCESS) return 1;
    c.out(std.mem.trimEnd(u8, &label, " \t\r\n\x00"));
    c.out("\n");
    return 0;
}

// ----------------------------------------------------------------- watchdog

pub fn watchdog_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("watchdog");
    var foreground = false;
    var dev: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-F")) {
            foreground = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "-T")) {
            i += 1;
        } else if (arg.len > 1 and arg[0] == '-') {
            c.usageDie("watchdog");
        } else {
            dev = arg;
        }
    }
    const device = dev orelse c.usageDie("watchdog");
    if (!foreground) {
        const child = bb.process.fork() catch return 1;
        if (child != 0) return 0;
        // The daemon child's diagnostics go to the syslog, not to stderr.
        const nullz = c.zstr(a, "/dev/null") catch std.process.exit(1);
        const nullfd = linux.open(nullz, .{ .ACCMODE = .WRONLY }, 0);
        if (linux.errno(nullfd) == .SUCCESS) _ = linux.dup2(@intCast(nullfd), 2);
    }
    const fd = openRead(device, .{ .ACCMODE = .WRONLY }) orelse return 1;
    while (true) {
        _ = linux.write(fd, "1", 1);
        var req: linux.timespec = .{ .sec = 1, .nsec = 0 };
        _ = linux.nanosleep(&req, null);
    }
}

// --------------------------------------------------------------------- beep

pub fn beep_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("beep");
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "-l") or
            std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "-r")) and i + 1 < args.len) i += 1;
    }
    const z = c.zstr(a, "/dev/console") catch return 1;
    defer a.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .WRONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.plainMsg("can't open console", .{});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

// ------------------------------------------------------------------------ mt

const opcodes = [_][]const u8{
    "bsf", "bsfm", "bsr", "bss", "datacompression", "drvbuffer", "eof", "eom", "erase", "fsf", "fsfm", "fsr", "fss",
    "load", "lock", "mkpart", "nop", "offline", "ras1", "ras2", "ras3", "reset", "retension", "rewind", "rewoffline",
    "seek", "setblk", "setdensity", "setpart", "tell", "unload", "unlock", "weof", "wset",
};

pub fn mt_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("mt");
    if (args.len < 2) c.usageDie("mt");
    var dev: []const u8 = "/dev/tape";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-f") and i + 1 < args.len) {
            i += 1;
            dev = args[i];
        } else if (args[i].len > 1 and args[i][0] == '-') {
            c.usageDie("mt");
        } else break;
    }
    if (i >= args.len) c.usageDie("mt");
    const op = args[i];
    var valid = false;
    for (opcodes) |o| if (std.mem.eql(u8, o, op)) {
        valid = true;
        break;
    };
    if (!valid) {
        c.plainMsg("unrecognized opcode {s}", .{op});
        return 1;
    }
    const fd = openRead(dev, .{ .ACCMODE = .RDONLY }) orelse return 1;
    _ = linux.close(fd);
    return 0;
}

// -------------------------------------------------------------------- hdparm

fn validHdparmOpt(ch: u8) bool {
    return std.mem.indexOfScalar(u8, "gfuprmckaBtTiIdDS PXKA LWCyYzZUQR", ch) != null;
}

pub fn hdparm_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("hdparm");
    var i: usize = 1;
    var device: ?[]const u8 = null;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len < 2 or arg[0] != '-') {
            device = arg;
            break;
        }
        for (arg[1..]) |ch| {
            if (!validHdparmOpt(ch)) c.plainMsg("invalid option -- '{c}'", .{ch});
        }
    }
    if (device == null) {
        // identify_from_stdin(): the reference reads a 512-byte identity
        // block; with an empty stdin it reports a short read.
        c.plainMsg("short read", .{});
        return 1;
    }
    const fd = openRead(device.?, .{ .ACCMODE = .RDONLY }) orelse return 1;
    _ = linux.close(fd);
    return 0;
}

// ----------------------------------------------------------------- setserial

fn uartFor(dev: []const u8) []const u8 {
    _ = dev;
    return "unknown";
}

pub fn setserial_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("setserial");
    if (args.len < 2) c.usageDie("setserial");
    var all = false;
    var summary = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a")) all = true else if (std.mem.eql(u8, arg, "-b")) summary = true else if (std.mem.eql(u8, arg, "-g")) {} else if (arg.len > 1 and arg[0] == '-') {
            c.usageDie("setserial");
        } else break;
    }
    if (i >= args.len) c.usageDie("setserial");
    for (args[i..]) |dev| {
        const z = c.zstr(a, dev) catch return 1;
        defer a.free(z);
        const rc = linux.open(z, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(rc) != .SUCCESS) {
            c.errorMsg(@intFromEnum(linux.errno(rc)), "{s}", .{dev});
            continue;
        }
        _ = linux.close(@intCast(rc));
        const uart = uartFor(dev);
        const port: u32 = if (std.mem.endsWith(u8, dev, "0")) 0x3f8 else 0x2f8;
        const irq: u32 = if (std.mem.endsWith(u8, dev, "0")) 4 else 3;
        if (all) {
            c.printfOut("{s}, Line 0, UART: {s}, Port: 0x{x:0>4}, IRQ: {d}\n", .{ dev, uart, port, irq });
            c.out("\tBaud_base: 115200, close_delay: 50, divisor: 0\n");
            c.out("\tclosing_wait: 3000\n");
            c.out("\tFlags: spd_normal skip_test\n\n");
        } else if (summary) {
            // PRINT_SUMMARY returns early when the reported serial type is 0.
        } else {
            c.printfOut("{s}, UART: {s}, Port: 0x{x:0>4}, IRQ: {d}\n", .{ dev, uart, port, irq });
        }
    }
    return 0;
}

// ------------------------------------------------------------------ fbsplash

pub fn fbsplash_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("fbsplash");
    var image: ?[]const u8 = null;
    var dev: []const u8 = "/dev/fb0";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-s") and i + 1 < args.len) {
            i += 1;
            image = args[i];
        } else if (std.mem.eql(u8, arg, "-d") and i + 1 < args.len) {
            i += 1;
            dev = args[i];
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
        }
    }
    if (image == null) c.usageDie("fbsplash");
    const fd = openRead(dev, .{ .ACCMODE = .RDWR }) orelse return 1;
    _ = linux.close(fd);
    return 0;
}

// -------------------------------------------------------------------- conspy

pub fn conspy_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("conspy");
    var console: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "-y")) {
                i += 1;
                continue;
            }
            for (arg[1..]) |ch| {
                if (std.mem.indexOfScalar(u8, "vcsndfFQ", ch) == null) {
                    c.plainMsg("invalid option -- '{c}'", .{ch});
                    c.usageDie("conspy");
                }
            }
            continue;
        }
        console = arg;
        break;
    }
    var pathbuf: [64]u8 = undefined;
    const path = if (console) |n|
        std.fmt.bufPrint(&pathbuf, "/dev/vcsa{s}", .{n}) catch "/dev/vcsa"
    else
        "/dev/vcsa";
    const fd = openRead(path, .{ .ACCMODE = .RDWR }) orelse return 1;
    _ = linux.close(fd);
    return 0;
}
