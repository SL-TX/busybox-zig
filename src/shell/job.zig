//! Job/process helpers shared by the executor.

const std = @import("std");
const linux = std.os.linux;

/// Decode a waitpid status into the shell's 8-bit exit status.
pub fn statusCode(status: i32) u8 {
    if ((status & 0x7f) != 0) return @intCast(128 + (status & 0x7f));
    return @intCast((status >> 8) & 0xff);
}

pub fn wait(pid: i32) u8 {
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    return statusCode(status);
}

pub fn spawn(pgid: bool) i32 {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return -1;
    if (pid == 0 and pgid) {
        _ = linux.setpgid(0, 0);
    }
    return @intCast(pid);
}

test "wait status decoding" {
    try std.testing.expectEqual(@as(u8, 7), statusCode(7 << 8));
    try std.testing.expectEqual(@as(u8, 130), statusCode(2));
}
