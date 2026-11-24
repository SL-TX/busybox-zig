const std = @import("std");
const sha1 = @import("libbb_zig").crypto.sha1;

test "sha1 abc matches RFC 3174" {
    var out: [20]u8 = undefined;
    sha1.hash("abc", &out);
    try std.testing.expectEqualStrings("\xa9\x99\x3e\x36\x47\x06\x81\x6a\xba\x3e\x25\x71\x78\x50\xc2\x6c\x9c\xd0\xd8\x9d", &out);
}

test "sha1 empty message" {
    var out: [20]u8 = undefined;
    sha1.hash("", &out);
    try std.testing.expectEqualStrings("\xda\x39\xa3\xee\x5e\x6b\x4b\x0d\x32\x55\xbf\xef\x95\x60\x18\x90\xaf\xd8\x07\x09", &out);
}

test "sha1 incremental matches one-shot" {
    var ctx = sha1.Context.init(.{});
    ctx.update("a");
    ctx.update("bc");
    var inc: [20]u8 = undefined;
    ctx.final(&inc);
    var one: [20]u8 = undefined;
    sha1.hash("abc", &one);
    try std.testing.expectEqualSlices(u8, &one, &inc);
}
