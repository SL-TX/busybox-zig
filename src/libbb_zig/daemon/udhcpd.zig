//! udhcpd.conf parsing helpers (Task 25), modelled on the keyword table in
//! busybox networking/udhcp/dhcpd.c. No sockets or system paths are touched.

const std = @import("std");
const config = @import("config.zig");

pub fn parseIPv4(text: []const u8) error{InvalidIP}!u32 {
    var parts = std.mem.splitScalar(u8, text, '.');
    var result: u32 = 0;
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count == 4) return error.InvalidIP;
        if (part.len == 0) return error.InvalidIP;
        const octet = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIP;
        result = (result << 8) | octet;
        count += 1;
    }
    if (count != 4) return error.InvalidIP;
    return result;
}

pub const Kind = enum { ip, string, number, option, static_lease };

pub const Setting = struct {
    key: []u8,
    value: []u8,
    extra: ?[]u8 = null,
    kind: Kind,
    ip: u32 = 0,
    number: u32 = 0,
    lineno: usize,
};

pub const Defaults = struct {
    start_ip: []const u8 = "192.168.0.20",
    end_ip: []const u8 = "192.168.0.254",
    interface: []const u8 = "eth0",
    max_leases: u32 = 235,
    auto_time: u32 = 7200,
    decline_time: u32 = 3600,
    conflict_time: u32 = 3600,
    offer_time: u32 = 60,
    min_lease: u32 = 60,
    lease_file: []const u8 = "/var/lib/udhcpd.leases",
    pidfile: []const u8 = "/var/run/udhcpd.pid",
    siaddr: []const u8 = "0.0.0.0",
};

pub fn defaults() Defaults {
    return .{};
}

pub const ParseError = error{
    UnknownKeyword,
    InvalidIP,
    InvalidNumber,
    InvalidOption,
    InvalidLease,
    TooFewTokens,
} || config.ConfigError;

const Keyword = struct { name: []const u8, kind: Kind };

const keywords = [_]Keyword{
    .{ .name = "start", .kind = .ip },
    .{ .name = "end", .kind = .ip },
    .{ .name = "interface", .kind = .string },
    .{ .name = "max_leases", .kind = .number },
    .{ .name = "auto_time", .kind = .number },
    .{ .name = "decline_time", .kind = .number },
    .{ .name = "conflict_time", .kind = .number },
    .{ .name = "offer_time", .kind = .number },
    .{ .name = "min_lease", .kind = .number },
    .{ .name = "lease_file", .kind = .string },
    .{ .name = "pidfile", .kind = .string },
    .{ .name = "siaddr", .kind = .ip },
    .{ .name = "option", .kind = .option },
    .{ .name = "opt", .kind = .option },
    .{ .name = "notify_file", .kind = .string },
    .{ .name = "sname", .kind = .string },
    .{ .name = "boot_file", .kind = .string },
    .{ .name = "static_lease", .kind = .static_lease },
};

fn keywordKind(name: []const u8) ?Kind {
    for (keywords) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.kind;
    }
    return null;
}

fn validMac(text: []const u8) bool {
    if (text.len != 17) return false;
    for (text, 0..) |ch, i| {
        if (i % 3 == 2) {
            if (ch != ':') return false;
        } else if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

pub fn parseUdhcpdConf(allocator: std.mem.Allocator, text: []const u8) ParseError![]Setting {
    const lines = try config.parseNormal(allocator, text, "# \t", 2, 1);
    defer {
        for (lines) |line| {
            for (line.tokens) |tok| allocator.free(tok);
            allocator.free(line.tokens);
        }
        allocator.free(lines);
    }

    var settings: std.ArrayList(Setting) = .empty;
    errdefer {
        for (settings.items) |s| {
            allocator.free(s.key);
            allocator.free(s.value);
            if (s.extra) |extra| allocator.free(extra);
        }
        settings.deinit(allocator);
    }

    for (lines) |line| {
        const tokens = line.tokens;
        if (tokens.len < 2) return error.TooFewTokens;
        const kind = keywordKind(tokens[0]) orelse return error.UnknownKeyword;
        var words = std.mem.tokenizeAny(u8, tokens[1], " \t");
        const first = words.next() orelse return error.TooFewTokens;
        const rest = words.rest();
        const extra_text = std.mem.trim(u8, rest, " \t");

        var setting = Setting{
            .key = try allocator.dupe(u8, tokens[0]),
            .value = try allocator.dupe(u8, first),
            .extra = if (extra_text.len > 0) try allocator.dupe(u8, extra_text) else null,
            .kind = kind,
            .lineno = line.lineno,
        };
        errdefer {
            allocator.free(setting.key);
            allocator.free(setting.value);
            if (setting.extra) |e| allocator.free(e);
        }

        switch (kind) {
            .ip => setting.ip = try parseIPv4(first),
            .number => setting.number = std.fmt.parseInt(u32, first, 10) catch return error.InvalidNumber,
            .option => if (extra_text.len == 0) return error.InvalidOption,
            .static_lease => {
                if (!validMac(first)) return error.InvalidLease;
                _ = try parseIPv4(extra_text);
            },
            .string => {},
        }
        try settings.append(allocator, setting);
    }
    return try settings.toOwnedSlice(allocator);
}
