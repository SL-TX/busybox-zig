//! fuser — port of procps/fuser.c.
//!
//! Options are not cosmetic: -m matches by device only, -4/-6 filter the
//! socket table by address family, -s suppresses PIDs and -k signals matches.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

const A = std.heap.page_allocator;
const FileId = c.FileId;

const Opts = struct {
    mount: bool = false,
    silent: bool = false,
    kill: bool = false,
    ip4: bool = false,
    ip6: bool = false,
    signo: c_int = 9, // SIGKILL
};

fn addId(list: *std.ArrayList(FileId), id: FileId) void {
    for (list.items) |existing| {
        if (existing.dev_major == id.dev_major and existing.dev_minor == id.dev_minor and existing.inode == id.inode) return;
    }
    list.append(A, id) catch {};
}

fn matches(list: []const FileId, id: FileId, mount: bool) bool {
    for (list) |want| {
        if (want.dev_major != id.dev_major or want.dev_minor != id.dev_minor) continue;
        if (mount or want.inode == id.inode) return true;
    }
    return false;
}

/// Read a /proc/net/{tcp,tcp6,udp,udp6} table and collect inodes of sockets
/// bound to `port`, honouring -4/-6 (address text length 8 vs >8).
fn scanProcNet(path: []const u8, port: u64, opts: Opts, ids: *std.ArrayList(FileId)) void {
    // The family comes from the table itself: /proc/net/tcp6 and udp6 hold
    // 32-hex-digit addresses, tcp/udp hold 8-hex-digit addresses. Deriving it
    // from the port text (4 chars) or colon count is always wrong.
    const v6_table = std.mem.endsWith(u8, path, "6");
    const data = c.readFile(A, path) orelse return;
    defer A.free(data);
    var socket_dev = FileId{ .dev_major = 0, .dev_minor = 0, .inode = 0 };
    // A fresh datagram socket gives the sockfs device used for fd matching.
    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (linux.errno(fd) != .SUCCESS) {
        socket_dev = .{ .dev_major = 0, .dev_minor = 0, .inode = 0 };
    } else {
        const fpath = std.fmt.allocPrint(A, "/proc/self/fd/{d}", .{fd}) catch return;
        defer A.free(fpath);
        if (c.fileId(fpath)) |sid| socket_dev = sid;
        _ = linux.close(@intCast(fd));
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        var fields: [10][]const u8 = undefined;
        var count: usize = 0;
        while (it.next()) |tok| {
            if (count < fields.len) {
                fields[count] = tok;
                count += 1;
            }
        }
        if (count < 10) continue;
        const local = fields[1];
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        if (std.fmt.parseInt(u64, local[colon + 1 ..], 16) catch continue != port) continue;
        const addr_hex = local[0..colon];
        const is_v6 = v6_table or addr_hex.len == 32;
        if ((opts.ip4 and is_v6) or (opts.ip6 and !is_v6)) continue;
        // /proc/net/tcp fields: sl, local, rem, st, tx:rx, tr:tm, retrnsmt,
        // uid, timeout, inode, ...  The inode is token 9.
        if (count >= 10) {
            const inode = std.fmt.parseInt(u64, fields[9], 10) catch 0;
            if (inode != 0) addId(ids, .{
                .dev_major = socket_dev.dev_major,
                .dev_minor = socket_dev.dev_minor,
                .inode = inode,
            });
        }
    }
}

fn scanMaps(pid: i32, ids: []const FileId, mount: bool) bool {
    const path = c.procPath(A, pid, "maps") catch return false;
    defer A.free(path);
    const data = c.readFile(A, path) orelse return false;
    defer A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next() orelse continue; // address range
        _ = it.next() orelse continue; // mode
        _ = it.next() orelse continue; // offset
        const dev = it.next() orelse continue;
        const inode_s = it.next() orelse continue;
        const colon = std.mem.indexOfScalar(u8, dev, ':') orelse continue;
        const maj = std.fmt.parseInt(u32, dev[0..colon], 16) catch continue;
        const min = std.fmt.parseInt(u32, dev[colon + 1 ..], 16) catch continue;
        const ino = std.fmt.parseInt(u64, inode_s, 10) catch continue;
        // procps ignores "unallocated" map entries (major or minor zero).
        if (maj == 0 or min == 0 or ino == 0) continue;
        if (matches(ids, .{ .dev_major = maj, .dev_minor = min, .inode = ino }, mount)) return true;
    }
    return false;
}

fn scanLink(path: []const u8, ids: []const FileId, mount: bool) bool {
    if (c.fileId(path)) |id| return matches(ids, id, mount);
    return false;
}

fn scanDirLinks(dir_path: []const u8, ids: []const FileId, mount: bool) bool {
    const z = c.zstr(A, dir_path) catch return false;
    defer A.free(z);
    const rc = linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    const noff = @offsetOf(linux.dirent64, "name");
    const n = linux.getdents64(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return false;
    var off: usize = 0;
    while (off + noff <= @as(usize, @intCast(n))) {
        const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
        if (dent.reclen == 0) break;
        const raw = buf[off + noff ..][0 .. dent.reclen - noff];
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        const name = raw[0..end];
        off += dent.reclen;
        if (name.len == 0 or name[0] == '.') continue;
        const full = std.fmt.allocPrint(A, "{s}/{s}", .{ dir_path, name }) catch continue;
        defer A.free(full);
        if (scanLink(full, ids, mount)) return true;
    }
    return false;
}

fn processUses(pid: i32, ids: []const FileId, opts: Opts) bool {
    if (scanMaps(pid, ids, opts.mount)) return true;
    const tails = [_][]const u8{ "cwd", "exe", "root", "fd", "lib", "mmap" };
    for (tails) |tail| {
        const path = c.procPath(A, pid, tail) catch continue;
        defer A.free(path);
        if (std.mem.eql(u8, tail, "fd") or std.mem.eql(u8, tail, "lib") or std.mem.eql(u8, tail, "mmap")) {
            if (scanDirLinks(path, ids, opts.mount)) return true;
        } else if (scanLink(path, ids, opts.mount)) return true;
    }
    return false;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const av = c.argsFrom(A, argv, argc) catch return 1;
    defer A.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var opts = Opts{};
    var i: usize = 1;
    // BusyBox scans for -SIGNAL first and removes it from argv.
    while (i < av.len) : (i += 1) {
        const arg = av[i];
        if (arg.len < 2 or arg[0] != '-') continue;
        if (std.mem.eql(u8, arg, "--")) break;
        if ((arg.len == 2 and (arg[1] == '4' or arg[1] == '6'))) continue;
        if (c.getSignum(arg[1..])) |sig| {
            opts.signo = sig;
            var j = i;
            while (j + 1 < av.len) : (j += 1) av[j] = av[j + 1];
            av[av.len - 1] = "";
            break;
        }
    }

    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(A);
    for (av[1..]) |arg| {
        if (arg.len == 0) continue;
        if (arg.len >= 2 and arg[0] == '-' and !std.mem.eql(u8, arg, "--")) {
            var recognized = false;
            for (arg[1..]) |ch| switch (ch) {
                'm' => { opts.mount = true; recognized = true; },
                's' => { opts.silent = true; recognized = true; },
                'k' => { opts.kill = true; recognized = true; },
                '4' => { opts.ip4 = true; recognized = true; },
                '6' => { opts.ip6 = true; recognized = true; },
                else => {},
            };
            if (!recognized) {
                c.plainMsg("invalid option -- '{c}'", .{arg[1]});
                c.usageDie(prog);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) continue;
        positional.append(A, arg) catch {};
    }
    if (positional.items.len == 0) c.usageDie(prog);

    var ids: std.ArrayList(FileId) = .empty;
    defer ids.deinit(A);
    for (positional.items) |arg| {
        const slash = std.mem.indexOfScalar(u8, arg, '/') orelse 0;
        if (slash != 0) {
            const port = std.fmt.parseInt(u64, arg[0..slash], 10) catch 0;
            const proto = arg[slash + 1 ..];
            if (port != 0 and (std.mem.eql(u8, proto, "tcp") or std.mem.eql(u8, proto, "udp") or
                std.mem.eql(u8, proto, "tcp6") or std.mem.eql(u8, proto, "udp6")))
            {
                const path = std.fmt.allocPrint(A, "/proc/net/{s}", .{proto}) catch continue;
                defer A.free(path);
                scanProcNet(path, port, opts, &ids);
                continue;
            }
        }
        if (c.fileId(arg)) |id| addId(&ids, id) else {
            c.errorMsg(@intFromEnum(linux.E.NOENT), "can't stat '{s}'", .{arg});
            return 1;
        }
    }

    const pids = c.listPids(A, "/proc") catch return 1;
    defer A.free(pids);
    var kill_failed = false;
    var found = false;
    const self = linux.getpid();
    for (pids) |pid| {
        if (pid == self) continue;
        if (!processUses(pid, ids.items, opts)) continue;
        found = true;
        if (opts.kill and linux.errno(linux.kill(pid, @enumFromInt(@as(u32, @bitCast(opts.signo))))) != .SUCCESS) {
            c.plainMsg("kill pid {d}", .{pid});
            kill_failed = true;
        }
        if (!opts.silent) c.printfOut("{d} ", .{pid});
    }
    if (found and !opts.silent) c.out("\n");
    if (kill_failed) return 1;
    return if (found) 0 else 1;
}
