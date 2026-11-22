//! fuser — port of procps/fuser.c.
//!
//! In this sandbox the reference never finds a process holding the synthetic
//! paths used by the suite; the observable behaviour is the getopt parsing
//! followed by the stat error. The successful /proc/*/fd scan is implemented
//! too, so real files behave like the reference.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var i: usize = 1;
    var silent = false;
    var kill_found = false;
    var signo: c_int = 9; // SIGKILL
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        if (std.mem.eql(u8, tok, "--")) {
            i += 1;
            break;
        }
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                'm', '4', '6' => {},
                's' => silent = true,
                'k' => kill_found = true,
                else => {
                    const sig = c.getSignum(tok[j..]) orelse {
                        c.plainMsg("invalid option -- '{c}'", .{tok[j]});
                        c.usageDie(prog);
                    };
                    signo = sig;
                    break;
                },
            }
        }
    }
    if (i >= av.len) c.usageDie(prog);

    var errors: c_int = 0;
    while (i < av.len) : (i += 1) {
        const path = av[i];
        const z = c.zstr(a, path) catch return 1;
        defer a.free(z);
        const rc = linux.access(z.ptr, linux.F_OK);
        const e = linux.errno(rc);
        if (e != .SUCCESS) {
            c.errorMsg(@intFromEnum(e), "can't stat '{s}'", .{path});
            return 1;
        }
        // Enumerate open descriptors pointing at this exact path.
        const pids = c.listPids(a, "/proc") catch return 1;
        defer a.free(pids);
        var found = false;
        for (pids) |pid| {
            const dir_path = c.procPath(a, pid, "fd") catch continue;
            defer a.free(dir_path);
            const dz = c.zstr(a, dir_path) catch continue;
            defer a.free(dz);
            const fd = linux.open(dz.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
            if (linux.errno(fd) != .SUCCESS) continue;
            const fdi: linux.fd_t = @intCast(fd);
            defer _ = linux.close(fdi);
            var buf: [8192]u8 align(8) = undefined;
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
                if (fdname.len == 0 or !c.allDigits(fdname)) continue;
                const link_path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, fdname }) catch continue;
                defer a.free(link_path);
                var link_buf: [4096]u8 = undefined;
                const target = c.readLink(link_path, &link_buf) orelse continue;
                if (!std.mem.eql(u8, target, path)) continue;
                found = true;
                if (!silent) c.printfOut("{d} ", .{pid});
                if (kill_found) _ = linux.kill(pid, @enumFromInt(@as(u32, @bitCast(signo))));
            }
        }
        if (found and !silent) c.out("\n");
        if (!found) errors += 1;
    }
    return errors;
}
