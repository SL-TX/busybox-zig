//! Additional I/O helpers. fullRead/fullWrite live in io.zig (re-exported
//! here); fullWriteWith is the injectable-writer form used to verify short
//! write handling without relying on kernel pipe-buffer sizes.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");

pub const fullRead = io.fullRead;
pub const fullWrite = io.fullWrite;

pub fn fullWriteWith(fd: linux.fd_t, bytes: []const u8, comptime writer: anytype) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try writer(fd, bytes[off..]);
        if (n == 0) return error.WriteFailed;
        off += n;
    }
}
