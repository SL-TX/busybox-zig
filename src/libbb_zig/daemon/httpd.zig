//! httpd.conf parsing helpers (Task 25), modelled on the `key:value` lines
//! documented in busybox networking/httpd.c parse_conf().

const std = @import("std");
const config = @import("config.zig");
const udhcpd = @import("udhcpd.zig");

pub const Directive = struct {
    name: []u8,
    value: []u8,
    lineno: usize,
};

pub const ParseError = error{ InvalidDirective, InvalidAcl } || config.ConfigError;

fn validateAcl(value: []const u8) ParseError!void {
    if (std.mem.eql(u8, value, "*")) return;
    var address = value;
    if (std.mem.indexOfScalar(u8, value, '/')) |slash| {
        address = value[0..slash];
        const bits = std.fmt.parseInt(u8, value[slash + 1 ..], 10) catch return error.InvalidAcl;
        if (bits > 32) return error.InvalidAcl;
    }
    _ = udhcpd.parseIPv4(address) catch return error.InvalidAcl;
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
        if (std.mem.eql(u8, name, "A") or std.mem.eql(u8, name, "D")) {
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
