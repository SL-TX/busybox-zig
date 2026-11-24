const std = @import("std");
const securetty = @import("libbb_zig").login.securetty;

test "securetty shortName strips /dev/" {
    try std.testing.expectEqualStrings("tty1", securetty.shortName("/dev/tty1"));
    try std.testing.expectEqualStrings("pts/0", securetty.shortName("pts/0"));
}

test "securetty matches exact tokens and ignores comments" {
    const data = "vc/1\n# ttyS0 disabled\ntty1\n";
    try std.testing.expect(securetty.isSecure(data, "tty1"));
    try std.testing.expect(securetty.isSecure(data, "/dev/tty1"));
    try std.testing.expect(securetty.isSecure(data, "vc/1"));
    try std.testing.expect(!securetty.isSecure(data, "ttyS0"));
    try std.testing.expect(!securetty.isSecure(data, "tty12"));
}

test "securetty empty file means all ttys are secure" {
    try std.testing.expect(securetty.isSecure("", "tty7"));
    try std.testing.expect(securetty.isSecure("\n# nothing\n", "pts/3"));
}
