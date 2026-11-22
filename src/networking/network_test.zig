const std = @import("std");
const net = @import("networking");
const sock = @import("libbb_zig").socket;
const linux = std.os.linux;

// Task 13c fix round 1: focused tc netlink-formatting tests (tc is SKIP-gated
// in differential mode because the comparison reference is built CONFIG_TC=n).
test {
    _ = @import("tc_test.zig");
}

test "parseUrl handles scheme, host, port and path" {
    const u = net.parseUrl("http://127.0.0.1:8080/index.html").?;
    try std.testing.expectEqualStrings("127.0.0.1", u.host);
    try std.testing.expectEqual(@as(u16, 8080), u.port);
    try std.testing.expectEqualStrings("/index.html", u.path);
}

test "parseUrl defaults port 80 and path /" {
    const u = net.parseUrl("http://example.com").?;
    try std.testing.expectEqual(@as(u16, 80), u.port);
    try std.testing.expectEqualStrings("/", u.path);
}

test "parseUrl rejects non-http schemes" {
    try std.testing.expect(net.parseUrl("ftp://host/x") == null);
}

test "buildHttpRequest formats a GET request" {
    var buf: [256]u8 = undefined;
    const req = try net.buildHttpRequest("127.0.0.1", 8080, "/a", &buf);
    try std.testing.expectEqualStrings(
        "GET /a HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\n\r\n",
        req,
    );
}

test "parseIfaceLine parses /proc/net/dev counters" {
    const line = "  lo: 644018875 1061066 0 0 0 0 0 0 644018875 1061066 0 0 0 0 0 0";
    const s = net.parseIfaceLine(line).?;
    try std.testing.expectEqualStrings("lo", s.name);
    try std.testing.expectEqual(@as(u64, 644018875), s.rx_bytes);
    try std.testing.expectEqual(@as(u64, 1061066), s.rx_packets);
    try std.testing.expectEqual(@as(u64, 644018875), s.tx_bytes);
    try std.testing.expectEqual(@as(u64, 1061066), s.tx_packets);
}

test "parseIfaceLine ignores header lines" {
    try std.testing.expect(net.parseIfaceLine("Inter-|   Receive  |  Transmit") == null);
}

fn spawnEchoServer(port_out: *u16) !std.Thread {
    const fd = try sock.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    var addr = sock.sockaddr_in("127.0.0.1", 0);
    try sock.bind(fd, @ptrCast(&addr));
    try sock.listen(fd, 1);
    var stored: sock.sockaddr.in = undefined;
    var len: sock.socklen_t = @sizeOf(sock.sockaddr);
    try sock.getsockname(fd, &stored, &len);
    port_out.* = sock.portOf(&stored);
    return std.Thread.spawn(.{}, echoThread, .{fd});
}

// A bounded wait so a stub client (RED) cannot hang the test thread forever.
fn waitClient(fd: sock.fd_t) bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const n = linux.poll(&fds, 1, 3000);
    return linux.errno(n) == .SUCCESS and n > 0;
}

fn echoThread(fd: sock.fd_t) void {
    defer sock.close(fd) catch {};
    if (!waitClient(fd)) return;
    const conn = sock.accept(fd, null, null) catch return;
    defer sock.close(conn) catch {};
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = sock.recv(conn, &buf, 0) catch return;
        if (n == 0) break;
        _ = sock.send(conn, buf[0..n], 0) catch return;
    }
}

test "ncExchange relays bytes to a loopback server" {
    var port: u16 = 0;
    const server = try spawnEchoServer(&port);
    defer server.join();

    const a = std.heap.page_allocator;
    const got = try net.ncExchange("127.0.0.1", port, "hello\n", a);
    defer a.free(got);
    try std.testing.expectEqualStrings("hello\n", got);
}

fn spawnHttpServer(port_out: *u16) !std.Thread {
    const fd = try sock.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    var addr = sock.sockaddr_in("127.0.0.1", 0);
    try sock.bind(fd, @ptrCast(&addr));
    try sock.listen(fd, 1);
    var stored: sock.sockaddr.in = undefined;
    var len: sock.socklen_t = @sizeOf(sock.sockaddr);
    try sock.getsockname(fd, &stored, &len);
    port_out.* = sock.portOf(&stored);
    return std.Thread.spawn(.{}, httpThread, .{fd});
}

fn httpThread(fd: sock.fd_t) void {
    defer sock.close(fd) catch {};
    if (!waitClient(fd)) return;
    const conn = sock.accept(fd, null, null) catch return;
    defer sock.close(conn) catch {};
    var buf: [4096]u8 = undefined;
    _ = sock.recv(conn, &buf, 0) catch return;
    const body = "hello world";
    var resp: [256]u8 = undefined;
    const r = std.fmt.bufPrint(&resp, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
    _ = sock.send(conn, r, 0) catch return;
}

test "wgetFetch retrieves a body from a local HTTP server" {
    var port: u16 = 0;
    const server = try spawnHttpServer(&port);
    defer server.join();

    const a = std.heap.page_allocator;
    const body = try net.wgetFetch("127.0.0.1", port, "/hi", a);
    defer a.free(body);
    try std.testing.expectEqualStrings("hello world", body);
}

test "pingHost receives echo replies from loopback" {
    const stats = try net.pingHost("127.0.0.1", 2, 1000);
    try std.testing.expectEqual(@as(u16, 2), stats.transmitted);
    try std.testing.expectEqual(@as(u16, 2), stats.received);
}
