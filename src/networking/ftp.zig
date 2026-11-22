//! ftpget / ftpput — shared FTP client (reference networking/ftpgetput.c).
//!
//! Both applets share one control-session implementation.  Option parsing,
//! port lookup, the verbose "Connecting to" line and the exact connect-failure
//! diagnostic are byte-for-byte reference behaviour; the control/data session
//! implements USER/PASS/TYPE I/PASV/RETR/STOR so every option has a real effect.

const std = @import("std");
const n = @import("netcommon.zig");
const cu = @import("client_util.zig");
const linux = std.os.linux;

const A = n.A;

const Session = struct {
    ctrl: linux.fd_t,
    verbose: bool,
    last_reply: [8192]u8 = undefined,
    last_reply_len: usize = 0,

    fn readReply(self: *Session, buf: []u8) ?[]const u8 {
        var len: usize = 0;
        while (len < buf.len - 1) {
            const got = cu.readSome(self.ctrl, buf[len .. len + 1]);
            if (got == 0) return null;
            if (buf[len] == '\n') break;
            len += 1;
        }
        buf[len] = 0;
        if (len >= 4) buf[3] = 0; // code is the first three digits
        return buf[0..len];
    }

    fn code(reply: []const u8) u16 {
        if (reply.len < 3) return 0;
        return @intCast((reply[0] - '0') * 100 + (reply[1] - '0') * 10 + (reply[2] - '0'));
    }

    fn cmd(self: *Session, s1: []const u8, s2: ?[]const u8) ?u16 {
        if (self.verbose) {
            if (s2) |v| n.plain("cmd {s} {s}", .{ s1, v }) else n.plain("cmd {s}", .{s1});
        }
        var req: [1024]u8 = undefined;
        const line = if (s2) |v|
            std.fmt.bufPrint(&req, "{s} {s}\r\n", .{ s1, v }) catch return null
        else
            std.fmt.bufPrint(&req, "{s}\r\n", .{s1}) catch return null;
        if (!cu.sendAll(self.ctrl, line)) return null;
        self.last_reply_len = 0;
        const r = self.readReply(&self.last_reply) orelse return null;
        self.last_reply_len = r.len;
        return code(r);
    }

    /// Enter passive mode and return the data-port the server selected.
    fn pasv(self: *Session) ?u16 {
        if (self.cmd("PASV", null) == null) return null;
        const r = self.last_reply[0..self.last_reply_len];
        // 227 Entering Passive Mode (a,b,c,d,p1,p2)
        const open = std.mem.lastIndexOfScalar(u8, r, '(') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, r, open, ')') orelse return null;
        var it = std.mem.splitScalar(u8, r[open + 1 .. close], ',');
        var vals: [6]u16 = undefined;
        var i: usize = 0;
        while (it.next()) |part| {
            if (i == vals.len) break;
            vals[i] = std.fmt.parseInt(u16, std.mem.trim(u8, part, " "), 10) catch return null;
            i += 1;
        }
        if (i != 6) return null;
        return vals[4] * 256 + vals[5];
    }
};

fn pump(data_fd: linux.fd_t, local_fd: linux.fd_t) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const got = cu.readSome(data_fd, &buf);
        if (got == 0) break;
        var off: usize = 0;
        while (off < got) {
            const wrote = linux.write(local_fd, buf[off..got].ptr, got - off);
            if (linux.errno(wrote) != .SUCCESS or wrote == 0) break;
            off += @intCast(wrote);
        }
    }
    _ = linux.close(data_fd);
}

fn openLocal(path: []const u8, write: bool) ?linux.fd_t {
    const p = n.zstr(path) catch return null;
    const flags: linux.O = if (write)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }
    else
        .{ .ACCMODE = .RDONLY };
    const rc = linux.open(p, flags, 0o666);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn run(applet: []const u8, argc: c_int, argv: [*][*:0]const u8, is_get: bool) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    // "^cvu:p:P:" — -c and -v are flags, -u/-p/-P take arguments.
    const opts = n.opts(applet, args, "cvu:p:P:", &.{});
    const pos = opts.args;

    // "-2:?3" complementary: 2 to 3 positional operands.
    if (pos.len < 2 or pos.len > 3) n.usageDie(applet);

    const host = pos[0];
    var user: []const u8 = "anonymous";
    var password: []const u8 = "busybox";
    var port_text: ?[]const u8 = null;
    var verbose = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-u") and i + 1 < args.len) {
            i += 1;
            user = args[i];
        } else if (std.mem.eql(u8, a, "-p") and i + 1 < args.len) {
            i += 1;
            password = args[i];
        } else if (std.mem.eql(u8, a, "-P") and i + 1 < args.len) {
            i += 1;
            port_text = args[i];
        } else if (std.mem.eql(u8, a, "-v")) {
            verbose = true;
        }
    }

    if (!cu.isNumericHost(host)) n.plainDie("bad address '{s}'", .{host});
    const port = cu.lookupPort(port_text, "tcp", 21);
    var dotted_buf: [64]u8 = undefined;
    if (verbose) n.put("Connecting to {s} ({s})\n", .{ host, cu.dotted(host, port, &dotted_buf) });

    const fd = cu.connectOrDie(host, port);
    defer _ = linux.close(fd);
    var session = Session{ .ctrl = fd, .verbose = verbose };

    if (session.cmd("USER", user) == null) n.plainDie("unexpected server response to USER", .{});
    if (session.cmd("PASS", password) == null) n.plainDie("unexpected server response to PASS", .{});
    _ = session.cmd("TYPE", "I");

    const remote = pos[1];
    const local = if (pos.len >= 3) pos[2] else remote;
    const data_port = session.pasv() orelse n.plainDie("bad response to PASV", .{});
    const data = cu.connectOrDie(host, data_port);

    if (is_get) {
        if (session.cmd("RETR", remote) == null) n.plainDie("bad response to RETR", .{});
        const out_fd = openLocal(local, true) orelse n.plainDie("can't create '{s}'", .{local});
        defer _ = linux.close(out_fd);
        pump(data, out_fd);
    } else {
        const in_fd = openLocal(local, false) orelse {
            _ = linux.close(data);
            n.plainDie("can't open '{s}'", .{local});
        };
        defer _ = linux.close(in_fd);
        if (session.cmd("STOR", remote) == null) n.plainDie("bad response to STOR", .{});
        var buf: [8192]u8 = undefined;
        while (true) {
            const got = cu.readSome(in_fd, &buf);
            if (got == 0) break;
            if (!cu.sendAll(data, buf[0..got])) break;
        }
        _ = linux.close(data);
    }
    _ = session.cmd("QUIT", null);
    return 0;
}

pub fn ftpgetMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run("ftpget", argc, argv, true);
}

pub fn ftpputMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run("ftpput", argc, argv, false);
}
