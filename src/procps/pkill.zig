//! pkill — thin entry point for the shared procps/pgrep.c implementation.

const p = @import("pgrep.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return p.pgrepMain(true, argc, argv);
}
