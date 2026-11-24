//! Shared helpers for the Task 18 console-tools applets.
//!
//! The reference applets are thin wrappers around libbb diagnostics, getopt32,
//! console-device discovery and VT/kbd ioctls. This module wires those
//! behaviours to the Task 9/15 libbb_zig helpers without opening a real VT.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const console = bb.term.console;

pub const Allocator = std.mem.Allocator;

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
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    out(s);
}

pub fn printfErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    errOut(s);
}

/// Exact `bb_show_usage()` followed by exit(1).
pub fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

/// getopt32 wrapper. The reference emits the offending option line inside
/// getopt32 and then calls bb_show_usage(); complement constraints (arg
/// counts, mutual exclusion) are checked explicitly by each applet.
pub fn opts(name: []const u8, av: []const []const u8, optstring: []const u8, longs: []const bb.getopt.LongOpt) bb.getopt.Options {
    return bb.getopt.getopt32(av, optstring, longs) catch usageDie(name);
}

pub fn argsFrom(allocator: Allocator, argv: [*][*:0]const u8, argc: c_int) ![][]const u8 {
    return bb.getopt.argsToSlices(allocator, argv, @intCast(argc));
}

pub fn zstr(a: Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

pub fn plainMsg(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

pub fn plainDie(comptime fmt: []const u8, args: anytype) noreturn {
    bb.messages.plainMsg(fmt, args);
    std.process.exit(1);
}

pub fn errorMsg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

pub fn errorMsgAndDie(errnum: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    bb.messages.errorMsgAndDie(errnum, fmt, args);
}

/// `bb_simple_error_msg_and_die("can't open console")`.
pub fn noConsole() noreturn {
    plainDie("can't open console", .{});
}

/// Locate a console fd exactly like `get_console_fd_or_die()`: try the three
/// console device names then the standard fds; die if none accepts KDGKBTYPE.
pub fn consoleFdOrDie() linux.fd_t {
    const c = console.Console.open() catch noConsole();
    return c.fd;
}

/// `xopen_nonblocking(path)` — O_RDONLY | O_NONBLOCK, die with the reference's
/// "can't open 'PATH': <errno>" message on failure.
pub fn openReadNonblock(path: []const u8) linux.fd_t {
    const z = zstr(std.heap.page_allocator, path) catch errorMsgAndDie(12, "can't open '{s}'", .{path});
    defer std.heap.page_allocator.free(z);
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true };
    const rc = linux.open(z.ptr, flags, 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS) errorMsgAndDie(@intFromEnum(e), "can't open '{s}'", .{path});
    return @intCast(rc);
}

/// `xopen(path, O_RDWR)` for openvt's VT device.
pub fn openRdWr(path: []const u8) linux.fd_t {
    const z = zstr(std.heap.page_allocator, path) catch errorMsgAndDie(12, "can't open '{s}'", .{path});
    defer std.heap.page_allocator.free(z);
    const rc = linux.open(z.ptr, .{ .ACCMODE = .RDWR }, 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS) errorMsgAndDie(@intFromEnum(e), "can't open '{s}'", .{path});
    return @intCast(rc);
}

/// `xopen(path, O_RDONLY)` for setlogcons.
pub fn openRead(path: []const u8) linux.fd_t {
    const z = zstr(std.heap.page_allocator, path) catch errorMsgAndDie(12, "can't open '{s}'", .{path});
    defer std.heap.page_allocator.free(z);
    const rc = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS) errorMsgAndDie(@intFromEnum(e), "can't open '{s}'", .{path});
    return @intCast(rc);
}

/// `xopen(path, O_WRONLY)` for setconsole/setlogcons.
pub fn openWrite(path: []const u8) linux.fd_t {
    const z = zstr(std.heap.page_allocator, path) catch errorMsgAndDie(12, "can't open '{s}'", .{path});
    defer std.heap.page_allocator.free(z);
    const rc = linux.open(z.ptr, .{ .ACCMODE = .WRONLY }, 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS) errorMsgAndDie(@intFromEnum(e), "can't open '{s}'", .{path});
    return @intCast(rc);
}

/// `xioctl(fd, REQ, arg)` — die with "<REQ>: <strerror>" on failure. `reqname`
/// is the literal macro name from the C source.
pub fn xioctl(fd: linux.fd_t, req: u32, arg: usize, reqname: []const u8) void {
    const rc = linux.ioctl(fd, req, arg);
    const e = linux.errno(rc);
    if (e != .SUCCESS) errorMsgAndDie(@intFromEnum(e), "{s}", .{reqname});
}

/// Parse a strictly decimal unsigned number the way `xatou_range` does and
/// enforce [lo, hi]. Overflow of u32 is reported as "invalid number".
pub fn xatouRange(text: []const u8, lo: u32, hi: u32) u32 {
    if (text.len == 0) plainDie("invalid number '{s}'", .{text});
    for (text) |c| {
        if (c < '0' or c > '9') plainDie("invalid number '{s}'", .{text});
    }
    const v = std.fmt.parseInt(u32, text, 10) catch plainDie("invalid number '{s}'", .{text});
    if (v < lo or v > hi) plainDie("number {d} is not in {d}..{d} range", .{ v, lo, hi });
    return v;
}

/// Base-16 scancode parser used by setkeycodes (`xstrtoul_range(..., 16,
/// 0, 0xe07f)`). "e030" is simply the hex number 0xe030; the caller performs
/// the reference's e000->0080 remapping before the ioctl.
pub fn parseScancode(text: []const u8) u32 {
    if (text.len == 0) plainDie("invalid number '{s}'", .{text});
    var s = text;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) s = s[2..];
    if (s.len == 0) plainDie("invalid number '{s}'", .{text});
    for (s) |c| {
        if (!std.ascii.isHex(c)) plainDie("invalid number '{s}'", .{text});
    }
    const v = std.fmt.parseInt(u32, s, 16) catch plainDie("invalid number '{s}'", .{text});
    if (v > 0xe07f) plainDie("number {d} is not in 0..{d} range", .{ v, 0xe07f });
    return v;
}

/// Read all of stdin into an allocated buffer (used by loadfont/loadkmap).
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

/// Read a whole file. Returns null and stores errno on failure.
pub fn readFile(a: Allocator, path: []const u8, err: *c_int) ?[]u8 {
    const z = zstr(std.heap.page_allocator, path) catch {
        err.* = 12;
        return null;
    };
    defer std.heap.page_allocator.free(z);
    const rc = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
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
