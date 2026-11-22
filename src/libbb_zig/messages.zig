//! Diagnostic messages, ported from busybox libbb/verror_msg.c.
//!
//! Every message is a single write to stderr and has the shape
//!     <program_name>: <text>[: <strerror>]\n
//! which is byte-for-byte what bb_verror_msg()/bb_perror_msg() emit.
//! `program_name` defaults to "busybox" and is set once by the meta-CLI.

const std = @import("std");
const linux = std.os.linux;

/// Prefix used by all diagnostics. Mutated by tests and by the meta-CLI.
pub var program_name: []const u8 = "busybox";

pub fn strerror(errnum: c_int) []const u8 {
    return switch (errnum) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        3 => "No such process",
        4 => "Interrupted system call",
        5 => "Input/output error",
        6 => "No such device or address",
        7 => "Argument list too long",
        8 => "Exec format error",
        9 => "Bad file descriptor",
        10 => "No child processes",
        11 => "Resource temporarily unavailable",
        12 => "Cannot allocate memory",
        13 => "Permission denied",
        14 => "Bad address",
        16 => "Device or resource busy",
        17 => "File exists",
        18 => "Invalid cross-device link",
        19 => "No such device",
        20 => "Not a directory",
        21 => "Is a directory",
        22 => "Invalid argument",
        23 => "Too many open files in system",
        24 => "Too many open files",
        25 => "Inappropriate ioctl for device",
        26 => "Text file busy",
        27 => "File too large",
        28 => "No space left on device",
        29 => "Illegal seek",
        30 => "Read-only file system",
        31 => "Too many links",
        32 => "Broken pipe",
        33 => "Numerical argument out of domain",
        34 => "Numerical result out of range",
        36 => "File name too long",
        39 => "Directory not empty",
        95 => "Operation not supported",
        110 => "Connection timed out",
        111 => "Connection refused",
        40 => "Too many levels of symbolic links",
        else => "Unknown error",
    };
}

fn emit(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) return;
        done += @intCast(n);
    }
}

fn line(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    emit(s);
}

/// Print `<prog>: <formatted message>: <strerror(errnum)>\n` to stderr.
pub fn errorMsg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    var msgbuf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msgbuf, fmt, args) catch return;
    line("{s}: {s}: {s}\n", .{ program_name, msg, strerror(errnum) });
}

/// Like errorMsg but takes the errno from the shared `process.errno` global.
pub fn perrorMsg(comptime fmt: []const u8, args: anytype) void {
    errorMsg(@import("process.zig").errno, fmt, args);
}

/// Print a diagnostic without a strerror suffix (used by getopt32).
pub fn plainMsg(comptime fmt: []const u8, args: anytype) void {
    var msgbuf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msgbuf, fmt, args) catch return;
    line("{s}: {s}\n", .{ program_name, msg });
}

/// Print `<prog>: <msg>\n` and exit with status 1.
pub fn die(msg: []const u8) noreturn {
    line("{s}: {s}\n", .{ program_name, msg });
    std.process.exit(1);
}

/// Print an errno-bearing diagnostic and exit with status 1.
pub fn errorMsgAndDie(errnum: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    errorMsg(errnum, fmt, args);
    std.process.exit(1);
}
