const std = @import("std");
const net = @import("libbb_zig").socket.net;

const loopback = [4]u8{ 127, 0, 0, 1 };

test "Address <-> sockaddr roundtrip (v4 and v6)" {
    const a = net.Address.initV4(loopback, 8080);
    const sa = a.toSockaddr();
    const back = try net.Address.fromSockaddr(&sa.data, sa.len);
    try std.testing.expectEqual(@as(u16, 8080), back.port);
    try std.testing.expectEqual(loopback, back.ip.v4);

    const a6 = net.Address.initV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 443);
    const sa6 = a6.toSockaddr();
    const back6 = try net.Address.fromSockaddr(&sa6.data, sa6.len);
    try std.testing.expectEqual(@as(u16, 443), back6.port);
    try std.testing.expectEqual(a6.ip.v6, back6.ip.v6);
}

test "createAndBind/listen/connect + partial send/recv" {
    const listener = try net.createAndBind(net.Address.initV4(loopback, 0));
    defer net.close(listener);
    try net.listen(listener, 4);

    const bound = try net.localAddr(listener);
    try std.testing.expect(bound.port > 0);

    const client = try net.createAndConnect(bound);
    defer net.close(client);

    const accepted = try net.accept(listener);
    defer net.close(accepted);

    const payload = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    try net.sendAll(client, payload, 0);
    var buf: [64]u8 = undefined;
    const n = try net.recvAll(accepted, buf[0..payload.len], 0);
    try std.testing.expectEqual(payload.len, n);
    try std.testing.expectEqualStrings(payload, buf[0..n]);

    // Reverse direction exercises sendAll on the peer too.
    try net.sendAll(accepted, "pong", 0);
    var rbuf: [4]u8 = undefined;
    _ = try net.recvAll(client, &rbuf, 0);
    try std.testing.expectEqualStrings("pong", &rbuf);
}

test "nonblocking + poll timeout" {
    const listener = try net.createAndBind(net.Address.initV4(loopback, 0));
    defer net.close(listener);
    try net.listen(listener, 1);
    const client = try net.createAndConnect(try net.localAddr(listener));
    defer net.close(client);
    const accepted = try net.accept(listener);
    defer net.close(accepted);

    // poll reports timeout when nothing is pending.
    try std.testing.expectEqual(false, try net.wait(accepted, true, false, 50));

    try net.setNonBlocking(accepted);
    var buf: [16]u8 = undefined;
    const r = net.recv(accepted, &buf, 0);
    try std.testing.expectError(error.WouldBlock, r);

    try net.setBlocking(accepted);
    try net.sendAll(client, "x", 0);
    try std.testing.expectEqual(true, try net.wait(accepted, true, false, 1000));
    const n = try net.recv(accepted, &buf, 0);
    try std.testing.expectEqualStrings("x", buf[0..n]);
}

test "receive timeout" {
    const listener = try net.createAndBind(net.Address.initV4(loopback, 0));
    defer net.close(listener);
    try net.listen(listener, 1);
    const client = try net.createAndConnect(try net.localAddr(listener));
    defer net.close(client);
    const accepted = try net.accept(listener);
    defer net.close(accepted);

    try net.setRecvTimeout(accepted, 30);
    var buf: [8]u8 = undefined;
    const r = net.recv(accepted, &buf, 0);
    // Linux reports EAGAIN on SO_RCVTIMEO expiry.
    try std.testing.expect(r == error.WouldBlock or r == error.Timeout);
}

test "UDP sendTo/recvFrom" {
    const server = try net.createUdp(net.Address.initV4(loopback, 0));
    defer net.close(server);
    const bound = try net.localAddr(server);

    const client = try net.createUdp(net.Address.initV4(loopback, 0));
    defer net.close(client);

    _ = try net.sendTo(client, "hello", bound, 0);
    var buf: [32]u8 = undefined;
    const got = try net.recvFrom(server, &buf, 0);
    try std.testing.expectEqualStrings("hello", buf[0..got.n]);
    try std.testing.expectEqual((try net.localAddr(client)).port, got.addr.port);
}
