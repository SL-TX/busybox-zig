//! Shared helpers for the util-linux applet wave.
//!
//! Diagnostic wording, exit statuses and usage bodies follow the reference
//! BusyBox 1.39.0 byte for byte. No C code and no external utility delegation.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const A = std.heap.page_allocator;
pub const LongOpt = bb.getopt.LongOpt;
pub const Options = bb.getopt.Options;

pub fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return bb.getopt.argsToSlices(A, argv, @intCast(argc)) catch &.{};
}

pub fn setProg(argv: [*][*:0]const u8) void {
    bb.env.setProgramName(std.fs.path.basename(std.mem.span(argv[0])));
}

pub fn setProgramName(name: []const u8) void {
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

pub fn errout(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn put(comptime fmt: []const u8, args: anytype) void {
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    out(s);
}

pub fn eput(comptime fmt: []const u8, args: anytype) void {
    var b: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    errout(s);
}

pub fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

pub fn opts(name: []const u8, av: []const []const u8, os: []const u8, longs: []const LongOpt) Options {
    return bb.getopt.getopt32(av, os, longs) catch usageDie(name);
}

pub fn flagged(o: Options, bit: u5) bool {
    return (o.flags & (@as(u32, 1) << bit)) != 0;
}

pub fn msg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

pub fn plain(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

pub fn msgDie(errnum: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    bb.messages.errorMsgAndDie(errnum, fmt, args);
}

pub fn zstr(s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(A, u8, &.{s}, 0);
}

pub fn fmtAlloc(comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(A, fmt, args);
}

pub fn num(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidCharacter;
    return std.fmt.parseInt(u64, s, 10);
}

/// Read all bytes from a path. Empty slice on failure.
pub fn readFile(path: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(A);
    const p = try zstr(path);
    defer A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try list.appendSlice(A, buf[0..n]);
    }
    return list.toOwnedSlice(A);
}

/// Read all bytes from stdin.
pub fn readStdin() []u8 {
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(A, buf[0..n]) catch break;
    }
    return list.toOwnedSlice(A) catch &.{};
}

/// Read a file, or stdin when path is "-" or empty.
pub fn readInput(path: []const u8) ![]u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "-")) return readStdin();
    return readFile(path);
}

/// Resolve a program name through the inherited PATH (or leave an explicit
/// path untouched) and exec it. Does not return on success.
pub fn childExec(argv: []const []const u8) noreturn {
    var resolved: []const u8 = argv[0];
    if (std.mem.indexOfScalar(u8, argv[0], '/') == null) {
        const path = bb.env.get("PATH") orelse "/usr/bin:/bin";
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const cand = std.fmt.allocPrint(A, "{s}/{s}", .{ dir, argv[0] }) catch continue;
            defer A.free(cand);
            const pz = zstr(cand) catch continue;
            defer A.free(pz);
            const rc = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(rc) == .SUCCESS) {
                _ = linux.close(@intCast(rc));
                resolved = A.dupe(u8, cand) catch argv[0];
                break;
            }
        }
    }
    const rp = zstr(resolved) catch linux.exit(111);
    var zargs = A.alloc(?[*:0]const u8, argv.len + 1) catch linux.exit(111);
    for (argv, 0..) |arg, i| {
        zargs[i] = zstr(arg) catch linux.exit(111);
    }
    zargs[argv.len] = null;
    const envp = bb.env.buildEnvp(A) catch linux.exit(111);
    _ = linux.execve(rp, @ptrCast(zargs.ptr), bb.env.envpPtr(envp));
    linux.exit(111);
}

/// Resolve a program name through the inherited PATH and exec it in a child.
/// Returns the child's exit status. Used by applets whose job is to run PROG.
pub fn runChild(argv: []const []const u8) u8 {
    if (argv.len == 0) return 1;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return 111;
    if (pid == 0) childExec(argv);
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    if ((status & 0x7f) == 0) return @intCast((status >> 8) & 0xff);
    return @intCast((status & 0x7f) | 0x80);
}
