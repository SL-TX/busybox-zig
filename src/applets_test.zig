const std = @import("std");
const a = @import("applets.zig");

test "registry contains the full applet set" {
    try std.testing.expect(a.countApplets() > 250);
}

test "applets are found by exact name" {
    try std.testing.expect(a.findAppletByName("cat") != null);
    try std.testing.expect(a.findAppletByName("echo") != null);
    try std.testing.expect(a.findAppletByName("definitely_not_an_applet") == null);
}

test "appletNames lists every registered applet sorted" {
    const names = try a.appletNames(std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(a.countApplets(), names.len);
    for (names, 1..) |name, i| {
        try std.testing.expect(std.mem.order(u8, names[i - 1], name) != .gt);
    }
}

test "applet metadata matches tests/parity/manifest.json" {
    const manifest_json = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/parity/manifest.json",
        std.testing.allocator,
        @as(std.Io.Limit, @enumFromInt(1024 * 1024)),
    );
    defer std.testing.allocator.free(manifest_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest_json, .{});
    defer parsed.deinit();
    const entries = parsed.value.object.get("entries").?.array.items;

    const names = [_][]const u8{
        "cat", "passwd", "init", "sh", "ls",
        "clear", "test", "[", "[[", "true",
    };
    for (names) |name| {
        var found: ?std.json.Value = null;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.object.get("name").?.string, name)) {
                found = entry;
                break;
            }
        }
        const expected = found orelse return error.MissingManifestEntry;
        const applet = a.findAppletByName(name) orelse return error.MissingApplet;

        try std.testing.expectEqualStrings(expected.object.get("location").?.string, applet.location);
        try std.testing.expectEqualStrings(expected.object.get("suid").?.string, @tagName(applet.suid));
        try std.testing.expectEqual(expected.object.get("noexec").?.bool, applet.noexec);
        try std.testing.expectEqual(expected.object.get("nofork").?.bool, applet.nofork);
        try std.testing.expectEqual(expected.object.get("scripted").?.bool, applet.scripted);
        try std.testing.expectEqualStrings(expected.object.get("category").?.string, applet.category);
        try std.testing.expectEqualStrings(expected.object.get("config").?.string, applet.config);
        try std.testing.expectEqual(expected.object.get("default_enabled").?.bool, applet.default_enabled);
    }
}

test "legacy non-applet helper names are absent" {
    const legacy = [_][]const u8{
        "tls_aes", "tcpudp", "isrv", "httpd_ssi", "tls_pstm_montgomery_reduce",
    };
    for (legacy) |name| {
        try std.testing.expect(a.findAppletByName(name) == null);
    }
}
