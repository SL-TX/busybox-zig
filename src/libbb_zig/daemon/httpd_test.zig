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
