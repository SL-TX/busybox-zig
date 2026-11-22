//! Escape-sequence aware single-key reader, ported from busybox
//! libbb/read_key.c. Works on any fd (typically a raw-mode tty).

const std = @import("std");
const linux = std.os.linux;
const io = @import("../io.zig");
const proc = @import("../process.zig");
const sm = @import("../signals_more.zig");
const termios = @import("termios.zig");

pub const KEYCODE = struct {
    pub const UP: i16 = -2;
    pub const DOWN: i16 = -3;
    pub const RIGHT: i16 = -4;
    pub const LEFT: i16 = -5;
    pub const HOME: i16 = -6;
    pub const END: i16 = -7;
    pub const INSERT: i16 = -8;
    pub const DELETE: i16 = -9;
    pub const PAGEUP: i16 = -10;
    pub const PAGEDOWN: i16 = -11;
    pub const BACKSPACE: i16 = -12;
    pub const D: i16 = -13;
    pub const ALT_BACKSPACE: i16 = -44; // BACKSPACE & ~0x20
    pub const ALT_D: i16 = -45; // D & ~0x20
    pub const ALT_RIGHT: i16 = -36; // RIGHT & ~0x20
    pub const ALT_LEFT: i16 = -37; // LEFT & ~0x20
    pub const CTRL_RIGHT: i16 = -68; // RIGHT & ~0x40
    pub const CTRL_LEFT: i16 = -69; // LEFT & ~0x40
    pub const CURSOR_POS: i64 = -0x100;
    pub const BUFFER_SIZE: usize = 16;
};

/// Buffered key input. `count` bytes at the front of `bytes` are pending.
pub const Buffer = struct {
    count: usize = 0,
    bytes: [KEYCODE.BUFFER_SIZE - 1]u8 = std.mem.zeroes([KEYCODE.BUFFER_SIZE - 1]u8),
};

const Seq = struct { chars: []const u8, code: i16 };

/// Sorted shortest-to-longest, matching busybox's esccmds table.
const esccmds = [_]Seq{
    .{ .chars = "\x7f", .code = KEYCODE.ALT_BACKSPACE },
    .{ .chars = "\x08", .code = KEYCODE.ALT_BACKSPACE },
    .{ .chars = "d", .code = KEYCODE.ALT_D },
    .{ .chars = "f", .code = KEYCODE.ALT_RIGHT },
    .{ .chars = "b", .code = KEYCODE.ALT_LEFT },
    .{ .chars = "OA", .code = KEYCODE.UP },
    .{ .chars = "OB", .code = KEYCODE.DOWN },
    .{ .chars = "OC", .code = KEYCODE.RIGHT },
    .{ .chars = "OD", .code = KEYCODE.LEFT },
    .{ .chars = "OH", .code = KEYCODE.HOME },
    .{ .chars = "OF", .code = KEYCODE.END },
    .{ .chars = "[A", .code = KEYCODE.UP },
    .{ .chars = "[B", .code = KEYCODE.DOWN },
    .{ .chars = "[C", .code = KEYCODE.RIGHT },
    .{ .chars = "[D", .code = KEYCODE.LEFT },
    .{ .chars = "[H", .code = KEYCODE.HOME },
    .{ .chars = "[F", .code = KEYCODE.END },
    .{ .chars = "[1~", .code = KEYCODE.HOME },
    .{ .chars = "[2~", .code = KEYCODE.INSERT },
    .{ .chars = "[3~", .code = KEYCODE.DELETE },
    .{ .chars = "[4~", .code = KEYCODE.END },
    .{ .chars = "[5~", .code = KEYCODE.PAGEUP },
    .{ .chars = "[6~", .code = KEYCODE.PAGEDOWN },
    .{ .chars = "[7~", .code = KEYCODE.HOME },
    .{ .chars = "[8~", .code = KEYCODE.END },
    .{ .chars = "[1;3C", .code = KEYCODE.ALT_RIGHT },
    .{ .chars = "[1;3D", .code = KEYCODE.ALT_LEFT },
    .{ .chars = "[1;5C", .code = KEYCODE.CTRL_RIGHT },
    .{ .chars = "[1;5D", .code = KEYCODE.CTRL_LEFT },
};

fn fill(fd: linux.fd_t, buf: *Buffer, at: usize) i8 {
    proc.errno = 0;
    const got = io.read(fd, buf.bytes[at .. at + 1]) catch return -1;
    if (got == 0) return -1;
    return 1;
}

/// Read one key. Returns the byte for ordinary keys, a negative KEYCODE for
/// escape sequences, -1 on EOF/error (errno EAGAIN on timeout). `timeout` of
/// -2 disables polling and only consumes already-buffered input.
pub fn readKey(fd: linux.fd_t, buf: *Buffer, timeout: i32) i64 {
    var polls = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN }};

    start_over: while (true) {
        proc.errno = 0;
        var n = buf.count;
        buf.count = 0;
        if (n == 0) {
            if (timeout >= -1) {
                const ready = sm.checkGotSignalAndPoll(&polls, timeout);
                if (ready < 0 and proc.errno == @backingInt(linux.E.INTR)) return -1;
                if (ready == 0) {
                    proc.errno = @backingInt(linux.E.AGAIN);
                    return -1;
                }
            }
            if (fill(fd, buf, 0) <= 0) return -1;
            n = 1;
        }

        const c = buf.bytes[0];
        n -= 1;
        if (n > 0) std.mem.copyForwards(u8, buf.bytes[0..n], buf.bytes[1 .. n + 1]);
        if (c != 27) {
            buf.count = n;
            return c;
        }

        var seq_idx: usize = 0;
        while (seq_idx < esccmds.len) : (seq_idx += 1) {
            const seq = esccmds[seq_idx];
            var i: usize = 0;
            while (true) {
                if (n <= i) {
                    const ready = sm.safePoll(&polls, 50);
                    if (ready == 0) break; // no more input: cannot extend this seq
                    if (fill(fd, buf, n) <= 0) {
                        if (proc.errno != @backingInt(linux.E.AGAIN)) {
                            buf.count = 0;
                            return -1;
                        }
                        break;
                    }
                    n += 1;
                }
                if (buf.bytes[i] != seq.chars[i]) break; // try the next sequence
                if (i + 1 == seq.chars.len) {
                    buf.count = 0;
                    return seq.code;
                }
                i += 1;
            }
        }

        // No known sequence matched. Keep reading briefly, as busybox does,
        // then report ESC alone (with leftovers buffered) or restart.
        while (n < buf.bytes.len) {
            const ready = sm.safePoll(&polls, 50);
            if (ready == 0) break;
            if (fill(fd, buf, n) <= 0) {
                if (proc.errno != @backingInt(linux.E.AGAIN)) {
                    buf.count = 0;
                    return -1;
                }
                break;
            }
            n += 1;
        }
        if (n <= 1) {
            buf.count = n;
            return 27;
        }
        // Upstream read_key.c drops unmatched leftovers (n > 1) and waits for
        // a fresh keypress: "Pretend there was no key pressed".
        buf.count = 0;
        continue :start_over;
    }
}

pub fn safeReadKey(fd: linux.fd_t, buf: *Buffer, timeout: i32) i64 {
    while (true) {
        const r = readKey(fd, buf, timeout);
        if (proc.errno != @backingInt(linux.E.INTR)) return r;
    }
}

/// Push characters back so the next readKey() returns them first.
pub fn unget(buf: *Buffer, str: []const u8) void {
    const n = @min(str.len, buf.bytes.len - buf.count);
    std.mem.copyForwards(u8, buf.bytes[buf.count .. buf.count + n], str[0..n]);
    buf.count += n;
}

/// Convenience: put the fd into raw mode and keep the original attributes.
pub const RawMode = struct {
    fd: linux.fd_t,
    original: termios.Termios,

    pub fn begin(fd: linux.fd_t) !RawMode {
        const original = try termios.Termios.get(fd);
        var raw = termios.Termios.raw();
        try raw.apply(fd);
        return .{ .fd = fd, .original = original };
    }

    pub fn end(self: *RawMode) void {
        self.original.apply(self.fd) catch {};
    }
};
