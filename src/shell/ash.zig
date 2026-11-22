//! ash / sh entry point.

const std = @import("std");
const runner = @import("runner.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return runner.run(std.heap.page_allocator, argc, argv, .ash);
}
