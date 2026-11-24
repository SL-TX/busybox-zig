//! TDD tests for httpd.conf parsing helpers (Task 25).

const std = @import("std");
const bb = @import("libbb_zig");
const httpd = bb.daemon.httpd;

fn freeDirectives(a: std.mem.Allocator, dirs: []httpd.Directive) void {
    for (dirs) |d| {
        a.free(d.name);
        a.free(d.value);
    }
    a.free(dirs);
}

test "parseHttpdConf reads colon separated directives" {
    const a = std.testing.allocator;
    const text =
        "H:/www\n" ++
        "I:index.html\n" ++
        "# comment\n" ++
        "*.php:/usr/bin/php\n" ++
        "/secret:alice:s3cr3t\n";
    const dirs = try httpd.parseHttpdConf(a, text);
    defer freeDirectives(a, dirs);
    try std.testing.expectEqual(@as(usize, 4), dirs.len);
    try std.testing.expectEqualStrings("H", dirs[0].name);
    try std.testing.expectEqualStrings("/www", dirs[0].value);
    try std.testing.expectEqualStrings("index.html", dirs[1].value);
    try std.testing.expectEqualStrings("*.php", dirs[2].name);
    try std.testing.expectEqualStrings("/usr/bin/php", dirs[2].value);
    try std.testing.expectEqualStrings("/secret", dirs[3].name);
    try std.testing.expectEqualStrings("alice:s3cr3t", dirs[3].value);
}

test "parseHttpdConf tolerates whitespace around directives" {
    const a = std.testing.allocator;
    const dirs = try httpd.parseHttpdConf(a, "  H : /srv/www  # note\n");
    defer freeDirectives(a, dirs);
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expectEqualStrings("H", dirs[0].name);
    try std.testing.expectEqualStrings("/srv/www", dirs[0].value);
}

test "parseHttpdConf rejects a line without a colon" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidDirective, httpd.parseHttpdConf(a, "no-colon\n"));
}

test "findDirective returns the first matching entry" {
    const a = std.testing.allocator;
    const dirs = try httpd.parseHttpdConf(a, "H:/one\nH:/two\n");
    defer freeDirectives(a, dirs);
    const found = httpd.findDirective(dirs, "H").?;
    try std.testing.expectEqualStrings("/one", found.value);
    try std.testing.expect(httpd.findDirective(dirs, "Z") == null);
}

test "httpd acl directives are validated as parsed" {
    const a = std.testing.allocator;
    const bad = httpd.parseHttpdConf(a, "D:not/an/ip\n");
    if (bad) |dirs| {
        freeDirectives(a, dirs);
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.InvalidAcl, e);
    }
    const dirs = try httpd.parseHttpdConf(a, "A:10.0.0.0/8\nD:*\n");
    defer freeDirectives(a, dirs);
    try std.testing.expectEqual(@as(usize, 2), dirs.len);
}

// Reference scan_ip_mask(): partial dotted IPs use an automask, dotted masks
// are accepted after '/', and only the first letter of allow/deny matters.
test "httpd acl accepts partial IPs, dotted masks and allow/deny spellings" {
    const a = std.testing.allocator;
    const text =
        "A:172.20.\n" ++
        "a:10.10.\n" ++
        "allow:10.0.0.0/25\n" ++
        "D:10.0.0.0/255.255.255.128\n" ++
        "d:1.2.3.\n" ++
        "deny:*\n";
    const dirs = try httpd.parseHttpdConf(a, text);
    defer freeDirectives(a, dirs);
    try std.testing.expectEqual(@as(usize, 6), dirs.len);

    for ([_][]const u8{
        "172.20.", "172.20", "10.10.", "1.2.3.", "10.0.0.0",
        "10.0.0.0/25", "10.0.0.0/0", "10.0.0.0/32",
        "10.0.0.0/255.255.255.128", "*",
    }) |valid| {
        try httpd.validateAcl(valid);
    }
    for ([_][]const u8{ "", "no/ip", "1.2.3.4/33", "1.2.3.4/", "256.1.1.1", "1.2.3.4/255.255" }) |invalid| {
        try std.testing.expectError(error.InvalidAcl, httpd.validateAcl(invalid));
    }
}
