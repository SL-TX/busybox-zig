//! tree — list directories as a tree (reference miscutils/tree.c).
//! The reference has no option parsing at all: every argument is a directory
//! path. Hidden names (leading '.') are skipped, entries are sorted, and the
//! final line reports directory/file counts.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

const Counts = struct { dirs: usize = 0, files: usize = 0 };
const Entry = struct { name: []u8, kind: u16 };

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn kindOf(a: std.mem.Allocator, path: []const u8) u16 {
    const z = c.zstr(a, path) catch return 0;
    defer a.free(z);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z.ptr, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return @truncate(st.mode & @as(u32, linux.S.IFMT));
}

fn linkTarget(a: std.mem.Allocator, path: []const u8) []const u8 {
    const z = c.zstr(a, path) catch return "";
    defer a.free(z);
    var buf: [4096]u8 = undefined;
    const n = linux.readlink(z.ptr, &buf, buf.len);
    if (linux.errno(n) == .SUCCESS and n > 0) return a.dupe(u8, buf[0..n]) catch "";
    return "";
}

fn printTree(a: std.mem.Allocator, path: []const u8, display: []const u8, prefix: []const u8, counts: *Counts) void {
    const pz = c.zstr(a, path) catch return;
    defer a.free(pz);
    const fd_rc = linux.open(pz.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) {
        c.printfOut("{s} [error opening dir]\n", .{display});
        return;
    }
    const fd: linux.fd_t = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| a.free(e.name);
        entries.deinit(a);
    }
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var pos: usize = 0;
        while (pos + 19 <= n) {
            const reclen = std.mem.readInt(u16, buf[pos + 16 ..][0..2], .native);
            if (reclen < 19 or pos + reclen > n) break;
            const name_bytes = buf[pos + 19 .. pos + reclen];
            const name_len = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
            if (name_len > 0 and name_bytes[0] != '.') {
                const name = a.dupe(u8, name_bytes[0..name_len]) catch break;
                const full = std.fmt.allocPrint(a, "{s}/{s}", .{ path, name }) catch {
                    a.free(name);
                    break;
                };
                const kind = kindOf(a, full);
                a.free(full);
                entries.append(a, .{ .name = name, .kind = kind }) catch break;
            }
            pos += reclen;
        }
    }
    std.mem.sort(Entry, entries.items, {}, lessThan);

    c.printfOut("{s}\n", .{display});

    for (entries.items, 0..) |entry, idx| {
        const last = idx + 1 == entries.items.len;
        const branch = if (last) "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 " else "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ";
        c.out(prefix);
        c.out(branch);

        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name }) catch {
            c.printfOut("{s}\n", .{entry.name});
            counts.files += 1;
            continue;
        };
        defer a.free(full);

        if (entry.kind == linux.S.IFDIR) {
            const bar = if (last) "    " else "\xe2\x94\x82   ";
            const next = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, bar }) catch continue;
            defer a.free(next);
            printTree(a, full, entry.name, next, counts);
            counts.dirs += 1;
        } else if (entry.kind == linux.S.IFLNK) {
            const target = linkTarget(a, full);
            c.printfOut("{s} -> {s}\n", .{ entry.name, target });
            counts.files += 1;
        } else {
            c.printfOut("{s}\n", .{entry.name});
            counts.files += 1;
        }
    }
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    var counts = Counts{};
    if (args.len <= 1) {
        printTree(a, ".", ".", "", &counts);
    } else {
        for (args[1..]) |path| printTree(a, path, path, "", &counts);
    }
    c.printfOut("\n{d} directories, {d} files\n", .{ counts.dirs, counts.files });
    return 0;
}
