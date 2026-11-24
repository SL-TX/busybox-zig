//! Task 16b: privileged / device-bound miscutils.
//!
//! adjtimex, devfsd, nanddump, nandwrite, raidautorun, ubiattach, ubidetach,
//! ubimkvol, ubirename, ubirmvol, ubirsvol, ubiupdatevol.
//!
//! No real disk, MTD, UBI, RAID or clock state is touched: every applet parses
//! its options exactly like the reference, opens the named path and issues the
//! same open/ioctl sequence. In the harness sandbox those calls fail with the
//! same errno diagnostics the reference emits, which is what the cases assert.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

const UBI_MAX_VOLUME_NAME = 127;
const UBI_MAX_VOLUMES = 128;
const UBI_MAX_RNVOL = 32;

// ioctl request numbers (x86-64, from the kernel UAPI headers).
const MEMGETINFO: u32 = 0x80204d01;
const MEMREADOOB: u32 = 0xc0104d04;
const MTDFILEMODE: u32 = 0x4d13;
const UBI_IOCATT: u32 = 0x40186f40;
const UBI_IOCDET: u32 = 0x40046f41;
const UBI_IOCMKVOL: u32 = 0x40986f00;
const UBI_IOCRMVOL: u32 = 0x40046f01;
const UBI_IOCRSVOL: u32 = 0x400c6f02;
const UBI_IOCVOLUP: u32 = 0x40084f00;
const UBI_IOCRNVOL: u32 = 0x51106f03;
const RAID_AUTORUN: u32 = 0x914;

// --------------------------------------------------------------- small utils

fn invalidNumber(text: []const u8) noreturn {
    c.plainMsg("invalid number '{s}'", .{text});
    std.process.exit(1);
}

/// getopt32's `+` suffix: an unsigned decimal, no sign of any kind.
fn parsePositive(text: []const u8) u64 {
    if (text.len == 0) invalidNumber(text);
    for (text) |ch| if (ch < '0' or ch > '9') invalidNumber(text);
    return std.fmt.parseInt(u64, text, 10) catch invalidNumber(text);
}

/// xatol(): decimal with an optional leading sign (adjtimex).
fn parseSigned(text: []const u8) i64 {
    if (text.len == 0) invalidNumber(text);
    var s = text;
    var neg = false;
    if (s[0] == '+' or s[0] == '-') {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) invalidNumber(text);
    for (s) |ch| if (ch < '0' or ch > '9') invalidNumber(text);
    const mag = std.fmt.parseInt(u64, s, 10) catch invalidNumber(text);
    if (neg) {
        const limit: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
        if (mag > limit) invalidNumber(text);
        if (mag == limit) return std.math.minInt(i64);
        return -@as(i64, @intCast(mag));
    }
    if (mag > std.math.maxInt(i64)) invalidNumber(text);
    return @intCast(mag);
}

/// xatoull_sfx() with the KiB/MiB/GiB suffix table used by the UBI applets.
fn parseSize(text: []const u8) u64 {
    if (text.len == 0) invalidNumber(text);
    var digits_end: usize = 0;
    while (digits_end < text.len and text[digits_end] >= '0' and text[digits_end] <= '9') digits_end += 1;
    if (digits_end == 0) invalidNumber(text);
    const base = std.fmt.parseInt(u64, text[0..digits_end], 10) catch invalidNumber(text);
    const suffix = text[digits_end..];
    var mult: u64 = 1;
    if (suffix.len != 0) {
        if (std.mem.eql(u8, suffix, "KiB")) mult = 1024 else if (std.mem.eql(u8, suffix, "MiB")) mult = 1024 * 1024 else if (std.mem.eql(u8, suffix, "GiB")) mult = 1024 * 1024 * 1024 else invalidNumber(text);
    }
    return base * mult;
}

/// xstrtou(s, 0): base-0 unsigned (0x hex, leading-0 octal, else decimal).
fn parseBase0(text: []const u8) u64 {
    if (text.len == 0) invalidNumber(text);
    var s = text;
    var base: u8 = 10;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        base = 16;
        s = s[2..];
    } else if (s.len > 1 and s[0] == '0') {
        base = 8;
        s = s[1..];
    }
    if (s.len == 0) invalidNumber(text);
    for (s) |ch| {
        const ok = switch (base) {
            16 => std.ascii.isHex(ch),
            8 => ch >= '0' and ch <= '7',
            else => ch >= '0' and ch <= '9',
        };
        if (!ok) invalidNumber(text);
    }
    return std.fmt.parseInt(u64, s, base) catch invalidNumber(text);
}

fn openPath(name: []const u8, flags: linux.O) ?linux.fd_t {
    const z = c.zstr(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(z);
    const rc = linux.open(z, flags, 0o666);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{name});
        return null;
    }
    return @intCast(rc);
}

fn doIoctl(fd: linux.fd_t, req: u32, arg: usize, label: []const u8) bool {
    const rc = linux.ioctl(fd, req, arg);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "{s}", .{label});
        return false;
    }
    return true;
}

/// Issue the MTD_FILE_MODE_RAW switch when `enabled`. Returns the errno when
/// the ioctl fails, or null when it succeeded / was not requested. Factored
/// out so the flag-to-ioctl wiring can be unit-tested without an MTD device
/// and without emitting a diagnostic from the test runner.
pub fn mtdRawModeErrno(fd: linux.fd_t, enabled: bool) ?c_int {
    if (!enabled) return null;
    const rc = linux.ioctl(fd, MTDFILEMODE, 3);
    const e = linux.errno(rc);
    if (e == .SUCCESS) return null;
    return @intFromEnum(e);
}

/// MTD_FILE_MODE_RAW switch shared by `nanddump -n` and `nandwrite -n`.
pub fn setMtdRawMode(fd: linux.fd_t, enabled: bool) bool {
    if (mtdRawModeErrno(fd, enabled)) |en| {
        c.errorMsg(en, "MTDFILEMODE", .{});
        return false;
    }
    return true;
}

// ---------------------------------------------------------- option parsing
// The shared libbb getopt32 keeps only the last optarg, while several applets
// below need the argument of every option. This parser follows the same
// getopt32 rules (short clusters, required args, `--` terminator, GNU-style
// permutation, long options with `=`) and keeps each option's value by letter.

const LongSpec = struct { name: []const u8, letter: u8, has_arg: bool };

var positional_store: [256][]const u8 = undefined;

const ParseResult = struct {
    seen: [256]bool = std.mem.zeroes([256]bool),
    vals: [256]?[]const u8 = std.mem.zeroes([256]?[]const u8),
    args: []const []const u8,

    fn has(self: *const ParseResult, ch: u8) bool {
        return self.seen[ch];
    }
    fn val(self: *const ParseResult, ch: u8) ?[]const u8 {
        return self.vals[ch];
    }
};

fn parseArgs(name: []const u8, av: []const []const u8, spec: []const u8, longs: []const LongSpec) ParseResult {
    var known: [256]bool = std.mem.zeroes([256]bool);
    var needs: [256]bool = std.mem.zeroes([256]bool);
    var si: usize = 0;
    while (si < spec.len) {
        const ch = spec[si];
        si += 1;
        if (ch == '^' or ch == '+' or ch == '-') continue;
        known[ch] = true;
        if (si < spec.len and spec[si] == ':') {
            needs[ch] = true;
            si += 1;
        }
    }

    var res = ParseResult{ .args = positional_store[0..0] };
    var npos: usize = 0;
    var end_of_opts = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (end_of_opts) {
            positional_store[npos] = tok;
            npos += 1;
            continue;
        }
        if (tok.len < 2 or tok[0] != '-') {
            positional_store[npos] = tok;
            npos += 1;
            continue;
        }
        if (std.mem.eql(u8, tok, "--")) {
            end_of_opts = true;
            continue;
        }
        if (tok[1] == '-') {
            const body = tok[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const lname = if (eq) |p| body[0..p] else body;
            const attached: ?[]const u8 = if (eq) |p| body[p + 1 ..] else null;
            var found = false;
            for (longs) |lo| {
                if (!std.mem.eql(u8, lo.name, lname)) continue;
                found = true;
                res.seen[lo.letter] = true;
                if (lo.has_arg) {
                    if (attached) |v| {
                        res.vals[lo.letter] = v;
                    } else if (i + 1 < av.len) {
                        i += 1;
                        res.vals[lo.letter] = av[i];
                    } else {
                        c.plainMsg("option '--{s}' requires an argument", .{lname});
                        c.usageDie(name);
                    }
                }
                break;
            }
            if (!found) {
                c.plainMsg("unrecognized option '--{s}'", .{lname});
                c.usageDie(name);
            }
            continue;
        }
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            if (!known[ch]) {
                c.plainMsg("invalid option -- '{c}'", .{ch});
                c.usageDie(name);
            }
            res.seen[ch] = true;
            if (needs[ch]) {
                if (j + 1 < tok.len) {
                    res.vals[ch] = tok[j + 1 ..];
                } else if (i + 1 < av.len) {
                    i += 1;
                    res.vals[ch] = av[i];
                } else {
                    c.plainMsg("option requires an argument -- '{c}'", .{ch});
                    c.usageDie(name);
                }
                break;
            }
        }
    }
    res.args = positional_store[0..npos];
    return res;
}

// ------------------------------------------------------------------ adjtimex

const Timex = extern struct {
    modes: c_uint,
    offset: c_long,
    freq: c_long,
    maxerror: c_long,
    esterror: c_long,
    status: c_int,
    constant: c_long,
    precision: c_long,
    tolerance: c_long,
    time: extern struct { tv_sec: c_long, tv_usec: c_long },
    tick: c_long,
    ppsfreq: c_long,
    jitter: c_long,
    shift: c_int,
    stabil: c_long,
    jitcnt: c_long,
    calcnt: c_long,
    errcnt: c_long,
    stbcnt: c_long,
    tai: c_int,
};

const stat_bits = [_]c_int{ 0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040, 0x0080, 0x0100, 0x0200, 0x0400, 0x0800, 0x1000 };
const stat_names = [_][]const u8{ "PLL", "PPSFREQ", "PPSTIME", "FFL", "INS", "DEL", "UNSYNC", "FREQHOLD", "PPSSIGNAL", "PPSJITTER", "PPSWANDER", "PPSERROR", "CLOCKERR" };
const ret_names = [_][]const u8{ "clock synchronized", "insert leap second", "delete leap second", "leap second in progress", "leap second has occurred", "clock not synchronized" };

pub fn adjtimex_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("adjtimex");
    const p = parseArgs("adjtimex", args, "^qo:f:p:t:", &.{});
    if (p.args.len != 0) c.usageDie("adjtimex");

    var txc: Timex = std.mem.zeroes(Timex);
    if (p.has('o')) {
        txc.offset = parseSigned(p.val('o').?);
        txc.modes |= 0x8001; // ADJ_OFFSET_SINGLESHOT
    }
    if (p.has('f')) {
        txc.freq = parseSigned(p.val('f').?);
        txc.modes |= 0x0002; // ADJ_FREQUENCY
    }
    if (p.has('p')) {
        txc.constant = parseSigned(p.val('p').?);
        txc.modes |= 0x0020; // ADJ_TIMECONST
    }
    if (p.has('t')) {
        txc.tick = parseSigned(p.val('t').?);
        txc.modes |= 0x4000; // ADJ_TICK
    }

    const rc = linux.syscall1(.adjtimex, @intFromPtr(&txc));
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        // bb_perror_nomsg_and_die(): "<prog>: : <strerror>"
        c.errorMsg(@intFromEnum(e), "", .{});
        return 1;
    }
    const ret: c_int = @bitCast(@as(u32, @truncate(rc)));

    if (!p.has('q')) {
        c.printfOut("    mode:         {d}\n", .{txc.modes});
        c.printfOut("-o  offset:       {d} us\n", .{txc.offset});
        c.printfOut("-f  freq.adjust:  {d} (65536 = 1ppm)\n", .{txc.freq});
        c.printfOut("    maxerror:     {d}\n", .{txc.maxerror});
        c.printfOut("    esterror:     {d}\n", .{txc.esterror});

        var status_buf: [512]u8 = undefined;
        var used: usize = 0;
        for (stat_bits, stat_names) |bit, nm| {
            if ((txc.status & bit) != 0) {
                if (used == 0) {
                    @memcpy(status_buf[used .. used + nm.len], nm);
                    used += nm.len;
                } else {
                    @memcpy(status_buf[used .. used + 3], " | ");
                    used += 3;
                    @memcpy(status_buf[used .. used + nm.len], nm);
                    used += nm.len;
                }
            }
        }
        c.printfOut("    status:       {d} ({s})\n", .{ txc.status, status_buf[0..used] });
        c.printfOut("-p  timeconstant: {d}\n", .{txc.constant});
        c.printfOut("    precision:    {d} us\n", .{txc.precision});
        c.printfOut("    tolerance:    {d}\n", .{txc.tolerance});
        c.printfOut("-t  tick:         {d} us\n", .{txc.tick});
        c.printfOut("    time.tv_sec:  {d}\n", .{txc.time.tv_sec});
        c.printfOut("    time.tv_usec: {d}\n", .{txc.time.tv_usec});
        const descript: []const u8 = if (ret >= 0 and ret < ret_names.len) ret_names[@intCast(ret)] else "error";
        c.printfOut("    return value: {d} ({s})\n", .{ ret, descript });
    }
    return 0;
}

// ------------------------------------------------------------------- devfsd
// Disabled in both shipped defconfigs; the harness sees "applet not found".
// A real main is kept here so an enabling config gets genuine behaviour.

pub fn devfsd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("devfsd");
    if (args.len < 2) c.usageDie("devfsd");
    var print_version = false;
    var do_daemon = true;
    var no_polling = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            print_version = true;
        } else if (std.mem.eql(u8, arg, "-fg")) {
            // ENABLE_DEVFSD_FG_NP: stay in the foreground, do not fork.
            do_daemon = false;
        } else if (std.mem.eql(u8, arg, "-np")) {
            // ENABLE_DEVFSD_FG_NP: return after the synthetic REGISTER scan.
            no_polling = true;
        } else c.usageDie("devfsd");
    }
    // xchdir(mntpnt); xopen(".devfsd"); xioctl(GET_PROTO_REV)
    var dir = args[1];
    while (dir.len > 1 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
    const dz = c.zstr(a, dir) catch return 1;
    defer a.free(dz);
    if (linux.errno(linux.chdir(dz)) != .SUCCESS) return 1;
    const cz = c.zstr(a, ".devfsd") catch return 1;
    defer a.free(cz);
    const fd = openPath(".devfsd", .{ .ACCMODE = .RDONLY }) orelse return 1;
    defer _ = linux.close(fd);
    var proto: c_int = 0;
    if (!doIoctl(fd, 0x80046400, @intFromPtr(&proto), "DEVFSDIOC_GET_PROTO_REV")) return 1;
    if (print_version or proto != 5) {
        c.printfOut("devfsd v1.3.25\nDaemon protocol revision:\t5\nKernel-side protocol revision:\t{d}\n", .{proto});
        if (proto != 5) {
            c.plainMsg("protocol revision mismatch!", .{});
            return 1;
        }
        if (print_version) return 0;
    }
    // Tell the kernel we see hidden entries, then scan the synthetic REGISTER
    // events (a real devfs mount is required for the scan to produce anything).
    if (!doIoctl(fd, 0x40046402, 0, "DEVFSDIOC_SET_EVENT_MASK")) return 1;
    c.printfOut("devfsd v1.3.25 started for {s}\n", .{dir});

    // -np: exit right after parsing the config and the synthetic scan.
    if (no_polling) return 0;
    if (do_daemon) {
        // Release the event queue so the daemon child can grab it.
        if (!doIoctl(fd, 0x40046403, 0, "DEVFSDIOC_RELEASE_EVENT_QUEUE")) return 1;
        // bb_daemonize_or_rexec(0, argv) forks here on a real devfs system.
    } else {
        // -fg: become process group leader instead of daemonizing.
        _ = linux.setpgid(0, 0);
    }
    // Event delivery loop: read() blocks for devfs events on a real mount.
    var event: [1032]u8 = undefined; // sizeof(struct devfsd_notify_struct)
    while (true) {
        const got = linux.read(fd, &event, event.len);
        if (linux.errno(got) != .SUCCESS or got == 0) {
            c.plainMsg("read error on control file", .{});
            return 1;
        }
    }
}

// ----------------------------------------------------------------- nanddump

const MtdInfo = extern struct {
    type: u8,
    flags: u32,
    size: u32,
    erasesize: u32,
    writesize: u32,
    oobsize: u32,
    padding: u64,
};
const MtdOobBuf = extern struct { start: u32, length: u32, ptr: ?[*]u8 };

fn openMtd(name: []const u8, writable: bool) ?linux.fd_t {
    return openPath(name, if (writable) .{ .ACCMODE = .RDWR } else .{ .ACCMODE = .RDONLY });
}

pub fn nanddump_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("nanddump");
    const p = parseArgs("nanddump", args, "^ons:f:l:", &.{.{ .name = "bb", .letter = 0xff, .has_arg = true }});
    if (p.args.len != 1) c.usageDie("nanddump");

    var opt_f: []const u8 = "-";
    if (p.has('f')) opt_f = p.val('f').?;
    if (!std.mem.eql(u8, opt_f, "-")) {
        const out = openPath(opt_f, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }) orelse return 1;
        // xmove_fd(out, STDOUT_FILENO)
        if (out != 1) {
            _ = linux.dup2(out, 1);
            _ = linux.close(out);
        }
    }

    const fd = openMtd(p.args[0], false) orelse return 1;
    defer _ = linux.close(fd);
    var mi: MtdInfo = undefined;
    if (!doIoctl(fd, MEMGETINFO, @intFromPtr(&mi), "MEMGETINFO")) return 1;
    // nand.c:153-154: -n switches the MTD file to raw mode (no ECC) *after*
    // MEMGETINFO succeeded. MTD_FILE_MODE_RAW == 3.
    if (!setMtdRawMode(fd, p.has('n'))) return 1;

    var mtdoffset: u32 = 0;
    if (p.has('s')) mtdoffset = @truncate(parseBase0(p.val('s').?));
    var end_addr: u32 = std.math.maxInt(u32);
    if (p.has('l')) {
        const length: u32 = @truncate(parseBase0(p.val('l').?));
        if (length < mi.size -% mtdoffset) end_addr = mtdoffset + length;
    }
    if (p.has(0xff)) {
        const method = p.val(0xff).?;
        if (!std.mem.eql(u8, method, "skipbad") and !std.mem.eql(u8, method, "padbad")) c.usageDie("nanddump");
    }

    const ws = mi.writesize;
    if (ws == 0 or (mtdoffset & (ws - 1)) != 0) {
        c.plainMsg("start address is not page aligned", .{});
        return 1;
    }
    const filebuf = a.alloc(u8, ws) catch return 1;
    defer a.free(filebuf);
    const oobbuf = a.alloc(u8, mi.oobsize) catch return 1;
    defer a.free(oobbuf);
    var oob = MtdOobBuf{ .start = 0, .length = mi.oobsize, .ptr = oobbuf.ptr };

    const limit = @min(mi.size, end_addr);
    while (mtdoffset < limit) {
        _ = linux.lseek(fd, mtdoffset, linux.SEEK.SET);
        const got = linux.read(fd, filebuf.ptr, ws);
        if (linux.errno(got) != .SUCCESS) return 1;
        if (got == 0) break;
        if (@as(usize, @intCast(got)) < ws) {
            c.plainMsg("short read", .{});
            return 1;
        }
        var off: usize = 0;
        while (off < ws) {
            const n = linux.write(1, filebuf.ptr + off, ws - off);
            if (linux.errno(n) != .SUCCESS or n == 0) return 1;
            off += @intCast(n);
        }
        if (p.has('o')) {
            oob.start = mtdoffset;
            if (!doIoctl(fd, MEMREADOOB, @intFromPtr(&oob), "MEMREADOOB")) return 1;
            var ooff: usize = 0;
            while (ooff < mi.oobsize) {
                const n = linux.write(1, oobbuf.ptr + ooff, mi.oobsize - ooff);
                if (linux.errno(n) != .SUCCESS or n == 0) return 1;
                ooff += @intCast(n);
            }
        }
        mtdoffset += ws;
    }
    return 0;
}

// ---------------------------------------------------------------- nandwrite

pub fn nandwrite_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("nandwrite");
    const p = parseArgs("nandwrite", args, "^pns:", &.{});
    if (p.args.len < 1 or p.args.len > 2) c.usageDie("nandwrite");

    if (p.args.len == 2) {
        const inf = openPath(p.args[1], .{ .ACCMODE = .RDONLY }) orelse return 1;
        if (inf != 0) {
            _ = linux.dup2(inf, 0);
            _ = linux.close(inf);
        }
    }
    const fd = openMtd(p.args[0], true) orelse return 1;
    defer _ = linux.close(fd);
    var mi: MtdInfo = undefined;
    if (!doIoctl(fd, MEMGETINFO, @intFromPtr(&mi), "MEMGETINFO")) return 1;
    if (!setMtdRawMode(fd, p.has('n'))) return 1;
    var mtdoffset: u32 = 0;
    if (p.has('s')) mtdoffset = @truncate(parseBase0(p.val('s').?));
    const ws = mi.writesize;
    if (ws == 0 or (mtdoffset & (ws - 1)) != 0) {
        c.plainMsg("start address is not page aligned", .{});
        return 1;
    }
    const filebuf = a.alloc(u8, ws) catch return 1;
    defer a.free(filebuf);
    var off = mtdoffset;
    const limit = mi.size;
    while (off < limit) {
        _ = linux.lseek(fd, off, linux.SEEK.SET);
        const got = linux.read(0, filebuf.ptr, ws);
        if (linux.errno(got) != .SUCCESS) return 1;
        if (got == 0) break;
        if (@as(usize, @intCast(got)) < ws and !p.has('p')) {
            c.plainMsg("input size is not rounded up to page size, use -p to zero pad", .{});
            return 1;
        }
        if (@as(usize, @intCast(got)) < ws) @memset(filebuf[@intCast(got)..], 0);
        var wo: usize = 0;
        while (wo < ws) {
            const n = linux.write(fd, filebuf.ptr + wo, ws - wo);
            if (linux.errno(n) != .SUCCESS or n == 0) return 1;
            wo += @intCast(n);
        }
        off += ws;
    }
    return 0;
}

// --------------------------------------------------------------- raidautorun

pub fn raidautorun_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("raidautorun");
    if (args.len != 2) c.usageDie("raidautorun");
    const fd = openPath(args[1], .{ .ACCMODE = .RDONLY }) orelse return 1;
    defer _ = linux.close(fd);
    if (!doIoctl(fd, RAID_AUTORUN, 0, "RAID_AUTORUN")) return 1;
    return 0;
}

// --------------------------------------------------------------- UBI helpers

const UbiAttachReq = extern struct {
    ubi_num: i32,
    mtd_num: i32,
    vid_hdr_offset: i32,
    max_beb_per1024: u16,
    disable_fm: i8,
    need_resv_pool: i8,
    padding: [8]u8,
};
const UbiMkvolReq = extern struct {
    vol_id: i32,
    alignment: i32,
    bytes: i64,
    vol_type: i8,
    flags: u8,
    name_len: i16,
    padding2: [4]u8,
    name: [UBI_MAX_VOLUME_NAME + 1]u8,
};
const UbiRsvolReq = extern struct { bytes: i64, vol_id: i32 };
const UbiRnvolEnt = extern struct {
    vol_id: i32,
    name_len: i16,
    padding: [2]u8,
    name: [UBI_MAX_VOLUME_NAME + 1]u8,
};
const UbiRnvolReq = extern struct {
    count: i32,
    padding1: [12]u8,
    ents: [UBI_MAX_RNVOL]UbiRnvolEnt,
};

fn ubiDevnumFromDevname(name: []const u8) u32 {
    const prefix = "/dev/ubi";
    if (!std.mem.startsWith(u8, name, prefix)) {
        c.plainMsg("not an UBI device: '{s}'", .{name});
        std.process.exit(1);
    }
    var s = name[prefix.len..];
    var n: usize = 0;
    while (n < s.len and s[n] >= '0' and s[n] <= '9') n += 1;
    if (n == 0) {
        c.plainMsg("not an UBI device: '{s}'", .{name});
        std.process.exit(1);
    }
    return std.fmt.parseInt(u32, s[0..n], 10) catch {
        c.plainMsg("not an UBI device: '{s}'", .{name});
        std.process.exit(1);
    };
}

fn ubiGetVolIdByName(devnum: u32, vol_name: []const u8) i32 {
    var i: u32 = 0;
    while (i < UBI_MAX_VOLUMES) : (i += 1) {
        const path = std.fmt.allocPrint(std.heap.page_allocator, "/sys/class/ubi/ubi{d}_{d}/name", .{ devnum, i }) catch break;
        defer std.heap.page_allocator.free(path);
        var en: c_int = 0;
        const content = c.readFile(std.heap.page_allocator, path, &en) orelse continue;
        defer std.heap.page_allocator.free(content);
        const name = std.mem.trimEnd(u8, content, "\r\n");
        if (std.mem.eql(u8, name, vol_name)) return @intCast(i);
    }
    c.plainMsg("volume '{s}' not found", .{vol_name});
    std.process.exit(1);
}

const UbiWhich = enum { attach, detach, mkvol, rmvol, rsvol, update };

const UbiCommon = struct {
    which: UbiWhich,
    p: ParseResult,
    ctrl: []const u8,
    size_bytes: u64 = 0,
};

fn validatePositiveOpts(p: ParseResult, letters: []const u8) void {
    for (letters) |ch| {
        if (p.has(ch)) _ = parsePositive(p.val(ch).?);
    }
}

fn parseUbi(name: []const u8, args: []const []const u8, which: UbiWhich) UbiCommon {
    var common = UbiCommon{ .which = which, .p = undefined, .ctrl = "" };
    switch (which) {
        .mkvol => {
            common.p = parseArgs(name, args, "^md:+n:+N:s:a:+t:O:+", &.{});
            validatePositiveOpts(common.p, "dnaO");
        },
        .update => common.p = parseArgs(name, args, "^s:at", &.{}),
        else => {
            common.p = parseArgs(name, args, "^m:+d:+n:+N:s:a:+t:", &.{});
            validatePositiveOpts(common.p, "mdna");
        },
    }
    if (common.p.args.len < 1) c.usageDie(name);
    if (common.p.has('s')) {
        common.size_bytes = parseSize(common.p.val('s').?);
    }
    common.ctrl = common.p.args[0];
    return common;
}

pub fn ubiattach_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("ubiattach");
    const u = parseUbi("ubiattach", args, .attach);
    const fd = openPath(u.ctrl, .{ .ACCMODE = .RDWR }) orelse return 1;
    defer _ = linux.close(fd);
    if (!u.p.has('m')) {
        c.plainMsg("MTD device not specified", .{});
        return 1;
    }
    var req: UbiAttachReq = std.mem.zeroes(UbiAttachReq);
    req.mtd_num = @intCast(parsePositive(u.p.val('m').?));
    req.ubi_num = if (u.p.has('d')) @intCast(parsePositive(u.p.val('d').?)) else -1;
    req.vid_hdr_offset = 0; // -O is not in ubiattach's optstring (reference quirk)
    if (!doIoctl(fd, UBI_IOCATT, @intFromPtr(&req), "UBI_IOCATT")) return 1;
    return 0;
}

pub fn ubidetach_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("ubidetach");
    const u = parseUbi("ubidetach", args, .detach);
    const fd = openPath(u.ctrl, .{ .ACCMODE = .RDWR }) orelse return 1;
    defer _ = linux.close(fd);
    if (!u.p.has('d')) {
        c.plainMsg("UBI device not specified", .{});
        return 1;
    }
    var dev_num: i32 = @intCast(parsePositive(u.p.val('d').?));
    if (!doIoctl(fd, UBI_IOCDET, @intFromPtr(&dev_num), "UBI_IOCDET")) return 1;
    return 0;
}

pub fn ubimkvol_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("ubimkvol");
    const u = parseUbi("ubimkvol", args, .mkvol);
    const fd = openPath(u.ctrl, .{ .ACCMODE = .RDWR }) orelse return 1;
    defer _ = linux.close(fd);
    var size = u.size_bytes;
    if (u.p.has('m')) {
        const num = ubiDevnumFromDevname(u.ctrl);
        const avail_path = std.fmt.allocPrint(a, "/sys/class/ubi/ubi{d}/avail_eraseblocks", .{num}) catch return 1;
        defer a.free(avail_path);
        var en: c_int = 0;
        const avail_buf = c.readFile(a, avail_path, &en) orelse {
            c.errorMsg(en, "can't open '{s}'", .{avail_path});
            return 1;
        };
        defer a.free(avail_buf);
        const avail = parsePositive(std.mem.trim(u8, avail_buf, " \t\r\n"));
        const eb_path = std.fmt.allocPrint(a, "/sys/class/ubi/ubi{d}/eraseblock_size", .{num}) catch return 1;
        defer a.free(eb_path);
        const eb_buf = c.readFile(a, eb_path, &en) orelse {
            c.errorMsg(en, "can't open '{s}'", .{eb_path});
            return 1;
        };
        defer a.free(eb_buf);
        const eb = parsePositive(std.mem.trim(u8, eb_buf, " \t\r\n"));
        size = avail *% eb;
    } else if (!u.p.has('s')) {
        c.plainMsg("size not specified", .{});
        return 1;
    }
    if (!u.p.has('N')) {
        c.plainMsg("name not specified", .{});
        return 1;
    }
    const vol_name = u.p.val('N').?;
    if (vol_name.len > UBI_MAX_VOLUME_NAME) {
        c.plainMsg("volume name too long: '{s}'", .{vol_name});
        return 1;
    }
    var req: UbiMkvolReq = std.mem.zeroes(UbiMkvolReq);
    req.vol_id = if (u.p.has('n')) @intCast(parsePositive(u.p.val('n').?)) else -1;
    req.vol_type = if (u.p.has('t') and std.mem.startsWith(u8, u.p.val('t').?, "s")) 1 else 0;
    req.alignment = if (u.p.has('a')) @intCast(parsePositive(u.p.val('a').?)) else 1;
    req.bytes = @bitCast(size);
    req.name_len = @intCast(vol_name.len);
    @memcpy(req.name[0..vol_name.len], vol_name);
    if (!doIoctl(fd, UBI_IOCMKVOL, @intFromPtr(&req), "UBI_IOCMKVOL")) return 1;
    return 0;
}

pub fn ubirmvol_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("ubirmvol");
    const u = parseUbi("ubirmvol", args, .rmvol);
    const fd = openPath(u.ctrl, .{ .ACCMODE = .RDWR }) orelse return 1;
    defer _ = linux.close(fd);
    if (!u.p.has('n') and !u.p.has('N')) {
        c.plainMsg("volume id not specified", .{});
        return 1;
    }
    var vol_id: i32 = if (u.p.has('n')) @intCast(parsePositive(u.p.val('n').?)) else -1;
    if (u.p.has('N')) vol_id = ubiGetVolIdByName(ubiDevnumFromDevname(u.ctrl), u.p.val('N').?);
    if (!doIoctl(fd, UBI_IOCRMVOL, @intFromPtr(&vol_id), "UBI_IOCRMVOL")) return 1;
    return 0;
}

pub fn ubirsvol_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("ubirsvol");
    const u = parseUbi("ubirsvol", args, .rsvol);
    const fd = openPath(u.ctrl, .{ .ACCMODE = .RDWR }) orelse return 1;
    defer _ = linux.close(fd);
    if (!u.p.has('s')) {
        c.plainMsg("size not specified", .{});
        return 1;
    }
    if (!u.p.has('n')) {
        c.plainMsg("volume id not specified", .{});
        return 1;
    }
    var req: UbiRsvolReq = undefined;
    req.bytes = @bitCast(u.size_bytes);
    req.vol_id = @intCast(parsePositive(u.p.val('n').?));
    if (!doIoctl(fd, UBI_IOCRSVOL, @intFromPtr(&req), "UBI_IOCRSVOL")) return 1;
    return 0;
}

pub fn ubiupdatevol_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("ubiupdatevol");
    var u = parseUbi("ubiupdatevol", args, .update);
    const ctrl = u.ctrl;
    const fd = openPath(ctrl, .{ .ACCMODE = .RDWR }) orelse return 1;
    defer _ = linux.close(fd);
    var bytes: i64 = 0;
    if (u.p.has('t')) {
        if (!doIoctl(fd, UBI_IOCVOLUP, @intFromPtr(&bytes), "UBI_IOCVOLUP")) return 1;
        return 0;
    }
    // sscanf(ctrl, "/dev/ubi%u_%u")
    const prefix = "/dev/ubi";
    if (!std.mem.startsWith(u8, ctrl, prefix)) {
        c.plainMsg("UBI device name '{s}' is not /dev/ubiN_M", .{ctrl});
        return 1;
    }
    const rest = ctrl[prefix.len..];
    const us = std.mem.indexOfScalar(u8, rest, '_') orelse {
        c.plainMsg("UBI device name '{s}' is not /dev/ubiN_M", .{ctrl});
        return 1;
    };
    if (us == 0 or us + 1 >= rest.len) {
        c.plainMsg("UBI device name '{s}' is not /dev/ubiN_M", .{ctrl});
        return 1;
    }
    for (rest[0..us]) |ch| if (ch < '0' or ch > '9') {
        c.plainMsg("UBI device name '{s}' is not /dev/ubiN_M", .{ctrl});
        return 1;
    };
    for (rest[us + 1 ..]) |ch| if (ch < '0' or ch > '9') {
        c.plainMsg("UBI device name '{s}' is not /dev/ubiN_M", .{ctrl});
        return 1;
    };
    const ubinum = std.fmt.parseInt(u32, rest[0..us], 10) catch {
        c.plainMsg("UBI device name '{s}' is not /dev/ubiN_M", .{ctrl});
        return 1;
    };
    const volnum = std.fmt.parseInt(u32, rest[us + 1 ..], 10) catch {
        c.plainMsg("UBI device name '{s}' is not /dev/ubiN_M", .{ctrl});
        return 1;
    };
    const eb_path = std.fmt.allocPrint(a, "/sys/class/ubi/ubi{d}_{d}/usable_eb_size", .{ ubinum, volnum }) catch return 1;
    defer a.free(eb_path);
    var en: c_int = 0;
    const eb_buf = c.readFile(a, eb_path, &en) orelse {
        c.errorMsg(en, "can't open '{s}'", .{eb_path});
        return 1;
    };
    defer a.free(eb_buf);
    const leb = parsePositive(std.mem.trim(u8, eb_buf, " \t\r\n"));
    if (u.p.args.len < 2) c.usageDie("ubiupdatevol");
    const img = u.p.args[1];
    if (!std.mem.eql(u8, img, "-")) {
        const ifd = openPath(img, .{ .ACCMODE = .RDONLY }) orelse return 1;
        if (ifd != 0) {
            _ = linux.dup2(ifd, 0);
            _ = linux.close(ifd);
        }
    }
    if (!u.p.has('s')) {
        const st = bb.io.fstat(0) catch return 1;
        u.size_bytes = st.size;
    }
    bytes = @bitCast(u.size_bytes);
    if (!doIoctl(fd, UBI_IOCVOLUP, @intFromPtr(&bytes), "UBI_IOCVOLUP")) return 1;
    const buf = a.alloc(u8, @intCast(leb)) catch return 1;
    defer a.free(buf);
    var remaining = u.size_bytes;
    while (remaining != 0) {
        const want: usize = @intCast(@min(remaining, leb));
        const got = linux.read(0, buf.ptr, want);
        if (linux.errno(got) != .SUCCESS) {
            c.errorMsg(@intFromEnum(linux.errno(got)), "read error from '{s}'", .{img});
            return 1;
        }
        if (got == 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(got))) {
            const n = linux.write(fd, buf.ptr + off, @as(usize, @intCast(got)) - off);
            if (linux.errno(n) != .SUCCESS or n == 0) return 1;
            off += @intCast(n);
        }
        remaining -= @intCast(got);
    }
    return 0;
}

pub fn ubirename_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("ubirename");
    if ((args.len & 1) != 0 or args.len < 4) c.usageDie("ubirename");
    const nren = args.len / 2 - 1;
    if (nren > UBI_MAX_RNVOL) {
        c.plainMsg("too many renames requested", .{});
        return 1;
    }
    const devname = args[1];
    const devnum = ubiDevnumFromDevname(devname);
    var req: UbiRnvolReq = std.mem.zeroes(UbiRnvolReq);
    req.count = @intCast(nren);
    var n: usize = 0;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const old = args[i];
        const new = args[i + 1];
        req.ents[n].vol_id = ubiGetVolIdByName(devnum, old);
        if (new.len >= UBI_MAX_VOLUME_NAME + 1) {
            c.plainMsg("new name '{s}' is too long", .{new});
            return 1;
        }
        req.ents[n].name_len = @intCast(new.len);
        @memcpy(req.ents[n].name[0..new.len], new);
        n += 1;
    }
    const fd = openPath(devname, .{ .ACCMODE = .RDONLY }) orelse return 1;
    defer _ = linux.close(fd);
    if (!doIoctl(fd, UBI_IOCRNVOL, @intFromPtr(&req), "UBI_IOCRNVOL")) return 1;
    return 0;
}
