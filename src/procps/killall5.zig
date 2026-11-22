//! killall5 — thin entry point for the shared procps/kill.c implementation.

const k = @import("kill.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return k.killMain(.killall5, argc, argv);
}
