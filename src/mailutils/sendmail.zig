//! sendmail — bare-bones SMTP client (reference mailutils/sendmail.c).
//!
//! The whole SMTP conversation is driven over fd 0/1, which are connected to
//! either -S HOST[:PORT] (loopback in tests) or the -H connection helper.
//! Verbose mode emits the exact send:/recv: transcript used by parity cases.

const std = @import("std");
const linux = std.os.linux;
const m = @import("mail_common.zig");

const SPECS = [_]m.OptSpec{
    .{ .ch = 't', .kind = .none },
    .{ .ch = 'f', .kind = .required },
    .{ .ch = 'o', .kind = .required },
    .{ .ch = 'i', .kind = .none },
    .{ .ch = 'w', .kind = .int },
    .{ .ch = 'H', .kind = .required },
    .{ .ch = 'S', .kind = .required },
    .{ .ch = 'a', .kind = .list },
    .{ .ch = 'v', .kind = .none },
};

const BIT_t = 1 << 0;
const BIT_f = 1 << 1;
const BIT_H = 1 << 5;
const BIT_S = 1 << 6;
const BIT_a = 1 << 7;
const BIT_v = 1 << 8;
const BIT_am_plain = 1 << 9;

const LastHdr = enum { other, tocc, bcc };

const Ctx = struct {
    verbose: bool,
    flags_t: bool = false,
    has_to: bool = false,
    last_hdr: LastHdr = .other,
    headers: std.ArrayList([]const u8) = .empty,
    recipients: []const []const u8 = &.{},
    nheaders: u32 = 0,
    data_started: bool = false,
};

pub fn sendmailMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    m.setProg(argv);
    const av = m.argsFrom(argv, argc);
    const opts = m.parseOptions("sendmail", av, &SPECS);
    global_verbose = (opts.flags & BIT_v) != 0 or opts.count('v') > 0;
    if (opts.value('w')) |v| m.timeout_secs = std.fmt.parseInt(u32, v, 10) catch 0;

    if ((opts.flags & BIT_H) != 0 and (opts.flags & BIT_S) != 0) m.usageDie("sendmail");
    if ((opts.flags & BIT_a) != 0 and opts.list.items.len == 0) m.usageDie("sendmail");

    var user: ?[]const u8 = null;
    var pass: ?[]const u8 = null;
    var auth = false;
    var plain = false;
    for (opts.list.items) |token| {
        if (token.len == 0) continue;
        auth = true;
        switch (token[0]) {
            'u' => user = token[1..],
            'p' => pass = token[1..],
            'm' => {
                if (token.len < 2) continue;
                const method = token[1] | 0x20;
                if (method == 'p') {
                    plain = true;
                } else if (method != 'l') {
                    m.plainDie("unsupported AUTH method {s}", .{token[1..]});
                }
            },
            else => {},
        }
    }

    // Preserve the original stdin on fd 3: body lines come from there, while
    // fd 0/1 become the SMTP socket (or the helper's pipes).
    _ = linux.dup2(0, 3);

    var connect_text: []const u8 = "127.0.0.1";
    if (m.getEnv("SMTPHOST")) |owned| { connect_text = owned; }
    if (opts.value('H')) |h| connect_text = h;
    if (opts.value('S')) |h| connect_text = h;

    if ((opts.flags & BIT_H) != 0) {
        m.launchHelper(&.{ "sh", "-c", connect_text });
        if (m.getEnv("SMTP_ANTISPAM_DELAY")) |delay| {
            const secs = std.fmt.parseInt(u32, delay, 10) catch 0;
            if (secs > 0) {
                var ts = linux.timespec{ .sec = secs, .nsec = 0 };
                _ = linux.nanosleep(&ts, &ts);
            }
        }
        const code = smtpCheck("NOOP", -1);
        if (code == 220) {
            _ = smtpCheck(null, 250);
        } else if (code != 250) {
            m.plainDie("SMTP init failed", .{});
        }
    } else {
        const ep = m.parseHostPort(connect_text, 25);
        const fd = m.connectOrDie(ep.host, ep.port);
        _ = linux.dup2(fd, 0);
        _ = linux.dup2(0, 1);
        _ = linux.close(fd);
        _ = smtpCheck(null, 220);
    }

    const host = m.hostname();
    const ehlo = std.fmt.allocPrint(m.A, "EHLO {s}", .{host}) catch return 1;
    defer m.A.free(ehlo);
    if (250 != smtpCheckp(ehlo, -1)) {
        const helo = std.fmt.allocPrint(m.A, "HELO {s}", .{host}) catch return 1;
        defer m.A.free(helo);
        _ = smtpCheckp(helo, 250);
    }

    if (auth) {
        if (user == null or pass == null) getCredOrDie(4, &user, &pass);
        if (plain) {
            _ = smtpCheck("AUTH PLAIN", 334);
            const u = user orelse "";
            const p = pass orelse "";
            const blob = std.mem.concat(m.A, u8, &.{ "\x00", u, "\x00", p }) catch return 1;
            defer m.A.free(blob);
            m.out(m.base64String(blob));
        } else {
            _ = smtpCheck("AUTH LOGIN", 334);
            m.out(m.base64String(user orelse ""));
            _ = smtpCheck("", 334);
            m.out(m.base64String(pass orelse ""));
        }
        _ = smtpCheck("", 235);
    }

    var from_owned: ?[]u8 = null;
    defer if (from_owned) |v| m.A.free(v);
    const sender: []const u8 = if (opts.value('f')) |f| f else blk: {
        const who = user orelse "root";
        from_owned = std.fmt.allocPrint(m.A, "{s}@{s}", .{ who, m.hostname() }) catch return 1;
        break :blk from_owned.?;
    };
    const mail_from = std.fmt.allocPrint(m.A, "MAIL FROM:<{s}>", .{sender}) catch return 1;
    defer m.A.free(mail_from);
    _ = smtpCheckp(mail_from, 250);

    var ctx = Ctx{
        .verbose = global_verbose,
        .flags_t = (opts.flags & BIT_t) != 0,
        .recipients = opts.args,
    };
    defer ctx.headers.deinit(m.A);
    processBody(&ctx);
    return 0;
}

fn verboseSend(ctx: *Ctx, s: []const u8) void {
    if (ctx.verbose) m.plain("send:'{s}'", .{s});
    m.out(s);
    m.out("\r\n");
}

fn smtpCheckp(msg: ?[]const u8, code: i32) i32 {
    if (msg != null) {
        // send_mail_command() logs via send_r_n(), which has no recipient
        // context here; the verbose transcript is produced by the caller for
        // message bodies. Command lines are logged centrally in verbose mode.
        sendCommand(msg);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(m.A);
    var n: i32 = 0;
    while (m.readLine(0, false, &buf)) |answer| {
        if (ctxVerbose()) m.plain("recv:'{s}'", .{answer});
        if (answer.len <= 3 or answer[3] != '-') {
            n = atoiPrefix(answer);
            break;
        }
    }
    m.cancelTimeout();
    if (code == -1 or (code != 0 and n == code)) return n;
    if (code == 0) return n;
    m.plainDie("{s} failed", .{msg orelse "(null)"});
}

fn smtpCheck(msg: ?[]const u8, code: i32) i32 {
    return smtpCheckp(msg, code);
}

var global_verbose: bool = false;
fn ctxVerbose() bool {
    return global_verbose;
}

fn sendCommand(msg: ?[]const u8) void {
    if (msg) |cmd| {
        m.armTimeout();
        if (ctxVerbose()) m.plain("send:'{s}'", .{cmd});
        m.out(cmd);
        m.out("\r\n");
    }
}

fn atoiPrefix(s: []const u8) i32 {
    var n: i32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n * 10 + @as(i32, c - '0');
    }
    return n;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn saneAddress(s: []const u8) []const u8 {
    const t = m.trim(s);
    for (t) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "=+_-.@", c) == null) {
            m.plain( "bad address '{s}'", .{t});
            return "";
        }
    }
    return t;
}

fn angleAddress(s: []const u8) []const u8 {
    const t = m.trim(s);
    if (t.len > 0 and t[t.len - 1] == '>') {
        if (std.mem.lastIndexOfScalar(u8, t, '<')) |p| return saneAddress(t[p + 1 .. t.len - 1]);
    }
    return saneAddress(t);
}

fn rcptto(address: []const u8) void {
    if (address.len == 0) return;
    const cmd = std.fmt.allocPrint(m.A, "RCPT TO:<{s}>", .{address}) catch return;
    defer m.A.free(cmd);
    if (smtpCheckp(cmd, -1) != 250)
        m.plain( "Bad recipient: <{s}>", .{address});
}

fn rcpttoList(ctx: *Ctx, list: []const u8) void {
    _ = ctx;
    var start: usize = 0;
    var in_quote = false;
    var prev: u8 = 0;
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        const ch = list[i];
        if (ch == '"' and prev != '\\') {
            in_quote = !in_quote;
        } else if (!in_quote and ch == ',') {
            rcptto(angleAddress(list[start..i]));
            start = i + 1;
        }
        prev = ch;
    }
    if (list.len == 0 or prev != ',') rcptto(angleAddress(list[start..]));
}

fn addHeader(ctx: *Ctx, s: []const u8) bool {
    ctx.nheaders += 1;
    if (ctx.nheaders >= 256) return false;
    ctx.headers.append(m.A, m.A.dupe(u8, s) catch return false) catch return false;
    return true;
}

fn reenter(ctx: *Ctx) bool {
    var check = true;
    for (ctx.recipients) |raw| {
        const addr = saneAddress(raw);
        rcptto(addr);
        if (!ctx.has_to) {
            const more = check and ctx.recipients.len > 1;
            const hdr = if (check and more)
                std.fmt.allocPrint(m.A, "To: {s},", .{addr}) catch return false
            else if (check)
                std.fmt.allocPrint(m.A, "To: {s}", .{addr}) catch return false
            else if (more)
                std.fmt.allocPrint(m.A, "{s},", .{addr}) catch return false
            else
                std.fmt.allocPrint(m.A, "{s}", .{addr}) catch return false;
            ctx.headers.append(m.A, hdr) catch return false;
            check = false;
        }
    }
    if (354 != smtpCheck("DATA", -1)) return false;
    ctx.data_started = true;
    for (ctx.headers.items) |hdr| verboseSend(ctx, hdr);
    return true;
}

fn startsIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn processBody(ctx: *Ctx) void {
    var mode: u32 = 0; // 0 = headers, 1 = body
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(m.A);
    var pending: ?[]const u8 = null;

    while (true) {
        if (mode == 0) {
            const maybe = m.readLine(3, true, &buf);
            if (maybe == null) {
                if (!reenter(ctx)) break;
                mode = 1;
                verboseSend(ctx, "");
                break;
            }
            const s = maybe.?;
            const to_hdr = startsIgnoreCase(s, "To:");
            if (to_hdr) ctx.has_to = true;
            if ((ctx.flags_t) and (to_hdr or startsIgnoreCase(s, "cc:"))) {
                rcpttoList(ctx, s[3..]);
                ctx.last_hdr = .tocc;
                if (!addHeader(ctx, s)) break;
                continue;
            }
            if ((ctx.flags_t) and startsIgnoreCase(s, "Bcc:")) {
                rcpttoList(ctx, s[4..]);
                ctx.last_hdr = .bcc;
                continue;
            }
            const continuation = ctx.headers.items.len > 0 and s.len > 0 and isSpace(s[0]);
            if (std.mem.indexOfScalar(u8, s, ':') != null or continuation) {
                if (continuation and ctx.last_hdr != .other) {
                    rcpttoList(ctx, s[1..]);
                    if (ctx.last_hdr == .bcc) continue;
                } else {
                    ctx.last_hdr = .other;
                }
                if (!addHeader(ctx, s)) break;
                continue;
            }
            if (!reenter(ctx)) break;
            mode = 1;
            pending = m.A.dupe(u8, s) catch null;
            continue;
        }
        const line = if (pending) |p| p else (m.readLine(3, true, &buf) orelse break);
        pending = null;
        if (line.len > 0 and line[0] == '.') m.out(".");
        verboseSend(ctx, line);
    }

    if (!ctx.data_started) {
        // The loop can only exit before DATA when the header cap was hit;
        // mirror the reference's "bail" path and skip the terminator.
        _ = smtpCheck("QUIT", 221);
        return;
    }
    _ = smtpCheck(".", 250);
    _ = smtpCheck("QUIT", 221);
}

fn getCredOrDie(fd: linux.fd_t, user: *?[]const u8, pass: *?[]const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(m.A);
    const u = m.readLine(fd, false, &buf) orelse m.plainDie("no username or password", .{});
    user.* = m.A.dupe(u8, u) catch return;
    const p = m.readLine(fd, false, &buf) orelse m.plainDie("no username or password", .{});
    pass.* = m.A.dupe(u8, p) catch return;
}
