const std = @import("std");
const sha512 = @import("libbb_zig").crypto.sha512;

test "sha512 abc matches RFC 6234" {
    var out: [64]u8 = undefined;
    sha512.hash("abc", &out);
    try std.testing.expectEqualStrings(
        "\xdd\xaf\x35\xa1\x93\x61\x7a\xba\xcc\x41\x73\x49\xae\x20\x41\x31" ++
            "\x12\xe6\xfa\x4e\x89\xa9\x7e\xa2\x0a\x9e\xee\xe6\x4b\x55\xd3\x9a" ++
            "\x21\x92\x99\x2a\x27\x4f\xc1\xa8\x36\xba\x3c\x23\xa3\xfe\xeb\xbd" ++
            "\x45\x4d\x44\x23\x64\x3c\xe8\x0e\x2a\x9a\xc9\x4f\xa5\x4c\xa4\x9f",
        &out,
    );
}

test "sha384 abc matches RFC 6234" {
    var out: [48]u8 = undefined;
    sha512.hash384("abc", &out);
    try std.testing.expectEqualStrings(
        "\xcb\x00\x75\x3f\x45\xa3\x5e\x8b\xb5\xa0\x3d\x69\x9a\xc6\x50\x07" ++
            "\x27\x2c\x32\xab\x0e\xde\xd1\x63\x1a\x8b\x60\x5a\x43\xff\x5b\xed" ++
            "\x80\x86\x07\x2b\xa1\xe7\xcc\x23\x58\xba\xec\xa1\x34\xc8\x25\xa7",
        &out,
    );
}

test "sha512 incremental matches one-shot" {
    var ctx = sha512.Context.init(.{});
    ctx.update("a");
    ctx.update("bc");
    var inc: [64]u8 = undefined;
    ctx.final(&inc);
    var one: [64]u8 = undefined;
    sha512.hash("abc", &one);
    try std.testing.expectEqualSlices(u8, &one, &inc);
}
