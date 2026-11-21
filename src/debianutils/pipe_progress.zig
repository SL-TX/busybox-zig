//! debianutils pipe_progress — copy stdin to stdout, printing a dot to stderr
//! once per second of activity.

const std = @import("std");
const c = @import("common.zig");
const linux = c.linux;

pub fn pipeProgressMain(_: c_int, _: [*][*:0]const u8) c_int {
    var last = c.nowSeconds();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) break;
        if (n == 0) break;
        const now = c.nowSeconds();
        if (now != last) {
            last = now;
            c.writeAll(2, ".");
        }
        c.writeAll(1, buf[0..n]);
    }
    c.writeAll(2, "\n");
    return 0;
}
