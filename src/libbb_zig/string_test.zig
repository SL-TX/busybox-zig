const std = @import("std");
const s = @import("libbb_zig").string;

test "strlen counts bytes until NUL" {
    try std.testing.expectEqual(@as(usize, 5), s.strlen("hello"));
    try std.testing.expectEqual(@as(usize, 0), s.strlen(""));
}

test "strnlen caps at max" {
    try std.testing.expectEqual(@as(usize, 3), s.strnlen("hello", 3));
    try std.testing.expectEqual(@as(usize, 5), s.strnlen("hello", 10));
}

test "strcmp compares lexicographically" {
    try std.testing.expectEqual(@as(c_int, 0), s.strcmp("abc", "abc"));
    try std.testing.expect(s.strcmp("abc", "abd") < 0);
    try std.testing.expect(s.strcmp("abd", "abc") > 0);
}

test "strncmp compares at most n bytes" {
    try std.testing.expectEqual(@as(c_int, 0), s.strncmp("abcXYZ", "abc123", 3));
    try std.testing.expect(s.strncmp("abc", "abd", 3) < 0);
}

test "strcpy copies into caller buffer" {
    var buf: [16]u8 = undefined;
    const dst = s.strcpy(&buf, "hi");
    try std.testing.expectEqualStrings("hi", dst);
}

test "strncpy copies at most n bytes" {
    var buf: [16]u8 = undefined;
    @memset(&buf, 'X');
    const dst = s.strncpy(&buf, "hi", 4);
    try std.testing.expectEqualStrings("hi", dst);
}

test "strdup allocates a copy" {
    const d = try s.strdup(std.testing.allocator, "hello");
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("hello", d);
}

test "strdupz copies a length-delimited slice" {
    const d = try s.strdupz(std.testing.allocator, "abc");
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("abc", d);
}

test "strchr finds first occurrence" {
    const r = s.strchr("hello", 'l');
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("llo", r.?);
}

test "strchr returns null when absent" {
    try std.testing.expect(s.strchr("hello", 'z') == null);
}

test "strrchr finds last occurrence" {
    const r = s.strrchr("hello", 'l');
    try std.testing.expectEqualStrings("lo", r.?);
}

test "strstr finds first substring" {
    try std.testing.expectEqualStrings("world", s.strstr("hello world", "world").?);
}

test "strrstr finds last substring" {
    try std.testing.expectEqualStrings("Xc", s.strrstr("aXbXc", "X").?);
}

test "strcasestr is case insensitive" {
    try std.testing.expectEqualStrings("World", s.strcasestr("hello World", "world").?);
}

test "strsep splits on delimiters" {
    var cur: [*:0]const u8 = "a,b,c";
    try std.testing.expectEqualStrings("a", s.strsep(&cur, ",").?);
    try std.testing.expectEqualStrings("b", s.strsep(&cur, ",").?);
    try std.testing.expectEqualStrings("c", s.strsep(&cur, ",").?);
    try std.testing.expect(s.strsep(&cur, ",") == null);
}

test "startswith and endswith" {
    try std.testing.expect(s.startswith("hello", "he"));
    try std.testing.expect(!s.startswith("hello", "lo"));
    try std.testing.expect(s.endswith("hello", "lo"));
    try std.testing.expect(!s.endswith("hello", "he"));
}

test "is_prefixed_with returns the remainder" {
    try std.testing.expectEqualStrings("llo", s.is_prefixed_with("hello", "he").?);
    try std.testing.expect(s.is_prefixed_with("hello", "xx") == null);
}

test "last_char_is returns string without trailing char" {
    try std.testing.expectEqualStrings("hell", s.last_char_is("hello", 'o').?);
    try std.testing.expect(s.last_char_is("hello", 'x') == null);
}

test "chomp removes trailing newlines" {
    try std.testing.expectEqualStrings("hello", s.chomp("hello\n"));
    try std.testing.expectEqualStrings("hello", s.chomp("hello\n\r\n"));
}

test "trim removes surrounding whitespace" {
    try std.testing.expectEqualStrings("hello", s.trim("  hello \t\n"));
}

test "skip_whitespace advances past leading whitespace" {
    try std.testing.expectEqualStrings("hello", s.skip_whitespace(" \thello"));
}

test "replace substitutes all occurrences" {
    const r = try s.replace(std.testing.allocator, "a-b-c", "-", "_");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a_b_c", r);
}

test "concat_path_file joins path and file" {
    const r = try s.concat_path_file(std.testing.allocator, "/tmp", "foo");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("/tmp/foo", r);
}

test "concat_path_file avoids double slash and keeps absolute file" {
    const a = try s.concat_path_file(std.testing.allocator, "/tmp/", "foo");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("/tmp/foo", a);
    const b = try s.concat_path_file(std.testing.allocator, "/tmp", "/abs");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("/abs", b);
}

test "concat_subpath_file rejects nested paths" {
    const a = try s.concat_subpath_file(std.testing.allocator, "/tmp", "foo");
    defer std.testing.allocator.free(a.?);
    try std.testing.expectEqualStrings("/tmp/foo", a.?);
    try std.testing.expect(try s.concat_subpath_file(std.testing.allocator, "/tmp", "a/b") == null);
}

test "get_last_path_component" {
    try std.testing.expectEqualStrings("c", s.get_last_path_component("/a/b/c"));
    try std.testing.expectEqualStrings("b", s.get_last_path_component("a/b/"));
    try std.testing.expectEqualStrings("x", s.get_last_path_component("x"));
}

test "match_fstype matches comma lists" {
    try std.testing.expect(s.match_fstype("ext2", "ext2"));
    try std.testing.expect(s.match_fstype("ext2,ext3", "ext3"));
    try std.testing.expect(!s.match_fstype("ext2", "vfat"));
}
