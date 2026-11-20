const std = @import("std");
const net = @import("libbb_zig").socket;

test "inet_pton parses IPv4" {
    try std.testing.expectEqual(@as(u32, 0x0100007f), net.inet_pton("127.0.0.1").?);
    try std.testing.expect(net.inet_pton("not-an-ip") == null);
}

test "inet_ntop renders IPv4" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("127.0.0.1", net.inet_ntop(0x0100007f, &buf));
}

test "socket bind listen connect send recv" {
    const listener = try net.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    defer net.close(listener) catch {};

    var addr = net.sockaddr_in("127.0.0.1", 0);
    try net.bind(listener, @ptrCast(&addr));
    try net.listen(listener, 1);

    var stored: net.sockaddr.in = undefined;
    var len: net.socklen_t = @sizeOf(net.sockaddr);
    try net.getsockname(listener, &stored, &len);
    const port = net.portOf(&stored);

    const client = try net.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    defer net.close(client) catch {};
    try net.connect(client, &stored, len);

    const accepted = try net.accept(listener, null, null);
    defer net.close(accepted) catch {};

    _ = try net.send(client, "ping", 0);
    var buf: [16]u8 = undefined;
    const n = try net.recv(accepted, &buf, 0);
    try std.testing.expectEqualStrings("ping", buf[0..n]);
    try std.testing.expect(port > 0);
}
