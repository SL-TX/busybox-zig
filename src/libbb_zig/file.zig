//! Filesystem helpers ported from busybox libbb:
//!   bb_make_directory, remove_file, find_mount_point.
//! All helpers are pure Zig/Linux-syscall implementations (no libc).

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");

const max_path = 4096;

fn zpath(path: []const u8, buf: *[max_path:0]u8) ! [*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn isDirMode(mode: u32) bool {
    return (mode & linux.S.IFMT) == linux.S.IFDIR;
}

fn statIsDir(path_z: [*:0]const u8) bool {
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path_z, 0, .BASIC_STATS, &st);
    return linux.errno(rc) == .SUCCESS and isDirMode(st.mode);
}

// --- makeDirectory ----------------------------------------------------------

fn mkdirOne(path: []const u8, mode: linux.mode_t) !void {
    var buf: [max_path:0]u8 = undefined;
    const p = try zpath(path, &buf);
    const rc = linux.mkdir(p, mode);
    if (linux.errno(rc) == .SUCCESS) return;
    const e = linux.errno(rc);
    if (e == .EXIST or e == .ISDIR) {
        if (statIsDir(p)) return;
        return error.NotDirectory;
    }
    return error.MkdirFailed;
}

/// Create `path`, creating any missing parent components (like `mkdir -p`).
/// Intermediate directories are created with at least u+wx permissions; the
/// final component uses `mode`. Existing directories are accepted.
pub fn makeDirectory(path: []const u8, mode: linux.mode_t) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "/")) return;

    var buf: [max_path:0]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var start: usize = 0;
    while (true) {
        var j = start + 1;
        while (j < path.len and path[j] != '/') : (j += 1) {}
        if (j >= path.len) break; // final component is handled after the loop
        const prefix = buf[0..j];
        if (j > 0 and !std.mem.eql(u8, prefix, "/") and !std.mem.eql(u8, prefix, ".") and !std.mem.eql(u8, prefix, "..")) {
            try mkdirOne(prefix, 0o700);
        }
        start = j;
    }
    try mkdirOne(path, mode);
}

// --- removeFile -------------------------------------------------------------

pub const RemoveFlags = struct {
    force: bool = false,
    recurse: bool = false,
    interactive: bool = false,
    verbose: bool = false,
};

fn lstatIsDir(path_z: [*:0]const u8) ?bool {
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path_z, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return isDirMode(st.mode);
}

/// Iterate the entries of `dir`, invoking `cb(name)` for each one. `.` and
/// `..` are skipped. The callback may recursively call removeFile.
pub const EntryCallback = *const fn (name: []const u8, ctx: ?*anyopaque) anyerror!void;

pub fn forEachEntry(dir_z: [*:0]const u8, cb: EntryCallback, ctx: ?*anyopaque) !void {
    const rc = linux.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var raw: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &raw, raw.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        var off: usize = 0;
        while (off + @offsetOf(linux.dirent64, "name") <= n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(raw[off..].ptr));
            if (dent.reclen == 0) break;
            const name_raw = raw[off + @offsetOf(linux.dirent64, "name") ..][0 .. dent.reclen - @offsetOf(linux.dirent64, "name")];
            off += dent.reclen;
            const end = std.mem.indexOfScalar(u8, name_raw, 0) orelse name_raw.len;
            const name = name_raw[0..end];
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            try cb(name, ctx);
        }
    }
}

const RemoveCtx = struct {
    flags: RemoveFlags,
    dir_buf: [max_path:0]u8 = undefined,
};

fn removeChild(name: []const u8, ctx: ?*anyopaque) anyerror!void {
    const c: *RemoveCtx = @ptrCast(@alignCast(ctx.?));
    // The parent path is stored at the start of c.dir_buf by removeFile.
    const parent_len = std.mem.indexOfScalar(u8, &c.dir_buf, 0) orelse return error.InvalidPath;
    const parent = c.dir_buf[0..parent_len];
    var child_buf: [max_path:0]u8 = undefined;
    if (parent.len + 1 + name.len >= child_buf.len) return error.NameTooLong;
    @memcpy(child_buf[0..parent.len], parent);
    child_buf[parent.len] = '/';
    @memcpy(child_buf[parent.len + 1 ..][0..name.len], name);
    child_buf[parent.len + 1 + name.len] = 0;
    try removeFileImpl(child_buf[0 .. parent.len + 1 + name.len], c.flags);
}

fn removeFileImpl(path: []const u8, flags: RemoveFlags) !void {
    var buf: [max_path:0]u8 = undefined;
    const p = try zpath(path, &buf);

    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) {
        const e = linux.errno(rc);
        if (e == .NOENT) {
            if (flags.force) return;
            return error.FileNotFound;
        }
        return error.StatFailed;
    }

    if (isDirMode(st.mode)) {
        if (!flags.recurse) return error.IsDirectory;

        var ctx = RemoveCtx{ .flags = flags };
        const plen = std.mem.indexOfScalar(u8, &buf, 0).?;
        @memcpy(ctx.dir_buf[0..plen], buf[0..plen]);
        ctx.dir_buf[plen] = 0;
        try forEachEntry(p, removeChild, &ctx);

        const rc_rm = linux.rmdir(p);
        if (linux.errno(rc_rm) != .SUCCESS) return error.RmdirFailed;
        return;
    }

    const rc_un = linux.unlink(p);
    if (linux.errno(rc_un) != .SUCCESS) return error.UnlinkFailed;
}

/// Remove `path`. A directory requires `.recurse`; a missing path is only a
/// no-op when `.force` is set. Interactive/verbose flags are accepted for
/// API parity but produce no prompts from this library-level helper.
pub fn removeFile(path: []const u8, flags: RemoveFlags) !void {
    try removeFileImpl(path, flags);
}

// --- findMountPoint ---------------------------------------------------------

/// Return the longest mount-point prefix of `path`, using /proc/mounts as the
/// mount table. The returned slice points into `path` (no allocation needed),
/// or null when no mount point matches. Mirrors busybox's find_mount_point()
/// for the common "find the filesystem of this path" case.
pub fn findMountPoint(path: []const u8) ?[]const u8 {
    var zbuf: [max_path:0]u8 = undefined;
    const p = zpath("/proc/mounts", &zbuf) catch return null;
    const fd_raw = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd_raw) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(fd_raw);
    defer _ = linux.close(fd);

    var content: [64 * 1024]u8 = undefined;
    var used: usize = 0;
    while (used < content.len) {
        const n = linux.read(fd, content[used..].ptr, content.len - used);
        if (linux.errno(n) != .SUCCESS) break;
        if (n == 0) break;
        used += @intCast(n);
    }

    var best: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content[0..used], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // device
        const mp = fields.next() orelse continue; // mount point
        if (mp.len == 0) continue;
        const matches = std.mem.eql(u8, mp, path) or
            (std.mem.startsWith(u8, path, mp) and (path.len == mp.len or path[mp.len] == '/'));
        if (matches and mp.len > best.len) best = mp;
    }

    if (best.len == 0) return null;
    return path[0..best.len];
}
