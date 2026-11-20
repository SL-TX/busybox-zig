const std = @import("std");
const awk = @import("coreutils").awk;

test "awk prints a selected field" {
    const out = try awk.renderAwk(std.testing.allocator, "a b\nc d\n", "{print $1}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nc\n", out);
}

test "awk matches a /pattern/ rule" {
    const out = try awk.renderAwk(std.testing.allocator, "a b\nc d\n", "/c/ {print $2}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("d\n", out);
}

test "awk supports BEGIN and END" {
    const out = try awk.renderAwk(std.testing.allocator, "a\nb\n", "BEGIN {print \"start\"} {print} END {print \"end\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("start\na\nb\nend\n", out);
}
