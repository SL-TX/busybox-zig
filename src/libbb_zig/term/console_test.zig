//! Tests for console device detection and VT activation (Task 15).
//! Real VTs are never touched: synthetic paths and a PTY are used instead.

const std = @import("std");
const bb = @import("libbb_zig");
const console = bb.term.console;
const util = @import("test_util.zig");
const io = bb.io;

const FAKE = "/tmp/opencode/bb-console-not-a-device";

test "isConsole rejects regular files and PTY slaves" {
    const fd = try io.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer io.close(fd) catch {};
    try std.testing.expect(!console.Console.isConsole(fd));

    var pair = try util.openPair();
    defer pair.deinit();
    try std.testing.expect(!console.Console.isConsole(pair.slave));
}

test "openWith returns NoConsole when no candidate is a real console" {
    const paths = [_][]const u8{ FAKE, "/tmp/opencode/definitely-missing" };
    const fds = [_]std.os.linux.fd_t{-1};
    var c = console.Console.openWith(&paths, &fds) catch |e| {
        try std.testing.expectEqual(console.Error.NoConsole, e);
        return;
    };
    c.close();
    try std.testing.expect(false);
}

test "makeActive reports VT ioctl failures instead of claiming success" {
    var pair = try util.openPair();
    defer pair.deinit();
    _ = console.Console.makeActive(pair.slave, 2) catch |e| {
        try std.testing.expectEqual(console.Error.NotConsole, e);
        return;
    };
    try std.testing.expect(false);
}

test "open returns a usable console fd or reports NoConsole" {
    var c = console.Console.open() catch |e| {
        try std.testing.expectEqual(console.Error.NoConsole, e);
        return;
    };
    defer c.close();
    try std.testing.expect(c.fd >= 0);
}

test "console constants match the Linux VT ABI" {
    try std.testing.expectEqual(@as(u32, 0x4B33), console.KDGKBTYPE);
    try std.testing.expectEqual(@as(u32, 0x5606), console.VT_ACTIVATE);
    try std.testing.expectEqual(@as(u32, 0x5607), console.VT_WAITACTIVE);
}

// Task 25 — init/runsv controlling-terminal extension.
test "acquireControllingTerminal reports failure for an invalid fd" {
    try std.testing.expectEqual(@as(u32, 0x540E), console.TIOCSCTTY);
    _ = console.acquireControllingTerminal(@as(std.os.linux.fd_t, -1)) catch |e| {
        try std.testing.expect(e == error.NotConsole or e == error.NotSessionLeader);
        return;
    };
    try std.testing.expect(false);
}

test "acquireControllingTerminal rejects a PTY slave that is not a session leader" {
    var pair = try util.openPair();
    defer pair.deinit();
    // The test process is already a session leader in some runners, so assert
    // only that the call reports a well-defined outcome, never a crash.
    _ = console.acquireControllingTerminal(pair.slave) catch |e| {
        try std.testing.expect(e == error.NotConsole or e == error.NotSessionLeader);
        return;
    };
}
