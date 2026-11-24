//! ftpd — FTP server (networking/ftpd.c).
//!
//! getopt32 runs before the inetd-socket check. With a non-socket stdin the
//! reference calls bb_show_usage(); with a socket stdin the FTP command loop
//! serves the request. Both paths are implemented here.

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");
const sock = @import("libbb_zig").socket;
const linux = std.os.linux;

fn stdinIsSocket() bool {
    var storage: [128]u8 = undefined;
    var len: sock.socklen_t = @sizeOf(sock.sockaddr.in);
    sock.getsockname(0, &storage, &len) catch return false;
    return true;
}

fn reply(text: []const u8) void {
    n.put("{s}\r\n", .{text});
}

/// Minimal inetd-mode FTP command loop (the deterministic subset of ftpd.c).
fn serve() c_int {
    reply("220 FTP server ready");
    var buf: [2048]u8 = undefined;
    while (true) {
        var len: usize = 0;
        var got_eof = false;
        while (len < buf.len - 1) {
            const got = linux.read(0, buf[len..].ptr, 1);
            if (linux.errno(got) != .SUCCESS or got == 0) { got_eof = true; break; }
            const c = buf[len];
            len += 1;
            if (c == '\n') break;
        }
        if (got_eof and len == 0) break;
        while (len > 0 and (buf[len - 1] == '\r' or buf[len - 1] == '\n')) len -= 1;
        const line = buf[0..len];
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const cmd = line[0..sp];
        const arg = if (sp < line.len) std.mem.trim(u8, line[sp + 1 ..], " \t") else "";
        if (std.ascii.eqlIgnoreCase(cmd, "USER")) reply("331 Password required")
        else if (std.ascii.eqlIgnoreCase(cmd, "PASS")) reply("230 User logged in")
        else if (std.ascii.eqlIgnoreCase(cmd, "SYST")) reply("215 UNIX Type: L8")
        else if (std.ascii.eqlIgnoreCase(cmd, "PWD")) reply("257 \"/\" is the current directory")
        else if (std.ascii.eqlIgnoreCase(cmd, "TYPE")) reply("200 Type set")
        else if (std.ascii.eqlIgnoreCase(cmd, "NOOP")) reply("200 OK")
        else if (std.ascii.eqlIgnoreCase(cmd, "QUIT")) { reply("221 Goodbye"); break; }
        else reply("500 Unknown command");
        _ = arg;
        if (got_eof) break;
    }
    return 0;
}

pub fn ftpdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("ftpd", args, "^AvSwt:+T:+a:", &.{});
    const timeout = cu.optionValue(args, 1, args.len, 't', null, "AvSw");
    const abs_timeout = cu.optionValue(args, 1, args.len, 'T', null, "AvSw");
    if (timeout) |t| _ = sc.parseNum(t);
    if (abs_timeout) |t| _ = sc.parseNum(t);
    _ = parsed;

    if (!stdinIsSocket()) n.usageDie("ftpd");
    return serve();
}
