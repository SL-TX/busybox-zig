//! debianutils start-stop-daemon — start/stop daemons by matching processes.

const std = @import("std");
const c = @import("common.zig");
const bb = c.bb;
const linux = c.linux;

const K: u32 = 1 << 0;
const S: u32 = 1 << 1;
const B: u32 = 1 << 2;
const Q: u32 = 1 << 3;
const T: u32 = 1 << 4;
const M: u32 = 1 << 5;
const A: u32 = 1 << 6;
const N: u32 = 1 << 7;
const SIG: u32 = 1 << 8;
const U: u32 = 1 << 9;
const C: u32 = 1 << 10;
const D: u32 = 1 << 11;
const X: u32 = 1 << 12;
const P: u32 = 1 << 13;
const O: u32 = 1 << 14;
const OK: u32 = 1 << 15;
const V: u32 = 1 << 16;

const LongMap = struct { name: []const u8, ch: u8 };
const longmap = [_]LongMap{
    .{ .name = "stop", .ch = 'K' }, .{ .name = "start", .ch = 'S' },
    .{ .name = "background", .ch = 'b' }, .{ .name = "quiet", .ch = 'q' },
    .{ .name = "test", .ch = 't' }, .{ .name = "make-pidfile", .ch = 'm' },
    .{ .name = "output", .ch = 'O' }, .{ .name = "oknodo", .ch = 'o' },
    .{ .name = "verbose", .ch = 'v' }, .{ .name = "nicelevel", .ch = 'N' },
    .{ .name = "startas", .ch = 'a' }, .{ .name = "name", .ch = 'n' },
    .{ .name = "signal", .ch = 's' }, .{ .name = "user", .ch = 'u' },
    .{ .name = "chuid", .ch = 'c' }, .{ .name = "chdir", .ch = 'd' },
    .{ .name = "exec", .ch = 'x' }, .{ .name = "pidfile", .ch = 'p' },
    .{ .name = "retry", .ch = 'R' },
};

fn bitFor(ch: u8) ?u32 {
    return switch (ch) {
        'K' => K, 'S' => S, 'b' => B, 'q' => Q, 't' => T, 'm' => M,
        'a' => A, 'n' => N, 's' => SIG, 'u' => U, 'c' => C, 'd' => D,
        'x' => X, 'p' => P, 'O' => O, 'o' => OK, 'v' => V,
        'N', 'R' => 0, // accepted but unused flags
        else => null,
    };
}

fn takesArg(ch: u8) bool {
    return switch (ch) {
        'a', 'n', 's', 'u', 'c', 'd', 'x', 'p', 'O', 'N', 'R' => true,
        else => false,
    };
}

const Parsed = struct {
    flags: u32 = 0,
    startas: ?[]const u8 = null,
    cmdname: ?[]const u8 = null,
    signame: ?[]const u8 = null,
    userspec: ?[]const u8 = null,
    execname: ?[]const u8 = null,
    pidfile: ?[]const u8 = null,
    positional: []const []const u8 = &.{},
};

fn parse(args: []const []const u8, prog: []const u8) Parsed {
    var out = Parsed{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (std.mem.eql(u8, tok, "--")) {
            out.positional = args[i + 1 ..];
            break;
        }
        if (tok.len < 2 or tok[0] != '-') {
            out.positional = args[i..];
            break;
        }
        if (tok[1] == '-') {
            const body = tok[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |p| body[0..p] else body;
            var ch: ?u8 = null;
            for (longmap) |lm| {
                if (std.mem.eql(u8, lm.name, name)) {
                    ch = lm.ch;
                    break;
                }
            }
            const cch = ch orelse {
                bb.messages.plainMsg("unrecognized option '--{s}'", .{name});
                bb.usage.die(prog);
            };
            if (bitFor(cch)) |b| out.flags |= b;
            if (takesArg(cch)) {
                var value: []const u8 = undefined;
                if (eq) |p| {
                    value = body[p + 1 ..];
                } else if (i + 1 < args.len) {
                    i += 1;
                    value = args[i];
                } else {
                    bb.messages.plainMsg("option '--{s}' requires an argument", .{name});
                    bb.usage.die(prog);
                }
                store(&out, cch, value);
            }
            continue;
        }
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            const b = bitFor(ch) orelse 0;
            if (bitFor(ch) == null and ch != 'N' and ch != 'R') {
                bb.messages.plainMsg("invalid option -- '{c}'", .{ch});
                bb.usage.die(prog);
            }
            out.flags |= b;
            if (takesArg(ch)) {
                var value: []const u8 = undefined;
                if (j + 1 < tok.len) {
                    value = tok[j + 1 ..];
                } else if (i + 1 < args.len) {
                    i += 1;
                    value = args[i];
                } else {
                    bb.messages.plainMsg("option requires an argument -- '{c}'", .{ch});
                    bb.usage.die(prog);
                }
                store(&out, ch, value);
                break;
            }
        }
    }
    return out;
}

fn store(out: *Parsed, ch: u8, value: []const u8) void {
    switch (ch) {
        'a' => out.startas = value,
        'n' => out.cmdname = value,
        's' => out.signame = value,
        'u' => out.userspec = value,
        'x' => out.execname = value,
        'p' => out.pidfile = value,
        else => {},
    }
}

fn signum(name: []const u8) ?i32 {
    if (std.fmt.parseInt(i32, name, 10)) |n| return n else |_| {}
    const pairs = [_]struct { []const u8, i32 }{
        .{ "TERM", 15 }, .{ "HUP", 1 }, .{ "INT", 2 }, .{ "QUIT", 3 },
        .{ "KILL", 9 }, .{ "STOP", 19 }, .{ "CONT", 18 }, .{ "USR1", 10 },
        .{ "USR2", 12 }, .{ "ALRM", 14 }, .{ "SIGTERM", 15 }, .{ "SIGKILL", 9 },
    };
    for (pairs) |p| if (std.ascii.eqlIgnoreCase(name, p[0])) return p[1];
    return null;
}

fn writePidfile(allocator: std.mem.Allocator, path: ?[]const u8, pid: u32) void {
    const p = path orelse return;
    var zbuf: [4096:0]u8 = undefined;
    const zp = c.z(p, &zbuf) catch return;
    const fd: linux.fd_t = @intCast(linux.open(zp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666));
    if (linux.errno(@as(usize, @intCast(fd))) != .SUCCESS) return;
    defer _ = linux.close(fd);
    var nb: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&nb, "{d}\n", .{pid}) catch return;
    c.writeAll(fd, s);
    _ = allocator;
}

fn readFileTrim(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const data = c.readFile(allocator, path) catch return null;
    return std.mem.trimEnd(u8, data, "\n\r");
}

fn pidIsExec(allocator: std.mem.Allocator, pid: u32, execname: []const u8) bool {
    var pathbuf: [64]u8 = undefined;
    const exe_path = std.fmt.bufPrint(&pathbuf, "/proc/{d}/exe", .{pid}) catch return false;
    var linkbuf: [4096]u8 = undefined;
    const exe_z = c.zstr(allocator, exe_path) catch return false;
    const n = linux.readlink(exe_z, &linkbuf, linkbuf.len);
    if (linux.errno(n) == .SUCCESS and n > 0 and std.mem.eql(u8, linkbuf[0..n], execname)) return true;
    const cmd_path = std.fmt.bufPrint(&pathbuf, "/proc/{d}/cmdline", .{pid}) catch return false;
    const data = c.readFile(allocator, cmd_path) catch return false;
    defer allocator.free(data);
    const first = std.mem.sliceTo(data, 0);
    return std.mem.eql(u8, first, execname);
}

fn pidIsName(allocator: std.mem.Allocator, pid: u32, cmdname: []const u8) bool {
    var pathbuf: [64]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&pathbuf, "/proc/{d}/stat", .{pid}) catch return false;
    const data = c.readFile(allocator, stat_path) catch return false;
    defer allocator.free(data);
    const open = std.mem.indexOfScalar(u8, data, '(') orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, data, ')') orelse return false;
    if (close <= open) return false;
    const comm = data[open + 1 .. close];
    if (comm.len >= 15) return false;
    return std.mem.eql(u8, comm, cmdname);
}

fn pidIsUser(pid: u32, user_id: u32) bool {
    var pathbuf: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&pathbuf, "/proc/{d}", .{pid}) catch return false;
    const st = c.fileInfo(p) orelse return false;
    return st.uid == user_id;
}

pub fn startStopDaemonMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const allocator = std.heap.page_allocator;
    const args = c.argsFrom(allocator, argv, argc) catch return 1;
    defer allocator.free(args);
    const prog = c.basename(args[0]);
    bb.env.setProgramName(prog);

    var o = parse(args, prog);
    const stop = (o.flags & K) != 0;
    const start = (o.flags & S) != 0;
    if (stop == start) bb.usage.die(prog);
    if ((o.flags & M) != 0 and (o.flags & P) == 0) bb.usage.die(prog);
    if (stop and o.execname == null and o.pidfile == null and o.userspec == null and o.cmdname == null)
        bb.usage.die(prog);

    var signal_nr: i32 = 15;
    if (o.flags & SIG != 0) {
        signal_nr = signum(o.signame.?) orelse bb.usage.die(prog);
    }

    var execname = o.execname;
    var startas = o.startas;
    if (start) {
        if (execname == null) {
            execname = startas;
            if (execname == null) {
                if (o.positional.len == 0) bb.usage.die(prog);
                execname = o.positional[0];
            }
        }
        if (startas == null) startas = execname;
        // Matching must use the resolved program name (from -x, -a or the
        // first positional argument), not the raw -x option alone.
        o.execname = execname;
    }

    var user_id: ?u32 = null;
    if (o.userspec) |u| {
        const n = std.fmt.parseInt(u32, u, 10) catch 0xffffffff;
        user_id = if (n != 0xffffffff) n else linux.getuid();
    }

    // Collect matching PIDs.
    var pids: std.ArrayList(u32) = .empty;
    defer pids.deinit(allocator);
    const checkPid = struct {
        fn call(a: std.mem.Allocator, list: *std.ArrayList(u32), opts: *const Parsed, pid: u32, uid: ?u32) void {
            if (opts.execname) |ex| if (!pidIsExec(a, pid, ex)) return;
            if (opts.cmdname) |nm| if (!pidIsName(a, pid, nm)) return;
            if (uid) |u| if (!pidIsUser(pid, u)) return;
            list.append(a, pid) catch {};
        }
    }.call;

    if (o.pidfile) |pf| {
        if (readFileTrim(allocator, pf)) |data| {
            const pid = std.fmt.parseInt(u32, std.mem.trim(u8, data, " \t"), 10) catch 0;
            if (pid != 0) checkPid(allocator, &pids, &o, pid, user_id);
        }
    } else {
        var dir = c.DirIter.open("/proc") orelse bb.messages.errorMsgAndDie(2, "nothing in /proc - not mounted?", .{});
        defer dir.close();
        while (dir.next()) |entry_name| {
            const pid = std.fmt.parseInt(u32, entry_name, 10) catch continue;
            checkPid(allocator, &pids, &o, pid, user_id);
        }
    }

    const quiet = (o.flags & Q) != 0;
    const test_only = (o.flags & T) != 0;

    if (stop) {
        const what = if (o.cmdname) |x| x else if (o.execname) |x| x else if (o.pidfile) |x|
            std.fmt.allocPrint(allocator, "process in pidfile '{s}'", .{x}) catch "" else if (o.userspec) |x|
            std.fmt.allocPrint(allocator, "process(es) owned by '{s}'", .{x}) catch "" else "";
        if (pids.items.len == 0) {
            if (!quiet) {
                c.writeAll(1, "no ");
                c.writeAll(1, what);
                c.writeAll(1, " found; none killed\n");
            }
            return if ((o.flags & OK) != 0) 0 else 1;
        }
        var killed: i32 = 0;
        var sr = std.ArrayList(u32).empty;
        defer sr.deinit(allocator);
        for (pids.items) |pid| {
            const sig: linux.SIG = @enumFromInt(if (test_only) 0 else signal_nr);
            const rc = linux.kill(@intCast(pid), sig);
            if (linux.errno(rc) == .SUCCESS) {
                killed += 1;
                sr.append(allocator, pid) catch {};
            } else {
                bb.messages.errorMsg(@intCast(@intFromEnum(linux.errno(rc))), "warning: killing process {d}", .{pid});
                if (test_only) return if ((o.flags & OK) != 0) 0 else 1;
            }
        }
        if (!quiet and killed > 0) {
            c.writeAll(1, "stopped ");
            c.writeAll(1, what);
            c.writeAll(1, " (pid");
            for (sr.items) |pid| {
                var nb: [32]u8 = undefined;
                c.writeAll(1, " ");
                c.writeAll(1, std.fmt.bufPrint(&nb, "{d}", .{pid}) catch "");
            }
            c.writeAll(1, ")\n");
        }
        return if (killed > 0) 0 else if ((o.flags & OK) != 0) 0 else 1;
    }

    // start
    if (pids.items.len > 0) {
        if (!quiet) {
            c.writeAll(1, execname.?);
            c.writeAll(1, " is already running\n");
        }
        return if ((o.flags & OK) != 0) 0 else 1;
    }
    const exe = execname.?;
    if (c.fileInfo(exe) == null) {
        bb.messages.errorMsgAndDie(2, "can't execute '{s}'", .{exe});
    }
    var argv_child: std.ArrayList([]const u8) = .empty;
    defer argv_child.deinit(allocator);
    argv_child.append(allocator, startas.?) catch {};
    // Without -x/-a the first positional argument was consumed as the program
    // name; argv[0] is re-inserted above, so skip it here.
    const positional_for_child = if (o.flags & X != 0 or o.flags & A != 0)
        o.positional
    else if (o.positional.len > 0)
        o.positional[1..]
    else
        o.positional;
    for (positional_for_child) |p| argv_child.append(allocator, p) catch {};

    const background = (o.flags & B) != 0;
    if (background) {
        // -b: detach, write the pidfile, and return success immediately.
        const pid_rc = linux.fork();
        if (pid_rc == 0) {
            if ((o.flags & M) != 0) writePidfile(allocator, o.pidfile, @intCast(linux.getpid()));
            _ = c.runChild(allocator, argv_child.items);
            std.process.exit(0);
        }
        return 0;
    }
    // Non-background: the reference vforks+execvp's, so the caller observes
    // the program's exit status. fork+wait reproduces that observably.
    if ((o.flags & M) != 0) writePidfile(allocator, o.pidfile, @intCast(linux.getpid()));
    return c.runChild(allocator, argv_child.items);
}
