//! Tests for readKey escape-sequence decoding (Task 15), driven over a PTY.

const std = @import("std");
const bb = @import("libbb_zig");
const kb = bb.term.keyboard;
const termios = bb.term.termios;
const util = @import("test_util.zig");

fn rawPair() !util.PtyPair {
    const pair = try util.openPair();
    var raw = termios.Termios.raw();
    try raw.apply(pair.slave);
    return pair;
}

test "readKey returns a plain character" {
    var pair = try rawPair();
    defer pair.deinit();
    var buf = kb.Buffer{};
    try pair.writeMaster("a");
    try std.testing.expectEqual(@as(i64, 'a'), kb.readKey(pair.slave, &buf, 1000));
}

test "readKey decodes CSI and SS3 arrow / home / delete sequences" {
    var pair = try rawPair();
    defer pair.deinit();
    var buf = kb.Buffer{};

    try pair.writeMaster("\x1b[A");
    try std.testing.expectEqual(@as(i64, kb.KEYCODE.UP), kb.readKey(pair.slave, &buf, 1000));
    try pair.writeMaster("\x1bOB");
    try std.testing.expectEqual(@as(i64, kb.KEYCODE.DOWN), kb.readKey(pair.slave, &buf, 1000));
    try pair.writeMaster("\x1b[1~");
    try std.testing.expectEqual(@as(i64, kb.KEYCODE.HOME), kb.readKey(pair.slave, &buf, 1000));
    try pair.writeMaster("\x1b[3~");
    try std.testing.expectEqual(@as(i64, kb.KEYCODE.DELETE), kb.readKey(pair.slave, &buf, 1000));
    try pair.writeMaster("\x1b[6~");
    try std.testing.expectEqual(@as(i64, kb.KEYCODE.PAGEDOWN), kb.readKey(pair.slave, &buf, 1000));
}

test "safeReadKey reads a key from a raw PTY" {
    var pair = try rawPair();
    defer pair.deinit();
    var buf = kb.Buffer{};
    try pair.writeMaster("q");
    try std.testing.expectEqual(@as(i64, 'q'), kb.safeReadKey(pair.slave, &buf, 1000));
}

test "readKey drops unrecognized multi-byte escape leftovers (upstream)" {
    var pair = try rawPair();
    defer pair.deinit();
    var buf = kb.Buffer{};
    // read_key.c:277-293 drops unmatched leftovers for n > 1 and restarts,
    // so \x1b[Z yields neither ESC nor its bytes: the call waits for a new key.
    try pair.writeMaster("\x1b[Z");
    try std.testing.expectEqual(@as(i64, -1), kb.readKey(pair.slave, &buf, 20));
    try std.testing.expectEqual(@as(c_int, @backingInt(std.os.linux.E.AGAIN)), bb.process.errno);
    // The dropped bytes are not replayed on the next read either.
    try pair.writeMaster("X");
    try std.testing.expectEqual(@as(i64, 'X'), kb.readKey(pair.slave, &buf, 1000));
}

test "readKey decodes alt-x and keeps x buffered for the next call" {
    var pair = try rawPair();
    defer pair.deinit();
    var buf = kb.Buffer{};
    try pair.writeMaster("\x1bx");
    try std.testing.expectEqual(@as(i64, 27), kb.readKey(pair.slave, &buf, 1000));
    try std.testing.expectEqual(@as(i64, 'x'), kb.readKey(pair.slave, &buf, -2));
}

test "readKey decodes alt-arrows and ctrl-arrows" {
    var pair = try rawPair();
    defer pair.deinit();
    var buf = kb.Buffer{};
    try pair.writeMaster("\x1b[1;3D");
    try std.testing.expectEqual(@as(i64, kb.KEYCODE.ALT_LEFT), kb.readKey(pair.slave, &buf, 1000));
    try pair.writeMaster("\x1b[1;5C");
    try std.testing.expectEqual(@as(i64, kb.KEYCODE.CTRL_RIGHT), kb.readKey(pair.slave, &buf, 1000));
}

test "readKey times out with EAGAIN" {
    var pair = try rawPair();
    defer pair.deinit();
    var buf = kb.Buffer{};
    try std.testing.expectEqual(@as(i64, -1), kb.readKey(pair.slave, &buf, 20));
    try std.testing.expectEqual(@as(c_int, @backingInt(std.os.linux.E.AGAIN)), bb.process.errno);
}

test "RawMode restores the original attributes" {
    var pair = try util.openPair();
    defer pair.deinit();
    const original = try termios.Termios.get(pair.slave);
    {
        var raw_mode = try kb.RawMode.begin(pair.slave);
        defer raw_mode.end();
        const now = try termios.Termios.get(pair.slave);
        try std.testing.expect(!now.lflag.ICANON);
    }
    const restored = try termios.Termios.get(pair.slave);
    try std.testing.expectEqual(original.lflag.ICANON, restored.lflag.ICANON);
    try std.testing.expectEqual(original.lflag.ECHO, restored.lflag.ECHO);
}

test "unget pushes characters back into the key buffer" {
    var pair = try rawPair();
    defer pair.deinit();
    var buf = kb.Buffer{};
    kb.unget(&buf, "hi");
    try std.testing.expectEqual(@as(i64, 'h'), kb.readKey(pair.slave, &buf, -2));
    try std.testing.expectEqual(@as(i64, 'i'), kb.readKey(pair.slave, &buf, -2));
}
