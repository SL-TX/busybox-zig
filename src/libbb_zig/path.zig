//! Path helpers from busybox libbb. The pure string operations live in
//! string.zig (re-exported here); the cwd/readlink wrappers use raw Linux
//! syscalls so no libc is needed.

const std = @import("std");
const linux = std.os.linux;
const string = @import("string.zig");
const util = @import("util.zig");

pub const concatPathFile = string.concatPathFile;
pub const simplifyPath = string.simplifyPath;
pub const getLastPathComponent = string.getLastPathComponent;
pub const processEscapeSequence = util.processEscapeSequence;

/// Return the current working directory as an owned slice.
pub fn xgetcwd(a: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = linux.getcwd(&buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return error.GetcwdFailed;
    return a.dupe(u8, buf[0..@intCast(n)]);
}

/// Return the target of a symlink, or null when `path` is not a symlink.
pub fn xreadlink(a: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len >= 4096) return error.NameTooLong;
    var zbuf: [4096:0]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    var buf: [4096]u8 = undefined;
    const n = linux.readlink(@ptrCast(&zbuf), &buf, buf.len);
    const e = linux.errno(n);
    if (e != .SUCCESS) {
        if (e == .INVAL) return null; // not a symbolic link
        return error.ReadlinkFailed;
    }
    return try a.dupe(u8, buf[0..@intCast(n)]);
}
