//! fakeidentd — fake ident/auth service (networking/isrv_identd.c).
//!
//! In inetd mode (-i) the request line is read from stdin and the fixed reply
//! is written to stdout, exactly like do_rd()/fdprintf() in the reference.

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");

pub fn fakeidentdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("fakeidentd", args, "fiwb:", &.{});
    const bind_addr = cu.optionValue(args, 1, args.len, 'b', null, "fiw");

    var user: []const u8 = "nobody";
    for (parsed.args) |a| { user = a; break; }

    // -i / -w inetd modes: one request on stdin, reply on stdout.
    if ((parsed.flags & 0x2) != 0 or (parsed.flags & 0x4) != 0) {
        var line: [256]u8 = undefined;
        const got = std.os.linux.read(0, &line, line.len - 1);
        const len: usize = if (std.os.linux.errno(got) == .SUCCESS) @intCast(got) else 0;
        var end: usize = 0;
        while (end < len and line[end] != '\r' and line[end] != '\n') : (end += 1) {}
        n.put("{s} : USERID : UNIX : {s}\r\n", .{ line[0..end], user });
        return 0;
    }

    _ = bind_addr;
    // Standalone mode binds the privileged ident port; without CAP_NET_BIND_SERVICE
    // the reference dies with "bind: Permission denied".
    const err = sc.bindTcp("0.0.0.0", 113);
    if (err != 0) {
        n.errorMsg(err, "bind", .{});
        return 1;
    }
    return 0;
}
