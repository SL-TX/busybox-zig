const std = @import("std");
const h = @import("hash.zig");

const sha256_abc = "\xba\x78\x16\xbf\x8f\x01\xcf\xea\x41\x41\x40\xde\x5d\xae\x22\x23\xb0\x03\x61\xa3\x96\x17\x7a\x9c\xb4\x10\xff\x61\xf2\x00\x15\xad";
const md5_abc = "\x90\x01\x50\x98\x3c\xd2\x4f\xb0\xd6\x96\x3f\x7d\x28\xe1\x7f\x72";

test "sha256 of abc matches RFC 6234" {
    var out: [32]u8 = undefined;
    h.sha256("abc", &out);
    try std.testing.expectEqualSlices(u8, sha256_abc, &out);
}

test "sha256 incremental matches one-shot" {
    var ctx = h.sha256_init();
    ctx.update("a");
    ctx.update("bc");
    var inc: [32]u8 = undefined;
    ctx.final(&inc);
    var one: [32]u8 = undefined;
    h.sha256("abc", &one);
    try std.testing.expectEqualSlices(u8, &one, &inc);
}

test "md5 of abc matches RFC 1321" {
    var out: [16]u8 = undefined;
    h.md5("abc", &out);
    try std.testing.expectEqualSlices(u8, md5_abc, &out);
}

test "crc32 of 123456789 matches check value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), h.crc32("123456789"));
}
