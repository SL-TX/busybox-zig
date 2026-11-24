//! Mount-table helpers ported from busybox libbb/mtab.c and
//! find_mount_point.c. Works on any mtab-formatted file (including a temp
//! file in tests) rather than hard-coding /etc/mtab.

const std = @import("std");
const io = @import("io.zig");
const file = @import("file.zig");

pub const Entry = struct {
    fsname: []u8,
    dir: []u8,
    type: []u8,
    opts: []u8,
    freq: i32,
    passno: i32,
};

/// Decode the octal escapes mtab uses for whitespace in mount-point names.
fn unescape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 3 < s.len) {
            const d1 = std.fmt.charToDigit(s[i + 1], 8) catch {
                try out.append(a, s[i]);
                i += 1;
                continue;
            };
            const d2 = std.fmt.charToDigit(s[i + 2], 8) catch {
                try out.append(a, s[i]);
                i += 1;
                continue;
            };
            try out.append(a, d1 * 8 + d2);
            i += 3;
            continue;
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn readAll(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try io.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer io.close(fd) catch {};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try io.read(fd, &buf);
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

pub fn readMountTable(a: std.mem.Allocator, path: []const u8) ![]Entry {
    const data = try readAll(a, path);
    defer a.free(data);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| freeEntry(a, e);
        entries.deinit(a);
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const fsname = fields.next() orelse continue;
        const dir = fields.next() orelse continue;
        const typ = fields.next() orelse continue;
        const opts = fields.next() orelse continue;
        const freq_s = fields.next() orelse "0";
        const pass_s = fields.next() orelse "0";
        try entries.append(a, .{
            .fsname = try unescape(a, fsname),
            .dir = try unescape(a, dir),
            .type = try unescape(a, typ),
            .opts = try unescape(a, opts),
            .freq = std.fmt.parseInt(i32, freq_s, 10) catch 0,
            .passno = std.fmt.parseInt(i32, pass_s, 10) catch 0,
        });
    }
    return entries.toOwnedSlice(a);
}

fn freeEntry(a: std.mem.Allocator, e: Entry) void {
    a.free(e.fsname);
    a.free(e.dir);
    a.free(e.type);
    a.free(e.opts);
}

pub fn freeEntries(a: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| freeEntry(a, e);
    a.free(entries);
}

/// Remove every entry whose device or mount point equals `name`, rewriting
/// the table in the standard six-field mtab format.
pub fn eraseMtab(a: std.mem.Allocator, path: []const u8, name: []const u8) !void {
    const entries = try readMountTable(a, path);
    defer freeEntries(a, entries);

    const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer io.close(fd) catch {};

    var buf: [4096]u8 = undefined;
    for (entries) |e| {
        if (std.mem.eql(u8, e.fsname, name) or std.mem.eql(u8, e.dir, name)) continue;
        const line = try std.fmt.bufPrint(&buf, "{s} {s} {s} {s} {d} {d}\n", .{ e.fsname, e.dir, e.type, e.opts, e.freq, e.passno });
        try io.writeAll(fd, line);
    }
}

/// Longest mount-point prefix of `path` (re-export of the filesystem helper).
pub fn findMountPoint(path: []const u8) ?[]const u8 {
    return file.findMountPoint(path);
}
