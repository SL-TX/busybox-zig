//! Shared helpers for the Task 8 applet waves (findutils/debianutils/
//! printutils/klibc). Uses raw Linux syscalls to stay consistent with the
//! rest of the codebase under Zig 0.17.1.

const std = @import("std");
pub const linux = std.os.linux;
pub const bb = @import("libbb_zig");

pub fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) return;
        done += @intCast(n);
    }
}

pub fn argsFrom(allocator: std.mem.Allocator, argv: [*][*:0]const u8, argc: c_int) ![][]const u8 {
    return bb.getopt.argsToSlices(allocator, argv, @intCast(argc));
}

pub fn z(path: []const u8, buf: *[4096:0]u8) ![:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn zstr(allocator: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    return (try allocator.dupeSentinel(u8, s, 0)).ptr;
}

pub fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
    return ts.sec;
}

pub const Stat = struct {
    mode: u32,
    size: u64,
    mtime_sec: i64,
    ino: u64,
    nlink: u64,
    uid: u32,
    gid: u32,
    dev: u64,
    rdev: u64,
};

pub fn fileInfo(path: []const u8) ?Stat {
    return statPath(path, false);
}

pub fn statPath(path: []const u8, follow: bool) ?Stat {
    var buf: [4096:0]u8 = undefined;
    const p = z(path, &buf) catch return null;
    var stx: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(@intCast(linux.AT.FDCWD), p.ptr, flags, .BASIC_STATS, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{
        .mode = stx.mode,
        .size = stx.size,
        .mtime_sec = stx.mtime.sec,
        .ino = stx.ino,
        .nlink = stx.nlink,
        .uid = stx.uid,
        .gid = stx.gid,
        .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
        .rdev = (@as(u64, stx.rdev_major) << 32) | stx.rdev_minor,
    };
}

pub fn readAllFd(allocator: std.mem.Allocator, fd: linux.fd_t) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) break;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [4096:0]u8 = undefined;
    const p = try z(path, &buf);
    const rc = linux.open(p.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    return readAllFd(allocator, fd);
}

/// Directory iterator in raw readdir order (matches BusyBox find/ls).
pub const DirIter = struct {
    fd: linux.fd_t,
    buf: [16384]u8 align(8) = undefined,
    off: usize = 0,
    n: usize = 0,

    pub fn open(path: []const u8) ?DirIter {
        var buf: [4096:0]u8 = undefined;
        const p = z(path, &buf) catch return null;
        const rc = linux.open(p.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .fd = @intCast(rc) };
    }

    pub fn close(self: *DirIter) void {
        _ = linux.close(self.fd);
    }

    pub fn next(self: *DirIter) ?[]const u8 {
        while (true) {
            if (self.off + @offsetOf(linux.dirent64, "name") > self.n) {
                const rc = linux.getdents64(self.fd, &self.buf, self.buf.len);
                if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
                self.n = rc;
                self.off = 0;
            }
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(self.buf[self.off..].ptr));
            if (dent.reclen == 0) return null;
            const name_len = dent.reclen - @offsetOf(linux.dirent64, "name");
            const raw = self.buf[self.off + @offsetOf(linux.dirent64, "name") ..][0..name_len];
            self.off += dent.reclen;
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            if (end > 0) return raw[0..end];
        }
    }
};

pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

pub fn parseSignedNumber(s: []const u8) ?struct { sign: i8, value: u64 } {
    if (s.len == 0) return null;
    var sign: i8 = 0;
    var rest = s;
    if (rest[0] == '+') {
        sign = 1;
        rest = rest[1..];
    } else if (rest[0] == '-') {
        sign = -1;
        rest = rest[1..];
    }
    if (rest.len == 0) return null;
    const v = std.fmt.parseInt(u64, rest, 10) catch return null;
    return .{ .sign = sign, .value = v };
}

fn buildEnvp(allocator: std.mem.Allocator) []const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    if (bb.env.map) |m| {
        const keys = m.keys();
        const vals = m.values();
        for (keys, vals) |k, v| {
            const entry = std.fmt.allocPrint(allocator, "{s}={s}", .{ k, v }) catch continue;
            list.append(allocator, zstr(allocator, entry) catch continue) catch {};
        }
    }
    list.append(allocator, null) catch {};
    return list.toOwnedSlice(allocator) catch &.{};
}

fn findExecutable(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (linux.access(zstr(allocator, name) catch return null, 1) == 0) return name;
        return null;
    }
    const path = bb.env.get("PATH") orelse "/bin:/usr/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
        if (linux.access(zstr(allocator, full) catch continue, 1) == 0) return full;
    }
    return null;
}

/// Run a child program, returning the exit code (or 128+signal).
pub fn runChild(allocator: std.mem.Allocator, argv: []const []const u8) c_int {
    if (argv.len == 0) return 0;
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return 1;
    const pid: linux.pid_t = @intCast(pid_rc);
    if (pid == 0) {
        var args: [256]?[*:0]const u8 = undefined;
        for (argv, 0..) |a, i| {
            if (i >= args.len - 1) break;
            args[i] = zstr(allocator, a) catch null;
        }
        args[@min(argv.len, args.len - 1)] = null;
        const path = findExecutable(allocator, argv[0]) orelse std.process.exit(127);
        const envp = buildEnvp(allocator);
        _ = linux.execve(zstr(allocator, path) catch std.process.exit(127), @ptrCast(&args), @ptrCast(envp.ptr));
        std.process.exit(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    if ((status & 0x7f) == 0) return @intCast((status >> 8) & 0xff);
    return 128 + @as(c_int, @intCast(status & 0x7f));
}
