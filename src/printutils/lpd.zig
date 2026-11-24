//! printutils lpd — minimal line printer daemon protocol handler.
//! Reads LPD commands from stdin (a local socket/pty substitute), no real
//! printer or network service is used.

const std = @import("std");
const c = @import("common.zig");
const bb = c.bb;
const linux = c.linux;

fn readLine(allocator: std.mem.Allocator) ?[]u8 {
    const data = c.readAllFd(allocator, 0) catch return null;
    if (data.len == 0) return null;
    // xmalloc_reads reads one line; take everything up to and including \n.
    const nl = std.mem.indexOfScalar(u8, data, '\n');
    const end = if (nl) |p| p + 1 else data.len;
    var out = allocator.dupe(u8, data[0..end]) catch return null;
    if (nl == null) {
        out = allocator.realloc(out, end + 1) catch return out;
        out[end] = 0;
    }
    return out;
}

fn sane(buf: []u8) []const u8 {
    var w: usize = 0;
    for (buf) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
            buf[w] = ch;
            w += 1;
        }
    }
    return buf[0..w];
}

pub fn lpdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const allocator = std.heap.page_allocator;
    const args = c.argsFrom(allocator, argv, argc) catch return 1;
    defer allocator.free(args);
    bb.env.setProgramName(c.basename(args[0]));

    if (args.len > 1) {
        var zbuf: [4096:0]u8 = undefined;
        const p = c.z(args[1], &zbuf) catch return 1;
        const rc = linux.chdir(p.ptr);
        if (linux.errno(rc) != .SUCCESS) {
            bb.messages.errorMsg(@intCast(@intFromEnum(linux.errno(rc))), "can't change directory to '{s}'", .{args[1]});
            return 1;
        }
    }

    const line = readLine(allocator) orelse return 1;
    defer allocator.free(line);
    if (line.len == 0) return 1;
    if (line[0] != 2) {
        var b: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&b, "Command {x:0>2} is not supported\n", .{line[0]}) catch "";
        c.writeAll(1, msg);
        return 1;
    }
    var queue = line[1..];
    if (queue.len > 0 and queue[queue.len - 1] == '\n') queue = queue[0 .. queue.len - 1];
    const qbuf = allocator.dupe(u8, queue) catch return 1;
    defer allocator.free(qbuf);
    if (queue.len == 0 or sane(qbuf).len == 0) return 1;

    // Non-spooling mode: acknowledge, then EOF terminates successfully.
    c.writeAll(1, "\x00");
    return 0;
}
