//! loginutils applet implementations.

const std = @import("std");
const bb = @import("libbb_zig");

pub const init = struct {
    pub fn init() void {}
};

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const out = std.heap.page_allocator.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

pub fn cryptpw_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var salt: []const u8 = "12345678";
    var password: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-S")) {
            i += 1;
            if (i < args.len) salt = args[i];
        } else if (std.mem.startsWith(u8, arg, "-a")) {
            // only md5 is supported for now
        } else if (arg.len > 0 and arg[0] == '-') {
            // ignore
        } else if (password.len == 0) {
            password = arg;
        }
    }
    if (password.len == 0) return 1;
    const hash = bb.pw.encryptMd5(std.heap.page_allocator, password, salt) catch return 1;
    defer std.heap.page_allocator.free(hash);
    _ = std.os.linux.write(1, hash.ptr, hash.len);
    _ = std.os.linux.write(1, "\n", 1);
    return 0;
}
