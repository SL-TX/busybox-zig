const std = @import("std");
const http = @import("libbb_zig").http;
const net = @import("libbb_zig").socket.net;

const loop = [4]u8{ 127, 0, 0, 1 };
const Handler = *const fn (*http.Connection) void;

fn serve(server: http.Server, handler: Handler, count: usize) std.Thread {
    return std.Thread.spawn(.{}, serverLoop, .{ server, handler, count }) catch unreachable;
}

fn serverLoop(server: http.Server, handler: Handler, count: usize) void {
    var s = server;
    defer s.deinit();
    for (0..count) |_| {
        var conn = s.accept() catch return;
        defer conn.deinit();
        net.setRecvTimeout(conn.fd, 3000) catch {};
        handler(&conn);
    }
}

fn baseUrl(addr: net.Address) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/", .{addr.port});
}

fn handlerGet(conn: *http.Connection) void {
    const a = std.heap.page_allocator;
    var req = conn.readRequest(a) catch return;
    defer req.deinit(a);
    if (!std.mem.eql(u8, req.method, "GET") or !std.mem.eql(u8, req.target, "/")) return;
    conn.respond(a, 200, "OK", "text/plain", "hello-world", &.{}) catch {};
}

test "HTTP GET" {
    const server = try http.Server.listen(net.Address.initV4(loop, 0));
    const url = try baseUrl(server.addr);
    defer std.testing.allocator.free(url);
    const t = serve(server, handlerGet, 2);
    defer t.join();

    var resp = try http.fetch(std.testing.allocator, url, .{});
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("hello-world", resp.body);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.heap.page_allocator);
    try http.httpGet(url, &out);
    try std.testing.expectEqualStrings("hello-world", out.items);
}

fn handlerPost(conn: *http.Connection) void {
    const a = std.heap.page_allocator;
    var req = conn.readRequest(a) catch return;
    defer req.deinit(a);
    const pairs = http.parseQuery(a, req.body) catch return;
    defer http.freePairs(a, pairs);
    const reply = if (pairs.len == 2 and std.mem.eql(u8, pairs[0].key, "name") and
        std.mem.eql(u8, pairs[0].value, "Alice") and std.mem.eql(u8, pairs[1].value, "1"))
        "form-ok"
    else
        "form-bad";
    conn.respond(a, 200, "OK", "text/plain", reply, &.{}) catch {};
}

test "HTTP POST + CGI form parsing" {
    const server = try http.Server.listen(net.Address.initV4(loop, 0));
    const url = try baseUrl(server.addr);
    defer std.testing.allocator.free(url);
    const t = serve(server, handlerPost, 1);
    defer t.join();

    var resp = try http.post(std.testing.allocator, url, "name=Alice&x=1", "application/x-www-form-urlencoded");
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("form-ok", resp.body);
}

fn handlerChunked(conn: *http.Connection) void {
    const a = std.heap.page_allocator;
    var req = conn.readRequest(a) catch return;
    defer req.deinit(a);
    const c1 = http.chunkEncode(a, "hello ") catch return;
    defer a.free(c1);
    const c2 = http.chunkEncode(a, "chunked") catch return;
    defer a.free(c2);
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(a);
    raw.appendSlice(a, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n") catch return;
    raw.appendSlice(a, c1) catch return;
    raw.appendSlice(a, c2) catch return;
    raw.appendSlice(a, "0\r\nX-Trailer: yes\r\n\r\n") catch return;
    conn.sendRaw(raw.items) catch {};
}

test "HTTP chunked transfer decoding" {
    const server = try http.Server.listen(net.Address.initV4(loop, 0));
    const url = try baseUrl(server.addr);
    defer std.testing.allocator.free(url);
    const t = serve(server, handlerChunked, 1);
    defer t.join();

    var resp = try http.fetch(std.testing.allocator, url, .{});
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello chunked", resp.body);
}

fn handlerRedirect(conn: *http.Connection) void {
    const a = std.heap.page_allocator;
    var req = conn.readRequest(a) catch return;
    defer req.deinit(a);
    if (std.mem.eql(u8, req.target, "/start")) {
        conn.respond(a, 302, "Found", "text/plain", "", &.{.{ .name = "Location", .value = "/final" }}) catch {};
    } else {
        conn.respond(a, 200, "OK", "text/plain", "arrived", &.{}) catch {};
    }
}

test "HTTP redirect with relative Location" {
    const server = try http.Server.listen(net.Address.initV4(loop, 0));
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/start", .{server.addr.port});
    defer std.testing.allocator.free(url);
    const t = serve(server, handlerRedirect, 2);
    defer t.join();

    var resp = try http.fetch(std.testing.allocator, url, .{});
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("arrived", resp.body);
}

fn handlerAuth(conn: *http.Connection) void {
    const a = std.heap.page_allocator;
    var req = conn.readRequest(a) catch return;
    defer req.deinit(a);
    const auth = req.header("Authorization") orelse "";
    if (std.mem.eql(u8, auth, "Basic dXNlcjpwYXNz")) {
        conn.respond(a, 200, "OK", "text/plain", "auth-ok", &.{}) catch {};
    } else {
        conn.respond(a, 401, "Unauthorized", "text/plain", "no", &.{}) catch {};
    }
}

test "HTTP basic auth from URL userinfo" {
    const server = try http.Server.listen(net.Address.initV4(loop, 0));
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://user:pass@127.0.0.1:{d}/", .{server.addr.port});
    defer std.testing.allocator.free(url);
    const t = serve(server, handlerAuth, 1);
    defer t.join();

    var resp = try http.fetch(std.testing.allocator, url, .{});
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("auth-ok", resp.body);
}

fn handlerRange(conn: *http.Connection) void {
    const a = std.heap.page_allocator;
    var req = conn.readRequest(a) catch return;
    defer req.deinit(a);
    const r = http.parseRange(req.header("Range") orelse "") orelse {
        conn.respond(a, 416, "Range Not Satisfiable", "text/plain", "", &.{}) catch {};
        return;
    };
    const data = "0123456789";
    const end = @min(r.end orelse (data.len - 1), data.len - 1);
    if (r.start > end or r.start >= data.len) {
        conn.respond(a, 416, "Range Not Satisfiable", "text/plain", "", &.{}) catch {};
        return;
    }
    const part = data[@intCast(r.start) .. @as(usize, @intCast(end)) + 1];
    const cr = std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ r.start, end, data.len }) catch return;
    defer a.free(cr);
    conn.respond(a, 206, "Partial Content", "text/plain", part, &.{.{ .name = "Content-Range", .value = cr }}) catch {};
}

test "HTTP range request" {
    const server = try http.Server.listen(net.Address.initV4(loop, 0));
    const url = try baseUrl(server.addr);
    defer std.testing.allocator.free(url);
    const t = serve(server, handlerRange, 1);
    defer t.join();

    const headers = [_]http.Header{.{ .name = "Range", .value = "bytes=0-4" }};
    var resp = try http.fetch(std.testing.allocator, url, .{ .headers = &headers });
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 206), resp.status);
    try std.testing.expectEqualStrings("01234", resp.body);
    try std.testing.expectEqualStrings("bytes 0-4/10", resp.header("Content-Range").?);
}

test "HTTP CGI/auth helper units" {
    const a = std.testing.allocator;
    const decoded = try http.urlDecode(a, "a+b%20c%2Bd");
    defer a.free(decoded);
    try std.testing.expectEqualStrings("a b c+d", decoded);

    const pairs = try http.parseQuery(a, "x=1&empty=&flag");
    defer http.freePairs(a, pairs);
    try std.testing.expectEqual(@as(usize, 3), pairs.len);
    try std.testing.expectEqualStrings("x", pairs[0].key);
    try std.testing.expectEqualStrings("1", pairs[0].value);
    try std.testing.expectEqualStrings("", pairs[1].value);

    const cred = http.basicCredentials(a, "Basic dXNlcjpwYXNz").?;
    defer cred.deinit(a);
    try std.testing.expectEqualStrings("user", cred.user);
    try std.testing.expectEqualStrings("pass", cred.password);

    const r = http.parseRange("bytes=10-20").?;
    try std.testing.expectEqual(@as(u64, 10), r.start);
    try std.testing.expectEqual(@as(?u64, 20), r.end);
    try std.testing.expect(http.parseRange("items=1-2") == null);

    const chunk = try http.chunkEncode(a, "abc");
    defer a.free(chunk);
    try std.testing.expectEqualStrings("3\r\nabc\r\n", chunk);
}
