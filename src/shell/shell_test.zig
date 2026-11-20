const std = @import("std");
const sh = @import("shell");

test "tokenize honors quotes and backslash escapes" {
    const a = std.testing.allocator;
    const words = try sh.tokenize(a, "echo 'hello world' \"a b\" c\\ d");
    defer {
        for (words) |w| a.free(w);
        a.free(words);
    }
    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("echo", words[0]);
    try std.testing.expectEqualStrings("hello world", words[1]);
    try std.testing.expectEqualStrings("a b", words[2]);
    try std.testing.expectEqualStrings("c d", words[3]);
}

test "expandVars substitutes $NAME and ${NAME}" {
    const a = std.testing.allocator;
    const vars = [_]sh.Var{
        .{ .name = "NAME", .value = "Alice" },
        .{ .name = "OTHER", .value = "Bob" },
    };
    const result = try sh.expandVars(a, "hi $NAME ${OTHER}", &vars);
    defer a.free(result);
    try std.testing.expectEqualStrings("hi Alice Bob", result);
}

test "cwdSlice strips the kernel's trailing NUL" {
    try std.testing.expectEqualStrings("/tmp", sh.cwdSlice("/tmp\x00rest", 5));
}

test "runInput executes semicolon-separated commands" {
    var ctx = sh.Context{ .allocator = std.testing.allocator };
    defer ctx.deinit();
    const code = sh.runInput(&ctx, "X=foo; exit 7");
    try std.testing.expectEqual(@as(u8, 7), code);
    try std.testing.expectEqualStrings("foo", ctx.get("X").?);
}

test "findInPath locates an executable" {
    const a = std.testing.allocator;
    const path = try sh.findInPath(a, "true", "/bin:/usr/bin");
    defer if (path) |p| a.free(p);
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/bin/true", path.?);
}

test "findInPath returns null for a missing command" {
    const a = std.testing.allocator;
    const path = try sh.findInPath(a, "definitely-not-a-real-command-xyz", "/bin:/usr/bin");
    defer if (path) |p| a.free(p);
    try std.testing.expect(path == null);
}
