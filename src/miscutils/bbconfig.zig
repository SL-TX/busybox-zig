//! bbconfig — print the build configuration (reference miscutils/bbconfig.c).
//! The applet is disabled in both the reference and Zig defconfigs, so the
//! multicall binary reports "applet not found" for it. The implementation is
//! still provided (and wired in applets.zig) for configs that enable it.

const std = @import("std");
const c = @import("common.zig");

const lines = [_][]const u8{
    "CONFIG_HAVE_DOT_CONFIG=y",
    "CONFIG_DESKTOP=y",
    "CONFIG_EXTRA_COMPAT=n",
    "CONFIG_LONG_OPTS=y",
    "CONFIG_SHOW_USAGE=y",
    "CONFIG_FEATURE_VERBOSE_USAGE=y",
    "CONFIG_BUSYBOX=y",
    "# CONFIG_BBCONFIG is not set",
};

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    for (lines) |line| {
        c.out(line);
        c.out("\n");
    }
    return 0;
}
