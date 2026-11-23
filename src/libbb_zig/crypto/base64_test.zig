const std = @import("std");
const base64 = @import("libbb_zig").crypto.base64;

test "base64 encode RFC 4648 vectors" {
    const a = std.testing.allocator;
    const cases = [_]struct { data: []const u8, want: []const u8 }{
        .{ .data = "", .want = "" },
        .{ .data = "f", .want = "Zg==" },
        .{ .data = "fo", .want = "Zm8=" },
        .{ .data = "foo", .want = "Zm9v" },
        .{ .data = "foobar", .want = "Zm9vYmFy" },
    };
    for (cases) |c| {
        const out = try base64.encode(a, c.data);
        defer a.free(out);
        try std.testing.expectEqualStrings(c.want, out);
    }
}

test "base64 decode round trip and malformed input" {
    const a = std.testing.allocator;
    const encoded = try base64.encode(a, "foobar");
    defer a.free(encoded);
    const decoded = try base64.decode(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings("foobar", decoded);

    try std.testing.expectError(error.InvalidCharacter, base64.decode(a, "Zm9v!!!!"));
    try std.testing.expectError(error.InvalidPadding, base64.decode(a, "Zg="));
    try std.testing.expectError(error.InvalidPadding, base64.decode(a, "Zg"));
}
