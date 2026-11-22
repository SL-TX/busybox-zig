//! Tests for the /dev/ptmx based pty helper (Task 15).

const std = @import("std");
const bb = @import("libbb_zig");
const util = @import("term/test_util.zig");
const io = bb.io;

test "Pty.open yields a master and a /dev/pts/N slave name" {
    var pair = try util.openPair();
    defer pair.deinit();
    try std.testing.expect(pair.master >= 0);
    try std.testing.expect(pair.slave >= 0);
    const name = pair.pty.name();
    try std.testing.expect(std.mem.startsWith(u8, name, "/dev/pts/"));
    try std.testing.expect(name.len > 0);
    try std.testing.expect(std.ascii.isDigit(name[name.len - 1]));
}

test "data written to the master is readable on the slave and vice versa" {
    var pair = try util.openPair();
    defer pair.deinit();

    try pair.writeMaster("ping\n");
    var buf: [64]u8 = undefined;
    const n = try pair.readSlave(&buf);
    try std.testing.expectEqualStrings("ping\n", buf[0..n]);

    // The line discipline echoes the first write back to the master; switch
    // the slave to raw mode so the slave->master direction is unambiguous.
    var raw = bb.term.termios.Termios.raw();
    try raw.apply(pair.slave);
    try io.writeAll(pair.slave, "pong");
    var pfds = [_]std.os.linux.pollfd{.{ .fd = pair.master, .events = std.os.linux.POLL.IN }};
    var found = false;
    for (0..8) |_| {
        if (bb.signals_more.safePoll(&pfds, 200) <= 0) break;
        const m = try pair.readMaster(&buf);
        if (std.mem.indexOf(u8, buf[0..m], "pong") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "xgetpty fills a caller buffer with the slave name" {
    var name_buf: [32]u8 = undefined;
    const master = try bb.pty.xgetpty(&name_buf);
    defer io.close(master) catch {};
    const name = std.mem.sliceTo(&name_buf, 0);
    try std.testing.expect(std.mem.startsWith(u8, name, "/dev/pts/"));
    const fd = try io.open(name, .{ .ACCMODE = .RDWR }, 0);
    io.close(fd) catch {};
}
