//! sysctl — port of procps/sysctl.c (read, write and -p/-a paths).

const std = @import("std");
const c = @import("common.zig");

const SHOW_KEYS: u32 = 1 << 0;
const SHOW_KEY_ERRORS: u32 = 1 << 1;
const SHOW_ALL: u32 = 1 << 3;
const PRELOAD: u32 = 1 << 4;
const WRITE: u32 = 1 << 5;
const QUIET: u32 = 1 << 6;

var flags: u32 = 0;

fn dotted(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try a.dupe(u8, path);
    for (out) |*ch| {
        if (ch.* == '/') ch.* = '.' else if (ch.* == '.') ch.* = '/';
    }
    return out;
}

fn showName(a: std.mem.Allocator, setting: []const u8) []const u8 {
    return dotted(a, setting) catch setting;
}

fn exists(path: []const u8) bool {
    const z = c.zstr(std.heap.page_allocator, path) catch return false;
    defer std.heap.page_allocator.free(z);
    const rc = std.os.linux.access(z.ptr, std.os.linux.F_OK);
    return std.os.linux.errno(rc) == .SUCCESS;
}

/// Convert a dotted key to the deepest existing /proc/sys path, like
/// sysctl_dots_to_slashes(). Returns the path relative to /proc/sys.
fn keyPath(a: std.mem.Allocator, key: []const u8) []const u8 {
    var out = a.dupe(u8, key) catch return key;
    const first_dot = std.mem.indexOfScalar(u8, out, '.');
    const first_slash = std.mem.indexOfScalar(u8, out, '/');
    if (first_dot != null and first_slash != null and first_dot.? < first_slash.?) {
        for (out) |*ch| {
            if (ch.* == '.') ch.* = '/' else if (ch.* == '/') ch.* = '.';
        }
        return out;
    }
    // Try replacing dots from the right until the path exists.
    var positions: [64]usize = undefined;
    var n: usize = 0;
    for (out, 0..) |ch, idx| {
        if (ch == '.' and n < positions.len) {
            positions[n] = idx;
            n += 1;
        }
    }
    var count = n;
    while (count > 0) {
        count -= 1;
        const pos = positions[count];
        out[pos] = '/';
        const full = std.fmt.allocPrint(a, "/proc/sys/{s}", .{out}) catch break;
        defer a.free(full);
        if (exists(full)) return out;
        out[pos] = '.';
    }
    return out;
}

/// `setting` is already in the formBusyBox passes to sysctl_act_on_setting():
/// argv keys have had dots converted, recursive -a keys have not.
fn actOne(a: std.mem.Allocator, setting: []const u8) u8 {
    const eqpos = std.mem.indexOfScalar(u8, setting, '=');
    const writing = (flags & WRITE != 0) or eqpos != null;
    const name = if (eqpos) |p| setting[0..p] else setting;
    const value = if (eqpos) |p| setting[p + 1 ..] else "";
    const outname = showName(a, name);
    defer a.free(outname);
    const rel = keyPath(a, name);
    defer a.free(rel);
    const full = std.fmt.allocPrint(a, "/proc/sys/{s}", .{rel}) catch return 1;
    defer a.free(full);

    if (writing) {
        if (eqpos == null) {
            c.plainMsg("error: '{s}' must be of the form name=value", .{outname});
            return 1;
        }
        if (eqpos.? == 0) {
            c.plainMsg("error: malformed setting '{s}'", .{outname});
            return 1;
        }
        const z = c.zstr(a, full) catch return 1;
        defer a.free(z);
        const fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
        const e = std.os.linux.errno(fd);
        if (e != .SUCCESS) {
            if (e == .NOENT and flags & SHOW_KEY_ERRORS != 0) {
                c.plainMsg("error: '{s}' is an unknown key", .{outname});
            }
            return 1;
        }
        const fdi: std.os.linux.fd_t = @intCast(fd);
        _ = std.os.linux.write(fdi, value.ptr, value.len);
        _ = std.os.linux.close(fdi);
        if (flags & QUIET == 0) {
            if (flags & SHOW_KEYS != 0) c.printfOut("{s} = ", .{outname});
            c.printfOut("{s}\n", .{value});
        }
        return 0;
    }

    const zr = c.zstr(a, full) catch return 1;
    defer a.free(zr);
    const rfd = std.os.linux.open(zr.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const re = std.os.linux.errno(rfd);
    if (re != .SUCCESS) {
        if (re == .ACCES) return 0; // write-only setting: reference stays silent
        if (flags & SHOW_KEY_ERRORS != 0) c.plainMsg("error: '{s}' is an unknown key", .{outname});
        return 1;
    }
    const rfd_t: std.os.linux.fd_t = @intCast(rfd);
    defer _ = std.os.linux.close(rfd_t);
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(a);
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const got = std.os.linux.read(rfd_t, &rbuf, rbuf.len);
        if (std.os.linux.errno(got) != .SUCCESS or got == 0) break;
        collected.appendSlice(a, rbuf[0..got]) catch break;
    }
    const data: []const u8 = collected.items;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        if (flags & SHOW_KEYS != 0) c.printfOut("{s} = ", .{outname});
        c.printfOut("{s}\n", .{line});
    }
    return 0;
}

fn walk(a: std.mem.Allocator, path: []const u8, rel: []const u8) u8 {
    const z = c.zstr(a, path) catch return 0;
    defer a.free(z);
    const fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (std.os.linux.errno(fd) != .SUCCESS) return actOne(a, rel);
    const fdi: std.os.linux.fd_t = @intCast(fd);
    defer _ = std.os.linux.close(fdi);
    var ret: u8 = 0;
    var buf: [16384]u8 align(8) = undefined;
    const noff = @offsetOf(std.os.linux.dirent64, "name");
    const n = std.os.linux.getdents64(fdi, &buf, buf.len);
    if (std.os.linux.errno(n) != .SUCCESS) return 0;
    var off: usize = 0;
    while (off + noff <= n) {
        const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
        if (dent.reclen == 0) break;
        const raw = buf[off + noff ..][0 .. dent.reclen - noff];
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        const name = raw[0..end];
        off += dent.reclen;
        if (name.len == 0 or name[0] == '.') continue;
        const child_rel = if (rel.len == 0 or std.mem.eql(u8, rel, "."))
            a.dupe(u8, name) catch continue
        else
            std.fmt.allocPrint(a, "{s}/{s}", .{ rel, name }) catch continue;
        defer a.free(child_rel);
        const child_path = std.fmt.allocPrint(a, "{s}/{s}", .{ path, name }) catch continue;
        defer a.free(child_path);
        ret |= walk(a, child_path, child_rel);
    }
    return ret;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                'n' => flags |= SHOW_KEYS,
                'e' => flags |= SHOW_KEY_ERRORS,
                'A' => flags |= SHOW_ALL,
                'a' => flags |= SHOW_ALL,
                'p' => flags |= PRELOAD,
                'w' => flags |= WRITE,
                'q' => flags |= QUIET,
                else => {
                    c.plainMsg("invalid option -- '{c}'", .{tok[j]});
                    c.usageDie(prog);
                },
            }
        }
    }
    flags ^= SHOW_KEYS | SHOW_KEY_ERRORS;

    if (flags & PRELOAD != 0) {
        const start = if (i < av.len) i else blk: {
            // default file, handled below as a single positional
            break :blk i;
        };
        var k: usize = start;
        while (k < av.len) : (k += 1) {
            const file = if (start == i and i >= av.len) "/etc/sysctl.conf" else av[k];
            const data = c.readFile(a, file) orelse {
                var e: c_int = 2;
                const z = c.zstr(a, file) catch return 0;
                defer a.free(z);
                const fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
                if (std.os.linux.errno(fd) != .SUCCESS) e = @intFromEnum(std.os.linux.errno(fd));
                c.errorMsg(e, "{s}", .{file});
                continue;
            };
            defer a.free(data);
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                _ = actOne(a, trimmed);
            }
        }
        if (i >= av.len) {
            const data = c.readFile(a, "/etc/sysctl.conf") orelse return 0;
            defer a.free(data);
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                _ = actOne(a, trimmed);
            }
        }
        return 0;
    }

    if (flags & SHOW_ALL != 0) {
        return @intCast(walk(a, "/proc/sys", "."));
    }

    var ret: u8 = 0;
    while (i < av.len) : (i += 1) {
        // sysctl_main() calls sysctl_dots_to_slashes() on every argv key.
        const converted = keyPath(a, av[i]);
        defer a.free(converted);
        ret |= actOne(a, converted);
    }
    return ret;
}
