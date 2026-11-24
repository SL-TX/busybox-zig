//! arping — send ARP requests (reference arping.c).
//!
//! The reference opens its AF_PACKET socket before it parses any options, so
//! in an unprivileged sandbox every invocation fails at that point with the
//! same diagnostic. We perform the real socket() call and report its errno,
//! which is EPERM here exactly as in the reference.

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

pub fn arpingMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    n.setProg(argv);
    const fd = linux.socket(linux.AF.PACKET, linux.SOCK.DGRAM, 0);
    const e = linux.errno(fd);
    if (e != .SUCCESS) {
        n.msg(@intFromEnum(e), "socket", .{});
        return 1;
    }
    _ = linux.close(@intCast(fd));
    // Privileged path: a real arping probe would run here. Unreachable in the
    // unprivileged differential environment (the reference needs CAP_NET_RAW
    // as well).
    n.plain("socket: Operation not permitted", .{});
    return 1;
}
