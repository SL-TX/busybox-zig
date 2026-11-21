//! Minimal HTTP/1.1 client and server helpers used by the networking applets.
//! Supports GET/POST, chunked transfer coding, redirects, basic auth and range
//! requests. The server half is intentionally small but sufficient for the CGI,
//! auth and range test servers used by this task.

const std = @import("std");
const net = @import("socket.zig");
const dns = @import("dns.zig");
const inet = @import("inet.zig");

pub const HttpError = error{
    BadUrl,
    UnsupportedScheme,
    ConnectionClosed,
    Timeout,
    BadResponse,
    TooManyRedirects,
    OutOfMemory,
    InvalidHeader,
};

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Options = struct {
    method: []const u8 = "GET",
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_ms: u32 = 5000,
    max_redirects: u8 = 5,
    follow_redirects: bool = true,
};

pub const Response = struct {
    status: u16,
    reason: []const u8,
    headers: []Header,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        freeHeaders(allocator, self.headers);
        allocator.free(self.reason);
        allocator.free(self.body);
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

fn componentText(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn findHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Decode '+' and %XX escapes (application/x-www-form-urlencoded).
pub fn urlDecode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(allocator, c);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(allocator, c);
                i += 1;
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const Pair = struct { key: []const u8, value: []const u8 };

/// Parse a CGI query string or urlencoded POST body into decoded pairs.
pub fn parseQuery(allocator: std.mem.Allocator, query: []const u8) ![]Pair {
    var pairs = std.ArrayList(Pair).empty;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |field| {
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=');
        const raw_key = if (eq) |p| field[0..p] else field;
        const raw_value = if (eq) |p| field[p + 1 ..] else "";
        const key = try urlDecode(allocator, raw_key);
        const value = try urlDecode(allocator, raw_value);
        try pairs.append(allocator, .{ .key = key, .value = value });
    }
    return pairs.toOwnedSlice(allocator);
}

pub fn freePairs(allocator: std.mem.Allocator, pairs: []Pair) void {
    for (pairs) |p| {
        allocator.free(p.key);
        allocator.free(p.value);
    }
    allocator.free(pairs);
}

pub const Credentials = struct {
    user: []u8,
    password: []u8,
    pub fn deinit(self: Credentials, allocator: std.mem.Allocator) void {
        allocator.free(self.user);
        allocator.free(self.password);
    }
};

/// Decode the credentials in an `Authorization: Basic <b64>` header value.
pub fn basicCredentials(allocator: std.mem.Allocator, value: []const u8) ?Credentials {
    const sp = std.mem.indexOfScalar(u8, value, ' ') orelse return null;
    if (!std.ascii.eqlIgnoreCase(value[0..sp], "basic")) return null;
    const b64 = std.mem.trim(u8, value[sp + 1 ..], " \t\r\n");
    const n = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return null;
    const decoded = allocator.alloc(u8, n) catch return null;
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, b64) catch return null;
    const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return null;
    const user = allocator.dupe(u8, decoded[0..colon]) catch return null;
    const password = allocator.dupe(u8, decoded[colon + 1 ..]) catch {
        allocator.free(user);
        return null;
    };
    return .{ .user = user, .password = password };
}

pub const Range = struct { start: u64, end: ?u64 };

/// Parse `bytes=start-end` (also accepts open-ended forms).
pub fn parseRange(header: []const u8) ?Range {
    if (!std.ascii.startsWithIgnoreCase(header, "bytes=")) return null;
    const spec = std.mem.trim(u8, header[6..], " \t");
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start = std.fmt.parseInt(u64, spec[0..dash], 10) catch return null;
    const end_text = std.mem.trim(u8, spec[dash + 1 ..], " \t");
    if (end_text.len == 0) return .{ .start = start, .end = null };
    const end = std.fmt.parseInt(u64, end_text, 10) catch return null;
    return .{ .start = start, .end = end };
}

/// Encode a byte string as a single HTTP chunk (used by test servers).
pub fn chunkEncode(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    const head = try std.fmt.allocPrint(allocator, "{x}\r\n", .{body.len});
    defer allocator.free(head);
    try out.appendSlice(allocator, head);
    try out.appendSlice(allocator, body);
    try out.appendSlice(allocator, "\r\n");
    return out.toOwnedSlice(allocator);
}

// ------------------------------ buffered reader ------------------------------

const BufReader = struct {
    fd: net.fd_t,
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    eof: bool = false,

    fn deinit(self: *BufReader) void {
        self.data.deinit(self.allocator);
    }

    fn fill(self: *BufReader) HttpError!void {
        if (self.eof) return;
        var tmp: [8192]u8 = undefined;
        const n = net.recv(self.fd, &tmp, 0) catch |e| switch (e) {
            error.WouldBlock, error.Timeout => return error.Timeout,
            else => return error.ConnectionClosed,
        };
        if (n == 0) {
            self.eof = true;
            return;
        }
        self.data.appendSlice(self.allocator, tmp[0..n]) catch return error.OutOfMemory;
    }

    fn ensure(self: *BufReader, n: usize) HttpError!void {
        while (self.data.items.len - self.pos < n and !self.eof) try self.fill();
    }

    fn readLine(self: *BufReader) HttpError![]const u8 {
        while (true) {
            const rest = self.data.items[self.pos..];
            if (std.mem.indexOfScalar(u8, rest, '\n')) |idx| {
                var end = self.pos + idx;
                if (end > self.pos and rest[idx - 1] == '\r') end -= 1;
                const line = self.data.items[self.pos..end];
                self.pos += idx + 1;
                return line;
            }
            if (self.eof) return error.ConnectionClosed;
            try self.fill();
        }
    }

    fn readExactly(self: *BufReader, n: usize) HttpError![]const u8 {
        try self.ensure(n);
        if (self.data.items.len - self.pos < n) return error.ConnectionClosed;
        const out = self.data.items[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn readAll(self: *BufReader) HttpError![]const u8 {
        while (!self.eof) try self.fill();
        const out = self.data.items[self.pos..];
        self.pos = self.data.items.len;
        return out;
    }
};

fn parseStatusLine(line: []const u8) HttpError!struct { status: u16, reason: []const u8 } {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return error.BadResponse;
    const code = it.next() orelse return error.BadResponse;
    const status = std.fmt.parseInt(u16, code, 10) catch return error.BadResponse;
    const rest = std.mem.trim(u8, line[std.mem.indexOf(u8, line, code).? + code.len ..], " \t");
    return .{ .status = status, .reason = rest };
}

fn parseHeaders(allocator: std.mem.Allocator, reader: *BufReader) HttpError![]Header {
    var list = std.ArrayList(Header).empty;
    while (true) {
        const line = try reader.readLine();
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadResponse;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const name_copy = allocator.dupe(u8, name) catch return error.OutOfMemory;
        const value_copy = allocator.dupe(u8, value) catch return error.OutOfMemory;
        list.append(allocator, .{ .name = name_copy, .value = value_copy }) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn readBody(allocator: std.mem.Allocator, reader: *BufReader, headers: []const Header, eof_is_body: bool) HttpError![]u8 {
    var body = std.ArrayList(u8).empty;
    if (findHeader(headers, "transfer-encoding")) |te| {
        if (containsIgnoreCase(te, "chunked")) {
            while (true) {
                const line = try reader.readLine();
                const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                const size_text = std.mem.trim(u8, line[0..semi], " \t");
                const size = std.fmt.parseInt(usize, size_text, 16) catch return error.BadResponse;
                if (size == 0) {
                    // Consume trailing headers up to the empty line.
                    while (true) {
                        const t = try reader.readLine();
                        if (t.len == 0) break;
                    }
                    break;
                }
                const chunk = try reader.readExactly(size);
                body.appendSlice(allocator, chunk) catch return error.OutOfMemory;
                const crlf = try reader.readExactly(2);
                if (!std.mem.eql(u8, crlf, "\r\n")) return error.BadResponse;
            }
            return body.toOwnedSlice(allocator) catch error.OutOfMemory;
        }
    }
    if (findHeader(headers, "content-length")) |cl| {
        const n = std.fmt.parseInt(usize, cl, 10) catch return error.BadResponse;
        const bytes = try reader.readExactly(n);
        body.appendSlice(allocator, bytes) catch return error.OutOfMemory;
        return body.toOwnedSlice(allocator) catch error.OutOfMemory;
    }
    if (!eof_is_body) return allocator.alloc(u8, 0) catch error.OutOfMemory;
    const bytes = try reader.readAll();
    body.appendSlice(allocator, bytes) catch return error.OutOfMemory;
    return body.toOwnedSlice(allocator) catch error.OutOfMemory;
}

// ------------------------------ client ------------------------------

fn resolveLocation(allocator: std.mem.Allocator, base: []const u8, location: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://"))
        return allocator.dupe(u8, location);
    const uri = try std.Uri.parse(base);
    const scheme = uri.scheme;
    const host = if (uri.host) |h| componentText(h) else return error.BadUrl;
    if (location.len > 0 and location[0] == '/') {
        if (uri.port) |p| return std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ scheme, host, p, location });
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ scheme, host, location });
    }
    const path = componentText(uri.path);
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const prefix = path[0 .. slash + 1];
    if (uri.port) |p| return std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}{s}", .{ scheme, host, p, prefix, location });
    return std.fmt.allocPrint(allocator, "{s}://{s}{s}{s}", .{ scheme, host, prefix, location });
}

fn basicAuthValue(allocator: std.mem.Allocator, user: []const u8, pass: []const u8) ![]u8 {
    const creds = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, pass });
    defer allocator.free(creds);
    const size = std.base64.standard.Encoder.calcSize(creds.len);
    const out = try allocator.alloc(u8, size);
    const encoded = std.base64.standard.Encoder.encode(out, creds);
    const result = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
    allocator.free(out);
    return result;
}

/// Fetch `url`, returning a fully decoded response (body owned by caller).
pub fn fetch(allocator: std.mem.Allocator, url: []const u8, options: Options) HttpError!Response {
    var current_url = try allocator.dupe(u8, url);
    defer allocator.free(current_url);
    var redirects: u8 = 0;

    while (true) {
        const uri = std.Uri.parse(current_url) catch return error.BadUrl;
        if (!std.mem.eql(u8, uri.scheme, "http")) return error.UnsupportedScheme;
        const host_c = uri.host orelse return error.BadUrl;
        const host = componentText(host_c);
        const port = uri.port orelse 80;
        var target = componentText(uri.path);
        if (target.len == 0) target = "/";
        var owns_target = false;
        if (uri.query) |q| {
            const qtext = componentText(q);
            if (qtext.len > 0) {
                target = try std.fmt.allocPrint(allocator, "{s}?{s}", .{ target, qtext });
                owns_target = true;
            }
        }
        defer if (owns_target) allocator.free(@constCast(target));

        // Resolve the host (numeric literals bypass DNS entirely).
        var addr: net.Address = undefined;
        if (inet.parse(host)) |ip| {
            addr = .{ .ip = ip, .port = port };
        } else {
            var resolver = dns.Resolver.init(allocator);
            const list = resolver.lookupHost(host, port) catch return error.BadUrl;
            defer allocator.free(list);
            if (list.len == 0) return error.BadUrl;
            addr = list[0];
        }

        const fd = net.createAndConnect(addr) catch return error.ConnectionClosed;
        defer net.close(fd);
        net.setRecvTimeout(fd, options.timeout_ms) catch {};
        net.setSendTimeout(fd, options.timeout_ms) catch {};

        var request = std.ArrayList(u8).empty;
        const req_writer = struct {
            fn line(l: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
                const s = try std.fmt.allocPrint(a, fmt ++ "\r\n", args);
                defer a.free(s);
                try l.appendSlice(a, s);
            }
        }.line;
        try req_writer(&request, allocator, "{s} {s} HTTP/1.1", .{ options.method, target });
        try req_writer(&request, allocator, "Host: {s}:{d}", .{ host, port });
        try req_writer(&request, allocator, "User-Agent: bb-zig/1.0", .{});
        try req_writer(&request, allocator, "Connection: close", .{});
        if (options.body.len > 0)
            try req_writer(&request, allocator, "Content-Length: {d}", .{options.body.len});

        var auth: ?[]u8 = null;
        defer if (auth) |a| allocator.free(a);
        if (uri.user) |u| {
            const user = componentText(u);
            const pass = if (uri.password) |p| componentText(p) else "";
            auth = try basicAuthValue(allocator, user, pass);
            try req_writer(&request, allocator, "Authorization: {s}", .{auth.?});
        }
        for (options.headers) |h| {
            try req_writer(&request, allocator, "{s}: {s}", .{ h.name, h.value });
        }
        try request.appendSlice(allocator, "\r\n");
        defer request.deinit(allocator);
        if (options.body.len > 0) try request.appendSlice(allocator, options.body);

        net.sendAll(fd, request.items, 0) catch return error.ConnectionClosed;

        var reader = BufReader{ .fd = fd, .allocator = allocator };
        defer reader.deinit();
        const status_line = try reader.readLine();
        const parsed = try parseStatusLine(status_line);
        const headers = try parseHeaders(allocator, &reader);
        const body = try readBody(allocator, &reader, headers, true);

        if (options.follow_redirects and redirects < options.max_redirects and
            parsed.status >= 300 and parsed.status < 400)
        {
            if (findHeader(headers, "location")) |loc| {
                const loc_copy = allocator.dupe(u8, loc) catch return error.OutOfMemory;
                freeHeaders(allocator, headers);
                allocator.free(body);
                const next = resolveLocation(allocator, current_url, loc_copy) catch return error.BadUrl;
                allocator.free(loc_copy);
                allocator.free(current_url);
                current_url = next;
                redirects += 1;
                continue;
            }
        }

        const reason_copy = allocator.dupe(u8, parsed.reason) catch return error.OutOfMemory;
        return .{ .status = parsed.status, .reason = reason_copy, .headers = headers, .body = body };
    }
}

/// Convenience helper from the brief: append the response body to `out`.
/// `out` and the returned data use page_allocator.
pub fn httpGet(url: []const u8, out: *std.ArrayList(u8)) HttpError!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const response = try fetch(arena.allocator(), url, .{});
    if (response.status < 200 or response.status >= 300) return error.BadResponse;
    out.appendSlice(std.heap.page_allocator, response.body) catch return error.OutOfMemory;
}

pub fn post(allocator: std.mem.Allocator, url: []const u8, body: []const u8, content_type: []const u8) HttpError!Response {
    const headers = [_]Header{.{ .name = "Content-Type", .value = content_type }};
    return fetch(allocator, url, .{ .method = "POST", .body = body, .headers = &headers });
}

// ------------------------------ server ------------------------------

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    version: []const u8,
    headers: []Header,
    body: []u8,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        freeHeaders(allocator, self.headers);
        allocator.free(self.body);
    }
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return findHeader(self.headers, name);
    }
};

pub const Server = struct {
    fd: net.fd_t,
    addr: net.Address,

    pub fn listen(addr: net.Address) HttpError!Server {
        const fd = net.createAndListen(addr, 8) catch return error.ConnectionClosed;
        return .{ .fd = fd, .addr = net.localAddr(fd) catch addr };
    }
    pub fn deinit(self: *Server) void {
        net.close(self.fd);
    }
    pub fn accept(self: *Server) HttpError!Connection {
        const fd = net.accept(self.fd) catch return error.ConnectionClosed;
        return .{ .fd = fd };
    }
};

pub const Connection = struct {
    fd: net.fd_t,

    pub fn deinit(self: *Connection) void {
        net.close(self.fd);
    }

    pub fn readRequest(self: *Connection, allocator: std.mem.Allocator) HttpError!Request {
        var reader = BufReader{ .fd = self.fd, .allocator = allocator };
        defer reader.deinit();
        const line = try reader.readLine();
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const method = it.next() orelse return error.BadResponse;
        const target = it.next() orelse return error.BadResponse;
        const version = it.next() orelse return error.BadResponse;
        const headers = try parseHeaders(allocator, &reader);
        const body = try readBody(allocator, &reader, headers, false);
        const method_copy = allocator.dupe(u8, method) catch return error.OutOfMemory;
        const target_copy = allocator.dupe(u8, target) catch return error.OutOfMemory;
        const version_copy = allocator.dupe(u8, version) catch return error.OutOfMemory;
        return .{
            .method = method_copy,
            .target = target_copy,
            .version = version_copy,
            .headers = headers,
            .body = body,
        };
    }

    pub fn sendRaw(self: *Connection, bytes: []const u8) HttpError!void {
        net.sendAll(self.fd, bytes, 0) catch return error.ConnectionClosed;
    }

    pub fn respond(
        self: *Connection,
        allocator: std.mem.Allocator,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        body: []const u8,
        extra: []const Header,
    ) HttpError!void {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        const head = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ status, reason, content_type, body.len });
        defer allocator.free(head);
        try out.appendSlice(allocator, head);
        for (extra) |h| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {s}\r\n", .{ h.name, h.value });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
        try out.appendSlice(allocator, "\r\n");
        try out.appendSlice(allocator, body);
        try self.sendRaw(out.items);
    }
};
