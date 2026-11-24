const std = @import("std");
const mod = @import("sysklogd");

const pri = [_]mod.Priority{
    .{ .name = "emerg", .value = 0 }, .{ .name = "panic", .value = 0 },
    .{ .name = "err", .value = 3 }, .{ .name = "warn", .value = 4 },
    .{ .name = "notice", .value = 5 }, .{ .name = "info", .value = 6 },
    .{ .name = "debug", .value = 7 },
};
const fac = [_]mod.Priority{
    .{ .name = "kern", .value = 0 }, .{ .name = "user", .value = 1 },
    .{ .name = "daemon", .value = 3 }, .{ .name = "local7", .value = 23 },
};

test "logger priority names and numeric prefixes decode like busybox" {
    for (pri) |p| try std.testing.expectEqual(p.value, mod.decode(&pri, p.name).?);
    try std.testing.expectEqual(5, mod.decode(&pri, "5xyz").?);
    try std.testing.expect(mod.decode(&pri, "bogus") == null);
    for (fac) |f| try std.testing.expectEqual(f.value, mod.decode(&fac, f.name).?);
}

test "encodePriority builds facility/level pairs" {
    try std.testing.expectEqual(@as(u8, 14), mod.encodePriority("logger", "user.info"));
    try std.testing.expectEqual(@as(u8, 188), mod.encodePriority("logger", "local7.warn"));
}
