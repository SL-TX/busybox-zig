//! TDD tests for crontab parsing helpers (Task 25).

const std = @import("std");
const bb = @import("libbb_zig");
const crond = bb.daemon.crond;

test "parseField accepts star, lists, ranges and steps" {
    const star = try crond.parseField("*", 0, 59);
    try std.testing.expectEqual(@as(usize, 60), star.count());
    try std.testing.expect(star.matches(0));
    try std.testing.expect(star.matches(59));

    const list = try crond.parseField("1,3,5", 0, 59);
    try std.testing.expect(list.matches(3));
    try std.testing.expect(!list.matches(2));

    const range = try crond.parseField("5-10", 0, 59);
    try std.testing.expect(range.matches(5));
    try std.testing.expect(range.matches(10));
    try std.testing.expect(!range.matches(11));

    const step = try crond.parseField("*/15", 0, 59);
    try std.testing.expect(step.matches(0));
    try std.testing.expect(step.matches(15));
    try std.testing.expect(step.matches(45));
    try std.testing.expect(!step.matches(7));

    const range_step = try crond.parseField("10-20/5", 0, 59);
    try std.testing.expect(range_step.matches(10));
    try std.testing.expect(range_step.matches(15));
    try std.testing.expect(!range_step.matches(11));
}

test "parseField accepts three-letter month and weekday names" {
    const months = try crond.parseField("jan,mar-jun", 1, 12);
    try std.testing.expect(months.matches(1));
    try std.testing.expect(months.matches(4));
    try std.testing.expect(!months.matches(7));
    const dow = try crond.parseField("mon-fri", 0, 7);
    try std.testing.expect(dow.matches(1));
    try std.testing.expect(!dow.matches(0));
}

test "parseField rejects malformed and out of range input" {
    try std.testing.expectError(error.InvalidField, crond.parseField("60", 0, 59));
    try std.testing.expectError(error.InvalidField, crond.parseField("-1", 0, 59));
    try std.testing.expectError(error.InvalidRange, crond.parseField("9-5", 0, 59));
    try std.testing.expectError(error.InvalidStep, crond.parseField("*/0", 0, 59));
    try std.testing.expectError(error.InvalidField, crond.parseField("nope", 0, 59));
    try std.testing.expectError(error.InvalidField, crond.parseField("", 0, 59));
}

test "parseCrontab keeps environment assignments and scheduled entries" {
    const a = std.testing.allocator;
    const text =
        "MAILTO=root\n" ++
        "# comment\n" ++
        "*/5 * * * * /bin/echo hello world\n" ++
        "0 3 * * 1-5 /usr/bin/backup --full\n";
    const crontab = try crond.parseCrontab(a, text);
    defer {
        for (crontab.entries) |e| a.free(e.command);
        a.free(crontab.entries);
        for (crontab.env) |e| {
            a.free(e.name);
            a.free(e.value);
        }
        a.free(crontab.env);
    }
    try std.testing.expectEqual(@as(usize, 1), crontab.env.len);
    try std.testing.expectEqualStrings("MAILTO", crontab.env[0].name);
    try std.testing.expectEqualStrings("root", crontab.env[0].value);
    try std.testing.expectEqual(@as(usize, 2), crontab.entries.len);
    try std.testing.expect(crontab.entries[0].minute.matches(5));
    try std.testing.expect(crontab.entries[0].hour.matches(12));
    try std.testing.expectEqualStrings("/bin/echo hello world", crontab.entries[0].command);
    try std.testing.expect(crontab.entries[1].dow.matches(3));
    try std.testing.expect(!crontab.entries[1].dow.matches(6));
}

test "parseCrontab rejects a line with too few time fields" {
    const a = std.testing.allocator;
    const r = crond.parseCrontab(a, "* * * /bin/true\n");
    if (r) |crontab| {
        for (crontab.entries) |e| a.free(e.command);
        a.free(crontab.entries);
        a.free(crontab.env);
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.TooFewTokens, e);
    }
}
