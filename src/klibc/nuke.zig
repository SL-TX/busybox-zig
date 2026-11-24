//! klibc nuke — alias to "rm -rf". Disabled in the default defconfig, but
//! implemented faithfully for completeness.

const std = @import("std");
const c = @import("common.zig");
const linux = c.linux;

fn removeTree(allocator: std.mem.Allocator, path: []const u8) void {
    var buf: [4096:0]u8 = undefined;
    const p = c.z(path, &buf) catch return;
    var dir = c.DirIter.open(path) orelse {
        _ = linux.unlink(p.ptr);
        return;
    };
    defer dir.close();
    while (dir.next()) |name| {
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name }) catch continue;
        defer allocator.free(child);
        const st = c.statPath(child, false);
        if (st != null and (st.?.mode & linux.S.IFMT) == linux.S.IFDIR) {
            removeTree(allocator, child);
        } else {
            var cb: [4096:0]u8 = undefined;
            if (c.z(child, &cb)) |zchild| {
                _ = linux.unlink(zchild.ptr);
                _ = linux.rmdir(zchild.ptr);
            } else |_| {}
        }
    }
    _ = linux.rmdir(p.ptr);
}

pub fn nukeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const allocator = std.heap.page_allocator;
    const args = c.argsFrom(allocator, argv, argc) catch return 0;
    defer allocator.free(args);
    for (args[1..]) |path| removeTree(allocator, path);
    return 0;
}
