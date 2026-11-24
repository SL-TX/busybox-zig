//! inetd.conf parsing helpers (Task 25), modelled on busybox networking/inetd.c.

const std = @import("std");
const config = @import("config.zig");

pub const Endpoint = struct {
    host: []const u8,
    port: u16,
};

const known_services = [_]struct { name: []const u8, port: u16 }{
    .{ .name = "echo", .port = 7 },
    .{ .name = "ftp", .port = 21 },
    .{ .name = "ssh", .port = 22 },
    .{ .name = "telnet", .port = 23 },
    .{ .name = "smtp", .port = 25 },
    .{ .name = "http", .port = 80 },
    .{ .name = "https", .port = 443 },
};

pub fn servicePort(name: []const u8) ?u16 {
    for (known_services) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.port;
    }
    return null;
}

pub fn splitEndpoint(text: []const u8) error{InvalidEndpoint}!Endpoint {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidEndpoint;
    const host = text[0..colon];
    const service = text[colon + 1 ..];
    if (service.len == 0) return error.InvalidEndpoint;
    const port = if (std.fmt.parseInt(u16, service, 10)) |numeric| numeric else |_| servicePort(service) orelse return error.InvalidEndpoint;
    if (port == 0) return error.InvalidEndpoint;
    return .{ .host = host, .port = port };
}

pub const SockType = enum { stream, dgram, rdm, seqpacket, raw };

pub const WaitMode = enum { wait, nowait };

pub const Entry = struct {
    host: ?[]u8,
    service: []u8,
    socktype: SockType,
    protocol: []u8,
    wait: WaitMode,
    max_connections: ?u16,
    user: []u8,
    group: ?[]u8,
    program: []u8,
    args: [][]u8,
    lineno: usize,
};

pub const ParseError = error{
    InvalidEndpoint,
    InvalidSocketType,
    InvalidWaitMode,
    InvalidNumber,
    TooFewTokens,
} || config.ConfigError;

fn sockTypeByName(name: []const u8) ?SockType {
    if (std.mem.eql(u8, name, "stream")) return .stream;
    if (std.mem.eql(u8, name, "dgram")) return .dgram;
    if (std.mem.eql(u8, name, "rdm")) return .rdm;
    if (std.mem.eql(u8, name, "seqpacket")) return .seqpacket;
    if (std.mem.eql(u8, name, "raw")) return .raw;
    return null;
}

fn freeEntry(allocator: std.mem.Allocator, entry: Entry) void {
    if (entry.host) |h| allocator.free(h);
    allocator.free(entry.service);
    allocator.free(entry.protocol);
    allocator.free(entry.user);
    if (entry.group) |g| allocator.free(g);
    allocator.free(entry.program);
    for (entry.args) |arg| allocator.free(arg);
    allocator.free(entry.args);
}

/// Parse `[host:]service socktype protocol wait[.max] user[:group] program [args]`.
pub fn parseInetdConf(allocator: std.mem.Allocator, text: []const u8) ParseError![]Entry {
    const lines = try config.parse(allocator, text, .{
        .delimiters = "# \t",
        .max_tokens = 16,
        .greedy = false,
        .min_tokens = 0,
    });
    defer {
        for (lines) |line| {
            for (line.tokens) |tok| allocator.free(tok);
            allocator.free(line.tokens);
        }
        allocator.free(lines);
    }

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| freeEntry(allocator, entry);
        entries.deinit(allocator);
    }

    var default_host: ?[]u8 = null;
    defer if (default_host) |h| allocator.free(h);

    for (lines) |line| {
        const tokens = line.tokens;
        if (tokens.len == 0) continue;

        var service_text = tokens[0];
        var host_text: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, service_text, ':')) |colon| {
            host_text = service_text[0..colon];
            service_text = service_text[colon + 1 ..];
            if (service_text.len == 0) {
                if (tokens.len != 1) return error.InvalidEndpoint;
                if (default_host) |old| allocator.free(old);
                default_host = try allocator.dupe(u8, host_text.?);
                continue;
            }
        }
        if (tokens.len < 6) return error.TooFewTokens;

        const socktype = sockTypeByName(tokens[1]) orelse return error.InvalidSocketType;
        if (tokens[2].len == 0) return error.InvalidEndpoint;

        const wait_text = tokens[3];
        var wait: WaitMode = undefined;
        var max_connections: ?u16 = null;
        if (std.mem.eql(u8, wait_text, "wait")) {
            wait = .wait;
        } else if (std.mem.eql(u8, wait_text, "nowait")) {
            wait = .nowait;
        } else if (std.mem.startsWith(u8, wait_text, "wait.")) {
            wait = .wait;
            max_connections = std.fmt.parseInt(u16, wait_text[5..], 10) catch return error.InvalidNumber;
            if (max_connections.? == 0) return error.InvalidNumber;
        } else if (std.mem.startsWith(u8, wait_text, "nowait.")) {
            wait = .nowait;
            max_connections = std.fmt.parseInt(u16, wait_text[7..], 10) catch return error.InvalidNumber;
            if (max_connections.? == 0) return error.InvalidNumber;
        } else {
            return error.InvalidWaitMode;
        }

        var user_text = tokens[4];
        var group_text: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, user_text, ':')) |colon| {
            group_text = user_text[colon + 1 ..];
            user_text = user_text[0..colon];
        }

        var args: std.ArrayList([]u8) = .empty;
        errdefer {
            for (args.items) |arg| allocator.free(arg);
            args.deinit(allocator);
        }
        for (tokens[6..]) |arg| try args.append(allocator, try allocator.dupe(u8, arg));

        const host_copy: ?[]u8 = if (host_text) |h|
            try allocator.dupe(u8, h)
        else if (default_host) |h|
            try allocator.dupe(u8, h)
        else
            null;

        const entry = Entry{
            .host = host_copy,
            .service = try allocator.dupe(u8, service_text),
            .socktype = socktype,
            .protocol = try allocator.dupe(u8, tokens[2]),
            .wait = wait,
            .max_connections = max_connections,
            .user = try allocator.dupe(u8, user_text),
            .group = if (group_text) |g| try allocator.dupe(u8, g) else null,
            .program = try allocator.dupe(u8, tokens[5]),
            .args = try args.toOwnedSlice(allocator),
            .lineno = line.lineno,
        };
        errdefer freeEntry(allocator, entry);
        try entries.append(allocator, entry);
    }

    return try entries.toOwnedSlice(allocator);
}
