//! Task 21 — regex hardening for the shell/editor waves.
//!
//! Focused regression/property tests for the pure-Zig engine: backreferences,
//! nested groups, alternation, intervals, character classes, ignore-case,
//! multiline anchors, malformed patterns, POSIX leftmost-longest matching,
//! deep-input stack safety, and deterministic fuzzing with a step budget.
//! The public Regex/Flags/Match API is unchanged; `execLongest` is additive.

const std = @import("std");
const regex = @import("libbb_zig").regex;
const Flags = regex.Flags;
const Match = regex.Match;

const bre = Flags{};
const ere = Flags{ .extended = true };
const ci = Flags{ .ignore_case = true };
const ci_ere = Flags{ .extended = true, .ignore_case = true };
const ml = Flags{ .newline = true };
const ml_ere = Flags{ .extended = true, .newline = true };

fn compile(pattern: []const u8, flags: Flags) !regex.Regex {
    return regex.compile(std.testing.allocator, pattern, flags);
}

fn find(pattern: []const u8, flags: Flags, text: []const u8) !?Match {
    var re = try compile(pattern, flags);
    defer re.deinit();
    var m: [16]Match = undefined;
    const n = try re.exec(text, &m);
    if (n == 0) return null;
    return m[0];
}

fn findLongest(pattern: []const u8, flags: Flags, text: []const u8) !?Match {
    var re = try compile(pattern, flags);
    defer re.deinit();
    var m: [16]Match = undefined;
    const n = try re.execLongest(text, &m);
    if (n == 0) return null;
    return m[0];
}

fn expectRange(pattern: []const u8, flags: Flags, text: []const u8, start: usize, end: usize) !void {
    const m = (try find(pattern, flags, text)) orelse return error.ExpectedMatch;
    try std.testing.expectEqual(start, m.start);
    try std.testing.expectEqual(end, m.end);
}

fn expectLongest(pattern: []const u8, flags: Flags, text: []const u8, start: usize, end: usize) !void {
    const m = (try findLongest(pattern, flags, text)) orelse return error.ExpectedMatch;
    try std.testing.expectEqual(start, m.start);
    try std.testing.expectEqual(end, m.end);
}

fn expectCompileError(pattern: []const u8, flags: Flags) !void {
    var re = compile(pattern, flags) catch |err| {
        try std.testing.expect(
            err == error.InvalidPattern or
                err == error.InvalidClass or
                err == error.UnmatchedParen or
                err == error.PatternTooLarge or
                err == error.TooManyGroups,
        );
        return;
    };
    re.deinit();
    return error.ExpectedCompileError;
}

// ---------------------------------------------------------------------------
// Step 1 — feature coverage
// ---------------------------------------------------------------------------

test "hardening: backreferences" {
    try expectRange("\\(a\\)\\1", bre, "xxaa", 2, 4);
    try expectRange("(ab)\\1", ere, "zzabab", 2, 6);
    try std.testing.expect((try find("(ab)\\1", ere, "zzabba")) == null);
    // Backreferences honour ignore-case.
    try expectRange("(ab)\\1", ci_ere, "zzABab", 2, 6);
    // A backreference to a group that did not participate matches empty.
    try expectRange("(a)?b\\1", ere, "zb", 1, 2);
    // Undefined backreferences are rejected, not silently treated as empty.
    try expectCompileError("\\9", bre);
    try expectCompileError("(a)\\2", ere);
}

test "hardening: nested groups and captures" {
    {
        var re = try compile("\\(a\\(b\\)\\)\\2", bre);
        defer re.deinit();
        var m: [8]Match = undefined;
        try std.testing.expectEqual(@as(usize, 3), try re.exec("zabb", &m));
        try std.testing.expectEqual(@as(usize, 1), m[0].start);
        try std.testing.expectEqual(@as(usize, 4), m[0].end);
        try std.testing.expectEqual(@as(usize, 1), m[1].start);
        try std.testing.expectEqual(@as(usize, 3), m[1].end);
        try std.testing.expectEqual(@as(usize, 2), m[2].start);
        try std.testing.expectEqual(@as(usize, 3), m[2].end);
    }

    // Repeated group: each group keeps the span of its last participation.
    {
        var re = try compile("((a)|(b))+", ere);
        defer re.deinit();
        var m: [8]Match = undefined;
        try std.testing.expectEqual(@as(usize, 4), try re.exec("zab", &m));
        try std.testing.expectEqual(@as(usize, 2), m[1].start); // group 1 = last "b"
        try std.testing.expectEqual(@as(usize, 3), m[1].end);
        try std.testing.expectEqual(@as(usize, 1), m[2].start); // group 2 = "a"
        try std.testing.expectEqual(@as(usize, 2), m[2].end);
        try std.testing.expectEqual(@as(usize, 2), m[3].start); // group 3 = "b"
        try std.testing.expectEqual(@as(usize, 3), m[3].end);
    }
}

test "hardening: alternation" {
    try expectRange("a\\|b", bre, "zzb", 2, 3);
    try expectRange("cat|dog", ere, "a dog here", 2, 5);
    // The classic leftmost-first engine stays leftmost-first (API preserved).
    try expectRange("a|ab", ere, "zabc", 1, 2);
}

test "hardening: POSIX leftmost-longest via execLongest" {
    try expectLongest("a|ab", ere, "zabc", 1, 3);
    try expectLongest("(a|ab)c", ere, "zabc", 1, 4);
    try expectLongest("ab|a.*b", ere, "zabxb", 1, 5);
    try expectLongest("a\\|ab", bre, "zabc", 1, 3);
    try std.testing.expect((try findLongest("z|q", ere, "abc")) == null);
}

test "hardening: intervals {m,n}" {
    try expectRange("a{2,4}", ere, "zaaaaab", 1, 5);
    try expectRange("a{2}", ere, "zaaab", 1, 3);
    try expectRange("a{0,2}b", ere, "zab", 1, 3);
    try expectRange("a\\{2,3\\}", bre, "zaaab", 1, 4);
    try expectRange("(ab){2}", ere, "zabab", 1, 5);
    try expectCompileError("a{3,2}", ere);
    try expectCompileError("a{100000}", ere);
}

test "hardening: character classes" {
    try expectRange("[]]", bre, "a]b", 1, 2);
    try expectRange("[-a]", bre, "z-", 1, 2);
    try expectRange("[^]]+", ere, "]ab]", 1, 3);
    try expectRange("[[:alpha:][:digit:]]+", ere, "!!a1b2", 2, 6);
    try expectRange("[^a-z]+", ere, "123abc", 0, 3);
    try expectCompileError("[abc", ere);
    try expectCompileError("[z-a]", ere);
}

test "hardening: ignore-case" {
    try expectRange("ABC", ci, "xxabcxx", 2, 5);
    try expectRange("[a-z]+", ci_ere, "ABC!", 0, 3);
    try expectRange("(abc)\\1", ci_ere, "zABCabc", 1, 7);
    try expectRange("[[:upper:]]+", ci_ere, "!!abc", 2, 5);
}

test "hardening: multiline anchors" {
    try expectRange("^b", ml, "a\nb", 2, 3);
    try expectRange("a$", ml, "a\nb", 0, 1);
    try expectRange("^b$", ml, "a\nb", 2, 3);
    try expectRange("^c", ml_ere, "a\nb\nc", 4, 5);
    try std.testing.expect((try find("^b", bre, "a\nb")) == null);
}

test "hardening: malformed patterns error instead of panicking" {
    const bad = [_][]const u8{
        "\\", // trailing backslash
        "[abc", // unterminated class
        "(a", // unmatched group
        "a{3,2}", // reversed interval
        "a{100000}", // oversized interval
        "\\9", // undefined backreference
        "(a)\\9", // undefined backreference with a defined group
        "\\1(a)", // forward backreference
        "(a\\1)", // reference to a still-open group
        "[z-a]", // reversed range
    };
    for (bad) |p| try expectCompileError(p, ere);
    try expectCompileError("\\", bre);
    try expectCompileError("[abc", bre);
}

test "hardening: deep nesting errors instead of overflowing the parser stack" {
    var pat: [4096]u8 = undefined;
    @memset(pat[0..2048], '(');
    @memset(pat[2048..], ')');
    try expectCompileError(&pat, ere);
}

test "hardening: long input does not exhaust the interpreter stack" {
    const text = try std.testing.allocator.alloc(u8, 100_001);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    text[100_000] = 'c';

    var re = try compile("a*c", ere);
    defer re.deinit();
    re.max_steps = 3_000_000;
    var m: [4]Match = undefined;
    const n = try re.execAt(text, 0, &m);
    try std.testing.expectEqual(@as(?usize, 1), n);
    try std.testing.expectEqual(@as(usize, 0), m[0].start);
    try std.testing.expectEqual(@as(usize, 100_001), m[0].end);
}

test "hardening: step budget returns an error" {
    const text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab";
    var re = try compile("(a+)+$", ere);
    defer re.deinit();
    re.max_steps = 2000;
    var m: [16]Match = undefined;
    try std.testing.expectError(error.StepLimitExceeded, re.exec(text, &m));
    try std.testing.expectError(error.StepLimitExceeded, re.execLongest(text, &m));
}

// ---------------------------------------------------------------------------
// Step 3 — deterministic fuzz / property test
// ---------------------------------------------------------------------------

test "hardening: fuzz — random patterns never hang or crash" {
    var prng = std.Random.DefaultPrng.init(0x5441534b3231);
    const rng = prng.random();
    const alphabet = "abcxy()[]{}|*+?.^$\\-,0123456789:";
    var buf: [24]u8 = undefined;
    const text = "abcxyabc\n";

    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        const len = rng.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
        const pat = buf[0..len];
        const flags = Flags{
            .extended = (i & 1) == 0,
            .ignore_case = (i & 2) != 0,
            .newline = (i & 4) != 0,
        };

        var re = compile(pat, flags) catch |err| {
            // Invalid random patterns are expected; panics are not.
            try std.testing.expect(
                err == error.InvalidPattern or
                    err == error.InvalidClass or
                    err == error.UnmatchedParen or
                    err == error.PatternTooLarge or
                    err == error.TooManyGroups,
            );
            continue;
        };
        defer re.deinit();
        re.max_steps = 500;

        var m: [8]Match = undefined;
        _ = re.exec(text, &m) catch |err| {
            try std.testing.expectEqual(error.StepLimitExceeded, err);
        };
        _ = re.execLongest(text, &m) catch |err| {
            try std.testing.expectEqual(error.StepLimitExceeded, err);
        };
    }
}
