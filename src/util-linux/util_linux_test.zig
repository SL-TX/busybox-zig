//! Unit tests for Task 10a round-2 regressions in the util-linux wave.
//! These exercise pure helpers with synthetic buffers so no real block device
//! or oversized sysfs name is required.

const std = @import("std");
const ul = @import("util_linux");

test "blkidDetect reads ext superblock at device offset 1024+0x38" {
    var buf: [2060]u8 = @splat(0);
    // Magic 0xEF53 at absolute 0x438 (1024 + 0x38).
    buf[1024 + 0x38] = 0x53;
    buf[1024 + 0x39] = 0xEF;
    // s_uuid at absolute 0x468 (1024 + 0x68): bytes 01..10.
    for (0..16) |i| buf[1024 + 0x68 + i] = @intCast(i + 1);

    const info = ul.blkidDetect(&buf) orelse return error.DetectionFailed;
    try std.testing.expectEqualStrings("ext4", info.kind);
    try std.testing.expect(info.has_uuid);
    try std.testing.expectEqualStrings("01020304-0506-0708-090a-0b0c0d0e0f10", &info.uuid);
}

test "blkidDetect tolerates a 1024-byte buffer (no panic, returns null)" {
    var short: [1024]u8 = @splat(0);
    // Even with magic bytes present at 0x38/0x39 the buffer is too small.
    short[0x38] = 0x53;
    short[0x39] = 0xEF;
    try std.testing.expect(ul.blkidDetect(short[0..1024]) == null);
}

test "blkidDetect tolerates truncated ext data with magic but no UUID" {
    var buf: [1024 + 0x38 + 2]u8 = @splat(0);
    buf[1024 + 0x38] = 0x53;
    buf[1024 + 0x39] = 0xEF;
    try std.testing.expect(ul.blkidDetect(&buf) == null);
}

test "blkidDetect detects ext at the exact minimum sized buffer" {
    var buf: [1024 + 0x68 + 16]u8 = @splat(0);
    buf[1024 + 0x38] = 0x53;
    buf[1024 + 0x39] = 0xEF;
    for (0..16) |i| buf[1024 + 0x68 + i] = @intCast(i + 1);
    const info = ul.blkidDetect(&buf) orelse return error.DetectionFailed;
    try std.testing.expectEqualStrings("ext4", info.kind);
    try std.testing.expectEqualStrings("01020304-0506-0708-090a-0b0c0d0e0f10", &info.uuid);
}

test "blkidDetect rejects magic at device offset zero (old bug)" {
    var buf: [2060]u8 = @splat(0);
    // The pre-fix code checked sb[0x38]/sb[0x39] on a buffer read from offset 0.
    buf[0x38] = 0x53;
    buf[0x39] = 0xEF;
    for (0..16) |i| buf[0x68 + i] = @intCast(i + 1);
    try std.testing.expect(ul.blkidDetect(&buf) == null);
}

test "blkidDetect recognises swap signature at 0x7fc" {
    var buf: [2060]u8 = @splat(0);
    @memcpy(buf[0x7fc .. 0x7fc + 10], "SWAPSPACE2");
    const info = ul.blkidDetect(&buf) orelse return error.DetectionFailed;
    try std.testing.expectEqualStrings("swap", info.kind);
    try std.testing.expect(!info.has_uuid);
}

test "padRight truncates an overlong device name instead of panicking" {
    var out: [15]u8 = undefined;
    ul.padRight(&out, "this-name-is-far-too-long-for-the-field", 15);
    try std.testing.expectEqualStrings("this-name-is-fa", &out);
}

test "padRight pads a short name and tolerates an undersized buffer" {
    var out: [15]u8 = undefined;
    ul.padRight(&out, "nvme0n1", 15);
    try std.testing.expectEqualStrings("nvme0n1        ", &out);

    var tiny: [4]u8 = .{ 'x', 'x', 'x', 'x' };
    ul.padRight(&tiny, "abcd", 15); // width > buffer: no writes, no panic
    try std.testing.expectEqualStrings("xxxx", &tiny);
}
