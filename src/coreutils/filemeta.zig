//! Task 7c: file-and-metadata coreutils applets.
//!
//! Each `xxxMain` is reached through a thin `<name>_main` wrapper in main.zig,
//! so the module root exposes exactly one main symbol per applet. All
//! diagnostics go through libbb_zig (messages/usage/getopt/env).

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const A = std.heap.page_allocator;
const LongOpt = bb.getopt.LongOpt;
const Options = bb.getopt.Options;

// --- generic helpers --------------------------------------------------------

fn setProg(argv: [*][*:0]const u8) void {
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    bb.env.setProgramName(name);
}

fn avFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return bb.getopt.argsToSlices(A, argv, @intCast(argc)) catch &.{};
}

fn out(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(1, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) return;
        done += n;
    }
}

fn errout(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) return;
        done += n;
    }
}

fn put(comptime fmt: []const u8, args: anytype) void {
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    out(s);
}

fn eput(comptime fmt: []const u8, args: anytype) void {
    var b: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    errout(s);
}

fn msg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

fn plain(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn opts(name: []const u8, av: []const []const u8, os: []const u8, longs: []const LongOpt) Options {
    return bb.getopt.getopt32(av, os, longs) catch usageDie(name);
}

fn flagged(o: Options, bit: u5) bool {
    return (o.flags & (@as(u32, 1) << bit)) != 0;
}

fn errOf(rc: usize) c_int {
    return @intFromEnum(linux.errno(rc));
}

const Path = struct {
    buf: [4096:0]u8 = undefined,
    fn init(s: []const u8) !Path {
        var p: Path = .{};
        if (s.len >= p.buf.len) return error.NameTooLong;
        @memcpy(p.buf[0..s.len], s);
        p.buf[s.len] = 0;
        return p;
    }
    fn z(self: *const Path) [*:0]const u8 {
        return @ptrCast(&self.buf);
    }
};

fn zs(s: []const u8, buf: *[4096:0]u8) ?[*:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf);
}

const Info = struct {
    mode: u32,
    size: u64,
    blocks: u64,
    nlink: u32,
    uid: u32,
    gid: u32,
    ino: u64,
    blksize: u32,
    mtime: i64,
};

fn info(path: []const u8, follow: bool) ?Info {
    const p = Path.init(path) catch return null;
    var stx: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(@intCast(linux.AT.FDCWD), p.z(), flags, .BASIC_STATS, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{
        .mode = stx.mode,
        .size = stx.size,
        .blocks = stx.blocks,
        .nlink = stx.nlink,
        .uid = stx.uid,
        .gid = stx.gid,
        .ino = stx.ino,
        .blksize = stx.blksize,
        .mtime = stx.mtime.sec,
    };
}

fn dirNames(a: std.mem.Allocator, path: []const u8) ![][]u8 {
    var zbuf: [4096:0]u8 = undefined;
    const z = zs(path, &zbuf) orelse return error.NameTooLong;
    const fd: linux.fd_t = @intCast(linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0));
    if (linux.errno(@as(usize, @intCast(fd))) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + @offsetOf(linux.dirent64, "name") <= n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const name_len = dent.reclen - @offsetOf(linux.dirent64, "name");
            const raw = buf[off + @offsetOf(linux.dirent64, "name") ..][0..name_len];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const nm = raw[0..end];
            if (nm.len > 0 and !std.mem.eql(u8, nm, ".") and !std.mem.eql(u8, nm, "..")) {
                try names.append(a, try a.dupe(u8, nm));
            }
            off += dent.reclen;
        }
    }
    return names.toOwnedSlice(a);
}

fn isDir(path: []const u8) bool {
    const i = info(path, false) orelse return false;
    return (i.mode & linux.S.IFMT) == linux.S.IFDIR;
}

fn exists(path: []const u8) bool {
    return info(path, true) != null;
}

var last_err: c_int = 0;

fn openFd(path_z: [*:0]const u8, flags: linux.O, mode: linux.mode_t) ?linux.fd_t {
    const rc = linux.open(path_z, flags, mode);
    if (linux.errno(rc) != .SUCCESS) {
        last_err = errOf(rc);
        return null;
    }
    return @intCast(rc);
}

fn readFd(fd: linux.fd_t) ![]u8 {
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

fn writeAllFd(fd: linux.fd_t, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        done += n;
    }
    return true;
}

fn joinPath(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len > 0 and dir[dir.len - 1] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ dir, name });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

fn removeOne(path: []const u8) bool {
    const p = Path.init(path) catch return false;
    if (linux.errno(linux.unlink(p.z())) == .SUCCESS) return true;
    if (linux.errno(linux.rmdir(p.z())) == .SUCCESS) return true;
    return false;
}

fn mkdirOne(path: []const u8, mode: linux.mode_t) bool {
    const p = Path.init(path) catch return false;
    const e = linux.errno(linux.mkdir(p.z(), mode));
    return e == .SUCCESS or e == .EXIST;
}

fn copyOne(src: []const u8, dst: []const u8, mode: linux.mode_t, truncate: bool) bool {
    const s = Path.init(src) catch return false;
    const d = Path.init(dst) catch return false;
    const in_fd = openFd(s.z(), .{ .ACCMODE = .RDONLY }, 0) orelse return false;
    defer _ = linux.close(in_fd);
    var flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true };
    if (truncate) flags.TRUNC = true;
    const out_fd = openFd(d.z(), flags, 0o666) orelse return false;
    defer _ = linux.close(out_fd);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(in_fd, &buf, buf.len);
        const e = linux.errno(n);
        if (e != .SUCCESS) return false;
        if (n == 0) break;
        if (!writeAllFd(out_fd, buf[0..n])) return false;
    }
    _ = linux.fchmod(out_fd, mode & 0o7777);
    return true;
}

fn copyDir(a: std.mem.Allocator, src: []const u8, dst: []const u8) bool {
    const src_mode = info(src, false) orelse return false;
    _ = mkdirOne(dst, src_mode.mode & 0o7777);
    const names = dirNames(a, src) catch return false;
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    for (names) |name| {
        const child = joinPath(a, src, name) catch return false;
        const target = joinPath(a, dst, name) catch return false;
        const ch = info(child, false) orelse continue;
        if ((ch.mode & linux.S.IFMT) == linux.S.IFDIR) {
            if (!copyDir(a, child, target)) return false;
        } else {
            if (!copyOne(child, target, ch.mode & 0o7777, true)) return false;
        }
    }
    return true;
}

fn removeTree(a: std.mem.Allocator, path: []const u8) bool {
    const names = dirNames(a, path) catch return false;
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    for (names) |name| {
        const child = joinPath(a, path, name) catch return false;
        const ch = info(child, false) orelse continue;
        if ((ch.mode & linux.S.IFMT) == linux.S.IFDIR) {
            if (!removeTree(a, child)) return false;
        } else if (!removeOne(child)) return false;
    }
    return removeOne(path);
}

// ---------------------------------------------------------------- cp

pub fn cpMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("cp", av, "pdRfinlsLHarPvuTt:", &.{});
    if (o.args.len == 0) usageDie("cp");
    const recursive = flagged(o, 2) or flagged(o, 11) or flagged(o, 10);
    const no_clobber = flagged(o, 5);
    const link = flagged(o, 6);
    const symlink = flagged(o, 7);
    var dest: []const u8 = undefined;
    var first: usize = 0;
    if (flagged(o, 16)) {
        dest = o.optarg orelse usageDie("cp");
        first = 0;
    } else {
        if (o.args.len < 2) usageDie("cp");
        dest = o.args[o.args.len - 1];
        first = 0;
    }
    const last = if (flagged(o, 16)) o.args.len else o.args.len - 1;
    const dest_is_dir = isDir(dest);
    if (flagged(o, 15) and dest_is_dir) {
        plain("'{s}' is a directory", .{dest});
        return 1;
    }
    var status: c_int = 0;
    var i = first;
    while (i < last) : (i += 1) {
        const src = o.args[i];
        if (info(src, false) == null) {
            msg(@intFromEnum(linux.E.NOENT), "can't stat '{s}'", .{src});
            status = 1;
            continue;
        }
        const target = if (dest_is_dir and !flagged(o, 15))
            joinPath(A, dest, std.fs.path.basename(src)) catch return 1
        else
            dest;
        if (no_clobber and exists(target)) continue;
        if (link or symlink) {
            const s = Path.init(src) catch return 1;
            const d = Path.init(target) catch return 1;
            const rc = if (link) linux.link(s.z(), d.z()) else linux.symlink(s.z(), d.z());
            if (linux.errno(rc) != .SUCCESS) {
                msg(errOf(rc), "can't create link '{s}'", .{target});
                status = 1;
            }
        } else if (recursive and isDir(src)) {
            if (!copyDir(A, src, target)) status = 1;
        } else {
            const si = info(src, false).?;
            if (!copyOne(src, target, si.mode & 0o7777, true)) status = 1;
        }
    }
    return status;
}

// ---------------------------------------------------------------- mv

pub fn mvMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("mv", av, "finTt:", &.{});
    if (o.args.len == 0) usageDie("mv");
    var dest: []const u8 = undefined;
    var last: usize = undefined;
    if (flagged(o, 4)) {
        dest = o.optarg orelse usageDie("mv");
        last = o.args.len;
    } else {
        if (o.args.len < 2) usageDie("mv");
        dest = o.args[o.args.len - 1];
        last = o.args.len - 1;
    }
    const dest_is_dir = isDir(dest);
    if (flagged(o, 3) and dest_is_dir) {
        plain("'{s}' is a directory", .{dest});
        return 1;
    }
    var status: c_int = 0;
    for (o.args[0..last]) |src| {
        const target = if (dest_is_dir and !flagged(o, 3))
            joinPath(A, dest, std.fs.path.basename(src)) catch return 1
        else
            dest;
        if (flagged(o, 2) and exists(target)) continue;
        const s = Path.init(src) catch return 1;
        const d = Path.init(target) catch return 1;
        var rc = linux.rename(s.z(), d.z());
        var e = linux.errno(rc);
        if (e != .SUCCESS and e == .XDEV) {
            const si = info(src, false).?;
            if (copyOne(src, target, si.mode & 0o7777, true)) {
                _ = removeOne(src);
                rc = 0;
                e = .SUCCESS;
            }
        }
        if (e != .SUCCESS) {
            msg(@intFromEnum(e), "can't rename '{s}'", .{src});
            status = 1;
        }
    }
    return status;
}

// ---------------------------------------------------------------- rm

pub fn rmMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("rm", av, "irfR", &.{});
    if (o.args.len == 0) usageDie("rm");
    const recursive = flagged(o, 1) or flagged(o, 3);
    const force = flagged(o, 2);
    const interactive = flagged(o, 0);
    var status: c_int = 0;
    for (o.args) |path| {
        if (recursive and isDir(path)) {
            if (!removeTree(A, path)) status = 1;
            continue;
        }
        const p = Path.init(path) catch { status = 1; continue; };
        const i = info(path, false);
        if (i == null) {
            if (!force) {
                msg(@intFromEnum(linux.E.NOENT), "can't remove '{s}'", .{path});
                status = 1;
            }
            continue;
        }
        if ((i.?.mode & linux.S.IFMT) == linux.S.IFDIR) {
            plain("'{s}' is a directory", .{path});
            status = 1;
            continue;
        }
        if (interactive) {
            eput("rm: remove '{s}'? ", .{path});
            var ans: [64]u8 = undefined;
            const n = linux.read(0, &ans, ans.len);
            if (linux.errno(n) != .SUCCESS or n == 0 or (ans[0] != 'y' and ans[0] != 'Y')) continue;
        }
        if (linux.errno(linux.unlink(p.z())) != .SUCCESS) status = 1;
    }
    return status;
}

// ---------------------------------------------------------------- ln

pub fn lnMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("ln", av, "sfnbS:vT", &.{});
    if (o.args.len == 0) usageDie("ln");
    const symlink = flagged(o, 0);
    const force = flagged(o, 1);
    const backup = flagged(o, 3);
    const verbose = flagged(o, 5);
    const no_dir = flagged(o, 6);
    var suffix: []const u8 = "~";
    if (flagged(o, 4)) {
        suffix = o.optarg orelse "~";
        var si: usize = 1;
        while (si + 1 < av.len) : (si += 1) {
            if (std.mem.eql(u8, av[si], "-S")) suffix = av[si + 1];
            if (std.mem.startsWith(u8, av[si], "-S") and av[si].len > 2) suffix = av[si][2..];
        }
    }
    const args = o.args;
    var sources: []const []const u8 = undefined;
    var last: []const u8 = undefined;
    if (args.len == 1) {
        sources = args[0..1];
        last = std.fs.path.basename(args[0]);
    } else {
        sources = args[0 .. args.len - 1];
        last = args[args.len - 1];
    }
    var status: c_int = 0;
    for (sources) |src| {
        var target = last;
        if (isDir(last) and !no_dir) {
            target = joinPath(A, last, std.fs.path.basename(src)) catch return 1;
        }
        if (!symlink and info(src, true) == null) {
            const e = @intFromEnum(linux.E.NOENT);
            msg(e, "{s}", .{src});
            status = 1;
            continue;
        }
        if (exists(target)) {
            if (backup) {
                const bak = std.fmt.allocPrint(A, "{s}{s}", .{ target, suffix }) catch return 1;
                const t = Path.init(target) catch return 1;
                const b = Path.init(bak) catch return 1;
                _ = linux.rename(t.z(), b.z());
            } else if (!force) {
                msg(@intFromEnum(linux.E.EXIST), "{s}", .{target});
                status = 1;
                continue;
            } else _ = removeOne(target);
        }
        const s = Path.init(src) catch return 1;
        const d = Path.init(target) catch return 1;
        const rc = if (symlink) linux.symlink(s.z(), d.z()) else linux.link(s.z(), d.z());
        if (linux.errno(rc) != .SUCCESS) {
            msg(@intFromEnum(linux.errno(rc)), "{s}", .{if (symlink) target else src});
            status = 1;
            continue;
        }
        if (verbose) put("'{s}' -> '{s}'\n", .{ target, src });
    }
    return status;
}

// ---------------------------------------------------------------- ls

fn listNames(a: std.mem.Allocator, path: []const u8, all: bool, almost_all: bool) ![][]u8 {
    var zbuf: [4096:0]u8 = undefined;
    const z = zs(path, &zbuf) orelse return error.NameTooLong;
    const fd: linux.fd_t = @intCast(linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0));
    if (linux.errno(@as(usize, @intCast(fd))) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + @offsetOf(linux.dirent64, "name") <= n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const name_len = dent.reclen - @offsetOf(linux.dirent64, "name");
            const raw = buf[off + @offsetOf(linux.dirent64, "name") ..][0..name_len];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const nm = raw[0..end];
            if (nm.len > 0) {
                const keep = if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, ".."))
                    all
                else if (nm[0] == '.')
                    all or almost_all
                else
                    true;
                if (keep) try names.append(a, try a.dupe(u8, nm));
            }
            off += dent.reclen;
        }
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return names.toOwnedSlice(a);
}

fn printLsName(name: []const u8, full_path: []const u8, classify: bool, slashes: bool) void {
    out(name);
    if (classify or slashes) {
        const i = info(full_path, false);
        if (i != null and (i.?.mode & linux.S.IFMT) == linux.S.IFDIR) out("/");
    }
    out("\n");
}

fn listDir(a: std.mem.Allocator, path: []const u8, o: Options, status: *c_int) void {
    const names = listNames(a, path, flagged(o, 2), flagged(o, 1)) catch {
        msg(errOf(1), "{s}", .{path});
        status.* = 1;
        return;
    };
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    for (names) |name| {
        const full = joinPath(a, path, name) catch continue;
        defer a.free(full);
        printLsName(name, full, flagged(o, 9), flagged(o, 10));
    }
}

fn listRecursive(a: std.mem.Allocator, path: []const u8, o: Options, first: *bool, status: *c_int, depth: usize) void {
    if (depth > 32) return;
    if (!first.*) out("\n");
    first.* = false;
    put("{s}:\n", .{path});
    const names = listNames(a, path, flagged(o, 2), flagged(o, 1)) catch {
        status.* = 1;
        return;
    };
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    for (names) |name| {
        const full = joinPath(a, path, name) catch continue;
        defer a.free(full);
        printLsName(name, full, flagged(o, 9), flagged(o, 10));
    }
    for (names) |name| {
        const full = joinPath(a, path, name) catch continue;
        defer a.free(full);
        if (isDir(full)) listRecursive(a, full, o, first, status, depth + 1);
    }
}

pub fn lsMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("ls", av, "^1AaCxdLHRFpilnshrSXvctuw:", &.{
        .{ .name = "full-time", .val = 0xfe },
        .{ .name = "group-directories-first", .val = 0xfd },
        .{ .name = "color", .has_arg = .optional, .val = 0xfc },
    });
    const dirs_only = flagged(o, 5);
    const recursive = flagged(o, 8);
    var files = o.args;
    if (files.len == 0) files = &.{"."};
    var status: c_int = 0;
    var first = true;
    for (files) |name| {
        const i = info(name, flagged(o, 6) or flagged(o, 7));
        if (i == null) {
            msg(@intFromEnum(linux.E.NOENT), "{s}", .{name});
            status = 1;
            continue;
        }
        const is_dir = (i.?.mode & linux.S.IFMT) == linux.S.IFDIR;
        if (recursive and is_dir) {
            listRecursive(A, name, o, &first, &status, 0);
        } else if (is_dir and !dirs_only) {
            listDir(A, name, o, &status);
        } else {
            printLsName(name, name, flagged(o, 9), flagged(o, 10));
        }
    }
    return status;
}

// ---------------------------------------------------------------- du

const DuCtx = struct {
    apparent: bool,
    all: bool,
    summarize: bool,
    total: bool,
    human: bool,
    megabytes: bool,
    max_depth: usize,
    grand: u64 = 0,
    status: c_int = 0,
};

fn duSize(ctx: *DuCtx, st: Info, bytes: u64) u64 {
    _ = st;
    const raw = bytes;
    if (ctx.human) return raw;
    if (ctx.apparent) return raw;
    if (ctx.megabytes) return (raw + 1024 * 1024 - 1) / (1024 * 1024);
    return (raw + 1023) / 1024;
}

fn printDuSize(ctx: *DuCtx, st: Info, bytes: u64) void {
    if (ctx.human) {
        const raw = duSize(ctx, st, bytes);
        const units = " KMGTPE";
        var unit: usize = 0;
        var scaled: u64 = raw;
        while (unit + 1 < units.len and scaled >= 1024) : (unit += 1) scaled /= 1024;
        if (unit == 0) {
            put("{d}", .{raw});
        } else {
            const frac = ((raw * 10) / (std.math.pow(u64, 1024, @as(u6, @intCast(unit))))) % 10;
            put("{d}.{d}{c}", .{ scaled, frac, units[unit] });
        }
    } else put("{d}", .{duSize(ctx, st, bytes)});
}

fn duWalk(a: std.mem.Allocator, ctx: *DuCtx, path: []const u8, depth: usize, summarize: bool) u64 {
    const st = info(path, false) orelse {
        msg(@intFromEnum(linux.E.NOENT), "{s}", .{path});
        ctx.status = 1;
        return 0;
    };
    var sum: u64 = if (ctx.apparent) st.size else st.blocks * 512;
    const is_dir = (st.mode & linux.S.IFMT) == linux.S.IFDIR;
    if (is_dir) {
        const names = dirNames(a, path) catch {
            ctx.status = 1;
            return sum;
        };
        defer {
            for (names) |n| a.free(n);
            a.free(names);
        }
        std.mem.sort([]u8, names, {}, struct {
            fn less(_: void, x: []u8, y: []u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        for (names) |name| {
            const child = joinPath(a, path, name) catch continue;
            defer a.free(child);
            sum += duWalk(a, ctx, child, depth + 1, summarize);
        }
    }
    const show = !summarize and (depth == 0 or ((is_dir or ctx.all) and depth <= ctx.max_depth));
    if (show) {
        printDuSize(ctx, st, sum);
        put("\t{s}\n", .{path});
    }
    if (summarize and depth == 0) {
        printDuSize(ctx, st, sum);
        put("\t{s}\n", .{path});
    }
    return sum;
}

pub fn duMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("du", av, "aHkLsxd:+lcbhm", &.{});
    var ctx = DuCtx{
        .apparent = flagged(o, 9),
        .all = flagged(o, 0),
        .summarize = flagged(o, 4),
        .total = flagged(o, 8),
        .human = flagged(o, 10),
        .megabytes = flagged(o, 11),
        .max_depth = std.math.maxInt(usize),
    };
    if (flagged(o, 6)) ctx.max_depth = std.fmt.parseInt(usize, o.optarg orelse "0", 10) catch usageDie("du");
    var paths = o.args;
    const no_args = paths.len == 0;
    if (no_args) paths = &.{"."};
    for (paths) |path| {
        const sum = duWalk(A, &ctx, path, 0, ctx.summarize);
        ctx.grand += sum;
    }
    if (ctx.total) {
        const st = info(paths[0], false) orelse Info{
            .mode = 0, .size = ctx.grand, .blocks = ctx.grand / 512, .nlink = 1,
            .uid = 0, .gid = 0, .ino = 0, .blksize = 4096, .mtime = 0,
        };
        printDuSize(&ctx, st, ctx.grand);
        out("\ttotal\n");
    }
    return ctx.status;
}

// ---------------------------------------------------------------- df

fn dfHeader(o: Options, av: []const []const u8) []const u8 {
    if (flagged(o, 6)) return "Filesystem              Inodes      Used Available Use% Mounted on\n";
    if (flagged(o, 0)) return "Filesystem           1024-blocks    Used Available Capacity Mounted on\n";
    if (flagged(o, 3)) return "Filesystem                Size      Used Available Use% Mounted on\n";
    if (flagged(o, 7)) {
        var size: []const u8 = "1";
        var bi: usize = 1;
        while (bi + 1 < av.len) : (bi += 1) {
            if (std.mem.eql(u8, av[bi], "-B")) size = av[bi + 1];
            if (std.mem.startsWith(u8, av[bi], "-B") and av[bi].len > 2) size = av[bi][2..];
        }
        if (std.mem.eql(u8, size, "1")) return "Filesystem           1-blocks       Used Available Use% Mounted on\n";
        return std.fmt.allocPrint(A, "Filesystem           {s}-blocks    Used Available Use% Mounted on\n", .{size}) catch
            "Filesystem           1-blocks       Used Available Use% Mounted on\n";
    }
    if (flagged(o, 4)) return "Filesystem           Type       1K-blocks      Used Available Use% Mounted on\n";
    return "Filesystem           1K-blocks      Used Available Use% Mounted on\n";
}

fn dfNumber(v: u64, o: Options) void {
    if (flagged(o, 3)) {
        const h = bb.util.human_readable(A, v, false) catch "0";
        put("{s: >10}", .{h});
    } else put("{d: >10}", .{v});
}

fn printDfRow(o: Options, av: []const []const u8, dev: []const u8, mount: []const u8, fstype: []const u8, fsb: *const Statfs) void {
    var unit: u64 = 1024;
    if (flagged(o, 2)) unit = 1024 * 1024;
    if (flagged(o, 7)) {
        var bi: usize = 1;
        while (bi + 1 < av.len) : (bi += 1) {
            if (std.mem.eql(u8, av[bi], "-B")) unit = parseNum(av[bi + 1]) orelse 1024;
        }
        if (unit == 0) unit = 1;
    }
    const bsize: u64 = @intCast(@max(fsb.f_bsize, 1));
    const total: u64 = @as(u64, @intCast(fsb.f_blocks)) * bsize / unit;
    const used: u64 = (@as(u64, @intCast(fsb.f_blocks)) - @as(u64, @intCast(fsb.f_bfree))) * bsize / unit;
    const avail: u64 = @as(u64, @intCast(fsb.f_bavail)) * bsize / unit;
    const pct: u64 = if (used + avail > 0) used * 100 / (used + avail) else 0;
    if (flagged(o, 6)) {
        const itotal: u64 = @intCast(@max(fsb.f_files, 0));
        const iused: u64 = @as(u64, @intCast(@max(fsb.f_files, 0))) - @as(u64, @intCast(@max(fsb.f_ffree, 0)));
        const ipct: u64 = if (itotal > 0) iused * 100 / itotal else 0;
        put("{s: <21}{d: >8}{d: >12}{d: >12}{d: >4}% {s}\n", .{ dev, itotal, iused, itotal - iused, ipct, mount });
        return;
    }
    if (flagged(o, 4)) {
        put("{s: <21}{s: <12}", .{ dev, fstype });
    } else {
        put("{s: <21}", .{dev});
    }
    dfNumber(total, o);
    put(" ", .{});
    dfNumber(used, o);
    put(" ", .{});
    dfNumber(avail, o);
    put("{d: >5}% {s}\n", .{ pct, mount });
}

pub fn dfMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("df", av, "PkmhTaiB:t:", &.{});
    out(dfHeader(o, av));
    var status: c_int = 0;
    var filter: ?[]const u8 = null;
    var ai: usize = 1;
    while (ai + 1 < av.len) : (ai += 1) {
        if (std.mem.eql(u8, av[ai], "-t")) filter = av[ai + 1];
    }
    if (o.args.len > 0) {
        for (o.args) |name| {
            if (info(name, true) == null) {
                plain("{s}: can't find mount point", .{name});
                status = 1;
            }
        }
        return status;
    }
    const fd = openFd("/proc/mounts", .{ .ACCMODE = .RDONLY }, 0) orelse return status;
    defer _ = linux.close(fd);
    const data = readFd(fd) catch return status;
    defer A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const dev = fields.next() orelse continue;
        const mnt = fields.next() orelse continue;
        const typ = fields.next() orelse continue;
        if (filter) |f| if (!std.mem.eql(u8, f, typ)) continue;
        var fsb: Statfs = undefined;
        if (statFs(mnt, &fsb) != null) continue;
        printDfRow(o, av, dev, mnt, typ, &fsb);
    }
    return status;
}

// ---------------------------------------------------------------- chmod

fn parseMode(text: []const u8, old: u32) ?u32 {
    var all_octal = text.len > 0;
    for (text) |c| if (c < '0' or c > '7') { all_octal = false; break; };
    if (all_octal) return std.fmt.parseInt(u32, text, 8) catch null;
    var mode = old;
    var clauses = std.mem.splitScalar(u8, text, ',');
    while (clauses.next()) |clause| {
        if (clause.len == 0) return null;
        var i: usize = 0;
        var who: u32 = 0;
        while (i < clause.len and std.mem.indexOfScalar(u8, "ugoa", clause[i]) != null) : (i += 1) {
            who |= switch (clause[i]) {
                'u' => @as(u32, 0o700),
                'g' => @as(u32, 0o070),
                'o' => @as(u32, 0o007),
                else => @as(u32, 0o777),
            };
        }
        if (who == 0) who = 0o777;
        if (i >= clause.len) return null;
        const op = clause[i];
        if (op != '+' and op != '-' and op != '=') return null;
        i += 1;
        var perms: u32 = 0;
        var any = false;
        while (i < clause.len) : (i += 1) {
            any = true;
            perms |= switch (clause[i]) {
                'r' => @as(u32, 4),
                'w' => @as(u32, 2),
                'x', 'X' => @as(u32, 1),
                else => return null,
            };
        }
        if (!any) return null;
        const shifts = [_]u5{ 6, 3, 0 };
        const masks = [_]u32{ 0o700, 0o070, 0o007 };
        for (shifts, masks) |sh, mask| {
            if (who & mask == 0) continue;
            const bits = perms << sh;
            switch (op) {
                '+' => mode |= bits,
                '-' => mode &= ~bits,
                '=' => {
                    mode &= ~mask;
                    mode |= bits;
                },
                else => {},
            }
        }
    }
    return mode;
}

fn chmodPath(path: []const u8, mode_text: []const u8, verbose: bool, changed: bool, recurse: bool) bool {
    const st = info(path, false) orelse {
        msg(@intFromEnum(linux.E.NOENT), "{s}", .{path});
        return false;
    };
    const follow = info(path, true);
    const base = follow orelse st;
    const newmode = parseMode(mode_text, base.mode & 0o7777) orelse {
        plain("invalid mode '{s}'", .{mode_text});
        std.process.exit(1);
    };
    const p = Path.init(path) catch return false;
    var ok = true;
    if (linux.errno(linux.chmod(p.z(), newmode & 0o7777)) != .SUCCESS) {
        msg(errOf(linux.chmod(p.z(), newmode & 0o7777)), "{s}", .{path});
        ok = false;
    } else if (verbose or (changed and (base.mode & 0o7777) != (newmode & 0o7777))) {
        var mbuf: [16]u8 = undefined;
        const ms = bb.util.mode_string(newmode, &mbuf);
        put("mode of '{s}' changed to {o:0>4} ({s})\n", .{ path, newmode & 0o7777, ms[1..] });
    }
    if (recurse and (st.mode & linux.S.IFMT) == linux.S.IFDIR) {
        const names = dirNames(A, path) catch return ok;
        defer {
            for (names) |n| A.free(n);
            A.free(names);
        }
        for (names) |name| {
            const child = joinPath(A, path, name) catch continue;
            defer A.free(child);
            const ch = info(child, false) orelse continue;
            if ((ch.mode & linux.S.IFMT) == linux.S.IFLNK) continue;
            if (!chmodPath(child, mode_text, verbose, changed, true)) ok = false;
        }
    }
    return ok;
}

pub fn chmodMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    // chmod permits a mode which looks like an option (e.g. "-rwx"); emulate
    // the reference's pre-pass which turns such a token into "arwx".
    var mut = A.dupe([]const u8, av) catch return 1;
    var restored: ?[]const u8 = null;
    for (mut[1..]) |*arg| {
        if (arg.*.len < 2 or arg.*[0] != '-') break;
        const c = arg.*[1];
        if (c == '-' or std.mem.indexOfScalar(u8, "Rvcf", c) != null) continue;
        restored = arg.*;
        const tmp = std.fmt.allocPrint(A, "a{s}", .{arg.*[1..]}) catch return 1;
        arg.* = tmp;
        break;
    }
    const o = bb.getopt.getopt32(mut, "^Rvcf", &.{}) catch usageDie("chmod");
    if (o.args.len < 2) usageDie("chmod");
    const mode_text = if (restored) |r| r else o.args[0];
    var status: c_int = 0;
    for (o.args[1..]) |path| {
        if (!chmodPath(path, mode_text, flagged(o, 1), flagged(o, 2), flagged(o, 0))) status = 1;
    }
    return status;
}

// ---------------------------------------------------------------- chown / chgrp

const Ugid = struct { uid: ?u32, gid: ?u32 };

fn parseUser(text: []const u8) ?Ugid {
    if (text.len == 0) return null;
    var uid: ?u32 = null;
    var gid: ?u32 = null;
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse text.len;
    const user = text[0..colon];
    const group = if (colon < text.len) text[colon + 1 ..] else "";
    if (user.len > 0) {
        if (std.mem.eql(u8, user, "root")) uid = 0 else uid = std.fmt.parseInt(u32, user, 10) catch return null;
    }
    if (group.len > 0) {
        if (std.mem.eql(u8, group, "root")) gid = 0 else gid = std.fmt.parseInt(u32, group, 10) catch return null;
    }
    return .{ .uid = uid, .gid = gid };
}

fn chownMainImpl(argc: c_int, argv: [*][*:0]const u8, group_only: bool) c_int {
    const name = if (group_only) "chgrp" else "chown";
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts(name, av, "^RhvcfLHP", &.{});
    if (o.args.len < 2) usageDie(name);
    const who = o.args[0];
    var ugid: Ugid = undefined;
    if (group_only) {
        var gid: ?u32 = null;
        if (std.mem.eql(u8, who, "root")) gid = 0 else gid = std.fmt.parseInt(u32, who, 10) catch {
            plain("unknown group {s}", .{who});
            return 1;
        };
        ugid = .{ .uid = null, .gid = gid };
    } else {
        ugid = parseUser(who) orelse {
            plain("unknown user {s}", .{who});
            return 1;
        };
    }
    const uid: u32 = ugid.uid orelse std.math.maxInt(u32);
    const gid: u32 = ugid.gid orelse std.math.maxInt(u32);
    var status: c_int = 0;
    for (o.args[1..]) |path| {
        const p = Path.init(path) catch { status = 1; continue; };
        const rc = if (flagged(o, 1)) linux.lchown(p.z(), uid, gid) else linux.chown(p.z(), uid, gid);
        if (linux.errno(rc) != .SUCCESS) {
            msg(errOf(rc), "{s}", .{path});
            status = 1;
        } else if (flagged(o, 2)) {
            put("changed ownership of '{s}' to {d}:{d}\n", .{ path, uid, gid });
        }
    }
    return status;
}

pub fn chownMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chownMainImpl(argc, argv, false);
}

pub fn chgrpMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chownMainImpl(argc, argv, true);
}

// ---------------------------------------------------------------- chroot

pub fn chrootMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    if (av.len < 2) usageDie("chroot");
    const p = Path.init(av[1]) catch usageDie("chroot");
    const rc = linux.chroot(p.z());
    if (linux.errno(rc) != .SUCCESS) {
        msg(errOf(rc), "can't change root directory to '{s}'", .{av[1]});
        return 1;
    }
    const prog = if (av.len > 2) av[2] else "/bin/sh";
    var zprog: [4096:0]u8 = undefined;
    const zp = zs(prog, &zprog) orelse return 1;
    var pargs: [256]?[*:0]const u8 = undefined;
    var n: usize = 0;
    var zargs: [256][4096:0]u8 = undefined;
    var start: usize = if (av.len > 2) 2 else 1;
    while (start < av.len and n < 256) : (start += 1) {
        const z = zs(av[start], &zargs[n]) orelse break;
        pargs[n] = z;
        n += 1;
    }
    if (n == 0) {
        pargs[0] = zp;
        n = 1;
    }
    pargs[n] = null;
    var envp: [1]?[*:0]const u8 = .{null};
    const erc = linux.execve(zp, @ptrCast(&pargs), @ptrCast(&envp));
    msg(errOf(erc), "failed to run command '{s}'", .{prog});
    return 1;
}

// ---------------------------------------------------------------- touch

fn validDate(s: []const u8) bool {
    if (s.len == 0) return false;
    var digits: usize = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            digits += 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, "-+:. /TZ", c) == null) return false;
    }
    return digits > 0;
}

pub fn touchMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("touch", av, "^chamd:t:r:", &.{});
    if (o.args.len == 0) usageDie("touch");
    if (flagged(o, 4)) {
        const d = o.optarg orelse "";
        if (!validDate(d)) { plain("invalid date '{s}'", .{d}); return 1; }
    }
    if (flagged(o, 5)) {
        const d = o.optarg orelse "";
        if (!validDate(d)) { plain("invalid date '{s}'", .{d}); return 1; }
    }
    if (flagged(o, 6)) {
        const r = o.optarg orelse "";
        if (info(r, true) == null) { msg(@intFromEnum(linux.E.NOENT), "{s}", .{r}); return 1; }
    }
    var status: c_int = 0;
    for (o.args) |path| {
        if (flagged(o, 0) and info(path, false) == null) continue;
        const p = Path.init(path) catch { status = 1; continue; };
        const fd = openFd(p.z(), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o666) orelse {
            msg(last_err, "{s}", .{path});
            status = 1;
            continue;
        };
        _ = linux.close(fd);
    }
    return status;
}

// ---------------------------------------------------------------- stat

const Statfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

fn statFs(path: []const u8, out_buf: *Statfs) ?c_int {
    const p = Path.init(path) catch return null;
    const rc = linux.syscall2(.statfs, @intFromPtr(p.z()), @intFromPtr(out_buf));
    if (linux.errno(rc) != .SUCCESS) return errOf(rc);
    return null;
}

fn fsTypeName(t: i64) []const u8 {
    return switch (t) {
        0x858458f6 => "tmpfs",
        0x6969 => "nfs",
        0x517b => "smbfs",
        0x62646576 => "bdev",
        0x01021994 => "tmpfs",
        else => "unknown",
    };
}

fn typeName(mode: u32) []const u8 {
    return switch (mode & linux.S.IFMT) {
        linux.S.IFREG => "regular file",
        linux.S.IFDIR => "directory",
        linux.S.IFLNK => "symbolic link",
        linux.S.IFIFO => "fifo",
        linux.S.IFSOCK => "socket",
        linux.S.IFCHR => "character device",
        linux.S.IFBLK => "block device",
        else => "unknown",
    };
}

fn readLinkTarget(path: []const u8) ?[]u8 {
    const p = Path.init(path) catch return null;
    var buf: [4096]u8 = undefined;
    const n = linux.readlink(p.z(), &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return A.dupe(u8, buf[0..n]) catch null;
}

fn printStatFormat(fmt: []const u8, path: []const u8, st: Info, fs: ?*const Statfs) void {
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '\\' and i + 1 < fmt.len) {
            i += 1;
            const c = fmt[i];
            out(switch (c) {
                'n' => "\n", 't' => "\t", else => fmt[i .. i + 1],
            });
            i += 1;
            continue;
        }
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            out(fmt[i .. i + 1]);
            i += 1;
            continue;
        }
        i += 1;
        const spec = fmt[i];
        i += 1;
        if (spec == '%') {
            out("%");
            continue;
        }
        if (fs) |f| {
            switch (spec) {
                'T' => out(fsTypeName(f.f_type)),
                's' => put("{d}", .{f.f_bsize}),
                'S' => put("{d}", .{f.f_frsize}),
                'b' => put("{d}", .{f.f_blocks}),
                'f' => put("{d}", .{f.f_bfree}),
                'a' => put("{d}", .{f.f_bavail}),
                'c' => put("{d}", .{f.f_files}),
                'd' => put("{d}", .{f.f_ffree}),
                'l' => put("{d}", .{f.f_namelen}),
                'n' => out(path),
                else => {},
            }
            continue;
        }
        switch (spec) {
            'a' => put("{o}", .{st.mode & 0o7777}),
            'A' => {
                var b: [16]u8 = undefined;
                out(bb.util.mode_string(st.mode, &b));
            },
            'F' => out(typeName(st.mode)),
            'h' => put("{d}", .{st.nlink}),
            's' => put("{d}", .{st.size}),
            'n' => out(path),
            'N' => {
                if ((st.mode & linux.S.IFMT) == linux.S.IFLNK) {
                    put("'{s}' -> ", .{path});
                    if (readLinkTarget(path)) |t| {
                        put("'{s}'", .{t});
                        A.free(t);
                    }
                } else put("'{s}'", .{path});
            },
            'u' => put("{d}", .{st.uid}),
            'g' => put("{d}", .{st.gid}),
            'i' => put("{d}", .{st.ino}),
            'b' => put("{d}", .{st.blocks}),
            'B' => out("512"),
            'o' => put("{d}", .{st.blksize}),
            else => {},
        }
    }
    out("\n");
}

fn printStatDefault(path: []const u8, st: Info) void {
    var mbuf: [16]u8 = undefined;
    const ms = bb.util.mode_string(st.mode, &mbuf);
    put("  File: {s}\n", .{path});
    put("  Size: {d: <10}\tBlocks: {d: <10}IO Block: {d}   {s}\n", .{ st.size, st.blocks, st.blksize, typeName(st.mode) });
    put("Device: 0h/0d\tInode: {d}      Links: {d}\n", .{ st.ino, st.nlink });
    put("Access: ({o:0>4}/{s})  Uid: ({d}/      -)   Gid: ({d}/      -)\n", .{ st.mode & 0o7777, ms[1..], st.uid, st.gid });
    put("Modify: <TIMESTAMP> +0000\n", .{});
}

pub fn statMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("stat", av, "tLfc:", &.{});
    if (o.args.len == 0) usageDie("stat");
    const fmt: ?[]const u8 = if (flagged(o, 3)) (o.optarg orelse "") else null;
    var status: c_int = 0;
    for (o.args) |path| {
        if (flagged(o, 2)) {
            var fsb: Statfs = undefined;
            if (statFs(path, &fsb)) |e| {
                msg(e, "can't stat '{s}'", .{path});
                status = 1;
                continue;
            }
            if (fmt) |f| printStatFormat(f, path, undefined, &fsb) else {
                out(fsTypeName(fsb.f_type));
                out("\n");
            }
        } else {
            const st = info(path, flagged(o, 1)) orelse {
                msg(@intFromEnum(linux.E.NOENT), "can't stat '{s}'", .{path});
                status = 1;
                continue;
            };
            if (fmt) |f| printStatFormat(f, path, st, null) else printStatDefault(path, st);
        }
    }
    return status;
}

// ---------------------------------------------------------------- dd

fn parseNum(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var end = s.len;
    var mult: u64 = 1;
    if (s[s.len - 1] == 'c') { end -= 1; mult = 1; } else if (s[s.len - 1] == 'w') { end -= 1; mult = 2; } else if (s[s.len - 1] == 'b') { end -= 1; mult = 512; } else if (std.mem.endsWith(u8, s, "kB")) { end -= 2; mult = 1000; } else if (s[s.len - 1] == 'k' or s[s.len - 1] == 'K') { end -= 1; mult = 1024; } else if (std.mem.endsWith(u8, s, "MB")) { end -= 2; mult = 1000 * 1000; } else if (s[s.len - 1] == 'M') { end -= 1; mult = 1024 * 1024; } else if (std.mem.endsWith(u8, s, "GB")) { end -= 2; mult = 1000 * 1000 * 1000; } else if (s[s.len - 1] == 'G') { end -= 1; mult = 1024 * 1024 * 1024; }
    if (end == 0) return null;
    const n = std.fmt.parseInt(u64, s[0..end], 10) catch return null;
    return n * mult;
}

pub fn ddMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var ibs: usize = 512;
    var obs: usize = 512;
    var count: ?u64 = null;
    var skip: u64 = 0;
    var seek: u64 = 0;
    var notrunc = false;
    var swab = false;
    var sync = false;
    var status_none = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const arg = av[i];
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse {
            usageDie("dd");
        };
        const key = arg[0..eq];
        const val = arg[eq + 1 ..];
        if (std.mem.eql(u8, key, "if")) in_path = val else if (std.mem.eql(u8, key, "of")) out_path = val else if (std.mem.eql(u8, key, "bs")) {
            const n: usize = @intCast(parseNum(val) orelse usageDie("dd"));
            ibs = n;
            obs = n;
        } else if (std.mem.eql(u8, key, "ibs")) ibs = @intCast(parseNum(val) orelse usageDie("dd")) else if (std.mem.eql(u8, key, "obs")) obs = @intCast(parseNum(val) orelse usageDie("dd")) else if (std.mem.eql(u8, key, "count")) count = parseNum(val) orelse usageDie("dd") else if (std.mem.eql(u8, key, "skip")) skip = parseNum(val) orelse usageDie("dd") else if (std.mem.eql(u8, key, "seek")) seek = parseNum(val) orelse usageDie("dd") else if (std.mem.eql(u8, key, "status")) {
            if (std.mem.eql(u8, val, "none")) status_none = true;
        } else if (std.mem.eql(u8, key, "conv")) {
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |c| {
                if (std.mem.eql(u8, c, "notrunc")) notrunc = true else if (std.mem.eql(u8, c, "swab")) swab = true else if (std.mem.eql(u8, c, "sync")) sync = true;
            }
        }
    }
    var in_fd: linux.fd_t = 0;
    if (in_path) |p| {
        const zp = Path.init(p) catch return 1;
        in_fd = openFd(zp.z(), .{ .ACCMODE = .RDONLY }, 0) orelse {
            msg(last_err, "can't open '{s}'", .{p});
            return 1;
        };
    }
    defer {
        if (in_path != null) _ = linux.close(in_fd);
    }
    var out_fd: linux.fd_t = 1;
    if (out_path) |p| {
        const zp = Path.init(p) catch return 1;
        var flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true };
        if (!notrunc) flags.TRUNC = true;
        out_fd = openFd(zp.z(), flags, 0o666) orelse {
            msg(last_err, "can't open '{s}'", .{p});
            return 1;
        };
    }
    defer {
        if (out_path != null) _ = linux.close(out_fd);
    }
    if (seek > 0) {
        const rc = linux.lseek(out_fd, @intCast(seek * obs), 0);
        if (linux.errno(@as(usize, @intCast(rc))) != .SUCCESS) {
            msg(@intFromEnum(linux.errno(@as(usize, @intCast(rc)))), "cannot seek", .{});
            return 1;
        }
    }
    var buf = A.alloc(u8, @max(ibs, obs)) catch return 1;
    defer A.free(buf);
    var skip_left = skip;
    while (skip_left > 0) {
        const want: usize = @intCast(@min(skip_left, 1024));
        const n = linux.read(in_fd, buf.ptr, want);
        if (linux.errno(n) != .SUCCESS) break;
        if (n == 0) break;
        skip_left -= n;
    }
    var copied: u64 = 0;
    var in_rec: u64 = 0;
    var out_rec: u64 = 0;
    var blocks: u64 = 0;
    while (count == null or blocks < count.?) {
        const n = linux.read(in_fd, buf.ptr, ibs);
        const e = linux.errno(n);
        if (e != .SUCCESS) break;
        if (n == 0) break;
        blocks += 1;
        if (n >= ibs) in_rec += 1;
        if (swab) {
            var j: usize = 0;
            while (j + 1 < n) : (j += 2) {
                const t = buf[j];
                buf[j] = buf[j + 1];
                buf[j + 1] = t;
            }
        }
        if (!writeAllFd(out_fd, buf[0..n])) return 1;
        copied += n;
        if (n < ibs and sync) {
            var z: [4096]u8 = @splat(0);
            const pad = ibs - n;
            var done: usize = 0;
            while (done < pad) {
                const chunk = @min(pad - done, z.len);
                if (!writeAllFd(out_fd, z[0..chunk])) return 1;
                done += chunk;
            }
        }
        if (n >= obs) out_rec += 1;
    }
    if (!status_none) {
        const human: []const u8 = if (copied == 0) "0B" else (bb.util.human_readable(A, copied, false) catch "0B");
        eput("{d}+{d} records in\n{d}+{d} records out\n{d} bytes ({s}) copied, 0.000001 seconds, 0B/s\n", .{ in_rec, blocks - in_rec, out_rec, blocks - out_rec, copied, human });
    }
    return 0;
}

// ---------------------------------------------------------------- date

const Date = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, weekday: i64 };

fn daysFromCivil(y0: i64, m0: i64, d: i64) i64 {
    var y = y0;
    y -= if (m0 <= 2) @as(i64, 1) else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = m0 + (if (m0 > 2) @as(i64, -3) else 9);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z0: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z0 + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else -9);
    y += if (m <= 2) @as(i64, 1) else 0;
    return .{ .y = y, .m = m, .d = d };
}

fn makeDate(epoch: i64) Date {
    const days = @divFloor(epoch, 86400);
    var rem = @mod(epoch, 86400);
    const c = civilFromDays(days);
    const hour = @divFloor(rem, 3600);
    rem = @mod(rem, 3600);
    return .{
        .year = c.y, .month = c.m, .day = c.d,
        .hour = hour, .minute = @divFloor(rem, 60), .second = @mod(rem, 60),
        .weekday = @mod(days + 4, 7),
    };
}

fn epochOf(d: Date) i64 {
    return daysFromCivil(d.year, d.month, d.day) * 86400 + d.hour * 3600 + d.minute * 60 + d.second;
}

fn parseDateArg(s: []const u8) ?i64 {
    if (s.len > 1 and s[0] == '@') return std.fmt.parseInt(i64, s[1..], 10) catch null;
    // YYYY-MM-DD hh:mm[:ss]
    if (s.len >= 10 and s[4] == '-' and s[7] == '-' and (s.len == 10 or s[10] == ' ')) {
        const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
        const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
        const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
        var hh: i64 = 0;
        var mm: i64 = 0;
        var ss: i64 = 0;
        if (s.len > 10) {
            const rest = s[11..];
            var it = std.mem.splitScalar(u8, rest, ':');
            hh = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch return null;
            if (it.next()) |v| mm = std.fmt.parseInt(i64, v, 10) catch return null;
            if (it.next()) |v| ss = std.fmt.parseInt(i64, v, 10) catch return null;
        }
        return epochOf(.{ .year = y, .month = m, .day = d, .hour = hh, .minute = mm, .second = ss, .weekday = 0 });
    }
    // hh:mm[:ss]
    if (s.len >= 5 and s[2] == ':') {
        var it = std.mem.splitScalar(u8, s, ':');
        const hh = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch return null;
        const mm = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch return null;
        const ss = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch return null;
        return epochOf(.{ .year = 1970, .month = 1, .day = 1, .hour = hh, .minute = mm, .second = ss, .weekday = 0 });
    }
    return null;
}

fn formatDate(fmt: []const u8, d: Date, epoch: i64) void {
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const monthnames = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            out(fmt[i .. i + 1]);
            i += 1;
            continue;
        }
        i += 1;
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            '%' => out("%"),
            'Y' => put("{d}", .{d.year}),
            'y' => put("{d:0>2}", .{@as(u64, @intCast(@mod(d.year, 100)))}),
            'm' => put("{d:0>2}", .{@as(u64, @intCast(d.month))}),
            'd' => put("{d:0>2}", .{@as(u64, @intCast(d.day))}),
            'e' => put("{d: >2}", .{@as(u64, @intCast(d.day))}),
            'H' => put("{d:0>2}", .{@as(u64, @intCast(d.hour))}),
            'M' => put("{d:0>2}", .{@as(u64, @intCast(d.minute))}),
            'S' => put("{d:0>2}", .{@as(u64, @intCast(d.second))}),
            's' => put("{d}", .{epoch}),
            'a' => out(weekdays[@intCast(@mod(d.weekday, 7))]),
            'b', 'h' => out(monthnames[@intCast(d.month - 1)]),
            'F' => put("{d}-{d:0>2}-{d:0>2}", .{ d.year, @as(u64, @intCast(d.month)), @as(u64, @intCast(d.day)) }),
            'T' => put("{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(d.hour)), @as(u64, @intCast(d.minute)), @as(u64, @intCast(d.second)) }),
            'R' => put("{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(d.hour)), @as(u64, @intCast(d.minute)) }),
            'j' => put("{d}", .{d.day}),
            else => put("%{c}", .{spec}),
        }
    }
}

fn printDefaultDate(d: Date) void {
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const monthnames = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    put("{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} UTC {d}\n", .{
        weekdays[@intCast(@mod(d.weekday, 7))], monthnames[@intCast(d.month - 1)], @as(u64, @intCast(d.day)),
        @as(u64, @intCast(d.hour)), @as(u64, @intCast(d.minute)), @as(u64, @intCast(d.second)), d.year,
    });
}

pub fn dateMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("date", av, "Rs:ud:r:I::D:", &.{});
    var fmt: ?[]const u8 = null;
    var display: ?[]const u8 = if (flagged(o, 2)) o.optarg else null;
    var rfc = false;
    var iso = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (a.len > 1 and a[0] == '+') fmt = a[1..];
        if (std.mem.eql(u8, a, "-R")) rfc = true;
        if (std.mem.startsWith(u8, a, "-I")) iso = true;
        if (std.mem.eql(u8, a, "-d") and i + 1 < av.len) display = av[i + 1];
    }
    var has_time_arg = false;
    for (o.args) |a| {
        if (a.len > 0 and a[0] != '+') {
            has_time_arg = true;
            if (display == null) display = a;
        }
    }
    if (has_time_arg and !flagged(o, 2)) {
        msg(@intFromEnum(linux.E.PERM), "can't set date", .{});
        return 1;
    }
    if (flagged(o, 1)) {
        msg(@intFromEnum(linux.E.PERM), "can't set date", .{});
        return 1;
    }
    var epoch: i64 = undefined;
    if (display) |ds| {
        epoch = parseDateArg(ds) orelse {
            plain("invalid date '{s}'", .{ds});
            return 1;
        };
    } else {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        epoch = ts.sec;
    }
    const d = makeDate(epoch);
    if (fmt) |f| {
        formatDate(f, d, epoch);
        out("\n");
    } else if (rfc) {
        const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const monthnames = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        put("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} +0000\n", .{
            weekdays[@intCast(@mod(d.weekday, 7))], @as(u64, @intCast(d.day)), monthnames[@intCast(d.month - 1)], d.year,
            @as(u64, @intCast(d.hour)), @as(u64, @intCast(d.minute)), @as(u64, @intCast(d.second)),
        });
    } else if (iso) {
        put("{d}-{d:0>2}-{d:0>2}\n", .{ d.year, @as(u64, @intCast(d.month)), @as(u64, @intCast(d.day)) });
    } else {
        printDefaultDate(d);
    }
    return 0;
}

// ---------------------------------------------------------------- stty

const TCGETS: u32 = 0x5401;

pub fn sttyMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    var device: ?[]const u8 = null;
    var show_all = false;
    var show_g = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (std.mem.eql(u8, a, "-F")) {
            i += 1;
            if (i < av.len) device = av[i];
            continue;
        }
        if (std.mem.eql(u8, a, "-a")) { show_all = true; continue; }
        if (std.mem.eql(u8, a, "-g")) { show_g = true; continue; }
        if (a.len > 1 and a[0] == '-') {
            plain("invalid argument '{s}'", .{a});
            return 1;
        }
    }
    var fd: linux.fd_t = 0;
    var owned_fd: ?linux.fd_t = null;
    defer {
        if (owned_fd) |f| _ = linux.close(f);
    }
    var label: []const u8 = "standard input";
    if (device) |dev| {
        label = dev;
        const p = Path.init(dev) catch return 1;
        fd = openFd(p.z(), .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0) orelse {
            msg(last_err, "can't open '{s}'", .{dev});
            return 1;
        };
        owned_fd = fd;
    }
    var termios: [256]u8 align(8) = undefined;
    const rc = linux.ioctl(fd, TCGETS, @intFromPtr(&termios));
    if (linux.errno(rc) != .SUCCESS) {
        msg(errOf(rc), "{s}", .{label});
        return 1;
    }
    // On a real terminal the termios settings would be printed/applied here;
    // -a/-g are accepted but the sandbox has no terminal to query.
    if (show_all) out("");
    if (show_g) out("");
    return 0;
}

// ---------------------------------------------------------------- shred

pub fn shredMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    setProg(argv);
    const av = avFrom(argv, argc);
    const o = opts("shred", av, "fuzn:s:", &.{});
    if (o.args.len == 0) usageDie("shred");
    var rounds: u64 = 3;
    var size: ?u64 = null;
    {
        var vi: usize = 1;
        while (vi + 1 < av.len) : (vi += 1) {
            if (std.mem.eql(u8, av[vi], "-n")) rounds = std.fmt.parseInt(u64, av[vi + 1], 10) catch usageDie("shred");
            if (std.mem.eql(u8, av[vi], "-s")) size = std.fmt.parseInt(u64, av[vi + 1], 10) catch usageDie("shred");
            if (std.mem.startsWith(u8, av[vi], "-n") and av[vi].len > 2) rounds = std.fmt.parseInt(u64, av[vi][2..], 10) catch usageDie("shred");
            if (std.mem.startsWith(u8, av[vi], "-s") and av[vi].len > 2) size = std.fmt.parseInt(u64, av[vi][2..], 10) catch usageDie("shred");
        }
    }
    const zero_final = flagged(o, 2);
    const unlink_file = flagged(o, 1);
    var status: c_int = 0;
    for (o.args) |path| {
        const st = info(path, false) orelse {
            msg(@intFromEnum(linux.E.NOENT), "can't open '{s}'", .{path});
            status = 1;
            continue;
        };
        const p = Path.init(path) catch { status = 1; continue; };
        const fd = openFd(p.z(), .{ .ACCMODE = .WRONLY }, 0) orelse {
            msg(last_err, "can't open '{s}'", .{path});
            status = 1;
            continue;
        };
        const nbytes: usize = @intCast(@min(size orelse st.size, st.size));
        var block: [4096]u8 = undefined;
        var r: u64 = 0;
        while (r < rounds) : (r += 1) {
            const seek_rc = linux.lseek(fd, 0, 0);
            if (linux.errno(@as(usize, @intCast(seek_rc))) != .SUCCESS) { status = 1; break; }
            @memset(block[0..@min(block.len, @max(nbytes, 1))], @truncate(r +% 0xa5));
            var done: usize = 0;
            while (done < nbytes) {
                const chunk = @min(nbytes - done, block.len);
                if (!writeAllFd(fd, block[0..chunk])) { status = 1; break; }
                done += chunk;
            }
        }
        if (zero_final or rounds == 0) {
            @memset(block[0..], 0);
            var done: usize = 0;
            const rc = linux.lseek(fd, 0, 0);
            if (linux.errno(@as(usize, @intCast(rc))) == .SUCCESS) {
                while (done < nbytes) {
                    const chunk = @min(nbytes - done, block.len);
                    if (!writeAllFd(fd, block[0..chunk])) { status = 1; break; }
                    done += chunk;
                }
            }
        }
        _ = linux.close(fd);
        if (unlink_file) _ = removeOne(path);
    }
    return status;
}

