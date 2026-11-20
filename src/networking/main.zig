//! Networking applet implementations (ifconfig, ping, wget, nc).
//! Uses the raw Linux syscall interface from libbb_zig/socket.zig — the build
//! is statically linked without libc.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("libbb_zig").socket;

pub const init = struct {
    pub fn init() void {}
};

fn out(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const a = std.heap.page_allocator;
    const result = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| result[i] = std.mem.span(argv[i]);
    return result;
}

fn zstr(a: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    const owned = try std.mem.concatWithSentinel(a, u8, &.{s}, 0);
    return owned.ptr;
}

fn readWholeFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const p = try zstr(a, path);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try result.appendSlice(a, buf[0..n]);
    }
    return result.toOwnedSlice(a);
}

fn sendAll(fd: sock.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try sock.send(fd, bytes[off..], 0);
        if (n == 0) return error.SendFailed;
        off += n;
    }
}

fn readAll(fd: sock.fd_t, a: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = sock.recv(fd, &buf, 0) catch break;
        if (n == 0) break;
        try result.appendSlice(a, buf[0..n]);
    }
    return result.toOwnedSlice(a);
}

// ---------------------------------------------------------------- URL / HTTP

pub const HostPort = struct { host: []const u8, port: u16, path: []const u8 };

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Parse an http:// URL. Non-http schemes are rejected: adding new protocols
/// is out of scope for this port.
pub fn parseUrl(input: []const u8) ?HostPort {
    var rest = input;
    if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else if (std.mem.indexOf(u8, rest, "://") != null) {
        return null;
    }
    if (rest.len == 0) return null;

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    if (authority.len == 0) return null;

    var host = authority;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        const port_s = authority[colon + 1 ..];
        if (allDigits(port_s)) {
            port = std.fmt.parseInt(u16, port_s, 10) catch return null;
            host = authority[0..colon];
        }
    }
    if (host.len == 0) return null;
    return .{ .host = host, .port = port, .path = path };
}

pub fn buildHttpRequest(host: []const u8, port: u16, path: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ path, host, port });
}

/// Return the body of a complete HTTP/1.x 200 response, or null on any other
/// status or a malformed header. Connection: close means the body runs to EOF.
pub fn parseHttpResponse(raw: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const head = raw[0..sep];
    if (!std.mem.startsWith(u8, head, "HTTP/1.")) return null;
    const sp = std.mem.indexOfScalar(u8, head, ' ') orelse return null;
    if (sp + 4 > head.len) return null;
    if (!std.mem.eql(u8, head[sp + 1 .. sp + 4], "200")) return null;
    return raw[sep + 4 ..];
}

pub fn wgetFetch(host: []const u8, port: u16, path: []const u8, a: std.mem.Allocator) ![]u8 {
    const fd = try sock.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    defer sock.close(fd) catch {};
    const addr = sock.sockaddr_in(host, port);
    try sock.connect(fd, @ptrCast(&addr), @sizeOf(sock.sockaddr.in));

    var reqbuf: [2048]u8 = undefined;
    const req = try buildHttpRequest(host, port, path, &reqbuf);
    try sendAll(fd, req);
    _ = linux.shutdown(fd, linux.SHUT.WR);

    const raw = try readAll(fd, a);
    defer a.free(raw);
    const body = parseHttpResponse(raw) orelse return error.BadHttpResponse;
    return a.dupe(u8, body);
}

// ------------------------------------------------------------------- netcat

pub fn ncRelay(fd: sock.fd_t, input: []const u8, a: std.mem.Allocator) ![]u8 {
    try sendAll(fd, input);
    _ = linux.shutdown(fd, linux.SHUT.WR);
    return readAll(fd, a);
}

pub fn ncExchange(host: []const u8, port: u16, input: []const u8, a: std.mem.Allocator) ![]u8 {
    const fd = try sock.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    defer sock.close(fd) catch {};
    const addr = sock.sockaddr_in(host, port);
    try sock.connect(fd, @ptrCast(&addr), @sizeOf(sock.sockaddr.in));
    return ncRelay(fd, input, a);
}

// ------------------------------------------------------------------ ifconfig

pub const IfaceStats = struct {
    name: []const u8,
    rx_bytes: u64,
    rx_packets: u64,
    tx_bytes: u64,
    tx_packets: u64,
};

/// Parse a data line of /proc/net/dev (name + 16 receive/transmit counters).
pub fn parseIfaceLine(line: []const u8) ?IfaceStats {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    if (name.len == 0) return null;

    var vals: [16]u64 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    while (it.next()) |tok| {
        if (n == vals.len) break;
        vals[n] = std.fmt.parseInt(u64, tok, 10) catch return null;
        n += 1;
    }
    if (n < 10) return null;
    return .{
        .name = name,
        .rx_bytes = vals[0],
        .rx_packets = vals[1],
        .tx_bytes = vals[8],
        .tx_packets = vals[9],
    };
}

// ---------------------------------------------------------------------- ping

pub const PingStats = struct {
    transmitted: u16,
    received: u16,
    min_ms: u32,
    max_ms: u32,
    avg_ms: u32,
};

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn icmpChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

/// ICMP echo using a Linux ping socket (SOCK_DGRAM/IPPROTO_ICMP), which needs
/// no CAP_NET_RAW when net.ipv4.ping_group_range permits it. Numeric IPv4
/// hosts only — there is no resolver in libbb_zig/socket.zig yet.
pub fn pingHost(host: []const u8, count: u16, timeout_ms: u32) !PingStats {
    var stats = PingStats{
        .transmitted = 0,
        .received = 0,
        .min_ms = std.math.maxInt(u32),
        .max_ms = 0,
        .avg_ms = 0,
    };
    if (count == 0) return stats;

    const ident: u16 = @truncate(@as(u32, @bitCast(linux.getpid())));
    const fd = try sock.socket(linux.AF.INET, linux.SOCK.DGRAM, linux.IPPROTO.ICMP);
    defer sock.close(fd) catch {};

    const addr = sock.sockaddr_in(host, ident);
    try sock.connect(fd, @ptrCast(&addr), @sizeOf(sock.sockaddr.in));

    var tv = linux.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @as(i64, @intCast(timeout_ms % 1000)) * 1000,
    };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));

    var sum_ms: u64 = 0;
    var seq: u16 = 1;
    while (seq <= count) : (seq += 1) {
        var packet: [64]u8 = std.mem.zeroes([64]u8);
        packet[0] = 8; // echo request
        packet[1] = 0;
        std.mem.writeInt(u16, packet[4..6], ident, .big);
        std.mem.writeInt(u16, packet[6..8], seq, .big);
        @memcpy(packet[8..24], "busybox-zig-ping");

        const csum = icmpChecksum(&packet);
        std.mem.writeInt(u16, packet[2..4], csum, .big);

        const start = nowMs();
        _ = sock.send(fd, &packet, 0) catch continue;
        stats.transmitted += 1;

        var reply: [512]u8 = undefined;
        const n = sock.recv(fd, &reply, 0) catch continue;
        if (n < 8 or reply[0] != 0) continue; // must be an echo reply
        if (std.mem.readInt(u16, reply[6..8], .big) != seq) continue;

        const elapsed = nowMs() - start;
        const ms: u32 = @intCast(@max(0, elapsed));
        sum_ms += ms;
        stats.received += 1;
        stats.min_ms = @min(stats.min_ms, ms);
        stats.max_ms = @max(stats.max_ms, ms);
    }
    if (stats.received > 0) {
        stats.avg_ms = @intCast(@divTrunc(sum_ms, stats.received));
    } else {
        stats.min_ms = 0;
    }
    return stats;
}

// ------------------------------------------------------------------- applets

pub fn ifconfig_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    const a = std.heap.page_allocator;
    const data = readWholeFile(a, "/proc/net/dev") catch return 1;
    defer a.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();
    _ = lines.next();
    while (lines.next()) |line| {
        const s = parseIfaceLine(line) orelse continue;
        var buf: [512]u8 = undefined;
        const row = std.fmt.bufPrint(&buf, "{s:<10} RX packets:{d} bytes:{d}  TX packets:{d} bytes:{d}\n", .{
            s.name, s.rx_packets, s.rx_bytes, s.tx_packets, s.tx_bytes,
        }) catch continue;
        out(row);
    }
    return 0;
}

pub fn ping_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var count: u16 = 4;
    var timeout: u32 = 1000;
    var host: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-W")) and i + 1 < args.len) {
            i += 1;
            const value = std.fmt.parseInt(u16, args[i], 10) catch return 1;
            if (std.mem.eql(u8, arg, "-c")) count = value else timeout = @as(u32, value) * 1000;
        } else if (arg.len > 0 and arg[0] == '-') {
            // ignore unsupported options
        } else {
            host = arg;
        }
    }
    if (host.len == 0) return 1;

    const stats = pingHost(host, count, timeout) catch return 1;
    const lost = stats.transmitted - stats.received;
    const pct: u32 = if (stats.transmitted == 0) 0 else @divTrunc(@as(u32, lost) * 100, stats.transmitted);
    var buf: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf,
        "--- {s} ping statistics ---\n{d} packets transmitted, {d} packets received, {d}% packet loss\nround-trip min/avg/max = {d}/{d}/{d} ms\n",
        .{ host, stats.transmitted, stats.received, pct, stats.min_ms, stats.avg_ms, stats.max_ms },
    ) catch return 1;
    out(summary);
    return if (stats.received > 0) 0 else 1;
}

pub fn wget_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const a = std.heap.page_allocator;
    var outfile: ?[]const u8 = null;
    var url: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "-o")) and i + 1 < args.len) {
            i += 1;
            outfile = args[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            // -q and other options are accepted but ignored
        } else {
            url = arg;
        }
    }
    if (url.len == 0) return 1;
    const u = parseUrl(url) orelse return 1;

    const body = wgetFetch(u.host, u.port, u.path, a) catch return 1;
    defer a.free(body);

    if (outfile) |path| {
        const p = zstr(a, path) catch return 1;
        const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        if (linux.errno(rc) != .SUCCESS) return 1;
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        var off: usize = 0;
        while (off < body.len) {
            const n = linux.write(fd, body[off..].ptr, body.len - off);
            if (linux.errno(n) != .SUCCESS or n == 0) return 1;
            off += n;
        }
    } else {
        out(body);
    }
    return 0;
}

pub fn nc_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    if (args.len < 3) return 1;
    const port = std.fmt.parseInt(u16, args[2], 10) catch return 1;

    const a = std.heap.page_allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        input.appendSlice(a, buf[0..n]) catch return 1;
    }

    const result = ncExchange(args[1], port, input.items, a) catch return 1;
    defer a.free(result);
    out(result);
    return 0;
}
