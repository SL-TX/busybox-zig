const std = @import("std");
const dns = @import("libbb_zig").dns;
const net = @import("libbb_zig").socket.net;

const Handler = *const fn ([]const u8, []u8) ?usize;

fn startServer(handler: Handler) !struct { fd: net.fd_t, addr: net.Address, thread: std.Thread } {
    const addr = net.Address.initV4(.{ 127, 0, 0, 1 }, 0);
    const fd = try net.createUdp(addr);
    try net.setRecvTimeout(fd, 200); // lets the server thread exit after close
    const bound = try net.localAddr(fd);
    const thread = try std.Thread.spawn(.{}, serverLoop, .{ fd, handler });
    return .{ .fd = fd, .addr = bound, .thread = thread };
}

fn serverLoop(fd: net.fd_t, handler: Handler) void {
    while (true) {
        var buf: [2048]u8 = undefined;
        const got = net.recvFrom(fd, &buf, 0) catch return;
        var out: [4096]u8 = undefined;
        const n = handler(buf[0..got.n], &out) orelse continue;
        _ = net.sendTo(fd, out[0..n], got.addr, 0) catch return;
    }
}

fn queryType(query: []const u8) u16 {
    var pos: usize = 12;
    while (pos < query.len and query[pos] != 0) pos += 1 + query[pos];
    pos += 1;
    if (pos + 2 > query.len) return 0;
    return std.mem.readInt(u16, query[pos..][0..2], .big);
}

fn queryName(query: []const u8, out: []u8) []const u8 {
    var pos: usize = 12;
    var w: usize = 0;
    while (pos < query.len) {
        const len = query[pos];
        if (len == 0) break;
        if (w > 0 and w < out.len) {
            out[w] = '.';
            w += 1;
        }
        pos += 1;
        for (0..len) |_| {
            if (pos >= query.len) break;
            if (w < out.len) {
                out[w] = query[pos];
                w += 1;
            }
            pos += 1;
        }
    }
    return out[0..w];
}

fn put16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .big);
}

fn encodeName(name: []const u8, out: []u8) usize {
    var w: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        out[w] = @intCast(label.len);
        w += 1;
        @memcpy(out[w .. w + label.len], label);
        w += label.len;
    }
    out[w] = 0;
    w += 1;
    return w;
}

const Answer = struct {
    name: []const u8,
    rtype: u16,
    rdata: []const u8,
};

fn makeResponse(query: []const u8, answers: []const Answer, rcode: u8, out: []u8) usize {
    const id = std.mem.readInt(u16, query[0..2], .big);
    put16(out, 0, id);
    put16(out, 2, 0x8180 | @as(u16, rcode)); // QR|RD|RA + rcode
    put16(out, 4, 1);
    put16(out, 6, @intCast(answers.len));
    put16(out, 8, 0);
    put16(out, 10, 0);

    // Echo back the question (QNAME + QTYPE + QCLASS).
    var qpos: usize = 12;
    while (query[qpos] != 0) qpos += 1 + query[qpos];
    qpos += 1 + 4;
    @memcpy(out[12..qpos], query[12..qpos]);
    var w = qpos;

    for (answers) |a| {
        w += encodeName(a.name, out[w..]);
        put16(out, w, a.rtype);
        w += 2;
        put16(out, w, 1); // IN
        w += 2;
        put16(out, w, 60); // TTL high
        w += 2;
        put16(out, w, 0); // TTL low
        w += 2;
        put16(out, w, @intCast(a.rdata.len));
        w += 2;
        @memcpy(out[w .. w + a.rdata.len], a.rdata);
        w += a.rdata.len;
    }
    return w;
}

fn handlerA(query: []const u8, out: []u8) ?usize {
    var nb: [256]u8 = undefined;
    const name = queryName(query, &nb);
    if (std.mem.eql(u8, name, "a.test") and queryType(query) == 1) {
        const rd = [_]u8{ 10, 1, 2, 3 };
        return makeResponse(query, &.{.{ .name = name, .rtype = 1, .rdata = &rd }}, 0, out);
    }
    return makeResponse(query, &.{}, 3, out); // NXDOMAIN
}

fn handlerAAAA(query: []const u8, out: []u8) ?usize {
    var nb: [256]u8 = undefined;
    const name = queryName(query, &nb);
    if (std.mem.eql(u8, name, "v6.test") and queryType(query) == 28) {
        var rd: [16]u8 = undefined;
        rd[15] = 1;
        return makeResponse(query, &.{.{ .name = name, .rtype = 28, .rdata = &rd }}, 0, out);
    }
    return makeResponse(query, &.{}, 3, out);
}

fn handlerCname(query: []const u8, out: []u8) ?usize {
    var nb: [256]u8 = undefined;
    const name = queryName(query, &nb);
    if (std.mem.eql(u8, name, "alias.test") and queryType(query) == 5) {
        var cname_rd: [64]u8 = undefined;
        const cn = encodeName("real.test", &cname_rd);
        return makeResponse(query, &.{.{ .name = name, .rtype = 5, .rdata = cname_rd[0..cn] }}, 0, out);
    }
    if (std.mem.eql(u8, name, "real.test") and queryType(query) == 1) {
        const rd = [_]u8{ 10, 9, 8, 7 };
        return makeResponse(query, &.{.{ .name = name, .rtype = 1, .rdata = &rd }}, 0, out);
    }
    return makeResponse(query, &.{}, 3, out);
}

fn handlerNx(query: []const u8, out: []u8) ?usize {
    return makeResponse(query, &.{}, 3, out);
}

fn handlerSilent(_: []const u8, _: []u8) ?usize {
    return null;
}

const tmp = "/tmp/opencode";
const linux = std.os.linux;

fn writeTextFile(path: []const u8, data: []const u8) !void {
    const zpath = try std.testing.allocator.alloc(u8, path.len + 1);
    defer std.testing.allocator.free(zpath);
    @memcpy(zpath[0..path.len], path);
    zpath[path.len] = 0;
    const zs: [:0]u8 = zpath[0..path.len :0];
    const rc = linux.open(zs.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.FileWriteFailed;
    const fd: net.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const nrc = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(nrc) != .SUCCESS) return error.FileWriteFailed;
        const n: usize = @intCast(nrc);
        if (n == 0) return error.FileWriteFailed;
        off += n;
    }
}

fn writeResolv(path: []const u8, addr: net.Address) !void {
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "nameserver 127.0.0.1:{d}\n", .{addr.port});
    try writeTextFile(path, line);
}

fn writeHosts(path: []const u8) !void {
    try writeTextFile(path, "127.0.0.1 localhost\n127.0.0.2 myhost aliasname\n::1 ip6-localhost\n");
}

test "DNS numeric IPv4 and IPv6" {
    var r = dns.Resolver.init(std.testing.allocator);
    const v4 = try r.lookupHost("127.0.0.1", 80);
    defer std.testing.allocator.free(v4);
    try std.testing.expectEqual(@as(usize, 1), v4.len);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, v4[0].ip.v4);
    try std.testing.expectEqual(@as(u16, 80), v4[0].port);

    const v6 = try r.lookupHost("::1", 443);
    defer std.testing.allocator.free(v6);
    try std.testing.expectEqual(@as(usize, 1), v6.len);
    try std.testing.expectEqual(v6[0].ip.v6[15], 1);
}

test "DNS /etc/hosts override" {
    const path = tmp ++ "/task12_hosts";
    try writeHosts(path);
    var r = dns.Resolver.init(std.testing.allocator);
    r.hosts_path = path;
    const got = try r.lookupHost("myhost", 8080);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 2 }, got[0].ip.v4);
    try std.testing.expectEqual(@as(u16, 8080), got[0].port);

    const alias = try r.lookupHost("aliasname", 1);
    defer std.testing.allocator.free(alias);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 2 }, alias[0].ip.v4);

    const v6 = try r.lookupHost("ip6-localhost", 1);
    defer std.testing.allocator.free(v6);
    try std.testing.expectEqual(v6[0].ip.v6[15], 1);
}

test "DNS A record via resolv.conf override" {
    var srv = try startServer(handlerA);
    defer {
        net.close(srv.fd);
        srv.thread.join();
    }
    const path = tmp ++ "/task12_resolv_a";
    try writeResolv(path, srv.addr);

    var r = dns.Resolver.init(std.testing.allocator);
    r.resolv_conf_path = path;
    r.hosts_path = tmp ++ "/task12_no_such_hosts";
    const got = try r.lookupHost("a.test", 1234);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual([4]u8{ 10, 1, 2, 3 }, got[0].ip.v4);
    try std.testing.expectEqual(@as(u16, 1234), got[0].port);
}

test "DNS AAAA record" {
    var srv = try startServer(handlerAAAA);
    defer {
        net.close(srv.fd);
        srv.thread.join();
    }
    const path = tmp ++ "/task12_resolv_aaaa";
    try writeResolv(path, srv.addr);
    var r = dns.Resolver.init(std.testing.allocator);
    r.resolv_conf_path = path;
    r.hosts_path = tmp ++ "/task12_no_such_hosts";
    const got = try r.lookupHost("v6.test", 53);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(got[0].ip.v6[15], 1);
}

test "DNS CNAME chase" {
    var srv = try startServer(handlerCname);
    defer {
        net.close(srv.fd);
        srv.thread.join();
    }
    const path = tmp ++ "/task12_resolv_cname";
    try writeResolv(path, srv.addr);
    var r = dns.Resolver.init(std.testing.allocator);
    r.resolv_conf_path = path;
    r.hosts_path = tmp ++ "/task12_no_such_hosts";
    const got = try r.lookupHost("alias.test", 80);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual([4]u8{ 10, 9, 8, 7 }, got[0].ip.v4);
}

test "DNS CNAME chase with caller-owned servers slice (no invalid free)" {
    var srv = try startServer(handlerCname);
    defer {
        net.close(srv.fd);
        srv.thread.join();
    }
    // Caller-owned, stack-allocated slice: Resolver must not free it. This
    // exercises firstCname(), which used to free it unconditionally.
    const servers = [_]net.Address{srv.addr};
    var r = dns.Resolver.init(std.testing.allocator);
    r.servers = &servers;
    r.hosts_path = tmp ++ "/task12_no_such_hosts";
    const got = try r.lookupHost("alias.test", 8080);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual([4]u8{ 10, 9, 8, 7 }, got[0].ip.v4);
    try std.testing.expectEqual(@as(u16, 8080), got[0].port);
}

test "DNS NXDOMAIN" {
    var srv = try startServer(handlerNx);
    defer {
        net.close(srv.fd);
        srv.thread.join();
    }
    const path = tmp ++ "/task12_resolv_nx";
    try writeResolv(path, srv.addr);
    var r = dns.Resolver.init(std.testing.allocator);
    r.resolv_conf_path = path;
    r.hosts_path = tmp ++ "/task12_no_such_hosts";
    try std.testing.expectError(error.NXDomain, r.lookupHost("missing.test", 80));
}

test "DNS timeout" {
    var srv = try startServer(handlerSilent);
    defer {
        net.close(srv.fd);
        srv.thread.join();
    }
    const path = tmp ++ "/task12_resolv_timeout";
    try writeResolv(path, srv.addr);
    var r = dns.Resolver.init(std.testing.allocator);
    r.resolv_conf_path = path;
    r.hosts_path = tmp ++ "/task12_no_such_hosts";
    r.timeout_ms = 60;
    try std.testing.expectError(error.Timeout, r.lookupHost("slow.test", 80));
}

test "DNS module-level lookupHost numeric" {
    const got = try dns.lookupHost("127.0.0.1", 9);
    defer dns.freeAddresses(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, got[0].ip.v4);
}
