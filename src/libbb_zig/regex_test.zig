const std = @import("std");
const regex = @import("libbb_zig").regex;
const Regex = regex.Regex;
const Flags = regex.Flags;
const Match = regex.Match;

const bre = Flags{};
const ere = Flags{ .extended = true };

fn find(pattern: []const u8, flags: Flags, text: []const u8) !?Match {
    var re = try regex.compile(std.testing.allocator, pattern, flags);
    defer re.deinit();
    var m: [16]Match = undefined;
    const n = try re.exec(text, &m);
    if (n == 0) return null;
    return m[0];
}

fn expectRange(pattern: []const u8, flags: Flags, text: []const u8, start: usize, end: usize) !void {
    const m = (try find(pattern, flags, text)) orelse return error.ExpectedMatch;
    try std.testing.expectEqual(start, m.start);
    try std.testing.expectEqual(end, m.end);
}

test "regex: literals" {
    try expectRange("abc", bre, "xxabcxx", 2, 5);
    try expectRange("abc", ere, "xxabcxx", 2, 5);
    try std.testing.expect((try find("abc", bre, "xxabxx")) == null);
}

test "regex: dot" {
    try expectRange("a.c", bre, "zzabc", 2, 5);
    try expectRange("a.c", ere, "zzabc", 2, 5);
    try std.testing.expect((try find("a.c", bre, "zzac")) == null);
}

test "regex: star, plus and question" {
    try expectRange("ab*c", bre, "xxabbbc", 2, 7);
    try expectRange("ab*c", bre, "xxac", 2, 4);
    try expectRange("ab+c", ere, "xxabbbc", 2, 7);
    try std.testing.expect((try find("ab+c", ere, "xxac")) == null);
    try expectRange("ab?c", ere, "xxac", 2, 4);
    try expectRange("ab?c", ere, "xxabc", 2, 5);
    try std.testing.expect((try find("ab?c", ere, "xxabbc")) == null);
}

test "regex: bracket expressions" {
    try expectRange("[abc]", bre, "zzbzz", 2, 3);
    try expectRange("[^abc]", bre, "abcde", 3, 4);
    try expectRange("[a-z]+", ere, "!!hello", 2, 7);
    try expectRange("[0-9]+", ere, "ab123", 2, 5);
}

test "regex: anchors" {
    try expectRange("^abc", bre, "abcxx", 0, 3);
    try std.testing.expect((try find("^abc", bre, "xabc")) == null);
    try expectRange("abc$", bre, "xxabc", 2, 5);
    try std.testing.expect((try find("abc$", bre, "abcx")) == null);
}

test "regex: BRE interval \\{m,n\\}" {
    try expectRange("a\\{2,3\\}b", bre, "zaabz", 1, 4);
    try expectRange("a\\{2,3\\}b", bre, "zaaabz", 1, 5);
    try std.testing.expect((try find("a\\{2,3\\}b", bre, "zabz")) == null);
    try expectRange("a\\{2,\\}b", bre, "zaaaab", 1, 6);
    try expectRange("a\\{2\\}b", bre, "zaab", 1, 4);
}

test "regex: ERE interval {m,n}" {
    try expectRange("a{2,3}b", ere, "zaabz", 1, 4);
    try expectRange("a{2,3}b", ere, "zaaabz", 1, 5);
    try std.testing.expect((try find("a{2,3}b", ere, "zabz")) == null);
}

test "regex: alternation" {
    try expectRange("a\\|b", bre, "zzb", 2, 3);
    try expectRange("a|b", ere, "zza", 2, 3);
    try expectRange("cat|dog", ere, "a dog here", 2, 5);
}

test "regex: groups" {
    try expectRange("\\(ab\\)\\+c", bre, "zzababc", 2, 7);
    try expectRange("(ab)+c", ere, "zzababc", 2, 7);
}

test "regex: backreferences" {
    try expectRange("\\(ab\\)\\1", bre, "zzabab", 2, 6);
    try std.testing.expect((try find("\\(ab\\)\\1", bre, "zzabba")) == null);
    try expectRange("(ab)\\1", ere, "zzabab", 2, 6);
}

test "regex: POSIX character classes" {
    try expectRange("[[:alpha:]]+", ere, "123abc!", 3, 6);
    try expectRange("[[:digit:]]\\{1,\\}", bre, "ab123cd", 2, 5);
    try expectRange("[[:space:]]", ere, "a\tb", 1, 2);
    try std.testing.expect((try find("[[:digit:]]", ere, "abc")) == null);
}

test "regex: ignore_case flag" {
    try expectRange("ABC", Flags{ .ignore_case = true }, "xxabcxx", 2, 5);
    try expectRange("[a-z]+", Flags{ .extended = true, .ignore_case = true }, "ABC!", 0, 3);
}

test "regex: capture group offsets" {
    var re = try regex.compile(std.testing.allocator, "([a-z]+)-([0-9]+)", ere);
    defer re.deinit();
    var m: [16]Match = undefined;
    try std.testing.expectEqual(@as(usize, 3), try re.exec("id:abc-123!", &m));
    try std.testing.expectEqual(@as(usize, 3), m[0].start);
    try std.testing.expectEqual(@as(usize, 10), m[0].end);
    try std.testing.expectEqual(@as(usize, 3), m[1].start);
    try std.testing.expectEqual(@as(usize, 6), m[1].end);
    try std.testing.expectEqual(@as(usize, 7), m[2].start);
    try std.testing.expectEqual(@as(usize, 10), m[2].end);
}

test "regex: empty pattern matches empty string" {
    try expectRange("", bre, "anything", 0, 0);
}

test "regex: newline flag makes anchors match at line boundaries" {
    try expectRange("^b", Flags{ .newline = true }, "a\nb", 2, 3);
    try std.testing.expect((try find("^b", bre, "a\nb")) == null);
}

test "regex: backtracking and empty-match loops" {
    try expectRange("(a|ab)c", ere, "zzabc", 2, 5);
    try expectRange("(a*)*b", ere, "xxaaab", 2, 6);
}

test "regex: step limit stops catastrophic backtracking" {
    var re = try regex.compile(std.testing.allocator, "(a+)+$", ere);
    defer re.deinit();
    re.max_steps = 2000;
    var m: [16]Match = undefined;
    try std.testing.expectError(error.StepLimitExceeded, re.exec("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab", &m));
}
