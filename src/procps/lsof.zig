//! lsof — port of procps/lsof.c: print PID, exe and each open fd link.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    const a = std.heap.page_allocator;
    const pids = c.listPids(a, "/proc") catch return 0;
    defer a.free(pids);
    const self = linux.getpid();
    for (pids) |pid| {
        if (pid == self) continue;
        const exe_path = c.procPath(a, pid, "exe") catch continue;
        defer a.free(exe_path);
        var exe_buf: [4096]u8 = undefined;
        const exe = c.readLink(exe_path, &exe_buf) orelse continue;

        const dir_path = c.procPath(a, pid, "fd") catch continue;
        defer a.free(dir_path);
        const dz = c.zstr(a, dir_path) catch continue;
        defer a.free(dz);
        const fd = linux.open(dz.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(fd) != .SUCCESS) continue;
        const fdi: linux.fd_t = @intCast(fd);
        defer _ = linux.close(fdi);
        var buf: [32768]u8 align(8) = undefined;
        const noff = @offsetOf(linux.dirent64, "name");
        const n = linux.getdents64(fdi, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) continue;
        var off: usize = 0;
        while (off + noff <= n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const raw = buf[off + noff ..][0 .. dent.reclen - noff];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const fdname = raw[0..end];
            off += dent.reclen;
            if (fdname.len == 0 or fdname[0] == '.') continue;
            const link_path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, fdname }) catch continue;
            defer a.free(link_path);
            var link_buf: [4096]u8 = undefined;
            if (c.readLink(link_path, &link_buf)) |target| {
                c.printfOut("{d}\t{s}\t{s}\t{s}\n", .{ pid, exe, fdname, target });
            }
        }
    }
    return 0;
}
