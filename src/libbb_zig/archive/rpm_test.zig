//! Tests for the RPM lead/header/payload helper.

const std = @import("std");
const rpm = @import("libbb_zig").archive.rpm;

test "build and parse a minimal RPM" {
    const payload = "07070100000000000041ed0000000000000000000000010000000000000000";
    const file = try rpm.build(std.testing.allocator, .{
        .name = "busybox-parity",
        .version = "1.39.0",
        .release = "1",
        .arch = "x86_64",
        .payload = payload,
    });
    defer std.testing.allocator.free(file);
    const parsed = try rpm.parse(file);
    try std.testing.expectEqual(@as(u16, 3), parsed.lead.major);
    try std.testing.expectEqualStrings("busybox-parity", rpm.getString(parsed.header, .name).?);
    try std.testing.expectEqualStrings("1.39.0", rpm.getString(parsed.header, .version).?);
    try std.testing.expectEqualStrings("1", rpm.getString(parsed.header, .release).?);
    try std.testing.expectEqualStrings("x86_64", rpm.getString(parsed.header, .arch).?);
    try std.testing.expectEqualStrings("cpio", rpm.getString(parsed.header, .payload_format).?);
    try std.testing.expectEqualSlices(u8, payload, parsed.payload);
}

test "RPM rejects corrupt lead and truncated headers" {
    const file = try rpm.build(std.testing.allocator, .{
        .name = "p",
        .version = "1",
        .release = "1",
        .arch = "noarch",
        .payload = "abc",
    });
    defer std.testing.allocator.free(file);
    const bad = try std.testing.allocator.dupe(u8, file);
    defer std.testing.allocator.free(bad);
    bad[0] = 0;
    try std.testing.expectError(error.BadMagic, rpm.parse(bad));
    try std.testing.expectError(error.Truncated, rpm.parse(file[0..50]));
    try std.testing.expectError(error.Truncated, rpm.parse(file[0 .. file.len - 4]));
}

test "RPM payload can be gzip-compressed" {
    const gzip = @import("libbb_zig").compression.gzip;
    const cpio_data = "07070100000000000041ed000000000000000000000001";
    const compressed = try gzip.compress(std.testing.allocator, cpio_data, .gzip);
    defer std.testing.allocator.free(compressed);
    const file = try rpm.build(std.testing.allocator, .{
        .name = "z",
        .version = "2",
        .release = "3",
        .arch = "i386",
        .payload = compressed,
        .payload_compressor = "gzip",
    });
    defer std.testing.allocator.free(file);
    const parsed = try rpm.parse(file);
    try std.testing.expectEqualStrings("gzip", rpm.getString(parsed.header, .payload_compressor).?);
    const out = try parsed.payloadData(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(cpio_data, out);
}
