//! /proc parsers and PID lookup, ported from busybox libbb/procps.c and
//! libbb/find_pid_by_name.c. All parsing is pure Zig; no libc is involved.
//!
//! The public entry points read from the real /proc. `...In` variants accept
//! a different proc root so unit tests can feed synthetic data, and `...Data`
//! variants parse a buffer directly.

const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");
const file = @import("file.zig");

pub const pid_t = linux.pid_t;

pub const Error = error{
    MalformedProcStat,
    MalformedProcStatus,
    MissingProcess,
};

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn readSmallFile(root: []const u8, pid: pid_t, name: []const u8, buf: []u8) ![]const u8 {
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}/{s}", .{ root, pid, name }) catch return error.NameTooLong;
    const fd = try io.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer io.close(fd) catch {};
    var used: usize = 0;
    while (used < buf.len) {
        const n = try io.read(fd, buf[used..]);
        if (n == 0) break;
        used += n;
    }
    return buf[0..used];
}

/// Parsed representation of /proc/PID/stat. `comm` is copied into a fixed
/// 16-byte buffer (the kernel truncates task names to 15 characters), so the
/// structure owns no heap memory and stays valid after the source buffer dies.
pub const Stat = struct {
    pid: pid_t = 0,
    comm: [16]u8 = std.mem.zeroes([16]u8),
    comm_len: usize = 0,
    state: u8 = 0,
    ppid: pid_t = 0,
    pgrp: i32 = 0,
    session: i32 = 0,
    tty_nr: i32 = 0,
    tpgid: i32 = 0,
    flags: u32 = 0,
    minflt: u64 = 0,
    cminflt: u64 = 0,
    majflt: u64 = 0,
    cmajflt: u64 = 0,
    utime: u64 = 0,
    stime: u64 = 0,
    cutime: i64 = 0,
    cstime: i64 = 0,
    priority: i64 = 0,
    nice: i64 = 0,
    num_threads: i64 = 0,
    itrealvalue: i64 = 0,
    starttime: u64 = 0,
    vsize: u64 = 0,
    rss: i64 = 0,

    pub fn commSlice(self: *const Stat) []const u8 {
        return self.comm[0..self.comm_len];
    }
};

fn nextTok(it: *std.mem.TokenIterator(u8, .any)) ![]const u8 {
    return it.next() orelse Error.MalformedProcStat;
}

fn parseU(tok: []const u8) !u64 {
    return std.fmt.parseInt(u64, tok, 10) catch Error.MalformedProcStat;
}
fn parseI(tok: []const u8) !i64 {
    return std.fmt.parseInt(i64, tok, 10) catch Error.MalformedProcStat;
}

/// Parse one line of /proc/PID/stat. The comm field may contain spaces and
/// parentheses, so it is delimited by the first '(' and the last ')'.
pub fn parseProcStatData(data: []const u8) Error!Stat {
    const open = std.mem.indexOfScalar(u8, data, '(') orelse return Error.MalformedProcStat;
    const close = std.mem.lastIndexOfScalar(u8, data, ')') orelse return Error.MalformedProcStat;
    if (close <= open) return Error.MalformedProcStat;

    var st = Stat{};
    st.pid = std.fmt.parseInt(pid_t, std.mem.trim(u8, data[0..open], " \t"), 10) catch return Error.MalformedProcStat;
    const raw_comm = data[open + 1 .. close];
    st.comm_len = @min(raw_comm.len, st.comm.len);
    @memcpy(st.comm[0..st.comm_len], raw_comm[0..st.comm_len]);

    var it = std.mem.tokenizeAny(u8, data[close + 1 ..], " \t\r\n");
    const state = try nextTok(&it);
    if (state.len == 0) return Error.MalformedProcStat;
    st.state = state[0];
    st.ppid = @intCast(try parseU(try nextTok(&it)));
    st.pgrp = @intCast(try parseI(try nextTok(&it)));
    st.session = @intCast(try parseI(try nextTok(&it)));
    st.tty_nr = @intCast(try parseI(try nextTok(&it)));
    st.tpgid = @intCast(try parseI(try nextTok(&it)));
    st.flags = @intCast(try parseU(try nextTok(&it)));
    st.minflt = try parseU(try nextTok(&it));
    st.cminflt = try parseU(try nextTok(&it));
    st.majflt = try parseU(try nextTok(&it));
    st.cmajflt = try parseU(try nextTok(&it));
    st.utime = try parseU(try nextTok(&it));
    st.stime = try parseU(try nextTok(&it));
    st.cutime = try parseI(try nextTok(&it));
    st.cstime = try parseI(try nextTok(&it));
    st.priority = try parseI(try nextTok(&it));
    st.nice = try parseI(try nextTok(&it));
    st.num_threads = try parseI(try nextTok(&it));
    st.itrealvalue = try parseI(try nextTok(&it));
    st.starttime = try parseU(try nextTok(&it));
    st.vsize = try parseU(try nextTok(&it));
    st.rss = try parseI(try nextTok(&it));
    return st;
}

pub fn parseProcStatIn(root: []const u8, pid: pid_t) !Stat {
    var buf: [8192]u8 = undefined;
    const data = try readSmallFile(root, pid, "stat", &buf);
    return parseProcStatData(data);
}

pub fn parseProcStat(pid: pid_t) !Stat {
    return parseProcStatIn("/proc", pid);
}

/// Parsed representation of /proc/PID/status.
pub const Status = struct {
    pid: pid_t = 0,
    tgid: pid_t = 0,
    ppid: pid_t = 0,
    name: [16]u8 = std.mem.zeroes([16]u8),
    name_len: usize = 0,
    state: u8 = 0,
    uid: u32 = 0,
    euid: u32 = 0,
    gid: u32 = 0,
    egid: u32 = 0,
    vmpeak_kb: u64 = 0,
    vmsize_kb: u64 = 0,
    vmrss_kb: u64 = 0,
    threads: u64 = 0,

    pub fn nameSlice(self: *const Status) []const u8 {
        return self.name[0..self.name_len];
    }
};

fn firstUint(text: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, tok, 10) catch null;
}

pub fn parseProcStatusData(data: []const u8) Error!Status {
    var s = Status{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Name")) {
            s.name_len = @min(value.len, s.name.len);
            @memcpy(s.name[0..s.name_len], value[0..s.name_len]);
        } else if (std.mem.eql(u8, key, "State")) {
            if (value.len > 0) s.state = value[0];
        } else if (std.mem.eql(u8, key, "Pid")) {
            s.pid = @intCast(firstUint(value) orelse return Error.MalformedProcStatus);
        } else if (std.mem.eql(u8, key, "Tgid")) {
            s.tgid = @intCast(firstUint(value) orelse return Error.MalformedProcStatus);
        } else if (std.mem.eql(u8, key, "PPid")) {
            s.ppid = @intCast(firstUint(value) orelse return Error.MalformedProcStatus);
        } else if (std.mem.eql(u8, key, "Uid")) {
            var it = std.mem.tokenizeAny(u8, value, " \t");
            s.uid = @intCast(firstUint(it.next() orelse "") orelse return Error.MalformedProcStatus);
            s.euid = @intCast(firstUint(it.next() orelse "") orelse return Error.MalformedProcStatus);
        } else if (std.mem.eql(u8, key, "Gid")) {
            var it = std.mem.tokenizeAny(u8, value, " \t");
            s.gid = @intCast(firstUint(it.next() orelse "") orelse return Error.MalformedProcStatus);
            s.egid = @intCast(firstUint(it.next() orelse "") orelse return Error.MalformedProcStatus);
        } else if (std.mem.eql(u8, key, "VmPeak")) {
            s.vmpeak_kb = firstUint(value) orelse return Error.MalformedProcStatus;
        } else if (std.mem.eql(u8, key, "VmSize")) {
            s.vmsize_kb = firstUint(value) orelse return Error.MalformedProcStatus;
        } else if (std.mem.eql(u8, key, "VmRSS")) {
            s.vmrss_kb = firstUint(value) orelse return Error.MalformedProcStatus;
        } else if (std.mem.eql(u8, key, "Threads")) {
            s.threads = firstUint(value) orelse return Error.MalformedProcStatus;
        }
    }
    if (s.name_len == 0) return Error.MalformedProcStatus;
    return s;
}

pub fn parseProcStatusIn(root: []const u8, pid: pid_t) !Status {
    var buf: [8192]u8 = undefined;
    const data = try readSmallFile(root, pid, "status", &buf);
    return parseProcStatusData(data);
}

pub fn parseProcStatus(pid: pid_t) !Status {
    return parseProcStatusIn("/proc", pid);
}

const CmdArgs = struct { argv0: []const u8 = "", argv1: []const u8 = "" };

fn cmdArgs(data: []const u8) CmdArgs {
    const a0 = std.mem.sliceTo(data, 0);
    const rest = if (a0.len < data.len) data[a0.len + 1 ..] else "";
    const a1 = std.mem.sliceTo(rest, 0);
    return .{ .argv0 = a0, .argv1 = a1 };
}

fn commMatches(comm: []const u8, name: []const u8, argv: CmdArgs) bool {
    // strncmp(comm, name, 15) semantics, plus the truncated-name workaround.
    if (comm.len >= 15) {
        if (!std.mem.startsWith(u8, name, comm[0..15])) return false;
        const a1 = basename(argv.argv1);
        return std.mem.eql(u8, a1, name);
    }
    return std.mem.eql(u8, comm, name);
}

const ScanCtx = struct {
    root: []const u8,
    name: []const u8,
    a: std.mem.Allocator,
    pids: std.ArrayList(pid_t),
};

fn scanEntry(entry_name: []const u8, ctx_ptr: ?*anyopaque) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const pid = std.fmt.parseInt(pid_t, entry_name, 10) catch return;

    var stat_buf: [8192]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&path_buf, "{s}/{d}/stat", .{ ctx.root, pid }) catch return;
    const sfd = io.open(stat_path, .{ .ACCMODE = .RDONLY }, 0) catch return;
    var used: usize = 0;
    while (used < stat_buf.len) {
        const n = io.read(sfd, stat_buf[used..]) catch break;
        if (n == 0) break;
        used += n;
    }
    io.close(sfd) catch {};
    const st = parseProcStatData(stat_buf[0..used]) catch return;

    var argv: CmdArgs = .{};
    const cmd_path = std.fmt.bufPrint(&path_buf, "{s}/{d}/cmdline", .{ ctx.root, pid }) catch return;
    if (io.open(cmd_path, .{ .ACCMODE = .RDONLY }, 0)) |cfd| {
        var cbuf: [8192]u8 = undefined;
        var cused: usize = 0;
        while (cused < cbuf.len) {
            const n = io.read(cfd, cbuf[cused..]) catch break;
            if (n == 0) break;
            cused += n;
        }
        io.close(cfd) catch {};
        if (cused > 0) argv = cmdArgs(cbuf[0..cused]);
    } else |_| {}

    var matched = commMatches(st.commSlice(), ctx.name, argv);
    if (!matched and argv.argv0.len > 0 and std.mem.eql(u8, basename(argv.argv0), ctx.name)) matched = true;
    if (!matched) {
        const exe_path = std.fmt.bufPrint(&path_buf, "{s}/{d}/exe", .{ ctx.root, pid }) catch return;
        var link_buf: [4096]u8 = undefined;
        if (io.readlink(exe_path, &link_buf)) |n| {
            if (n > 0) {
                const exe = link_buf[0..n];
                if (ctx.name.len > 0 and ctx.name[0] == '/') {
                    matched = std.mem.eql(u8, exe, ctx.name);
                } else {
                    matched = std.mem.eql(u8, basename(exe), ctx.name);
                }
            }
        } else |_| {}
    }
    if (matched) try ctx.pids.append(ctx.a, pid);
}

/// Return the PIDs of processes whose comm, argv[0] basename, argv[1]
/// basename (for truncated comms) or exe link matches `name`.
pub fn findPidByNameIn(root: []const u8, name: []const u8, a: std.mem.Allocator) ![]pid_t {
    var ctx = ScanCtx{ .root = root, .name = name, .a = a, .pids = .empty };
    errdefer ctx.pids.deinit(a);
    var root_buf: [4096:0]u8 = undefined;
    if (root.len >= root_buf.len) return error.NameTooLong;
    @memcpy(root_buf[0..root.len], root);
    root_buf[root.len] = 0;
    try file.forEachEntry(@ptrCast(&root_buf), scanEntry, &ctx);
    return ctx.pids.toOwnedSlice(a);
}

pub fn findPidByName(name: []const u8) ![]pid_t {
    return findPidByNameIn("/proc", name, std.heap.page_allocator);
}

pub fn freePidList(list: []pid_t, a: std.mem.Allocator) void {
    a.free(list);
}

/// Reverse a PID list in place, matching busybox's pidlist_reverse().
pub fn pidlistReverse(list: []pid_t) []pid_t {
    std.mem.reverse(pid_t, list);
    return list;
}
