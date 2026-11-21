//! Exact BusyBox usage output for applet error paths.
//!
//! `bb_show_usage()` writes the version banner followed by the applet's
//! generated usage body to stderr and exits with status 1. The concrete table
//! lives in the root module (generated goldens are root-owned), so applets
//! reach it through a callback registered during startup.

const std = @import("std");
const linux = std.os.linux;

pub const ShowFn = *const fn ([]const u8, linux.fd_t) void;

/// Installed by src/main.zig at startup.
pub var showFn: ?ShowFn = null;

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) return;
        done += @intCast(n);
    }
}

pub fn show(name: []const u8, fd: linux.fd_t) void {
    if (showFn) |f| return f(name, fd);
    writeAll(fd, "\nUsage: ");
    writeAll(fd, name);
    writeAll(fd, "\n");
}

pub fn die(name: []const u8) noreturn {
    show(name, 2);
    std.process.exit(1);
}
