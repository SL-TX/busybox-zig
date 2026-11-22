//! pstree — port of procps/pstree.c (tree assembly and tree drawing).

const std = @import("std");
const c = @import("common.zig");
const bb = @import("libbb_zig");

const A = std.heap.page_allocator;

const Proc = struct {
    comm: []u8,
    pid: i32,
    ppid: i32,
    uid: u32,
    children: std.ArrayList(*Proc) = .empty,
    parent: ?*Proc = null,
};

fn newProc(comm: []const u8, pid: i32, uid: u32) ?*Proc {
    const p = A.create(Proc) catch return null;
    p.* = .{ .comm = A.dupe(u8, comm) catch return null, .pid = pid, .ppid = 0, .uid = uid };
    return p;
}

fn findProc(list: *std.ArrayList(*Proc), pid: i32) ?*Proc {
    for (list.items) |p| if (p.pid == pid) return p;
    return null;
}

fn addProc(list: *std.ArrayList(*Proc), comm: []const u8, pid: i32, ppid: i32, uid: u32) void {
    var self = findProc(list, pid);
    if (self == null) {
        self = newProc(comm, pid, uid);
        if (self == null) return;
        list.append(A, self.?) catch return;
    } else {
        A.free(self.?.comm);
        self.?.comm = A.dupe(u8, comm) catch return;
        self.?.uid = uid;
    }
    var parent_pid = ppid;
    if (pid == parent_pid) parent_pid = 0;
    var parent = findProc(list, parent_pid);
    if (parent == null) {
        parent = newProc("?", parent_pid, 0);
        if (parent == null) return;
        list.append(A, parent.?) catch return;
    }
    if (findChild(self.?, parent.?) == null) {
        parent.?.children.append(A, self.?) catch return;
    }
    self.?.parent = parent.?;
}

fn findChild(parent: *Proc, child: *Proc) ?*Proc {
    for (parent.children.items) |p| if (p == child) return p;
    return null;
}

fn uidOf(pid: i32) u32 {
    const path = c.procPath(A, @intCast(pid), "status") catch return 0;
    defer A.free(path);
    const data = c.readFile(A, path) orelse return 0;
    defer A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var it = std.mem.tokenizeAny(u8, line[4..], " \t");
        const tok = it.next() orelse return 0;
        return std.fmt.parseInt(u32, tok, 10) catch 0;
    }
    return 0;
}

fn statFields(pid: i32) ?struct { comm: []u8, ppid: i32 } {
    const path = c.procPath(A, @intCast(pid), "stat") catch return null;
    defer A.free(path);
    const data = c.readFile(A, path) orelse return null;
    defer A.free(data);
    const open = std.mem.indexOfScalar(u8, data, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, data, ')') orelse return null;
    const raw_comm = data[open + 1 .. close];
    const comm = A.dupe(u8, raw_comm[0..@min(raw_comm.len, 15)]) catch return null;
    var it = std.mem.tokenizeAny(u8, data[close + 1 ..], " \t");
    _ = it.next() orelse return null;
    const ppid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    return .{ .comm = comm, .ppid = ppid };
}

fn addThreads(list: *std.ArrayList(*Proc), pid: i32) void {
    const path = c.procPath(A, @intCast(pid), "task") catch return;
    defer A.free(path);
    const z = c.zstr(A, path) catch return;
    defer A.free(z);
    const rc = linuxOpenDir(z) orelse return;
    defer _ = std.os.linux.close(rc);
    var buf: [16384]u8 align(8) = undefined;
    const noff = @offsetOf(std.os.linux.dirent64, "name");
    const n = std.os.linux.getdents64(rc, &buf, buf.len);
    if (std.os.linux.errno(n) != .SUCCESS) return;
    var off: usize = 0;
    while (off + noff <= n) {
        const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
        if (dent.reclen == 0) break;
        const raw = buf[off + noff ..][0 .. dent.reclen - noff];
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        const tid_s = raw[0..end];
        off += dent.reclen;
        const tid = std.fmt.parseInt(i32, tid_s, 10) catch continue;
        if (tid == pid) continue;
        if (statFields(tid)) |f| {
            const name = std.fmt.allocPrint(A, "{{{s}}}", .{f.comm}) catch continue;
            defer A.free(name);
            addProc(list, name, tid, pid, uidOf(tid));
        }
    }
}

fn linuxOpenDir(path: [:0]const u8) ?std.os.linux.fd_t {
    const rc = std.os.linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn treeEqual(a: *Proc, b: *Proc, show_pid: bool) bool {
    if (!std.mem.eql(u8, a.comm, b.comm)) return false;
    if (show_pid and a.pid != b.pid) return false;
    if (a.children.items.len != b.children.items.len) return false;
    for (a.children.items, b.children.items) |x, y| {
        if (!treeEqual(x, y, show_pid)) return false;
    }
    return true;
}

const Drawer = struct {
    show_pid: bool,
    width: [64]usize = undefined,
    more: [64]bool = undefined,
    cur_x: usize = 0,

    fn chars(self: *Drawer, s: []const u8) void {
        // pstree.c:out_char() replaces the 80th column with '+' and drops the
        // rest. stdout is piped in the harness, so the width is the default 80.
        for (s) |ch| {
            self.cur_x += 1;
            if (self.cur_x > 80) continue;
            c.out(if (self.cur_x == 80) "+" else &[_]u8{ch});
        }
    }

    fn argChars(self: *Drawer, s: []const u8) void {
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        for (s) |ch| {
            if (ch == '\\') {
                buf[n..][0..2].* = "\\\\".*;
                n += 2;
            } else if (ch >= ' ' and ch < 0x7f) {
                buf[n] = ch;
                n += 1;
            } else {
                const oct = std.fmt.bufPrint(buf[n..], "\\{o:0>3}", .{ch}) catch continue;
                n += oct.len;
            }
        }
        self.chars(buf[0..n]);
    }

    fn dump(self: *Drawer, node: ?*Proc, level: usize, rep: usize, leaf: bool, last: bool, closing: usize) void {
        const cur = node orelse return;
        if (!leaf) {
            var lvl: usize = 0;
            while (lvl < level) : (lvl += 1) {
                var i: usize = self.width[lvl] + 1;
                while (i > 0) : (i -= 1) self.chars(" ");
                if (lvl == level - 1) {
                    self.chars(if (last) "`-" else "|-");
                } else {
                    self.chars(if (self.more[lvl + 1]) "| " else "  ");
                }
            }
        }
        var extra: usize = 0;
        if (rep > 1) {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}*[", .{rep}) catch "";
            self.chars(s);
            extra = s.len;
        }
        const before = self.cur_x;
        self.argChars(cur.comm);
        var comm_len = self.cur_x - before;
        if (self.show_pid) {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "({d})", .{cur.pid}) catch "";
            self.chars(s);
            comm_len += s.len;
        }
        const offset = self.cur_x;
        if (cur.children.items.len == 0) {
            var cl = closing;
            while (cl > 0) : (cl -= 1) self.chars("]");
            c.out("\n");
            self.cur_x = 0;
        }
        self.more[level] = !last;
        if (cur.children.items.len == 0) return;
        self.width[level] = comm_len + self.cur_x - offset + extra;
        // Group identical subtrees, as pstree.c's tree_equal() scan does.
        var groups: std.ArrayList(struct { node: *Proc, rep: usize }) = .empty;
        for (cur.children.items) |child| {
            var placed = false;
            for (groups.items) |*g| {
                if (treeEqual(g.node, child, self.show_pid)) {
                    g.rep += 1;
                    placed = true;
                    break;
                }
            }
            if (!placed) groups.append(A, .{ .node = child, .rep = 1 }) catch return;
        }
        var first = true;
        for (groups.items, 0..) |g, idx| {
            if (first) {
                self.chars(if (idx + 1 < groups.items.len) "-+-" else "---");
                first = false;
            }
            self.dump(g.node, level + 1, g.rep, idx == 0,
                idx + 1 >= groups.items.len,
                closing + (if (g.rep != 1) @as(usize, 1) else 0));
        }
    }
};

fn uidFromName(name: []const u8) ?u32 {
    const data = c.readFile(A, "/etc/passwd") orelse return null;
    defer A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, line, ':');
        const user = it.next() orelse continue;
        if (!std.mem.eql(u8, user, name)) continue;
        _ = it.next();
        const uid_s = it.next() orelse return null;
        return std.fmt.parseInt(u32, uid_s, 10) catch null;
    }
    return null;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const av = c.argsFrom(A, argv, argc) catch return 1;
    defer A.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var show_pid = false;
    var i: usize = 1;
    while (i < av.len and av[i].len > 1 and av[i][0] == '-') : (i += 1) {
        for (av[i][1..]) |ch| {
            if (ch != 'p') {
                c.plainMsg("invalid option -- '{c}'", .{ch});
                c.usageDie(prog);
            }
            show_pid = true;
        }
    }
    var root_pid: i32 = 1;
    var uid: u32 = 0;
    if (i < av.len) {
        const arg = av[i];
        if (arg.len > 0 and arg[0] >= '0' and arg[0] <= '9') {
            root_pid = std.fmt.parseInt(i32, arg, 10) catch 1;
        } else {
            uid = uidFromName(arg) orelse {
                c.plainMsgAndDie("unknown user {s}", .{arg});
            };
        }
    }

    var procs: std.ArrayList(*Proc) = .empty;
    const pids = c.listPids(A, "/proc") catch return 1;
    defer A.free(pids);
    for (pids) |pid| {
        if (statFields(@intCast(pid))) |f| {
            addProc(&procs, f.comm, pid, f.ppid, uidOf(pid));
            addThreads(&procs, pid);
        }
    }
    // add_child() in pstree.c keeps siblings sorted by comm, then uid.
    for (procs.items) |p| {
        std.mem.sort(*Proc, p.children.items, {}, struct {
            fn lessThan(_: void, x: *Proc, y: *Proc) bool {
                const ord = std.mem.order(u8, x.comm, y.comm);
                if (ord == .eq) return x.uid < y.uid;
                return ord == .lt;
            }
        }.lessThan);
    }
    // Ensure a root node exists even for a missing PID.
    if (findProc(&procs, root_pid) == null) return 0;

    var d = Drawer{ .show_pid = show_pid };
    if (uid == 0) {
        d.dump(findProc(&procs, root_pid), 0, 1, true, true, 0);
    } else {
        var dumped = false;
        for (procs.items) |p| {
            if (p.uid == uid) {
                if (dumped) c.out("\n");
                d.cur_x = 0;
                d.dump(p, 0, 1, true, true, 0);
                dumped = true;
            }
        }
        if (!dumped) c.plainMsgAndDie("no processes found", .{});
    }
    return 0;
}
