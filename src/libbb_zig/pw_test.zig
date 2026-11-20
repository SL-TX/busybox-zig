const std = @import("std");
const pw = @import("libbb_zig").pw;

test "pw_encrypt_md5 matches the canonical $1$ vector" {
    const out = try pw.encryptMd5(std.testing.allocator, "password", "12345678");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("$1$12345678$o2n/JiO/h5VviOInWJ4OQ/", out);
}

test "pw_encrypt_md5 truncates long salts to 8 characters" {
    const out = try pw.encryptMd5(std.testing.allocator, "password", "12345678901234");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "$1$12345678$"));
}
