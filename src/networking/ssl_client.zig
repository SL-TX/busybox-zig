//! ssl_client — pipe data to/from a TLS connection (networking/ssl_client.c).

const std = @import("std");
const linux = std.os.linux;
const n = @import("netcommon.zig");
const tls = @import("tls_core.zig");
const spawn = @import("ssl_spawn.zig");
const bb = @import("libbb_zig");

fn ignoreSigpipe() void {
    var act = linux.Sigaction{
        .handler = .{ .handler = @ptrFromInt(1) }, // SIG_IGN
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

fn optValue(args: []const []const u8, ch: u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-' or a[1] == '-' or std.mem.eql(u8, a, "--")) continue;
        for (a[1..], 0..) |c, j| {
            if (c != ch) continue;
            if (j + 2 < a.len) return a[j + 2 ..];
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
    }
    return null;
}

fn parseFd(text: []const u8) linux.fd_t {
    const v = std.fmt.parseInt(u32, text, 10) catch {
        n.plain("invalid number '{s}'", .{text});
        std.process.exit(1);
    };
    return @intCast(v);
}

const FdValues = struct { s: ?linux.fd_t = null, r: ?linux.fd_t = null };

/// getopt32's `s:+r:+` suffix makes the numeric conversion happen while the
/// options are parsed — before the applet's e/s/r exclusivity check. Walk the
/// option tokens in order and convert every -s/-r value as it appears, so
/// e.g. `-s abc -e true` reports `invalid number 'abc'`, not usage.
fn scanFdOptions(args: []const []const u8) FdValues {
    var out = FdValues{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        // The leading '+' in "^+..." stops option parsing at the first
        // non-option token; later "-s abc" is positional, not an option.
        if (tok.len < 2 or tok[0] != '-') break;
        if (std.mem.eql(u8, tok, "--")) break;
        if (tok[1] == '-') continue; // no long options for this applet
        var j: usize = 1;
        while (j < tok.len) {
            const c = tok[j];
            if (c == 's' or c == 'r') {
                var value: ?[]const u8 = null;
                if (j + 1 < tok.len) {
                    value = tok[j + 1 ..]; // attached form: -s3
                } else if (i + 1 < args.len) {
                    i += 1;
                    value = args[i];
                }
                const fd = parseFd(value orelse "0"); // missing arg already died in getopt32
                if (c == 's') out.s = fd else out.r = fd;
                break; // the option consumed the rest of the token
            }
            if (c == 'n') {
                // String option: skip its attached value (or the next token).
                if (j + 1 == tok.len and i + 1 < args.len) i += 1;
                break;
            }
            j += 1; // flag option (e)
        }
    }
    return out;
}

fn connectHost(host: []const u8) linux.fd_t {
    const addrs = bb.dns.lookupHost(host, 443) catch {
        n.plain("can't resolve '{s}'", .{host});
        std.process.exit(1);
    };
    if (addrs.len == 0) {
        n.plain("can't resolve '{s}'", .{host});
        std.process.exit(1);
    }
    return bb.socket.createAndConnect(addrs[0]) catch {
        n.errorMsg(111, "can't connect to {s}", .{host});
        std.process.exit(1);
    };
}

fn handshakeError(conn: *tls.Conn, e: anyerror) noreturn {
    switch (e) {
        error.WriteFailed => n.errorDie(conn.last_errno, "write error", .{}),
        error.ConnectionClosed, error.ReadFailed => n.plainDie("got bad TLS record (len:0) while expecting handshake record", .{}),
        error.BadCertificate => n.plainDie("certificate verification failed", .{}),
        error.BadFinished => n.plainDie("bad Finished message", .{}),
        error.BadMac => n.plainDie("bad record MAC", .{}),
        error.UnsupportedCipher => n.plainDie("no supported cipher", .{}),
        error.RngFailed => n.plainDie("can't get random bytes", .{}),
        else => n.plainDie("TLS handshake error", .{}),
    }
}

pub fn sslClientMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    ignoreSigpipe();
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = n.opts("ssl_client", args, "^+s:+r:+n:e", &.{});
    const has_s = (parsed.flags & 1) != 0;
    const has_r = (parsed.flags & 2) != 0;
    const has_n = (parsed.flags & 4) != 0;
    const has_e = (parsed.flags & 8) != 0;
    const fds = scanFdOptions(args);
    if (has_e and (has_s or has_r)) n.usageDie("ssl_client");

    const a = std.heap.page_allocator;
    var ifd: linux.fd_t = 0;
    var ofd: linux.fd_t = 1;
    var sni: ?[]const u8 = null;
    if (has_n) sni = optValue(args, 'n');

    if (has_e) {
        if (parsed.args.len == 0) n.usageDie("ssl_client");
        const child = spawn.spawn(parsed.args) catch n.errorDie(5, "pipe", .{});
        ofd = child.to_wr;
        ifd = child.from_rd;
    } else if (has_s or has_r) {
        if (!has_s or parsed.args.len != 0) n.usageDie("ssl_client");
        ofd = fds.s orelse n.usageDie("ssl_client");
        ifd = if (has_r) (fds.r orelse n.usageDie("ssl_client")) else ofd;
    } else {
        if (parsed.args.len != 1) n.usageDie("ssl_client");
        if (sni == null) sni = parsed.args[0];
        ifd = connectHost(parsed.args[0]);
        ofd = ifd;
    }

    var conn = tls.Conn.init(a, ifd, ofd, .client);
    defer conn.deinit();
    conn.hostname = sni;
    conn.handshakeClient() catch |e| handshakeError(&conn, e);

    conn.copyLoop(has_s) catch |e| {
        if (e == error.WriteFailed) n.errorDie(conn.last_errno, "write error", .{});
        if (e == error.ConnectionClosed or e == error.ReadFailed) return 0;
        if (e == error.RngFailed) n.plainDie("can't get random bytes", .{});
        n.plainDie("TLS I/O error", .{});
    };
    return 0;
}
