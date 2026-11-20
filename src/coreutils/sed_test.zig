const std = @import("std");
const sed = @import("coreutils").sed;

test "sed substitutes first occurrence per line" {
    const out = try sed.renderSed(std.testing.allocator, "foo foo\nbar foo\n", "s/foo/bar/", false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("bar foo\nbar bar\n", out);
}

test "sed substitutes globally with g flag" {
    const out = try sed.renderSed(std.testing.allocator, "foo foo\n", "s/foo/bar/g", false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("bar bar\n", out);
}

test "sed deletes an addressed line" {
    const out = try sed.renderSed(std.testing.allocator, "a\nb\nc\n", "2d", false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nc\n", out);
}

test "sed -n with address p prints only matching lines" {
    const out = try sed.renderSed(std.testing.allocator, "a\nb\na\n", "/a/p", true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\na\n", out);
}

test "sed address $ targets the last line" {
    const out = try sed.renderSed(std.testing.allocator, "a\nb\nc\n", "$d", false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb\n", out);
}
