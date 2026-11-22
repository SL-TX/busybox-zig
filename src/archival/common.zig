//! Shared helpers for the archival applet wave (Task 20).
//!
//! All applets here are pure Zig and reuse the Task 19 libbb compression and
//! archive helpers. This module only provides the small libbb-style shell:
//! option parsing, byte-exact stdout/stderr writes, and file I/O.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const A = std.heap.page_allocator;
pub const LongOpt = bb.getopt.LongOpt;
pub const Options = bb.getopt.Options;

/// Set the libbb program name from argv[0] so diagnostics carry the invoked
/// applet name ("gzip:", "zcat:", ...), exactly like the reference binary.
pub fn setProg(argv: [*][*:0]const u8) void {
    bb.env.setProgramName(std.fs.path.basename(std.mem.span(argv[0])));
}

pub fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return bb.getopt.argsToSlices(A, argv, @intCast(argc)) catch &.{};
}

pub fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn out(bytes: []const u8) void {
    writeAll(1, bytes);
}

pub fn errout(bytes: []const u8) void {
    writeAll(2, bytes);
}

pub fn put(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    out(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

pub fn eput(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    errout(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

/// `bb_error_msg()` — "<prog>: <message>\n" on stderr.
pub fn msg(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

/// `bb_perror_msg()` — "<prog>: <message>: <strerror>\n" on stderr.
pub fn perror(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

/// Parse options; on failure getopt32 has already emitted the diagnostic and
/// we emit the exact generated usage body and exit 1 (`bb_show_usage`).
pub fn opts(name: []const u8, av: []const []const u8, os: []const u8, longs: []const LongOpt) Options {
    return bb.getopt.getopt32(av, os, longs) catch bb.usage.die(name);
}

pub fn flagged(o: Options, bit: u5) bool {
    return (o.flags & (@as(u32, 1) << bit)) != 0;
}

fn pathZ(s: []const u8) ?[*:0]const u8 {
    if (s.len == 0 or s.len >= 4095) return null;
    const buf = A.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(buf[0..s.len], s);
    return buf.ptr;
}

pub fn openRead(path: []const u8) ?linux.fd_t {
    if (std.mem.eql(u8, path, "-")) return 0;
    const p = pathZ(path) orelse return null;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn readFd(fd: linux.fd_t) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(A);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        const e = linux.errno(n);
        if (e != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(A, buf[0..n]);
    }
    return list.toOwnedSlice(A);
}

pub fn readAll(path: []const u8) ?[]u8 {
    const fd = openRead(path) orelse return null;
    defer {
        if (!std.mem.eql(u8, path, "-")) _ = linux.close(fd);
    }
    return readFd(fd) catch null;
}

/// Read stdin as raw bytes (used when no file operands are given).
pub fn readStdin() []u8 {
    return readFd(0) catch &.{};
}

pub fn writeFileMode(path: []const u8, data: []const u8, mode: u32) bool {
    const p = pathZ(path) orelse return false;
    const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    writeAll(fd, data);
    return true;
}

pub fn writeFile(path: []const u8, data: []const u8) bool {
    return writeFileMode(path, data, 0o644);
}

/// Apply a mode to an already-created file (used for archive members whose
/// stored permissions differ from the default 0644).
pub fn chmod(path: []const u8, mode: u32) void {
    const p = pathZ(path) orelse return;
    _ = linux.chmod(p, mode);
}

pub fn unlink(path: []const u8) void {
    const p = pathZ(path) orelse return;
    _ = linux.unlink(p);
}

pub fn exists(path: []const u8) bool {
    const p = pathZ(path) orelse return false;
    return linux.errno(linux.access(p, 0)) == .SUCCESS;
}

pub fn isDirectory(path: []const u8) bool {
    const p = pathZ(path) orelse return false;
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, 0, .BASIC_STATS, &st);
    return linux.errno(rc) == .SUCCESS and (st.mode & linux.S.IFMT) == linux.S.IFDIR;
}

/// Report a failed open in the canonical BusyBox form: "<prog>: <path>: <err>".
pub fn reportOpenError(path: []const u8, errnum: c_int) void {
    perror(errnum, "{s}", .{path});
}
