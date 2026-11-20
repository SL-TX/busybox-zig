const std = @import("std");
const rem = @import("remaining");

test "formatAsciiLine renders a table row" {
    var buf: [64]u8 = undefined;
    const line = try rem.formatAsciiLine(65, &buf);
    try std.testing.expectEqualStrings(" 65 0x41 A", line);
}

test "dcEval evaluates reverse-Polish arithmetic" {
    try std.testing.expectEqual(@as(i64, 7), try rem.dcEval("3 4 +"));
    try std.testing.expectEqual(@as(i64, 12), try rem.dcEval("3 4 *"));
    try std.testing.expectError(error.InvalidExpression, rem.dcEval("3 +"));
}

test "bbconfigLine emits a Kconfig-style line" {
    var buf: [128]u8 = undefined;
    const line = try rem.bbconfigLine("CAT", &buf);
    try std.testing.expectEqualStrings("CONFIG_CAT=y\n", line);
}
