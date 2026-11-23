//! TDD tests for inetd.conf parsing helpers (Task 25).

const std = @import("std");
const bb = @import("libbb_zig");
const inetd = bb.daemon.inetd;

fn freeEntries(a: std.mem.Allocator, entries: []inetd.Entry) void {
    for (entries) |e| {
        if (e.host) |h| a.free(h);
        a.free(e.service);
        a.free(e.protocol);
        a.free(e.user);
        if (e.group) |g| a.free(g);
        a.free(e.program);
        for (e.args) |arg| a.free(arg);
        a.free(e.args);
    }
    a.free(entries);
}

test "splitEndpoint parses host and port and rejects bad input" {
    const ep = try inetd.splitEndpoint("127.0.0.1:8080");
    try std.testing.expectEqualStrings("127.0.0.1", ep.host);
    try std.testing.expectEqual(@as(u16, 8080), ep.port);
    const any = try inetd.splitEndpoint(":telnet");
    try std.testing.expectEqualStrings("", any.host);
    try std.testing.expectEqual(@as(u16, 23), any.port);
    try std.testing.expectError(error.InvalidEndpoint, inetd.splitEndpoint("no-colon"));
    try std.testing.expectError(error.InvalidEndpoint, inetd.splitEndpoint("host:99999"));
    try std.testing.expectError(error.InvalidEndpoint, inetd.splitEndpoint("host:not-a-port"));
}

test "parseInetdConf reads a normal service line" {
    const a = std.testing.allocator;
    const text = "telnet stream tcp nowait root /usr/sbin/telnetd telnetd -a\n";
    const entries = try inetd.parseInetdConf(a, text);
    defer freeEntries(a, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("telnet", entries[0].service);
    try std.testing.expectEqual(inetd.SockType.stream, entries[0].socktype);
    try std.testing.expectEqualStrings("tcp", entries[0].protocol);
    try std.testing.expectEqual(inetd.WaitMode.nowait, entries[0].wait);
    try std.testing.expectEqualStrings("root", entries[0].user);
    try std.testing.expectEqualStrings("/usr/sbin/telnetd", entries[0].program);
    try std.testing.expectEqual(@as(usize, 2), entries[0].args.len);
    try std.testing.expectEqualStrings("-a", entries[0].args[1]);
}

test "parseInetdConf applies a host-only default line to later services" {
    const a = std.testing.allocator;
    const text =
        "192.168.1.1:\n" ++
        "echo stream tcp nowait root internal\n";
    const entries = try inetd.parseInetdConf(a, text);
    defer freeEntries(a, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("192.168.1.1", entries[0].host.?);
    try std.testing.expectEqualStrings("echo", entries[0].service);
}

test "parseInetdConf parses wait with a connection limit" {
    const a = std.testing.allocator;
    const entries = try inetd.parseInetdConf(a, "finger stream tcp wait.5 root /usr/sbin/fingerd\n");
    defer freeEntries(a, entries);
    try std.testing.expectEqual(inetd.WaitMode.wait, entries[0].wait);
    try std.testing.expectEqual(@as(u16, 5), entries[0].max_connections.?);
}

test "parseInetdConf rejects unknown socket types and bad wait modes" {
    const a = std.testing.allocator;
    const bad_sock = inetd.parseInetdConf(a, "x bogus tcp nowait root /bin/x\n");
    if (bad_sock) |entries| {
        freeEntries(a, entries);
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.InvalidSocketType, e);
    }
    const bad_wait = inetd.parseInetdConf(a, "x stream tcp later root /bin/x\n");
    if (bad_wait) |entries| {
        freeEntries(a, entries);
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.InvalidWaitMode, e);
    }
}

test "parseInetdConf rejects short lines" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.TooFewTokens, inetd.parseInetdConf(a, "x stream tcp nowait\n"));
}
