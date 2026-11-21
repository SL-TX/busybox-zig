//! copy_file / copyfd helpers ported from busybox libbb.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");
const file = @import("file.zig");

/// Options controlling copyFile. Defaults are plain POSIX-like copy semantics.
pub const Options = struct {
    recurse: bool = false,
    force: bool = false,
    preserve: bool = false,
    dereference: bool = false,
    make_softlink: bool = false,
    make_hardlink: bool = false,
    verbose: bool = false,
};

/// Copy all bytes from src_fd to dst_fd until EOF; returns bytes copied.
pub const copyFd = io.copyFd;

fn zpath(path: []const u8, buf: *[4096:0]u8) ! [*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn lstatPath(path: []const u8) !linux.Statx {
    var buf: [4096:0]u8 = undefined;
    const p = try zpath(path, &buf);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
    return st;
}

fn statPath(path: []const u8) !linux.Statx {
    var buf: [4096:0]u8 = undefined;
    const p = try zpath(path, &buf);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, 0, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
    return st;
}

fn sameFile(a: linux.Statx, b: linux.Statx) bool {
    // Statx does not expose st_dev in this Zig version; inode equality is
    // sufficient for the common "copy onto itself" case.
    return a.ino == b.ino;
}

const CopyCtx = struct {
    opts: Options,
    /// Immutable parent paths; child paths are built into separate buffers.
    src_parent: [4096:0]u8 = undefined,
    dest_parent: [4096:0]u8 = undefined,
};

fn appendName(parent: []const u8, name: []const u8, out: *[4096:0]u8) ![]const u8 {
    if (parent.len + 1 + name.len >= out.len) return error.NameTooLong;
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = '/';
    @memcpy(out[parent.len + 1 ..][0..name.len], name);
    out[parent.len + 1 + name.len] = 0;
    return out[0 .. parent.len + 1 + name.len];
}

fn copyChild(name: []const u8, ctx: ?*anyopaque) anyerror!void {
    const c: *CopyCtx = @ptrCast(@alignCast(ctx.?));
    const src_len = std.mem.indexOfScalar(u8, &c.src_parent, 0) orelse return error.InvalidPath;
    const dest_len = std.mem.indexOfScalar(u8, &c.dest_parent, 0) orelse return error.InvalidPath;
    var src_child: [4096:0]u8 = undefined;
    var dest_child: [4096:0]u8 = undefined;
    const sp = try appendName(c.src_parent[0..src_len], name, &src_child);
    const dp = try appendName(c.dest_parent[0..dest_len], name, &dest_child);
    try copyFileImpl(sp, dp, c.opts);
}

fn removeIfExists(path: []const u8) !void {
    file.removeFile(path, .{ .force = true }) catch |e| switch (e) {
        error.IsDirectory => try file.removeFile(path, .{ .force = true, .recurse = true }),
        else => {},
    };
}

fn copyFileImpl(src: []const u8, dest: []const u8, opts: Options) !void {
    var src_buf_z: [4096:0]u8 = undefined;
    const src_z = try zpath(src, &src_buf_z);

    const source_stat = if (opts.dereference) try statPath(src) else try lstatPath(src);

    // Detect copying a file onto itself.
    if (lstatPath(dest)) |ds| {
        if (sameFile(source_stat, ds)) return error.SameFile;
    } else |_| {}

    const src_kind = source_stat.mode & linux.S.IFMT;

    if (src_kind == linux.S.IFDIR) {
        if (!opts.recurse) return error.IsDirectory;
        try file.makeDirectory(dest, @intCast(source_stat.mode & 0o7777));
        var ctx = CopyCtx{ .opts = opts };
        const slen = std.mem.indexOfScalar(u8, &src_buf_z, 0).?;
        @memcpy(ctx.src_parent[0..slen], src_buf_z[0..slen]);
        ctx.src_parent[slen] = 0;
        var dest_buf_z: [4096:0]u8 = undefined;
        _ = try zpath(dest, &dest_buf_z);
        const dlen = std.mem.indexOfScalar(u8, &dest_buf_z, 0).?;
        @memcpy(ctx.dest_parent[0..dlen], dest_buf_z[0..dlen]);
        ctx.dest_parent[dlen] = 0;
        try file.forEachEntry(src_z, copyChild, &ctx);
        return;
    }

    // Links: honour -d / -l / -s over content copying.
    if (opts.make_softlink or opts.make_hardlink or (!opts.dereference and src_kind == linux.S.IFLNK)) {
        var lbuf: [4096]u8 = undefined;
        const n = try io.readlink(src, &lbuf);
        try removeIfExists(dest);
        if (opts.make_hardlink) {
            try io.link(src, dest);
        } else {
            try io.symlink(lbuf[0..n], dest);
        }
        return;
    }

    if (src_kind != linux.S.IFREG) return error.UnsupportedFileType;

    // A non-regular source cannot carry a meaningful mode.
    const mode: linux.mode_t = @intCast(source_stat.mode & 0o7777);
    const src_fd = try io.open(src, .{ .ACCMODE = .RDONLY }, 0);
    defer io.close(src_fd) catch {};
    try removeIfExists(dest);
    const dst_fd = try io.open(dest, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    defer io.close(dst_fd) catch {};
    _ = try io.copyFd(src_fd, dst_fd);

    if (opts.preserve) {
        try io.setTimes(dest, source_stat.mtime.sec, 0);
        io.fchmod(dst_fd, mode) catch {};
    }
}

/// Copy `src` to `dest` according to `opts`.
pub fn copyFile(src: []const u8, dest: []const u8, opts: Options) !void {
    try copyFileImpl(src, dest, opts);
}
