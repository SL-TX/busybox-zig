//! TDD tests for the generic parse_config helper (Task 25).

const std = @import("std");
const bb = @import("libbb_zig");
const config = bb.daemon.config;

fn parseOwned(text: []const u8, opts: config.Options) ![]config.Entry {
    return config.parse(std.testing.allocator, text, opts);
}

fn freeEntries(entries: []config.Entry) void {
    const a = std.testing.allocator;
    for (entries) |e| {
        for (e.tokens) |tok| a.free(tok);
        a.free(e.tokens);
    }
    a.free(entries);
}

test "parse splits whitespace, collapses runs and strips comments" {
    const entries = try parseOwned(
        "  kern.info   /var/log/messages  # trailing note\n" ++
            "# whole line comment\n" ++
            "\tuser.*\t/dev/console\n",
        .{},
    );
    defer freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 1), entries[0].lineno);
    try std.testing.expectEqualStrings("kern.info", entries[0].tokens[0]);
    try std.testing.expectEqualStrings("/var/log/messages", entries[0].tokens[1]);
    try std.testing.expectEqual(@as(usize, 3), entries[1].lineno);
    try std.testing.expectEqualStrings("user.*", entries[1].tokens[0]);
}

test "parse joins backslash continuations and tracks physical line numbers" {
    const entries = try parseOwned(
        "first \\\ncontinued token  third\n",
        .{},
    );
    defer freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(usize, 2), entries[0].lineno);
    try std.testing.expectEqual(@as(usize, 4), entries[0].tokens.len);
    try std.testing.expectEqualStrings("continued", entries[0].tokens[1]);
}

test "parse greedy keeps the remainder as the final token" {
    const entries = try parseOwned("cmd one two   three\n", .{ .max_tokens = 2 });
    defer freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 2), entries[0].tokens.len);
    try std.testing.expectEqualStrings("cmd", entries[0].tokens[0]);
    try std.testing.expectEqualStrings("one two   three", entries[0].tokens[1]);
}

test "parse without greedy splits only up to max tokens" {
    const entries = try parseOwned("a b c d\n", .{ .max_tokens = 2, .greedy = false });
    defer freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 2), entries[0].tokens.len);
    try std.testing.expectEqualStrings("a", entries[0].tokens[0]);
    try std.testing.expectEqualStrings("b", entries[0].tokens[1]);
}

test "parse honours custom delimiters for inittab style lines" {
    const entries = try parseOwned("tty1:2345:respawn:/sbin/getty 38400 tty1\n", .{
        .delimiters = ":",
    });
    defer freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 4), entries[0].tokens.len);
    try std.testing.expectEqualStrings("/sbin/getty 38400 tty1", entries[0].tokens[3]);
}

test "parse preserves empty fields when trim and collapse are disabled" {
    const entries = try parseOwned("::sysinit:/bin/sh\n", .{
        .delimiters = ":",
        .trim = false,
        .collapse = false,
        .max_tokens = 4,
    });
    defer freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 4), entries[0].tokens.len);
    try std.testing.expectEqualStrings("", entries[0].tokens[0]);
    try std.testing.expectEqualStrings("", entries[0].tokens[1]);
    try std.testing.expectEqualStrings("sysinit", entries[0].tokens[2]);
}

test "parse reports too few tokens instead of silently accepting a bad line" {
    var lineno: usize = 0;
    const r = config.parse(std.testing.allocator, "ok one\nbad\n", .{
        .min_tokens = 2,
        .last_lineno = &lineno,
    });
    if (r) |entries| {
        freeEntries(entries);
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.TooFewTokens, e);
        try std.testing.expectEqual(@as(usize, 2), lineno);
    }
}

test "parse supports alternate comment characters" {
    const entries = try parseOwned("value ; comment\n; skipped\n", .{
        .alt_comment = ';',
        .ws_comments = true,
    });
    defer freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("value", entries[0].tokens[0]);
}

test "parse skips blank lines and returns an empty slice for empty input" {
    const entries = try parseOwned("\n\n   \n", .{});
    defer freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
