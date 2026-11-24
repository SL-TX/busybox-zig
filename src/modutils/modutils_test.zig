//! Unit coverage for the metadata parser shared by depmod/modprobe.

const std = @import("std");
const mu = @import("modutils");

test "module metadata aliases and deps" {
    const image = "\x7fELF\x00alias=pci:v0000\x00alias=usb:1\x00" ++
        "depends=mod-b,mod-a\x00__ksymtab_my-sym\x00__ksymtab_gpl\x00";
    const info = mu.common.parseModule("kernel/x/foo.ko", image);
    try std.testing.expectEqualStrings("pci:v0000 usb:1 symbol:my_sym", info.aliases);
    try std.testing.expectEqualStrings("mod_b mod_a", info.deps);
}

test "depfile record layout" {
    var b: std.ArrayList(u8) = .empty;
    mu.common.writeDepRecord(&b, .{ .pathname = "a.ko", .aliases = "one two", .deps = "b c" });
    mu.common.writeDepRecord(&b, .{ .pathname = "d.ko", .aliases = "", .deps = "" });
    try std.testing.expectEqualStrings(
        "a.ko one two\nb c\n\nd.ko\n\n",
        b.items,
    );
}

test "filename2modname" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("some_module", mu.rmmod.filename2modname("some-module.ko", &buf));
    try std.testing.expectEqualStrings("foo", mu.rmmod.filename2modname("foo.ko", &buf));
}

test "alias glob matching" {
    try std.testing.expect(mu.common.fnmatch("pci:v*", "pci:v0000"));
    try std.testing.expect(!mu.common.fnmatch("pci:v*", "usb:v0000"));
    try std.testing.expect(mu.common.fnmatch("foo?", "foob"));
    try std.testing.expect(!mu.common.fnmatch("foo?", "foobar"));
}
