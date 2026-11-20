const std = @import("std");
const u = @import("util.zig");

test "isqrt floors the square root" {
    try std.testing.expectEqual(@as(u64, 4), u.isqrt(16));
    try std.testing.expectEqual(@as(u64, 4), u.isqrt(17));
    try std.testing.expectEqual(@as(u64, 0), u.isqrt(0));
}

test "human_readable scales with binary units" {
    const a = try u.human_readable(std.testing.allocator, 1536, false);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("1.5K", a);
}

test "mode_string renders a file mode" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("-rw-r--r--", u.mode_string(0o100644, &buf));
}

test "parse_mode reads octal modes" {
    try std.testing.expectEqual(@as(u32, 0o755), try u.parse_mode("0755"));
}

test "process_escape_sequence decodes common escapes" {
    const out = try u.process_escape_sequence(std.testing.allocator, "a\\nb\\t\\x41");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb\tA", out);
}

test "signal_names returns the short name" {
    try std.testing.expectEqualStrings("TERM", u.signal_names(15));
}

test "get_cpu_count is positive" {
    try std.testing.expect(u.get_cpu_count() > 0);
}
