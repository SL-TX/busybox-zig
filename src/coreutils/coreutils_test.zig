const std = @import("std");
const cu = @import("coreutils");

test "echo joins arguments and appends a newline" {
    const out = try cu.renderEcho(std.testing.allocator, &.{ "hello", "world" }, false, false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world\n", out);
}

test "echo -n suppresses the newline" {
    const out = try cu.renderEcho(std.testing.allocator, &.{"hi"}, true, false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hi", out);
}

test "echo -e decodes escapes" {
    const out = try cu.renderEcho(std.testing.allocator, &.{"a\\nb"}, false, true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb\n", out);
}

test "printf substitutes %s and %d" {
    const out = try cu.renderPrintf(std.testing.allocator, "%s=%d\n", &.{ "x", "42" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("x=42\n", out);
}
