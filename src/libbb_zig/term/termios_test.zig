//! Tests for termios wrappers (Task 15). Uses a real PTY slave.

const std = @import("std");
const bb = @import("libbb_zig");
const termios = bb.term.termios;
const util = @import("test_util.zig");

test "Termios.get reads a PTY and raw/apply switches it to raw mode" {
    var pair = try util.openPair();
    defer pair.deinit();
    const original = try termios.Termios.get(pair.slave);

    var raw = termios.Termios.raw();
    try raw.apply(pair.slave);
    defer original.apply(pair.slave) catch {};

    const now = try termios.Termios.get(pair.slave);
    try std.testing.expect(!now.lflag.ICANON);
    try std.testing.expect(!now.lflag.ECHO);
    try std.testing.expect(!now.lflag.ISIG);
    try std.testing.expect(!now.lflag.IEXTEN);
    try std.testing.expect(!now.oflag.OPOST);
    try std.testing.expect(!now.iflag.ICRNL);
    try std.testing.expectEqual(@as(u2, 3), @backingInt(now.cflag.CSIZE));
}

test "Termios.makeRaw mutates an existing configuration" {
    var t = termios.Termios.sane();
    try std.testing.expect(t.lflag.ICANON);
    t.makeRaw();
    try std.testing.expect(!t.lflag.ICANON);
    try std.testing.expect(!t.lflag.ECHO);
    try std.testing.expectEqual(@as(u2, 3), @backingInt(t.cflag.CSIZE));
}

test "Termios.sane enables canonical echo and signal processing" {
    const t = termios.Termios.sane();
    try std.testing.expect(t.lflag.ICANON);
    try std.testing.expect(t.lflag.ECHO);
    try std.testing.expect(t.lflag.ISIG);
    try std.testing.expect(t.iflag.ICRNL);
    try std.testing.expect(t.oflag.OPOST);
}

test "Termios speed round-trips through cflag" {
    var t = termios.Termios.raw();
    try t.setSpeed(9600);
    try std.testing.expectEqual(@as(u32, 9600), t.speed());
    try t.setSpeed(38400);
    try std.testing.expectEqual(@as(u32, 38400), t.speed());
}

test "window size helpers round-trip on a PTY" {
    var pair = try util.openPair();
    defer pair.deinit();
    const ws = termios.WindowSize{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    try termios.setWindowSize(pair.slave, &ws);
    const got = try termios.getWindowSize(pair.master);
    try std.testing.expectEqual(@as(u16, 24), got.row);
    try std.testing.expectEqual(@as(u16, 80), got.col);
    try std.testing.expect(termios.isatty(pair.slave));
    try std.testing.expect(!termios.isatty(@as(std.os.linux.fd_t, -1)));
}

test "Termios.get fails for a non-terminal descriptor" {
    const fd = try bb.io.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer bb.io.close(fd) catch {};
    _ = termios.Termios.get(fd) catch |e| {
        try std.testing.expectEqual(error.NotATerminal, e);
        return;
    };
    try std.testing.expect(false);
}
