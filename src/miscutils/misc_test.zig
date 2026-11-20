const std = @import("std");
const misc = @import("miscutils");
const env = @import("libbb_zig").env;

test "parseRenicePriority accepts signed priorities in the POSIX range" {
    try std.testing.expectEqual(@as(i32, -3), try misc.parseRenicePriority("-3"));
    try std.testing.expectEqual(@as(i32, 19), try misc.parseRenicePriority("19"));
    try std.testing.expectError(error.InvalidPriority, misc.parseRenicePriority("20"));
    try std.testing.expectError(error.InvalidPriority, misc.parseRenicePriority("abc"));
}

test "parseIonice parses class and data" {
    const idle = try misc.parseIonice("idle");
    try std.testing.expectEqual(@as(u16, 3), idle.class);
    try std.testing.expectEqual(@as(u16, 0), idle.data);
    const be = try misc.parseIonice("be:7");
    try std.testing.expectEqual(@as(u16, 2), be.class);
    try std.testing.expectEqual(@as(u16, 7), be.data);
    const numeric = try misc.parseIonice("3");
    try std.testing.expectEqual(@as(u16, 3), numeric.class);
    try std.testing.expectEqual(@as(u16, 0), numeric.data);
    try std.testing.expectError(error.InvalidPriority, misc.parseIonice("rt:8"));
}

test "parseIoniceArgs separates options from the command" {
    const inv = try misc.parseIoniceArgs(&.{ "ionice", "-c", "3", "/bin/true" });
    try std.testing.expectEqual(@as(u16, 3), inv.prio.class);
    try std.testing.expectEqual(@as(usize, 3), inv.command_start);
    const named = try misc.parseIoniceArgs(&.{ "ionice", "idle", "/bin/true" });
    try std.testing.expectEqual(@as(u16, 3), named.prio.class);
    try std.testing.expectEqual(@as(usize, 2), named.command_start);
}

test "resolveCommand searches PATH for ionice children" {
    const path = try misc.resolveCommand(std.testing.allocator, "true", "/bin:/usr/bin");
    defer if (path) |p| std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("/bin/true", path.?);
}

test "ioprioValue packs class and data into the syscall value" {
    try std.testing.expectEqual(@as(u16, (2 << 13) | 4), misc.ioprioValue(.{ .class = 2, .data = 4 }));
}

test "parseCrontabLine validates the five time fields" {
    const e = misc.parseCrontabLine("*/5 * * * * /bin/echo hi").?;
    try std.testing.expectEqualStrings("*/5", e.minute);
    try std.testing.expectEqualStrings("*", e.hour);
    try std.testing.expectEqualStrings("/bin/echo hi", e.command);
    try std.testing.expect(misc.parseCrontabLine("61 * * * * cmd") == null);
    try std.testing.expect(misc.parseCrontabLine("* * * * cmd") == null);
}

test "spoolPath honors the environment override" {
    var test_map = std.process.Environ.Map.init(std.testing.allocator);
    defer test_map.deinit();
    try test_map.put("CRONTAB_DIR", "/tmp/bb-spool");
    const prev = env.map;
    env.map = &test_map;
    defer env.map = prev;

    const path = try misc.spoolPath(std.testing.allocator, "crontab");
    defer std.testing.allocator.free(path);
    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "/tmp/bb-spool/{d}", .{std.os.linux.getuid()});
    try std.testing.expectEqualStrings(expected, path);
}
