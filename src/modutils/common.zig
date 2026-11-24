//! Shared helpers for the modutils applets (reference: modprobe-small.c,
//! modinfo.c). Metadata is parsed from module bytes; nothing loads a real
//! kernel module unless the init_module/delete_module syscall says so.

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

pub fn err(rc: usize) c_int {
    return @intFromEnum(linux.errno(rc));
}

pub fn strerror(e: c_int) []const u8 {
    return switch (e) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        3 => "No such process",
        8 => "Exec format error",
        12 => "Cannot allocate memory",
        13 => "Permission denied",
        22 => "Invalid argument",
        25 => "Inappropriate ioctl for device",
        38 => "Function not implemented",
        95 => "Operation not supported",
        else => "Unknown error",
    };
}

pub fn zstr(s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(A, u8, &.{s}, 0);
}

pub fn readFile(path: []const u8) ?[]u8 {
    const p = zstr(path) catch return null;
    defer A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(A);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(A, buf[0..n]) catch break;
    }
    return list.toOwnedSlice(A) catch null;
}

pub fn readFileErr(path: []const u8) struct { data: ?[]u8, errno: c_int } {
    const p = zstr(path) catch return .{ .data = null, .errno = 22 };
    defer A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return .{ .data = null, .errno = err(rc) };
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(A, buf[0..n]) catch break;
    }
    return .{ .data = list.toOwnedSlice(A) catch null, .errno = 0 };
}

pub fn chdir(path: []const u8) bool {
    const p = zstr(path) catch return false;
    defer A.free(p);
    return linux.errno(linux.chdir(p)) == .SUCCESS;
}

pub fn chdirErr(path: []const u8) c_int {
    const p = zstr(path) catch return 22;
    defer A.free(p);
    return err(linux.chdir(p));
}

pub fn unameRelease() []const u8 {
    const u = std.posix.uname();
    return A.dupe(u8, std.mem.sliceTo(&u.release, 0)) catch "unknown";
}

fn statMode(path: []const u8) ?u16 {
    const p = zstr(path) catch return null;
    defer A.free(p);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return st.mode;
}

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
            if (name_len > 0 and !isDot(name_bytes[0..name_len])) {
                list.append(A, A.dupe(u8, name_bytes[0..name_len]) catch return list.toOwnedSlice(A) catch &.{}) catch
                    return list.toOwnedSlice(A) catch &.{};
            }
            pos += reclen;
        }
    }
    return list.toOwnedSlice(A) catch &.{};
}

fn isDot(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

pub fn isDir(path: []const u8) bool {
    const mode = statMode(path) orelse return false;
    return (mode & linux.S.IFMT) == linux.S.IFDIR;
}

fn findKeyword(image: []const u8, word: []const u8) ?[]const u8 {
    if (image.len < word.len) return null;
    var pos: usize = 0;
    while (pos + word.len <= image.len) {
        const hit = std.mem.indexOfPos(u8, image, pos, word) orelse return null;
        if (std.mem.startsWith(u8, image[hit..], word)) return image[hit + word.len ..];
        pos = hit + 1;
    }
    return null;
}

fn cString(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

/// Metadata extracted from a module image (modprobe-small's parse_module()).
pub const ModuleInfo = struct {
    pathname: []const u8,
    aliases: []const u8 = "",
    deps: []const u8 = "",
};

fn undash(s: []const u8) []u8 {
    const result = A.dupe(u8, s) catch return @constCast(s);
    for (result) |*ch| {
        if (ch.* == '-') ch.* = '_';
    }
    return result;
}

pub fn parseModule(pathname: []const u8, image: []const u8) ModuleInfo {
    var aliases: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos <= image.len) {
        var after = findKeyword(image[pos..], "alias=");
        var is_symbol = false;
        if (after == null) {
            after = findKeyword(image[pos..], "__ksymtab_");
            if (after == null) break;
            const sym = cString(after.?);
            if (std.mem.eql(u8, sym, "gpl") or std.mem.eql(u8, sym, "strings")) {
                const consumed = (@intFromPtr(sym.ptr) - @intFromPtr(image.ptr)) + 1;
                pos = @min(consumed, image.len);
                continue;
            }
            is_symbol = true;
        }
        const text = cString(after.?);
        const consumed = (@intFromPtr(text.ptr) - @intFromPtr(image.ptr)) + text.len + 1;
        const alias = if (is_symbol) std.fmt.allocPrint(A, "symbol:{s}", .{text}) catch text else text;
        // Drop exact duplicates (modprobe-small does the same).
        var duplicate = false;
        if (aliases.items.len > 0) {
            var it = std.mem.splitScalar(u8, aliases.items, ' ');
            while (it.next()) |prev| {
                if (prev.len > 0 and std.mem.eql(u8, prev, alias)) duplicate = true;
            }
        }
        if (!duplicate) {
            aliases.appendSlice(A, alias) catch {};
            aliases.append(A, ' ') catch {};
        }
        pos = @min(consumed, image.len);
    }
    if (aliases.items.len > 0) _ = aliases.pop();
    const alias_str = undash(aliases.items);
    var deps: []const u8 = "";
    if (findKeyword(image, "depends=")) |d| {
        const text = cString(d);
        const buf: []u8 = A.dupe(u8, text) catch return .{ .pathname = pathname };
        for (buf) |*ch| {
            if (ch.* == ',') ch.* = ' ';
            if (ch.* == '-') ch.* = '_';
        }
        deps = buf;
    }
    return .{ .pathname = pathname, .aliases = alias_str, .deps = deps };
}

/// modules.dep.bb record writer (modprobe-small's write_out_dep_bb()).
pub fn writeDepRecord(buf: *std.ArrayList(u8), info: ModuleInfo) void {
    buf.appendSlice(A, info.pathname) catch {};
    if (info.aliases.len > 0) buf.append(A, ' ') catch {};
    buf.appendSlice(A, info.aliases) catch {};
    buf.append(A, '\n') catch {};
    buf.appendSlice(A, info.deps) catch {};
    if (info.deps.len > 0) buf.append(A, '\n') catch {};
    buf.append(A, '\n') catch {};
}

/// Shell-style '*'/'?' matching, enough for module aliases.
pub fn fnmatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star = pi;
            pi += 1;
            mark = ti;
        } else if (star) |s| {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}
