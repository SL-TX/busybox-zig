//! Unit tests for the Task 18 console-tools helpers (parsers and formatters).

const std = @import("std");
const ct = @import("console_tools");
const font = ct.font;
const common = ct.common;

test "setfont textual map fills vanilla entries and detects unicode mode" {
    var u: [256]u16 = undefined;
    const unicode = try font.parseTextualMap("0x00 U+0000\n0x41 U+0410\n", &u);
    try std.testing.expect(unicode);
    try std.testing.expectEqual(@as(u16, 0xf001), u[1]);
    try std.testing.expectEqual(@as(u16, 0x0410), u[0x41]);
    try std.testing.expectEqual(@as(u16, 0), u[0]);
}

test "setfont textual map accepts quoted chars and ASCII-only maps" {
    var u: [256]u16 = undefined;
    const unicode = try font.parseTextualMap("'A' 65 # comment\n0x42 0x42\n", &u);
    try std.testing.expect(!unicode);
    try std.testing.expectEqual(@as(u16, 65), u[65]);
    try std.testing.expectEqual(@as(u16, 0x42), u[0x42]);
}

test "setfont textual map rejects malformed lines" {
    var u: [256]u16 = undefined;
    try std.testing.expectError(error.MapFormat, font.parseTextualMap("0x41\n", &u));
    try std.testing.expectError(error.MapFormat, font.parseTextualMap("999 65\n", &u));
    try std.testing.expectError(error.MapFormat, font.parseTextualMap("1 99999\n", &u));
}

test "scancode parser handles e0 prefix and bounds" {
    // The pure part of setkeycodes' scancode conversion.
    try std.testing.expectEqual(@as(u32, 0xe030), common.parseScancode("e030"));
    try std.testing.expectEqual(@as(u32, 0x30), common.parseScancode("30"));
}
