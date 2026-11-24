const std = @import("std");
const mod = @import("editors");

test "diff blank-line filtering keeps only non-blank lines" {
    const input = [_][]const u8{ "a", "", "  ", "b" };
    const out = mod.nonBlank(&input);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("a", out[0]);
    try std.testing.expectEqualStrings("b", out[1]);
}

test "diff address normalisation folds case and whitespace runs" {
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const x = mod.normalizeLine("A  B", true, true, false, &buf1);
    const y = mod.normalizeLine("a b", true, true, false, &buf2);
    try std.testing.expectEqualStrings(x, y);
}

test "patch-style path stripping removes leading components" {
    try std.testing.expectEqualStrings("f", mod.stripPath("a/b/f", 2));
    try std.testing.expectEqualStrings("b/f", mod.stripPath("a/b/f", 1));
    try std.testing.expectEqualStrings("f", mod.stripPath("a/b/f", 5));
}
