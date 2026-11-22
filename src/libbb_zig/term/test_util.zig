//! Shared PTY fixture for the terminal-helper unit tests.
const std = @import("std");
const bb = @import("libbb_zig");
const linux = std.os.linux;
const io = bb.io;

pub const PtyPair = struct {
    pty: bb.pty.Pty,
    master: linux.fd_t,
    slave: linux.fd_t,

    pub fn deinit(self: *PtyPair) void {
        io.close(self.slave) catch {};
        self.pty.close();
    }

    pub fn writeMaster(self: *const PtyPair, bytes: []const u8) !void {
        try io.writeAll(self.master, bytes);
    }

    pub fn readMaster(self: *const PtyPair, buf: []u8) !usize {
        return io.read(self.master, buf);
    }

    pub fn readSlave(self: *const PtyPair, buf: []u8) !usize {
        return io.read(self.slave, buf);
    }
};

pub fn openPair() !PtyPair {
    var p = try bb.pty.Pty.open();
    errdefer p.close();
    const slave = try p.openSlave();
    return .{ .pty = p, .master = p.master, .slave = slave };
}
