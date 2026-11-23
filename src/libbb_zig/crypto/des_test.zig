const std = @import("std");
const des = @import("libbb_zig").crypto.des;

test "raw DES matches the FIPS 46-3 known-answer vector" {
    // key 0x133457799BBCDFF1, plaintext 0x0123456789ABCDEF
    try std.testing.expectEqual(@as(u64, 0x85E813540F0AB405), des.encryptBlockRaw(0x133457799BBCDFF1, 0x0123456789ABCDEF));
}

test "traditional DES crypt matches reference cryptpw vectors" {
    const a = std.testing.allocator;
    const cases = [_]struct { key: []const u8, salt: []const u8, want: []const u8 }{
        .{ .key = "password", .salt = "ab", .want = "abJnggxhB/yWI" },
        .{ .key = "password", .salt = "sa", .want = "sa3tHJ3/KuYvI" },
        .{ .key = "hello", .salt = "ab", .want = "abl0JrMf6tlhw" },
    };
    for (cases) |c| {
        const out = try des.crypt(a, c.key, c.salt);
        defer a.free(out);
        try std.testing.expectEqualStrings(c.want, out);
    }
}

test "DES crypt rejects malformed salts and keys" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidSalt, des.crypt(a, "password", "a"));
    try std.testing.expectError(error.InvalidSalt, des.crypt(a, "password", ":a"));
    try std.testing.expectError(error.InvalidSalt, des.crypt(a, "password", "a:"));
    // Only the first eight key bytes are significant.
    const short = try des.crypt(a, "password", "ab");
    defer a.free(short);
    const long = try des.crypt(a, "passwordEXTRA", "ab");
    defer a.free(long);
    try std.testing.expectEqualStrings(short, long);
}
