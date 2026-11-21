//! Unit coverage for the pure helpers behind the e2fsprogs applets.

const std = @import("std");
const ef = @import("e2fsprogs");

test "e2fs flags short rendering" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("--------------------", ef.flags.render(0, &b));
    try std.testing.expectEqualStrings("----ia--------------", ef.flags.render(0x30, &b));
}

test "e2fs flags long rendering" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("---", ef.flags.renderLong(0, &b));
    try std.testing.expectEqualStrings("Immutable, Append_Only", ef.flags.renderLong(0x30, &b));
}

test "chattr accepted letters map to distinct bits" {
    try std.testing.expectEqual(@as(?u32, 0x10), ef.chattr.State.getFlag('i'));
    try std.testing.expectEqual(@as(?u32, null), ef.chattr.State.getFlag('s'));
    try std.testing.expectEqual(@as(?u32, null), ef.chattr.State.getFlag('Z'));
    var seen: u32 = 0;
    for (ef.chattr.letters) |l| {
        const v = ef.chattr.State.getFlag(l).?;
        try std.testing.expect(seen & v == 0);
        seen |= v;
    }
    try std.testing.expect(@popCount(seen) == 19);
}

test "tune2fs superblock mangling" {
    var sb: [1024]u8 = std.mem.zeroes([1024]u8);
    ef.tune2fs.mangleSuperblock(&sb, .{
        .label = "myvol",
        .max_mnt = 0,
        .interval_days = 2,
        .mount_count = 7,
    });
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, sb[56..58], .little));
    try std.testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, sb[58..60], .little));
    try std.testing.expectEqualStrings("myvol", sb[120..125]);
    try std.testing.expectEqual(@as(u32, 2 * 24 * 60 * 60), std.mem.readInt(u32, sb[72..76], .little));
}
