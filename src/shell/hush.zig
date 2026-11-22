//! hush entry point. hush and ash share the interpreter core; they differ in
//! accepted command-line options and a few default option settings.

const std = @import("std");
const runner = @import("runner.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return runner.run(std.heap.page_allocator, argc, argv, .hush);
}
