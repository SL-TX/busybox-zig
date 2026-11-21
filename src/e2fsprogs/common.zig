//! Shared helpers for the e2fsprogs applet wave.
//!
//! Diagnostics, usage bodies and ioctl numbers follow reference BusyBox
//! 1.39.0 byte for byte. No C code and no external utility delegation.

const std = @import("std");
pub const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const A = std.heap.page_allocator;
pub const Options = bb.getopt.Options;

pub fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return bb.getopt.argsToSlices(A, argv, @intCast(argc)) catch &.{};
}

pub fn setProg(argv: [*][*:0]const u8) void {
    bb.env.setProgramName(std.fs.path.basename(std.mem.span(argv[0])));
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

pub fn opts(name: []const u8, av: []const []const u8, os: []const u8) Options {
    return bb.getopt.getopt32(av, os, &.{}) catch usageDie(name);
}

pub fn msg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

pub fn plain(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

pub fn plainDie(comptime fmt: []const u8, args: anytype) noreturn {
    plain(fmt, args);
    std.process.exit(1);
}

pub fn zstr(s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(A, u8, &.{s}, 0);
}

pub fn err(rc: usize) c_int {
    return @intFromEnum(linux.errno(rc));
}

/// ext2 file-attribute ioctls (from bb_e2fs_defs.h, 64-bit _IOC encoding).
pub const IOC_GETFLAGS: u32 = 0x80086601;
pub const IOC_SETFLAGS: u32 = 0x40086602;
pub const IOC_GETVERSION: u32 = 0x80087601;
pub const IOC_SETVERSION: u32 = 0x40087602;
pub const IOC_FSGETXATTR: u32 = 0x801c581f;
pub const IOC_FSSETXATTR: u32 = 0x401c5820;

pub fn ioctl(fd: linux.fd_t, request: u32, arg: *anyopaque) usize {
    return linux.ioctl(fd, request, @intFromPtr(arg));
}

/// Names in raw readdir order, including "." and "..". iterate_on_dir() in
/// BusyBox uses readdir directly, so std.fs.Dir.iterate (which skips those two
/// entries) cannot be used here.
pub fn dirNames(path: []const u8) [][]const u8 {
    const p = zstr(path) catch return &.{};
    defer A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return &.{};
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList([]const u8) = .empty;
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var pos: usize = 0;
        while (pos + 19 <= n) {
            const reclen = std.mem.readInt(u16, buf[pos + 16 ..][0..2], .native);
            if (reclen < 19 or pos + reclen > n) break;
            const name_bytes = buf[pos + 19 .. pos + reclen];
            const name_len = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
            if (name_len > 0) {
                list.append(A, A.dupe(u8, name_bytes[0..name_len]) catch return list.toOwnedSlice(A) catch &.{}) catch
                    return list.toOwnedSlice(A) catch &.{};
            }
            pos += reclen;
        }
    }
    return list.toOwnedSlice(A) catch &.{};
}

fn statMode(path: []const u8) ?u16 {
    const p = zstr(path) catch return null;
    defer A.free(p);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return st.mode;
}

pub fn isDir(path: []const u8) bool {
    const mode = statMode(path) orelse return false;
    return (mode & linux.S.IFMT) == linux.S.IFDIR;
}

pub fn isReg(path: []const u8) bool {
    const mode = statMode(path) orelse return false;
    return (mode & linux.S.IFMT) == linux.S.IFREG;
}

pub fn isLnk(path: []const u8) bool {
    const mode = statMode(path) orelse return false;
    return (mode & linux.S.IFMT) == linux.S.IFLNK;
}

pub fn exists(path: []const u8) bool {
    return statMode(path) != null;
}

/// errno of lstat(path), or 0 on success.
pub fn lstatErr(path: []const u8) c_int {
    const p = zstr(path) catch return 22;
    defer A.free(p);
    var st: linux.Statx = undefined;
    return err(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st));
}

pub fn getEnv(key: []const u8) ?[]const u8 {
    return bb.env.get(key);
}

/// Fork+exec a program looked up in PATH. Returns the child pid.
pub fn spawn(argv: []const []const u8) ?i32 {
    if (argv.len == 0) return null;
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
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return null;
    if (pid == 0) {
        const rp = zstr(resolved) catch linux.exit(127);
        var zargs = A.alloc(?[*:0]const u8, argv.len + 1) catch linux.exit(127);
        for (argv, 0..) |a, i| zargs[i] = zstr(a) catch linux.exit(127);
        zargs[argv.len] = null;
        const envp = bb.env.buildEnvp(A) catch linux.exit(127);
        _ = linux.execve(rp, @ptrCast(zargs.ptr), bb.env.envpPtr(envp));
        linux.exit(127);
    }
    return @intCast(pid);
}

/// Read the whole file (used for fstab). Empty on failure.
pub fn readFile(path: []const u8) ?[]u8 {
    const p = zstr(path) catch return null;
    defer A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(A, buf[0..n]) catch break;
    }
    return list.toOwnedSlice(A) catch null;
}
