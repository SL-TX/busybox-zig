const std = @import("std");
const mod = @import("runit");

test "svlogd printable range excludes control characters" {
    try std.testing.expect(mod.isPrintable(' '));
    try std.testing.expect(mod.isPrintable('~'));
    try std.testing.expect(!mod.isPrintable('\t'));
    try std.testing.expect(!mod.isPrintable(0x80));
}
