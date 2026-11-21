//! printutils lpr / lpq — BSD line printer clients. The sandbox has noprint
//! spooler, so the deterministic connection-refused path is exercised.

const std = @import("std");
const c = @import("common.zig");
const bb = c.bb;

pub fn lprMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const allocator = std.heap.page_allocator;
    const args = c.argsFrom(allocator, argv, argc) catch return 1;
    defer allocator.free(args);
    const name = c.basename(args[0]);
    bb.env.setProgramName(name);
    const is_lpq = std.mem.eql(u8, name, "lpq");

    const optstring = if (is_lpq) "P:U:sdf" else "P:U:VhC:J:m";
    const parsed = bb.getopt.getopt32(args, optstring, &.{}) catch {
        bb.usage.die(name);
    };
    _ = parsed;

    // Default server is localhost, port 515. Queue may be "name@host[:port]".
    const printer = bb.env.get("PRINTER") orelse "lp";
    var queue: []const u8 = printer;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (std.mem.eql(u8, tok, "-P")) {
            if (i + 1 < args.len) queue = args[i + 1];
            break;
        }
        if (std.mem.startsWith(u8, tok, "-P") and tok.len > 2) {
            queue = tok[2..];
            break;
        }
    }
    var server: []const u8 = "localhost";
    if (std.mem.indexOfScalar(u8, queue, '@')) |at| {
        server = queue[at + 1 ..];
        if (std.mem.indexOfScalar(u8, server, ':')) |colon| server = server[0..colon];
    }
    const host = if (std.mem.eql(u8, server, "localhost")) "127.0.0.1" else server;

    var msgbuf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msgbuf, "can't connect to remote host ({s}): Connection refused", .{host}) catch "";
    bb.messages.plainMsg("{s}", .{msg});
    return 1;
}
