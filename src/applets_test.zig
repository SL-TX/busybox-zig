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
