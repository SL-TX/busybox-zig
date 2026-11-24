//! pscan — TCP port scanner (networking/pscan.c).
//!
//! Non-blocking connect() with a per-port timeout, the exact scanning banner,
//! aligned result rows and the well-known service-name lookup are reproduced.

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const sock = @import("libbb_zig").socket;
const linux = std.os.linux;

fn serviceName(port: u16) []const u8 {
    return switch (port) {
        1 => "tcpmux", 7 => "echo", 9 => "discard", 13 => "daytime",
        19 => "chargen", 20 => "ftp-data", 21 => "ftp", 22 => "ssh",
        23 => "telnet", 25 => "smtp", 37 => "time", 53 => "domain",
        67 => "bootps", 68 => "bootpc", 69 => "tftp", 80 => "http",
        110 => "pop3", 111 => "sunrpc", 123 => "ntp", 137 => "netbios-ns",
        139 => "netbios-ssn", 143 => "imap2", 161 => "snmp", 179 => "bgp",
        443 => "https", 512 => "exec", 513 => "login", 514 => "shell",
        515 => "printer", 1080 => "socks", 2049 => "nfs", 3306 => "mysql",
        else => "unknown",
    };
}

fn probe(host: []const u8, port: u16, timeout_ms: u32) enum { open, closed, timedout } {
    const fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(fd) != .SUCCESS) return .closed;
    defer _ = linux.close(@intCast(fd));
    sock.setNonBlocking(@intCast(fd)) catch {};
    const addr = sock.sockaddr_in(host, port);
    _ = linux.connect(@intCast(fd), @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    var pfds = [_]linux.pollfd{.{ .fd = @intCast(fd), .events = linux.POLL.OUT, .revents = 0 }};
    const ready = linux.poll(&pfds, 1, @intCast(timeout_ms));
    if (linux.errno(ready) != .SUCCESS or ready == 0) return .timedout;
    var err: c_int = 0;
    var len: linux.socklen_t = @sizeOf(c_int);
    _ = linux.getsockopt(@intCast(fd), linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &len);
    if (err == 0) return .open;
    return if (err == @intFromEnum(linux.E.CONNREFUSED) or err == @intFromEnum(linux.E.HOSTUNREACH) or err == @intFromEnum(linux.E.NETUNREACH)) .closed else .timedout;
}

pub fn pscanMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("pscan", args, "^cbp:P:t:T:", &.{});
    const min_text = cuOption(args, 'p', "cb");
    const max_text = cuOption(args, 'P', "cb");
    const timeout_text = cuOption(args, 't', "cb");
    const rtt_text = cuOption(args, 'T', "cb");
    const min_port: u16 = @truncate(sc.parseNum(min_text orelse "1"));
    const max_port: u16 = @truncate(sc.parseNum(max_text orelse "1024"));
    const timeout_ms: u32 = if (timeout_text) |t| sc.parseNum(t) else 5000;
    if (rtt_text) |t| _ = sc.parseNum(t);
    if (parsed.args.len != 1) n.usageDie("pscan");

    const host = parsed.args[0];
    if (sock.inet_pton(host) == null) n.plainDie("bad address '{s}'", .{host});
    n.put("Scanning {s} ports {d} to {d}\n Port\tProto\tState\tService\n", .{ host, min_port, max_port });

    var closed: u32 = 0;
    var open: u32 = 0;
    var port: u32 = min_port;
    while (port <= max_port) : (port += 1) {
        const result = probe(host, @intCast(port), timeout_ms);
        const state = switch (result) {
            .open => "open",
            .closed => "closed",
            .timedout => "timed out",
        };
        switch (result) {
            .open => open += 1,
            .closed => closed += 1,
            .timedout => {},
        }
        const show = switch (result) {
            .open => true,
            .closed => (parsed.flags & 1) != 0,
            .timedout => (parsed.flags & 2) != 0,
        };
        if (show) {
            n.put("{d: >5}\ttcp\t{s}\t{s}\n", .{ port, state, serviceName(@intCast(port)) });
        }
    }
    n.put("{d} closed, {d} open, {d} timed out (or blocked) ports\n", .{
        closed, open, @as(u32, @intCast(max_port)) - min_port + 1 - closed - open,
    });
    return 0;
}

fn cuOption(args: []const []const u8, ch: u8, flag_chars: []const u8) ?[]const u8 {
    const cu = @import("client_util.zig");
    return cu.optionValue(args, 1, args.len, ch, null, flag_chars);
}
