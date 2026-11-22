//! Shared helpers for the Task 16a miscutils applets.
//!
//! Everything here is deliberately thin: it wires the reference-style
//! diagnostics (program name, `bb_show_usage()`, errno strings) to the libbb
//! implementations that Tasks 9/15 provide, and converts the argc/argv pair
//! that the meta dispatcher hands us into the slice form getopt32 expects.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const Allocator = std.mem.Allocator;

/// Set the applet name used as the prefix of every diagnostic message.
pub fn setName(name: []const u8) void {
    bb.env.setProgramName(name);
}

pub fn out(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(1, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn errOut(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn printfOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    out(s);
}

pub fn printfErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    errOut(s);
}

/// Exact `bb_show_usage()` followed by exit(1).
pub fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

/// getopt32 wrapper: on any parse error getopt32 has already emitted the
/// `invalid option` line; emit the exact banner + usage body and exit(1).
pub fn opts(name: []const u8, av: []const []const u8, optstring: []const u8, longs: []const bb.getopt.LongOpt) bb.getopt.Options {
    return bb.getopt.getopt32(av, optstring, longs) catch usageDie(name);
}

/// `bb_error_msg("can't open '%s': %s", name, strerror(errno))`.
pub fn cantOpen(name: []const u8, errnum: c_int) void {
    bb.messages.errorMsg(errnum, "can't open '{s}'", .{name});
}

pub fn errorMsg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

pub fn plainMsg(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

pub fn errorMsgAndDie(errnum: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    bb.messages.errorMsgAndDie(errnum, fmt, args);
}

pub fn argsFrom(allocator: Allocator, argv: [*][*:0]const u8, argc: c_int) ![][]const u8 {
    return bb.getopt.argsToSlices(allocator, argv, @intCast(argc));
}

pub fn zstr(a: Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

pub fn realtimeSecs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub fn monotonicMillis() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Read a whole file into an allocated buffer. Returns null on open/read error
/// and stores the errno in `err`.
pub fn readFile(a: Allocator, path: []const u8, err: *c_int) ?[]u8 {
    const z = zstr(std.heap.page_allocator, path) catch {
        err.* = 12;
        return null;
    };
    defer std.heap.page_allocator.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        err.* = @intFromEnum(linux.errno(rc));
        return null;
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        const e = linux.errno(n);
        if (e != .SUCCESS) {
            err.* = @intFromEnum(e);
            return null;
        }
        if (n == 0) break;
        result.appendSlice(a, buf[0..n]) catch {
            err.* = 12;
            return null;
        };
    }
    return result.toOwnedSlice(a) catch {
        err.* = 12;
        return null;
    };
}

/// Read all of stdin into an allocated buffer.
pub fn readStdin(a: Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try result.appendSlice(a, buf[0..n]);
    }
    return result.toOwnedSlice(a);
}

/// Parse a base-0 integer the way busybox's bb_strtou does: accept an optional
/// 0x/0X prefix for hex, leading 0 for octal, otherwise decimal.
pub fn parseUnsigned(text: []const u8, base_hint: u8) !u64 {
    if (text.len == 0) return error.Invalid;
    var base: u8 = if (base_hint == 0) 10 else base_hint;
    var s = text;
    if (base_hint == 0) {
        if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            base = 16;
            s = s[2..];
        } else if (s.len > 1 and s[0] == '0') {
            base = 8;
            s = s[1..];
        }
    }
    return std.fmt.parseInt(u64, s, base) catch error.Invalid;
}

/// Return true when `text` is a syntactically valid integer for base 0.
pub fn isNumber(text: []const u8) bool {
    _ = parseUnsigned(text, 0) catch return false;
    return true;
}
