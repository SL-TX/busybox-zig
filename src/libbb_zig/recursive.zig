//! Recursive directory walker ported from busybox libbb/recursive_action.c.
//! A callback is invoked for every entry; its return value controls whether
//! a directory is descended into or the whole walk is aborted.

const std = @import("std");
const linux = std.os.linux;

pub const Action = enum {
    /// Continue (descend into directories when recursing).
    ok,
    /// Do not descend into this directory.
    skip_dir,
    /// Stop the entire walk.
    abort,
};

pub const Options = struct {
    /// Allocator used to build child paths passed to the callback.
    allocator: std.mem.Allocator,
    /// Descend into subdirectories (default true).
    recurse: bool = true,
    /// Invoke the directory callback after its children instead of before.
    depth_first: bool = false,
    /// Follow symlinks to directories when deciding whether to recurse.
    follow_links: bool = false,
    /// Currently informational; the helper never prints diagnostics.
    quiet: bool = false,
};

pub const Callback = struct {
    func: *const fn (path: []const u8, is_dir: bool, ctx: ?*anyopaque) Action,
    ctx: ?*anyopaque = null,
};

const Flow = enum { normal, abort };

fn isDirectory(path: []const u8, follow: bool) bool {
    var buf: [4096:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(linux.AT.FDCWD, @ptrCast(&buf), flags, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return false;
    return (st.mode & linux.S.IFMT) == linux.S.IFDIR;
}

fn emit(path: []const u8, is_dir: bool, cb: Callback) Flow {
    return switch (cb.func(path, is_dir, cb.ctx)) {
        .abort => .abort,
        else => .normal,
    };
}

fn walk(path: []const u8, opts: Options, cb: Callback, depth: usize) !Flow {
    const dir = isDirectory(path, opts.follow_links);

    if (!dir or !opts.recurse) {
        return emit(path, dir, cb);
    }

    if (!opts.depth_first) {
        const action = cb.func(path, true, cb.ctx);
        if (action == .abort) return .abort;
        if (action == .skip_dir) return .normal;
    }

    var buf: [4096:0]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const p: [*:0]const u8 = @ptrCast(&buf);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        // BusyBox reports the failure and returns false; we propagate an error.
        return error.OpenFailed;
    }
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

            const child = try joinPath(opts.allocator, path, name);
            defer opts.allocator.free(child);
            if (try walk(child, opts, cb, depth + 1) == .abort) return .abort;
        }
    }

    if (opts.depth_first) {
        return emit(path, true, cb);
    }
    return .normal;
}

fn joinPath(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, dir, "/")) return std.fmt.allocPrint(a, "{s}{s}", .{ dir, name });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

/// Walk `path` and invoke `callback` for every entry. See `Options` and
/// `Callback` for the control knobs. `.abort` from any callback stops the
/// walk early; the function still returns normally.
pub fn recursiveAction(path: []const u8, opts: Options, callback: Callback) !void {
    _ = try walk(path, opts, callback, 0);
}
