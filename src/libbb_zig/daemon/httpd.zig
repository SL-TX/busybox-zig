//! httpd.conf parsing helpers (Task 25), modelled on the `key:value` lines
//! documented in busybox networking/httpd.c parse_conf().

const std = @import("std");
const config = @import("config.zig");

pub const Directive = struct {
    name: []u8,
    value: []u8,
    lineno: usize,
};

pub const ParseError = error{ InvalidDirective, InvalidAcl } || config.ConfigError;

const IpScan = struct { rest: []const u8, automask: u8 };

/// Mirrors busybox scan_ip(): four decimal octets, optional '.' separators,
/// an automask derived from the components actually written, and an optional
/// terminator (`/` for a mask suffix, null for a full dotted mask).
fn scanIp(text: []const u8, endc: ?u8) ?IpScan {
    if (text.len == 0 or text[0] == '/') return null;
    var rest = text;
    var automask: u8 = 8;
    var octets: usize = 0;
    while (octets < 4) : (octets += 1) {
        if (rest.len > 0 and rest[0] != '/' and !std.ascii.isDigit(rest[0])) return null;
        var octet: u16 = 0;
        while (rest.len > 0 and std.ascii.isDigit(rest[0])) {
            octet = octet * 10 + (rest[0] - '0');
            if (octet > 255) return null;
            rest = rest[1..];
        }
        if (rest.len > 0 and rest[0] == '.') rest = rest[1..];
        if (rest.len > 0) automask += 8;
    }
    if (rest.len > 0) {
        if (endc) |c| {
            if (rest[0] != c) return null;
            rest = rest[1..];
            if (rest.len == 0) return null;
        } else return null;
    }
    return .{ .rest = rest, .automask = automask };
}

/// Mirrors busybox scan_ip_mask(): accepts partial IPs with automasks,
/// numeric /0../32 prefixes and full dotted masks such as /255.255.255.128.
pub fn validateAcl(value: []const u8) ParseError!void {
    if (std.mem.eql(u8, value, "*")) return;
    if (value.len == 0) return error.InvalidAcl;
    const ip = scanIp(value, '/') orelse return error.InvalidAcl;

    if (ip.rest.len == 0) {
        if (ip.automask > 32) return error.InvalidAcl;
        return;
    }
    if (std.mem.indexOfScalar(u8, ip.rest, '.') != null) {
        const mask = scanIp(ip.rest, null) orelse return error.InvalidAcl;
        // scan_ip() returns its automask; a full dotted mask yields 32.
        if (mask.rest.len != 0 or mask.automask != 32) return error.InvalidAcl;
        return;
    }
    var prefix: u32 = 0;
    for (ip.rest) |ch| {
        if (!std.ascii.isDigit(ch)) return error.InvalidAcl;
        prefix = prefix * 10 + (ch - '0');
        if (prefix > 32) return error.InvalidAcl;
    }
}

/// Parse `directive:value` lines. The value is taken greedily so embedded
/// colons (auth and ACL entries) are preserved.
pub fn parseHttpdConf(allocator: std.mem.Allocator, text: []const u8) ParseError![]Directive {
    const lines = try config.parse(allocator, text, .{
        .delimiters = ": \t",
        .comment = '#',
        .max_tokens = 2,
        .min_tokens = 0,
        .greedy = true,
    });
    defer {
        for (lines) |line| {
            for (line.tokens) |tok| allocator.free(tok);
            allocator.free(line.tokens);
        }
        allocator.free(lines);
    }

    var directives: std.ArrayList(Directive) = .empty;
    errdefer {
        for (directives.items) |d| {
            allocator.free(d.name);
            allocator.free(d.value);
        }
        directives.deinit(allocator);
    }

    for (lines) |line| {
        if (line.tokens.len < 2) return error.InvalidDirective;
        const name = line.tokens[0];
        const value = line.tokens[1];
        // Reference: "A/D may be a/d or allow/deny - only first char matters."
        if (name.len > 0 and (std.ascii.toUpper(name[0]) == 'A' or std.ascii.toUpper(name[0]) == 'D')) {
            try validateAcl(value);
        }
        try directives.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
            .lineno = line.lineno,
        });
    }
    return try directives.toOwnedSlice(allocator);
}

pub fn findDirective(directives: []const Directive, name: []const u8) ?Directive {
    for (directives) |d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}
