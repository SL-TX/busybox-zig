const std = @import("std");
const md5 = @import("libbb_zig").crypto.md5;

test "md5 abc matches RFC 1321" {
    var out: [16]u8 = undefined;
    md5.hash("abc", &out);
    try std.testing.expectEqualStrings("\x90\x01\x50\x98\x3c\xd2\x4f\xb0\xd6\x96\x3f\x7d\x28\xe1\x7f\x72", &out);
}

test "md5 empty message" {
    var out: [16]u8 = undefined;
    md5.hash("", &out);
    try std.testing.expectEqualStrings("\xd4\x1d\x8c\xd9\x8f\x00\xb2\x04\xe9\x80\x09\x98\xec\xf8\x42\x7e", &out);
}

test "md5 incremental matches one-shot" {
    var ctx = md5.Context.init(.{});
    ctx.update("a");
    ctx.update("bc");
    var inc: [16]u8 = undefined;
    ctx.final(&inc);
    var one: [16]u8 = undefined;
    md5.hash("abc", &one);
    try std.testing.expectEqualSlices(u8, &one, &inc);
}
