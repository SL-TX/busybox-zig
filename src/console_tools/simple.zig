//! The console-tools applets whose reference implementation is a short
//! parse-then-ioctl sequence: chvt, clear, deallocvt, dumpkmap, fgconsole,
//! reset, resize, setconsole, setkeycodes and setlogcons.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const coreutils = @import("coreutils");
const termios = @import("libbb_zig").term.termios;

const VT_GETSTATE: u32 = 0x5603;
const VT_DISALLOCATE: u32 = 0x5608;
const KDGKBENT: u32 = 0x4B46;
const TIOCCONS: u32 = 0x541D;
const TIOCLINUX: u32 = 0x541C;
const KDSETKEYCODE: u32 = 0x4B4D;

fn avFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return c.argsFrom(std.heap.page_allocator, argv, argc) catch &.{};
}

fn singleArg(name: []const u8, av: []const []const u8) []const u8 {
    var i: usize = 1;
    if (i < av.len and std.mem.eql(u8, av[i], "--")) i += 1;
    if (i >= av.len or i + 1 < av.len) c.usageDie(name);
    return av[i];
}

// ------------------------------------------------------------------- chvt

pub fn chvtMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("chvt");
    const av = avFrom(argv, argc);
    const num = c.xatouRange(singleArg("chvt", av), 1, 63);
    const fd = c.consoleFdOrDie();
    const arg: usize = @intCast(num);
    c.xioctl(fd, 0x5606, arg, "VT_ACTIVATE");
    c.xioctl(fd, 0x5607, arg, "VT_WAITACTIVE");
    return 0;
}

// ------------------------------------------------------------------ clear

pub fn clearMain(_: c_int, _: [*][*:0]const u8) c_int {
    c.setName("clear");
    c.out("\x1b[H\x1b[J");
    return 0;
}

// --------------------------------------------------------------- deallocvt

pub fn deallocvtMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("deallocvt");
    const av = avFrom(argv, argc);
    var num: u32 = 0;
    if (av.len > 1) {
        if (av.len > 2) c.usageDie("deallocvt");
        num = c.xatouRange(av[1], 1, 63);
    }
    const fd = c.consoleFdOrDie();
    c.xioctl(fd, VT_DISALLOCATE, @intCast(num), "VT_DISALLOCATE");
    return 0;
}

// ---------------------------------------------------------------- dumpkmap

pub fn dumpkmapMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("dumpkmap");
    const av = avFrom(argv, argc);
    if (av.len > 1) c.usageDie("dumpkmap");
    const fd = c.consoleFdOrDie();

    // bkeymap header: magic + 256 one-byte "table present" flags.
    var flags: [7 + 256]u8 = @splat(0);
    const magic = "bkeymap\x01\x01\x01\x00\x01\x01\x01\x00\x01\x01\x01\x00\x01";
    @memcpy(flags[0..magic.len], magic);
    c.out(flags[0..]);

    var ke = extern struct {
        kb_table: u8,
        kb_index: u8,
        kb_value: u16,
    }{ .kb_table = 0, .kb_index = 0, .kb_value = 0 };
    for (0..13) |table| {
        if (flags[7 + table] == 0) continue;
        ke.kb_table = @intCast(table);
        for (0..128) |j| {
            ke.kb_index = @intCast(j);
            const rc = linux.ioctl(fd, KDGKBENT, @intFromPtr(&ke));
            if (linux.errno(rc) == .SUCCESS) {
                var v: [2]u8 = undefined;
                std.mem.writeInt(u16, &v, ke.kb_value, .little);
                c.out(&v);
            }
        }
    }
    _ = linux.close(fd);
    return 0;
}

// --------------------------------------------------------------- fgconsole

pub fn fgconsoleMain(_: c_int, _: [*][*:0]const u8) c_int {
    c.setName("fgconsole");
    const fd = c.consoleFdOrDie();
    var vtstat = extern struct {
        v_active: u16 = 0,
        v_signal: u16 = 0,
        v_state: u16 = 0,
    }{};
    c.xioctl(fd, VT_GETSTATE, @intFromPtr(&vtstat), "VT_GETSTATE");
    c.printfOut("{d}\n", .{vtstat.v_active});
    return 0;
}

// ------------------------------------------------------------------- reset

pub fn resetMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    c.setName("reset");
    if (!termios.isatty(1)) return 0;
    c.out("\x1bc\x1b(B\x1b[m\x1b[J\x1b[?25h");
    var args: [2][*:0]const u8 = .{ "stty", "sane" };
    return coreutils.stty_main(2, &args);
}

// ------------------------------------------------------------------ resize

/// Minimal scanf("\033[%hu;%huR") over fd 0. Returns false on EOF/mismatch.
fn scanCursor(row: *u16, col: *u16) bool {
    var state: u8 = 0; // 0: seek ESC, 1: seek '[', 2: row, 3: col
    var value: u32 = 0;
    var byte: [1]u8 = undefined;
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        const n = linux.read(0, &byte, 1);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        const ch = byte[0];
        switch (state) {
            0 => {
                if (ch == 0x1b) state = 1;
            },
            1 => {
                if (ch != '[') return false;
                state = 2;
                value = 0;
            },
            2 => {
                if (ch >= '0' and ch <= '9') {
                    value = value * 10 + (ch - '0');
                } else if (ch == ';') {
                    row.* = @truncate(value);
                    value = 0;
                    state = 3;
                } else return false;
            },
            3 => {
                if (ch >= '0' and ch <= '9') {
                    value = value * 10 + (ch - '0');
                } else if (ch == 'R') {
                    col.* = @truncate(value);
                    return true;
                } else return false;
            },
            else => unreachable,
        }
    }
    return false;
}

pub fn resizeMain(_: c_int, _: [*][*:0]const u8) c_int {
    c.setName("resize");
    const old = termios.Termios.get(2) catch termios.Termios{};
    var new = old;
    new.cflag.CLOCAL = true;
    new.cflag.CREAD = true;
    new.lflag.ICANON = false;
    new.lflag.ECHO = false;
    new.lflag.ECHOE = false;
    new.lflag.ISIG = false;
    new.set(2, termios.TCSETSF) catch {};

    c.errOut("\x1b7\x1b[r\x1b[999;999H\x1b[6n");

    var ws = termios.WindowSize{};
    _ = scanCursor(&ws.row, &ws.col);
    c.errOut("\x1b8");

    const rc = linux.ioctl(2, termios.TIOCSWINSZ, @intFromPtr(&ws));
    const ret = linux.errno(rc) == .SUCCESS;
    old.set(2, termios.TCSETS) catch {};

    c.printfOut("COLUMNS={d};LINES={d};export COLUMNS LINES;\n", .{ ws.col, ws.row });
    return if (ret) 0 else -1;
}

// -------------------------------------------------------------- setconsole

pub fn setconsoleMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("setconsole");
    const av = avFrom(argv, argc);
    const o = c.opts("setconsole", av, "^r\x00?1", &.{});
    if (o.args.len > 1) c.usageDie("setconsole");
    var device: []const u8 = "/dev/tty";
    if (o.args.len == 1) {
        device = o.args[0];
    } else if ((o.flags & 1) != 0) {
        device = "/dev/console";
    }
    const fd = c.openWrite(device);
    c.xioctl(fd, TIOCCONS, 0, "TIOCCONS");
    return 0;
}

// ------------------------------------------------------------- setkeycodes

pub fn setkeycodesMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("setkeycodes");
    if (@mod(argc, 2) == 0 or argc < 2) c.usageDie("setkeycodes");
    const fd = c.consoleFdOrDie();
    const av = avFrom(argv, argc);
    var i: usize = 1;
    while (i < av.len) : (i += 2) {
        var sc = c.parseScancode(av[i]);
        if (sc >= 0xe000) sc = sc - 0xe000 + 0x80;
        const kc = c.xatouRange(av[i + 1], 0, 255);
        const a = extern struct { scancode: u32, keycode: u32 }{
            .scancode = sc,
            .keycode = kc,
        };
        const rc = linux.ioctl(fd, KDSETKEYCODE, @intFromPtr(&a));
        if (linux.errno(rc) != .SUCCESS) {
            c.errorMsgAndDie(@intFromEnum(linux.errno(rc)), "can't set SCANCODE {x} to KEYCODE {d}", .{ sc, kc });
        }
    }
    return 0;
}

// -------------------------------------------------------------- setlogcons

pub fn setlogconsMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("setlogcons");
    const av = avFrom(argv, argc);
    var arg = extern struct { fn_code: u8, subarg: u8 }{ .fn_code = 11, .subarg = 0 };
    if (av.len > 1) arg.subarg = @intCast(c.xatouRange(av[1], 0, 63));
    var namebuf: [32]u8 = undefined;
    const devname = std.fmt.bufPrint(&namebuf, "/dev/tty{d}", .{arg.subarg}) catch unreachable;
    const fd = c.openRead(devname);
    c.xioctl(fd, TIOCLINUX, @intFromPtr(&arg), "TIOCLINUX");
    return 0;
}
