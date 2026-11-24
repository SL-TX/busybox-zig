//! Keyboard-mode applets: kbd_mode, loadkmap and showkey.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");
const termios = bb.term.termios;

const KDGKBMODE: u32 = 0x4B44;
const KDSKBMODE: u32 = 0x4B45;
const KDSKBENT: u32 = 0x4B47;

const K_RAW: c_int = 0;
const K_XLATE: c_int = 1;
const K_MEDIUMRAW: c_int = 2;
const K_UNICODE: c_int = 3;

fn avFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return c.argsFrom(std.heap.page_allocator, argv, argc) catch &.{};
}

// ---------------------------------------------------------------- kbd_mode

pub fn kbdModeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("kbd_mode");
    const av = avFrom(argv, argc);
    const o = c.opts("kbd_mode", av, "sakuC:", &.{});
    // Bits: s=1, a=2, k=4, u=8, C=16 (as in the reference opt constants).
    const tty_name: ?[]const u8 = if ((o.flags & 16) != 0) blk: {
        for (av, 0..) |a, i| {
            if (std.mem.eql(u8, a, "-C") and i + 1 < av.len) break :blk av[i + 1];
            if (a.len > 2 and std.mem.startsWith(u8, a, "-C")) break :blk a[2..];
        }
        break :blk null;
    } else null;

    const fd = if (tty_name) |name| c.openReadNonblock(name) else c.consoleFdOrDie();
    const mode_bits = o.flags & 0xf;
    if (mode_bits == 0) {
        var m: c_int = 0;
        c.xioctl(fd, KDGKBMODE, @intFromPtr(&m), "KDGKBMODE");
        const mode: []const u8 = if (m == K_RAW)
            "raw (scancode)"
        else if (m == K_XLATE)
            "default (ASCII)"
        else if (m == K_MEDIUMRAW)
            "mediumraw (keycode)"
        else if (m == K_UNICODE)
            "Unicode (UTF-8)"
        else if (m == 4)
            "off"
        else
            "unknown";
        c.printfOut("The keyboard is in {s} mode\n", .{mode});
    } else {
        // opt = opt & UNICODE ? 3 : opt >> 1;
        const request: usize = if ((mode_bits & 8) != 0) 3 else @as(usize, mode_bits >> 1);
        c.xioctl(fd, KDSKBMODE, request, "KDSKBMODE");
    }
    _ = linux.close(fd);
    return 0;
}

// ---------------------------------------------------------------- loadkmap

pub fn loadkmapMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("loadkmap");
    const av = avFrom(argv, argc);
    if (av.len > 1) c.usageDie("loadkmap");
    const fd = c.consoleFdOrDie();

    var magic: [7]u8 = undefined;
    var got: usize = 0;
    while (got < magic.len) {
        const n = linux.read(0, magic[got..].ptr, magic.len - got);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        got += @intCast(n);
    }
    if (!std.mem.startsWith(u8, &magic, "bkeymap")) c.plainDie("not a valid binary keymap", .{});

    var flags: [256]u8 = undefined;
    got = 0;
    while (got < flags.len) {
        const n = linux.read(0, flags[got..].ptr, flags.len - got);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        got += @intCast(n);
    }

    var ibuff: [128]u16 = undefined;
    for (flags, 0..) |present, table| {
        if (present != 1) continue;
        got = 0;
        while (got < ibuff.len * 2) {
            const n = linux.read(0, @as([*]u8, @ptrCast(&ibuff))[got..], ibuff.len * 2 - got);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            got += @intCast(n);
        }
        for (ibuff, 0..) |value, idx| {
            const ke = extern struct {
                kb_table: u8,
                kb_index: u8,
                kb_value: u16,
            }{
                .kb_table = @intCast(table),
                .kb_index = @intCast(idx),
                .kb_value = value,
            };
            _ = linux.ioctl(fd, KDSKBENT, @intFromPtr(&ke));
        }
    }
    _ = linux.close(fd);
    return 0;
}

// ----------------------------------------------------------------- showkey

fn setTermios(fd: linux.fd_t, t: *const termios.Termios, action: u32) void {
    var kernel = t.toLinux();
    const rc = linux.ioctl(fd, action, @intFromPtr(&kernel));
    if (linux.errno(rc) != .SUCCESS) {
        const e: c_int = @intFromEnum(linux.errno(rc));
        c.errorMsg(e, "can't tcsetattr for stdin", .{});
    }
}

pub fn showkeyMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("showkey");
    const av = avFrom(argv, argc);
    const o = c.opts("showkey", av, "^aks\x00a--ks:k--as:s--ak", &.{});
    const a_bit = o.flags & 1;
    const k_bit = o.flags & 2;
    const s_bit = o.flags & 4;
    var mode_count: u8 = 0;
    if (a_bit != 0) mode_count += 1;
    if (k_bit != 0) mode_count += 1;
    if (s_bit != 0) mode_count += 1;
    if (mode_count > 1) c.usageDie("showkey");

    const old = termios.Termios.get(0) catch termios.Termios{};
    var raw = old;
    raw.makeRaw();
    setTermios(0, &raw, termios.TCSETSF);

    if (a_bit != 0) {
        c.out("Press any keys, program terminates on EOF (ctrl-D):\r\n\n");
        var ch: [1]u8 = undefined;
        while (true) {
            const n = linux.read(0, &ch, 1);
            if (linux.errno(n) != .SUCCESS or n != 1) break;
            c.printfOut("{d: >3} 0{o:0>3} 0x{x:0>2}\r\n", .{ ch[0], ch[0], ch[0] });
            if (ch[0] == 0x04) break;
        }
    } else {
        var kbmode: c_int = 0;
        c.xioctl(0, KDGKBMODE, @intFromPtr(&kbmode), "KDGKBMODE");
        const mode_name: []const u8 = if (kbmode == K_RAW)
            "RAW"
        else if (kbmode == K_XLATE)
            "XLATE"
        else if (kbmode == K_MEDIUMRAW)
            "MEDIUMRAW"
        else if (kbmode == K_UNICODE)
            "UNICODE"
        else
            "UNKNOWN";
        c.printfOut("Keyboard mode was {s}.\r\n\n", .{mode_name});
        const new_mode: usize = if (k_bit != 0) K_MEDIUMRAW else K_RAW;
        c.xioctl(0, KDSKBMODE, new_mode, "KDSKBMODE");
        c.out("Press any keys, program terminates 10s after last keypress:\r\n\n");

        var buf: [18]u8 = undefined;
        while (true) {
            const n = linux.read(0, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var i: usize = 0;
            while (i < @as(usize, @intCast(n))) {
                if (s_bit != 0) {
                    c.printfOut("0x{x:0>2} ", .{buf[i]});
                    i += 1;
                } else {
                    const ch = buf[i];
                    var kc: u32 = ch & 0x7f;
                    if (i + 2 < @as(usize, @intCast(n)) and (ch & 0x7f) == 0 and
                        (buf[i + 1] & 0x80) != 0 and (buf[i + 2] & 0x80) != 0)
                    {
                        kc = (@as(u32, buf[i + 1] & 0x7f) << 7) | (buf[i + 2] & 0x7f);
                        i += 3;
                    } else {
                        i += 1;
                    }
                    c.printfOut("keycode {d: >3} {s}", .{ kc, if ((ch & 0x80) != 0) "release" else "press" });
                }
            }
            c.out("\r");
        }
        c.xioctl(0, KDSKBMODE, @intCast(kbmode), "KDSKBMODE");
    }
    setTermios(0, &old, termios.TCSETSF);
    return 0;
}
