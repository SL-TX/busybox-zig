//! popmaildir — fetch a POP3 mailbox into a local Maildir
//! (reference mailutils/popmaildir.c). The network connection is provided by
//! the documented CONN_HELPER ARGS mechanism (launch_helper); tests use a
//! loopback POP3 server and a local helper only.

const std = @import("std");
const linux = std.os.linux;
const m = @import("mail_common.zig");

const SPECS = [_]m.OptSpec{
    .{ .ch = 'b', .kind = .none },
    .{ .ch = 'd', .kind = .none },
    .{ .ch = 'm', .kind = .none },
    .{ .ch = 'V', .kind = .none },
    .{ .ch = 'c', .kind = .none },
    .{ .ch = 'a', .kind = .none },
    .{ .ch = 's', .kind = .none },
    .{ .ch = 'T', .kind = .none },
    .{ .ch = 'k', .kind = .none },
    .{ .ch = 't', .kind = .int },
    .{ .ch = 'R', .kind = .int },
    .{ .ch = 'Z', .kind = .required },
    .{ .ch = 'L', .kind = .int },
    .{ .ch = 'H', .kind = .int },
    .{ .ch = 'M', .kind = .required },
    .{ .ch = 'F', .kind = .required },
};

const BIT_a = 1 << 5;
const BIT_s = 1 << 6;
const BIT_T = 1 << 7;
const BIT_k = 1 << 8;
const BIT_M = 1 << 14;
const BIT_F = 1 << 15;

const Globals = struct {
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
};

pub fn popmaildirMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    m.setProg(argv);
    const av = m.argsFrom(argv, argc);
    const opts = m.parseOptions("popmaildir", av, &SPECS);
    // opt_complementary "-1": at least one positional (MAILDIR) is required.
    if (opts.args.len == 0) m.usageDie("popmaildir");

    if (opts.value('t')) |v| m.timeout_secs = std.fmt.parseInt(u32, v, 10) catch 0;

    var g = Globals{};
    if ((opts.flags & BIT_s) == 0) getCredOrDie(&g);

    const maildir = opts.args[0];
    const helper_args = opts.args[1..];
    chdirOrDie(maildir);
    if (helper_args.len > 0) m.launchHelper(helper_args);

    var greeting: ?[]u8 = null;
    defer if (greeting) |v| m.A.free(v);
    pop3Checkr(null, true, &greeting);

    if ((opts.flags & BIT_s) == 0) {
        if (greeting != null and greeting.?[0] == '<' and (opts.flags & BIT_a) != 0) {
            var stamp = greeting.?;
            if (std.mem.indexOfScalar(u8, stamp, '>')) |p| stamp = stamp[0 .. p + 1];
            const digest = md5Hex(stamp, g.pass orelse "");
            const cmd = std.fmt.allocPrint(m.A, "APOP {s} {s}", .{ g.user orelse "", digest }) catch return 1;
            defer m.A.free(cmd);
            pop3Checkr(cmd, false, null);
        } else {
            const user_cmd = std.fmt.allocPrint(m.A, "USER {s}", .{g.user orelse ""}) catch return 1;
            defer m.A.free(user_cmd);
            pop3Checkr(user_cmd, false, null);
            const pass_cmd = std.fmt.allocPrint(m.A, "PASS {s}", .{g.pass orelse ""}) catch return 1;
            defer m.A.free(pass_cmd);
            pop3Checkr(pass_cmd, false, null);
        }
    }

    var stat: ?[]u8 = null;
    defer if (stat) |v| m.A.free(v);
    pop3Checkr("STAT", true, &stat);
    const nmsg: u32 = atoiPrefix(stat orelse "");

    const host = m.hostname();
    const pid: u32 = @intCast(linux.getpid());
    const nlines: u32 = if (opts.value('H')) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 0;

    var n = nmsg;
    while (n > 0) : (n -= 1) {
        const us: u64 = m.monotonicUs();
        const filename = std.fmt.allocPrint(m.A, "tmp/{d}.{d}.{s}", .{ us, pid, host }) catch return 1;
        defer m.A.free(filename);

        const retr = if ((opts.flags & BIT_T) != 0)
            std.fmt.allocPrint(m.A, "TOP {d} {d}", .{ n, nlines }) catch return 1
        else
            std.fmt.allocPrint(m.A, "RETR {d}", .{n}) catch return 1;
        defer m.A.free(retr);
        pop3Checkr(retr, false, null);

        const delivery = opts.value('M') orelse opts.value('F');
        var target: linux.fd_t = 1;
        var child: ?linux.pid_t = null;
        if ((opts.flags & (BIT_M | BIT_F)) != 0 and delivery != null) {
            const envs = [_]m.EnvVar{.{ .key = "FILENAME", .value = filename }};
            const filter = m.spawnFilter(&.{ "sh", "-c", delivery.? }, &envs);
            target = filter.fd;
            child = filter.pid;
        } else {
            const z = m.zstr(filename) catch return 1;
            const fd = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
            if (linux.errno(fd) != .SUCCESS)
                m.errorDie(@intFromEnum(linux.errno(fd)), "can't open '{s}'", .{filename});
            target = @intCast(fd);
        }

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(m.A);
        while (m.readCrLfLine(0, &line)) |ln| {
            var s = ln;
            if (s.len > 0 and s[0] == '.') {
                if (s.len > 1 and s[1] == '.') {
                    s = s[1..];
                } else if (s.len == 3 and s[1] == '\r' and s[2] == '\n') {
                    break;
                }
            }
            m.writeAll(target, s);
        }
        _ = linux.close(target);
        if (child) |cpid| {
            _ = m.waitChild(cpid);
            // popen()+pclose() path: the reference skips DELE and rename.
            continue;
        }

        if ((opts.flags & BIT_k) == 0) {
            const dele = std.fmt.allocPrint(m.A, "DELE {d}", .{n}) catch return 1;
            defer m.A.free(dele);
            pop3Checkr(dele, false, null);
        }

        const target_name = std.fmt.allocPrint(m.A, "new/{s}", .{filename[4..]}) catch return 1;
        defer m.A.free(target_name);
        const from_z = m.zstr(filename) catch return 1;
        const to_z = m.zstr(target_name) catch return 1;
        const rc = linux.rename(from_z, to_z);
        if (linux.errno(rc) != .SUCCESS) {
            m.errorMsg(@intFromEnum(linux.errno(rc)), "can't rename '{s}' to '{s}'", .{ filename, target_name });
            break;
        }
    }

    pop3Checkr("QUIT", false, null);
    return 0;
}

fn getCredOrDie(g: *Globals) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(m.A);
    const user = m.readLine(0, true, &buf) orelse m.plainDie("no username or password", .{});
    g.user = m.A.dupe(u8, user) catch return;
    const pass = m.readLine(0, true, &buf) orelse m.plainDie("no username or password", .{});
    g.pass = m.A.dupe(u8, pass) catch return;
    if (g.user.?.len == 0 or g.pass == null) m.plainDie("no username or password", .{});
}

fn chdirOrDie(path: []const u8) void {
    const z = m.zstr(path) catch return;
    const rc = linux.chdir(z);
    if (linux.errno(rc) != .SUCCESS)
        m.errorDie(@intFromEnum(linux.errno(rc)), "can't chdir to '{s}'", .{path});
}

fn pop3Checkr(msg: ?[]const u8, want_ret: bool, ret: ?*?[]u8) void {
    if (msg) |cmd| {
        m.armTimeout();
        m.out(cmd);
        m.out("\r\n");
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(m.A);
    const answer = m.readLine(0, true, &buf) orelse "";
    if (answer.len > 0 and answer[0] == '+') {
        m.cancelTimeout();
        if (want_ret and ret != null) {
            const value = if (answer.len >= 4) answer[4..] else "";
            ret.?.* = m.A.dupe(u8, value) catch null;
        }
        return;
    }
    m.plainDie("{s} failed, reply was: {s}", .{ msg orelse "(null)", answer });
}

fn atoiPrefix(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n *% 10 +% @as(u32, c - '0');
    }
    return n;
}

fn md5Hex(stamp: []const u8, pass: []const u8) []const u8 {
    const joined = std.mem.concat(m.A, u8, &.{ stamp, pass }) catch return "";
    defer m.A.free(joined);
    var digest: [16]u8 = undefined;
    m.md5(joined, &digest);
    const hex = m.A.alloc(u8, 32) catch return "";
    const chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[2 * i] = chars[b >> 4];
        hex[2 * i + 1] = chars[b & 0xf];
    }
    return hex;
}
