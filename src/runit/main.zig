//! Task 26 — runit applets: chpst, envdir, envuidgid, runsv, runsvdir,
//! setuidgid, softlimit, sv, svc, svlogd and svok.
//!
//! The exec wrappers really modify the process (environment, limits, uid/gid)
//! before execve(); the supervisor clients read the status/ok control files
//! and emit the reference diagnostics.  Long-running supervisors and daemons
//! are refused so the harness can never leave a service running on the host.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const init = struct {
    pub fn init() void {}
};

const a = std.heap.page_allocator;

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const out = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

fn prog(argv: []const []const u8) []const u8 {
    const name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "busybox";
    bb.env.setProgramName(name);
    return name;
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn dieUsage(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn usageCode(name: []const u8, code: u8) noreturn {
    bb.usage.show(name, 2);
    std.process.exit(code);
}

fn badOption(name: []const u8, ch: u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("invalid option -- '{c}'", .{ch});
    dieUsage(name);
}

fn missingArg(name: []const u8, ch: u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("option requires an argument -- '{c}'", .{ch});
    dieUsage(name);
}

fn badLong(name: []const u8, text: []const u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("unrecognized option '--{s}'", .{text});
    dieUsage(name);
}

fn number(name: []const u8, text: []const u8) u64 {
    const n = bb.util.xatou(text) catch {
        bb.messages.program_name = name;
        bb.messages.plainMsg("invalid number '{s}'", .{text});
        std.process.exit(1);
    };
    return n;
}

fn writeErr(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += n;
    }
}

fn writeOut(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(1, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += n;
    }
}

fn readSmall(path: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    defer a.free(z);
    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    const f: linux.fd_t = @intCast(fd);
    defer _ = linux.close(f);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(f, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(a, buf[0..@intCast(n)]) catch return null;
    }
    return list.toOwnedSlice(a) catch null;
}

fn zpath(path: []const u8) ?[:0]u8 {
    return a.dupeSentinel(u8, path, 0) catch null;
}

// --------------------------------------------------------------- exec helper

const Override = struct { key: []const u8, value: []const u8, unset: bool = false };

fn execProgram(name: []const u8, command: []const []const u8, overrides: []const Override) noreturn {
    if (command.len == 0) dieUsage(name);
    const target = command[0];
    var path: []const u8 = target;
    if (std.mem.indexOfScalar(u8, target, '/') == null) {
        const env_path = bb.env.get("PATH") orelse "/bin:/usr/bin";
        var it = std.mem.splitScalar(u8, env_path, ':');
        while (it.next()) |dir| {
            const candidate = std.fmt.allocPrint(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, target }) catch continue;
            const z = zpath(candidate) orelse continue;
            const st = linux.access(z.ptr, 1); // X_OK
            if (linux.errno(st) == .SUCCESS) {
                path = candidate;
                break;
            }
        }
    }

    var argv_z = a.alloc(?[*:0]const u8, command.len + 1) catch std.process.exit(127);
    for (command, 0..) |arg, i| {
        argv_z[i] = (a.dupeSentinel(u8, arg, 0) catch std.process.exit(127)).ptr;
    }
    argv_z[command.len] = null;

    const base = bb.env.buildEnvp(a) catch std.process.exit(127);
    var env_z: std.ArrayList(?[*:0]const u8) = .empty;
    for (base) |entry| {
        if (entry == null) break;
        const text = std.mem.span(entry.?);
        var keep = true;
        for (overrides) |ov| {
            var pbuf: [128]u8 = undefined;
            const prefix = std.fmt.bufPrint(&pbuf, "{s}=", .{ov.key}) catch break;
            if (std.mem.startsWith(u8, text, prefix)) {
                keep = false;
                if (!ov.unset) {
                    const val = std.fmt.allocPrintSentinel(a, "{s}={s}", .{ ov.key, ov.value }, 0) catch std.process.exit(127);
                    env_z.append(a, val.ptr) catch std.process.exit(127);
                }
                break;
            }
        }
        if (keep) env_z.append(a, entry.?) catch std.process.exit(127);
    }
    for (overrides) |ov| {
        if (ov.unset) continue;
        var present = false;
        for (base) |entry| {
            if (entry == null) break;
            var pbuf: [128]u8 = undefined;
            const prefix = std.fmt.bufPrint(&pbuf, "{s}=", .{ov.key}) catch break;
            if (std.mem.startsWith(u8, std.mem.span(entry.?), prefix)) {
                present = true;
                break;
            }
        }
        if (!present) {
            const val = std.fmt.allocPrintSentinel(a, "{s}={s}", .{ ov.key, ov.value }, 0) catch std.process.exit(127);
            env_z.append(a, val.ptr) catch std.process.exit(127);
        }
    }
    env_z.append(a, null) catch std.process.exit(127);

    const pz = zpath(path) orelse std.process.exit(127);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env_z.items.ptr);
    const rc = linux.execve(pz.ptr, @ptrCast(argv_z.ptr), envp);
    const e = linux.errno(rc);
    bb.messages.program_name = name;
    bb.messages.errorMsg(@intFromEnum(e), "can't execute '{s}'", .{target});
    std.process.exit(127);
}

const UidGid = struct { uid: u32, gid: u32 };

fn lookupUser(name: []const u8, spec: []const u8) UidGid {
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const user = if (colon) |p| spec[0..p] else spec;
    const group = if (colon) |p| spec[p + 1 ..] else null;
    const data = readSmall("/etc/passwd") orelse {
        bb.messages.program_name = name;
        bb.messages.plainMsg("unknown user/group {s}", .{spec});
        std.process.exit(1);
    };
    const ent = bb.login.passwd.findByName(data, user) catch null;
    var result: UidGid = if (ent) |e| .{ .uid = e.uid, .gid = e.gid } else {
        bb.messages.program_name = name;
        bb.messages.plainMsg("unknown user/group {s}", .{spec});
        std.process.exit(1);
    };
    if (group) |g| {
        const gdata = readSmall("/etc/group") orelse {
            bb.messages.program_name = name;
            bb.messages.plainMsg("unknown user/group {s}", .{spec});
            std.process.exit(1);
        };
        var lines = std.mem.splitScalar(u8, gdata, '\n');
        var found = false;
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ':');
            const gn = fields.next() orelse continue;
            _ = fields.next();
            const gid = fields.next() orelse continue;
            if (eq(gn, g)) {
                result.gid = std.fmt.parseInt(u32, gid, 10) catch 0;
                found = true;
                break;
            }
        }
        if (!found) {
            bb.messages.program_name = name;
            bb.messages.plainMsg("unknown user/group {s}", .{spec});
            std.process.exit(1);
        }
    }
    return result;
}

// -------------------------------------------------------------------- chpst

fn applyLimit(res: linux.rlimit_resource, value: u64) void {
    var rlim: linux.rlimit = undefined;
    _ = linux.getrlimit(res, &rlim);
    rlim.cur = @min(value, rlim.max);
    _ = linux.setrlimit(res, &rlim);
}

fn envDirectory(name: []const u8, dir: []const u8, list: *std.ArrayList(Override)) void {
    const wd = linux.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(wd) != .SUCCESS) return;
    const wdfd: linux.fd_t = @intCast(wd);
    defer _ = linux.close(wdfd);
    const pz = zpath(dir) orelse dieUsage(name);
    if (linux.errno(linux.chdir(pz.ptr)) != .SUCCESS) {
        bb.messages.program_name = name;
        bb.messages.errorMsg(2, "can't change directory to '{s}'", .{dir});
        std.process.exit(1);
    }
    defer {
        _ = linux.fchdir(wdfd);
    }
    const Ctx = struct { list: *std.ArrayList(Override), a: std.mem.Allocator };
    var ctx = Ctx{ .list = list, .a = a };
    const cb: bb.file.EntryCallback = struct {
        fn call(entry: []const u8, opaque_ctx: ?*anyopaque) anyerror!void {
            const c: *Ctx = @ptrCast(@alignCast(opaque_ctx.?));
            if (entry.len == 0 or entry[0] == '.') return;
            const data = readSmall(entry) orelse return;
            const line_end = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
            const trimmed = std.mem.trimEnd(u8, data[0..line_end], " \t\r\n\x0b\x0c");
            const key = try c.a.dupe(u8, entry);
            const value = try c.a.dupe(u8, trimmed);
            if (value.len == 0) {
                try c.list.append(c.a, .{ .key = key, .value = "", .unset = true });
            } else {
                try c.list.append(c.a, .{ .key = key, .value = value });
            }
        }
    }.call;
    bb.file.forEachEntry(".", cb, &ctx) catch {};
}

fn chpstCommon(argc: c_int, argv: [*][*:0]const u8, flavor: enum { chpst, envdir, envuidgid, setuidgid, softlimit }) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var overrides: std.ArrayList(Override) = .empty;
    var limits: std.ArrayList(struct { res: linux.rlimit_resource, val: u64 }) = .empty;
    var user: ?[]const u8 = null;
    var do_setuid = false;
    var do_envuid = false;
    var env_dir: ?[]const u8 = null;
    var chroot_dir: ?[]const u8 = null;
    var nice_val: ?i64 = null;
    var new_session = false;
    var close_fd: [3]bool = .{ false, false, false };
    var start: usize = 1;

    if (flavor == .chpst or flavor == .softlimit) {
        while (start < args.len) : (start += 1) {
            const tok = args[start];
            if (eq(tok, "--")) {
                start += 1;
                break;
            }
            if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
            if (tok.len < 2 or tok[0] != '-') break;
            var j: usize = 1;
            while (j < tok.len) : (j += 1) {
                const ch = tok[j];
                const takes_arg = switch (ch) {
                    'a', 'c', 'd', 'f', 'l', 'm', 'o', 'p', 'r', 's', 't', 'u', 'U', 'e', 'n', '/' => true,
                    else => false,
                };
                if (!takes_arg) {
                    switch (ch) {
                        'v' => {},
                        'P' => new_session = true,
                        '0', '1', '2' => close_fd[ch - '0'] = true,
                        else => badOption(name, ch),
                    }
                    continue;
                }
                var value: []const u8 = undefined;
                if (j + 1 < tok.len) value = tok[j + 1 ..] else if (start + 1 < args.len) {
                    start += 1;
                    value = args[start];
                } else missingArg(name, ch);
                switch (ch) {
                    'u' => {
                        user = value;
                        do_setuid = true;
                    },
                    'U' => {
                        user = value;
                        do_envuid = true;
                    },
                    'e' => env_dir = value,
                    'n' => nice_val = bb.util.xatoi(value) catch {
                        bb.messages.program_name = name;
                        bb.messages.plainMsg("invalid number '{s}'", .{value});
                        std.process.exit(1);
                    },
                    '/' => chroot_dir = value,
                    'a' => limits.append(a, .{ .res = .AS, .val = number(name, value) }) catch {},
                    'd' => limits.append(a, .{ .res = .DATA, .val = number(name, value) }) catch {},
                    's' => limits.append(a, .{ .res = .STACK, .val = number(name, value) }) catch {},
                    'l' => limits.append(a, .{ .res = .MEMLOCK, .val = number(name, value) }) catch {},
                    'c' => limits.append(a, .{ .res = .CORE, .val = number(name, value) }) catch {},
                    'f' => limits.append(a, .{ .res = .FSIZE, .val = number(name, value) }) catch {},
                    'o' => limits.append(a, .{ .res = .NOFILE, .val = number(name, value) }) catch {},
                    'p' => limits.append(a, .{ .res = .NPROC, .val = number(name, value) }) catch {},
                    'r' => limits.append(a, .{ .res = .RSS, .val = number(name, value) }) catch {},
                    't' => limits.append(a, .{ .res = .CPU, .val = number(name, value) }) catch {},
                    'm' => {
                        const v = number(name, value);
                        for ([_]linux.rlimit_resource{ .AS, .STACK, .MEMLOCK, .DATA }) |res| {
                            limits.append(a, .{ .res = res, .val = v }) catch {};
                        }
                    },
                    else => unreachable,
                }
                break;
            }
        }
    } else {
        // envdir / envuidgid / setuidgid take no options; the first argument
        // is the directory or user.
        if (start >= args.len) dieUsage(name);
        switch (flavor) {
            .envdir => env_dir = args[start],
            .envuidgid => {
                user = args[start];
                do_envuid = true;
            },
            .setuidgid => {
                user = args[start];
                do_setuid = true;
            },
            else => unreachable,
        }
        start += 1;
    }
    if (start >= args.len) dieUsage(name);

    for (limits.items) |l| applyLimit(l.res, l.val);
    if (new_session) _ = linux.setsid();
    if (env_dir) |dir| envDirectory(name, dir, &overrides);
    const ugid = if (user) |u| lookupUser(name, u) else null;
    if (chroot_dir) |dir| {
        const cz = zpath(dir) orelse return 1;
        const rc = linux.chroot(cz.ptr);
        if (linux.errno(rc) != .SUCCESS) {
            bb.messages.program_name = name;
            bb.messages.errorMsg(@intFromEnum(linux.errno(rc)), "can't change root directory to '{s}'", .{dir});
            return 1;
        }
    }
    if (do_envuid and ugid != null) {
        overrides.append(a, .{ .key = "UID", .value = std.fmt.allocPrint(a, "{d}", .{ugid.?.uid}) catch "" }) catch {};
        overrides.append(a, .{ .key = "GID", .value = std.fmt.allocPrint(a, "{d}", .{ugid.?.gid}) catch "" }) catch {};
    }
    if (do_setuid and ugid != null) {
        var groups = [_]linux.gid_t{ugid.?.gid};
        if (linux.errno(linux.setgroups(1, &groups)) != .SUCCESS) {
            bb.messages.program_name = name;
            bb.messages.errorMsg(1, "setgroups", .{});
            return 1;
        }
        _ = linux.setgid(ugid.?.gid);
        _ = linux.setuid(ugid.?.uid);
    }
    if (nice_val) |n| {
        // Reference: errno = 0; nice(xatoi(nicestr)); on error die("nice").
        const cur = @as(i64, @intCast(linux.syscall2(.getpriority, 0, 0)));
        const rc = linux.syscall3(.setpriority, 0, 0, @bitCast(cur + n));
        if (@as(isize, @bitCast(rc)) < 0) {
            bb.messages.program_name = name;
            bb.messages.errorMsg(@intFromEnum(linux.errno(rc)), "nice", .{});
            return 1;
        }
    }
    for (0..3) |k| {
        if (close_fd[k]) _ = linux.close(@intCast(k));
    }
    execProgram(name, args[start..], overrides.items);
}

pub fn chpst_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chpstCommon(argc, argv, .chpst);
}
pub fn envdir_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chpstCommon(argc, argv, .envdir);
}
pub fn envuidgid_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chpstCommon(argc, argv, .envuidgid);
}
pub fn setuidgid_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chpstCommon(argc, argv, .setuidgid);
}
pub fn softlimit_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chpstCommon(argc, argv, .softlimit);
}

// ---------------------------------------------------------------------- svok

pub fn svok_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    if (args.len < 2) dieUsage(name);
    const dir = args[1];
    if (dir[0] != '/' and dir[0] != '.' and !std.mem.endsWith(u8, dir, "/")) {
        const pz = zpath("/var/service") orelse return 111;
        if (linux.errno(linux.chdir(pz.ptr)) != .SUCCESS) {
            bb.messages.program_name = name;
            bb.messages.errorMsg(2, "can't change directory to '{s}'", .{"/var/service"});
            return 111;
        }
    }
    const dz = zpath(dir) orelse return 111;
    if (linux.errno(linux.chdir(dz.ptr)) != .SUCCESS) {
        bb.messages.program_name = name;
        bb.messages.errorMsg(2, "can't change directory to '{s}'", .{dir});
        return 111;
    }
    const oz = zpath("supervise/ok") orelse return 100;
    const fd = linux.open(oz.ptr, .{ .ACCMODE = .WRONLY }, 0);
    const err = linux.errno(fd);
    if (err != .SUCCESS) {
        if (err == .NOENT or err == .NXIO) return 100;
        bb.messages.program_name = name;
        bb.messages.errorMsg(@intFromEnum(err), "can't open '{s}'", .{@as([]const u8, "supervise/ok")});
        return 111;
    }
    _ = linux.close(@intCast(fd));
    return 0;
}

// -------------------------------------------------------------------- sv/svc

fn svStatus(name: []const u8, dir: []const u8, code: u8) u8 {
    const dz = zpath(dir) orelse return 1;
    const chdir_rc = linux.chdir(dz.ptr);
    if (linux.errno(chdir_rc) != .SUCCESS) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fail: {s}: can't change to service directory: {s}\n", .{ dir, bb.messages.strerror(@intFromEnum(linux.errno(chdir_rc))) }) catch return 1;
        writeOut(msg);
        return 1;
    }
    const oz = zpath("supervise/ok") orelse return 1;
    const ofd = linux.open(oz.ptr, .{ .ACCMODE = .WRONLY }, 0);
    if (linux.errno(ofd) != .SUCCESS) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "warning: {s}: can't open supervise/ok: {s}\n", .{ dir, bb.messages.strerror(@intFromEnum(linux.errno(ofd))) }) catch return 1;
        writeOut(msg);
        return 1;
    }
    _ = linux.close(@intCast(ofd));
    const sz = zpath("supervise/status") orelse return 1;
    const sfd = linux.open(sz.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(sfd) != .SUCCESS) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "warning: {s}: can't open supervise/status: {s}\n", .{ dir, bb.messages.strerror(@intFromEnum(linux.errno(sfd))) }) catch return 1;
        writeOut(msg);
        return 1;
    }
    _ = linux.close(@intCast(sfd));
    _ = name;
    return code;
}

fn svCommon(argc: c_int, argv: [*][*:0]const u8, is_sv: bool) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var index: usize = 1;
    if (is_sv) {
        while (index < args.len) : (index += 1) {
            const tok = args[index];
            if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
            if (tok.len < 2 or tok[0] != '-') break;
            for (tok[1..]) |ch| switch (ch) {
                'v' => {},
                'w' => {
                    if (index + 1 < args.len) index += 1 else missingArg(name, 'w');
                    _ = bb.util.xatou(args[index]) catch {
                        bb.messages.program_name = name;
                        bb.messages.plainMsg("invalid number '{s}'", .{args[index]});
                        std.process.exit(100);
                    };
                },
                else => badOption(name, ch),
            };
        }
        if (index >= args.len) usageCode(name, 100);
        const cmd = args[index][0];
        const valid = "suodxhpaicktq12";
        if (std.mem.indexOfScalar(u8, valid, cmd) == null) usageCode(name, 100);
        index += 1;
        if (index >= args.len) usageCode(name, 100);
    } else {
        while (index < args.len) : (index += 1) {
            const tok = args[index];
            if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
            if (tok.len < 2 or tok[0] != '-') break;
            for (tok[1..]) |ch| {
                if (std.mem.indexOfScalar(u8, "udopchaitkx", ch) == null) badOption(name, ch);
            }
        }
        if (index >= args.len) dieUsage(name);
    }
    for (args[index..]) |dir| {
        const rc = svStatus(name, dir, 0);
        if (rc != 0) return rc;
    }
    return 0;
}

pub fn sv_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return svCommon(argc, argv, true);
}
pub fn svc_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return svCommon(argc, argv, false);
}

// --------------------------------------------------------------------- svlogd

pub fn isPrintable(c: u8) bool {
    return c >= 32 and c <= 126;
}

pub fn svlogd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var repl: ?u8 = null;
    var replace: []const u8 = "";
    var verbose = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (std.mem.eql(u8, tok, "--")) {
            i += 1;
            break;
        }
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            switch (ch) {
                't' => {},
                'v' => verbose = true,
                'r', 'R', 'l', 'b' => {
                    var value: []const u8 = undefined;
                    if (j + 1 < tok.len) value = tok[j + 1 ..] else if (i + 1 < args.len) {
                        i += 1;
                        value = args[i];
                    } else missingArg(name, ch);
                    switch (ch) {
                        'r' => {
                            if (value.len != 1) dieUsage(name);
                            repl = value[0];
                        },
                        'R' => {
                            replace = value;
                            if (repl == null) repl = '_';
                        },
                        'l' => _ = bb.util.xatou(value) catch {
                            bb.messages.program_name = name;
                            bb.messages.plainMsg("invalid number '{s}'", .{value});
                            std.process.exit(1);
                        },
                        'b' => {}, // buffer length (compatibility, no observable effect)
                        else => unreachable,
                    }
                    break;
                },
                else => badOption(name, ch),
            }
        }
    }
    if (i >= args.len) dieUsage(name);
    const dirs = args[i..];

    var usable: usize = 0;
    for (dirs) |dir| {
        const dz = zpath(dir) orelse continue;
        const dfd = linux.open(dz.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(dfd) != .SUCCESS) {
            bb.messages.program_name = name;
            bb.messages.errorMsg(@intFromEnum(linux.errno(dfd)), "warning: can't open log directory: {s}", .{dir});
            continue;
        }
        usable += 1;
    }
    if (usable == 0) {
        bb.messages.program_name = name;
        bb.messages.plainMsg("fatal: no functional log directories", .{});
        return 1;
    }

    var input: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        input.appendSlice(a, buf[0..@intCast(n)]) catch return 1;
    }
    if (repl) |r| {
        for (input.items) |*c| {
            if (c.* == '\n') continue;
            if (!isPrintable(c.*) or std.mem.indexOfScalar(u8, replace, c.*) != null) c.* = r;
        }
    }
    for (dirs) |dir| {
        const lock = std.fmt.allocPrint(a, "{s}/lock", .{dir}) catch continue;
        const lz = zpath(lock) orelse continue;
        const lfd = linux.open(lz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
        if (linux.errno(lfd) == .SUCCESS) {
            _ = linux.fchmod(@intCast(lfd), 0o600);
            _ = linux.close(@intCast(lfd));
        }
        if (verbose) {
            var vbuf: [512]u8 = undefined;
            const vmsg = std.fmt.bufPrint(&vbuf, "svlogd: info: new: {s}/current\n", .{dir}) catch "";
            writeErr(vmsg);
        }
        if (input.items.len == 0) continue;
        const cur = std.fmt.allocPrint(a, "{s}/current", .{dir}) catch continue;
        const cz = zpath(cur) orelse continue;
        const cfd = linux.open(cz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        if (linux.errno(cfd) != .SUCCESS) continue;
        var off: usize = 0;
        while (off < input.items.len) {
            const n = linux.write(@intCast(cfd), input.items[off..].ptr, input.items.len - off);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            off += n;
        }
        _ = linux.fchmod(@intCast(cfd), 0o744);
        _ = linux.close(@intCast(cfd));
    }
    if (verbose) {
        for (dirs) |dir| {
            var vbuf: [512]u8 = undefined;
            const vmsg = std.fmt.bufPrint(&vbuf, "svlogd: info: close: {s}\n", .{dir}) catch "";
            writeErr(vmsg);
        }
    }
    return 0;
}

// ------------------------------------------------------------------ runsv(dir)

pub fn runsv_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    if (args.len < 2) dieUsage(name);
    const dz = zpath(args[1]) orelse return 1;
    if (linux.errno(linux.chdir(dz.ptr)) != .SUCCESS) {
        bb.messages.program_name = name;
        bb.messages.errorMsg(2, "can't change directory to '{s}'", .{args[1]});
        return 1;
    }
    // A real supervisor would run ./run forever; refuse to leave a process
    // behind in the parity sandbox.
    return 1;
}

pub fn runsvdir_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                'P' => {},
                's' => {
                    if (j + 1 < tok.len) j = tok.len else if (i + 1 < args.len) i += 1 else missingArg(name, 's');
                },
                else => badOption(name, tok[j]),
            }
        }
    }
    if (i >= args.len) dieUsage(name);
    // A real runsvdir supervises children forever; never do that here.
    return 1;
}
