const std = @import("std");
const crc32 = @import("libbb_zig").crypto.crc32;

test "crc32 check value for 123456789" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32.checksum("123456789"));
}

test "crc32 empty" {
    try std.testing.expectEqual(@as(u32, 0), crc32.checksum(""));
}

test "crc32 incremental matches one-shot" {
    var state = crc32.init();
    state = crc32.update(state, "1234");
    state = crc32.update(state, "56789");
    try std.testing.expectEqual(crc32.checksum("123456789"), crc32.final(state));
}
