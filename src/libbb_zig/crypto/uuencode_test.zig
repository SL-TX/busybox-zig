const std = @import("std");
const uu = @import("libbb_zig").crypto.uuencode;

test "uuencode emits BusyBox-compatible document" {
    const a = std.testing.allocator;
    const out = try uu.encode(a, "demo.txt", 0o664, "foobar");
    defer a.free(out);
    try std.testing.expectEqualStrings("begin 664 demo.txt\n&9F]O8F%R\n`\nend\n", out);
}

test "uuencode splits at 45 bytes" {
    const a = std.testing.allocator;
    const data = @as([46]u8, @splat('A'));
    const out = try uu.encode(a, "f", 0o644, &data);
    defer a.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    try std.testing.expectEqualStrings("begin 644 f", lines.next().?);
    try std.testing.expectEqualStrings("M04%!04%!04%!04%!04%!04%!04%!04%!04%!04%!04%!04%!04%!04%!04%!", lines.next().?);
    try std.testing.expectEqualStrings("!00``", lines.next().?);
    try std.testing.expectEqualStrings("`", lines.next().?);
    try std.testing.expectEqualStrings("end", lines.next().?);
}

test "uudecode round trip and malformed inputs" {
    const a = std.testing.allocator;
    const doc = try uu.encode(a, "demo.txt", 0o664, "foobar");
    defer a.free(doc);
    var decoded = try uu.decode(a, doc);
    defer decoded.deinit(a);
    try std.testing.expectEqualStrings("demo.txt", decoded.name);
    try std.testing.expectEqual(@as(u16, 0o664), decoded.mode);
    try std.testing.expectEqualStrings("foobar", decoded.data);

    try std.testing.expectError(error.InvalidName, uu.encode(a, "bad name", 0o644, "x"));
    try std.testing.expectError(error.MalformedHeader, uu.decode(a, "no header\nend\n"));
    try std.testing.expectError(error.MissingEnd, uu.decode(a, "begin 644 f\n!00``\n"));
    try std.testing.expectError(error.InvalidLength, uu.decode(a, "begin 644 f\n!00\n`\nend\n"));
}
