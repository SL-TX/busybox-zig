const std = @import("std");
const t = @import("coreutils");

const sample = "one\ntwo\nthree\n";

test "headLines returns the first n lines" {
    try std.testing.expectEqualStrings("one\ntwo\n", t.headLines(sample, 2));
}

test "tailLines returns the last n lines" {
    try std.testing.expectEqualStrings("two\nthree\n", t.tailLines(sample, 2));
}

test "wordCount counts lines words and bytes" {
    const c = t.wordCount(sample);
    try std.testing.expectEqual(@as(usize, 3), c.lines);
    try std.testing.expectEqual(@as(usize, 3), c.words);
    try std.testing.expectEqual(@as(usize, 14), c.bytes);
}

test "sortLines sorts lexicographically" {
    const out = try t.sortLines(std.testing.allocator, "c\na\nb\n", false, false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb\nc\n", out);
}

test "sortLines with unique drops duplicates" {
    const out = try t.sortLines(std.testing.allocator, "b\na\nb\n", false, true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb\n", out);
}

test "uniqLines drops adjacent duplicates" {
    const out = try t.uniqLines(std.testing.allocator, "a\na\nb\na\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb\na\n", out);
}

test "cutFields selects a delimited field" {
    const out = try t.cutFields(std.testing.allocator, "a:b:c\nd:e:f\n", ':', 2);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("b\ne\n", out);
}
