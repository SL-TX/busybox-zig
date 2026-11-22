//! cttyhack — give a program a controlling tty if possible.

const std = @import("std");
const linux = std.os.linux;

fn errStr(e: linux.E) []const u8 {
    return switch (e) {
        .ACCES => "Permission denied",
        .NOENT => "No such file or directory",
        .NODEV => "No such device",
        .INVAL => "Invalid argument",
        .NXIO => "No such device or address",
        .BUSY => "Device or resource busy",
        else => "Input/output error",
    };
}

fn writeAll(fd: i32, s: []const u8) void {
    if (s.len != 0) _ = linux.write(fd, s.ptr, s.len);
}

fn readSmall(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = std.mem.concatWithSentinel(a, u8, &.{path}, 0) catch return null;
    defer a.free(z);
    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var data: std.ArrayList(u8) = .empty;
    var buf: [256]u8 = undefined;
    while (true) {
        const n = linux.read(@intCast(fd), &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        data.appendSlice(a, buf[0..n]) catch return null;
    }
    return data.toOwnedSlice(a) catch null;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    var fd: i32 = -1;
    var console: []const u8 = "/dev/tty";

    const ttyz = std.mem.concatWithSentinel(a, u8, &.{"/dev/tty"}, 0) catch return 1;
    const rc = linux.open(ttyz.ptr, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) == .SUCCESS) {
        fd = @intCast(rc);
    } else {
        console = "";
        if (readSmall(a, "/sys/class/tty/console/active")) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len != 0) {
                var token = trimmed;
                if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |p| token = trimmed[p + 1 ..];
                console = std.fmt.allocPrint(a, "/dev/{s}", .{token}) catch "";
            }
        }
        if (console.len == 0) {
            // VT_GETSTATE on stdin
            const VtStat = extern struct { v_active: u16, v_signal: u16, v_state: u16 };
            var vt: VtStat = undefined;
            if (linux.errno(linux.ioctl(0, 0x5603, @intFromPtr(&vt))) == .SUCCESS) {
                console = std.fmt.allocPrint(a, "/dev/tty{d}", .{vt.v_active}) catch "";
            }
        }
    }

    const nargs: usize = @intCast(argc);
    if (nargs <= 1) {
        if (console.len == 0) return 1;
        writeAll(1, console);
        writeAll(1, "\n");
        return 0;
    }

    if (fd < 0) {
        const z = std.mem.concatWithSentinel(a, u8, &.{console}, 0) catch return 1;
        const opened = linux.open(z.ptr, .{ .ACCMODE = .RDWR }, 0);
        const err = linux.errno(opened);
        if (err != .SUCCESS) {
            var b: [512]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "cttyhack: can't open '{s}': {s}\n", .{ console, errStr(err) }) catch "";
            writeAll(2, m);
        } else {
            fd = @intCast(opened);
        }
    }
    if (fd >= 0) {
        _ = linux.dup2(fd, 0);
        _ = linux.dup2(fd, 1);
        _ = linux.dup2(fd, 2);
        while (fd > 2) {
            _ = linux.close(fd);
            fd -= 1;
        }
        // TIOCSCTTY — best effort.
        _ = linux.ioctl(0, 0x540e, 1);
    }

    const prog = std.mem.span(argv[1]);
    const path = findProgram(a, prog) orelse prog;
    const argz = a.allocSentinel(?[*:0]const u8, nargs - 1, null) catch return 127;
    for (1..nargs) |k| argz[k - 1] = argv[k];
    const pz = std.mem.concatWithSentinel(a, u8, &.{path}, 0) catch return 127;
    var envp: [256:null]?[*:0]const u8 = undefined;
    var envn: usize = 0;
    const ez = std.mem.concatWithSentinel(a, u8, &.{"/proc/self/environ"}, 0) catch return 127;
    const efd = linux.open(ez.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(efd) == .SUCCESS) {
        var data: std.ArrayList(u8) = .empty;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = linux.read(@intCast(efd), &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            data.appendSlice(a, buf[0..n]) catch break;
        }
        _ = linux.close(@intCast(efd));
        var it = std.mem.splitScalar(u8, data.items, 0);
        while (it.next()) |entry| {
            if (entry.len == 0 or envn >= envp.len - 1) continue;
            envp[envn] = (std.mem.concatWithSentinel(a, u8, &.{entry}, 0) catch return 127).ptr;
            envn += 1;
        }
    }
    envp[envn] = null;
    _ = linux.execve(pz.ptr, argz.ptr, &envp);
    var b: [512]u8 = undefined;
    const m = std.fmt.bufPrint(&b, "cttyhack: can't execute '{s}': No such file or directory\n", .{prog}) catch "";
    writeAll(2, m);
    return 127;
}

fn findProgram(a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    var path: []const u8 = "/bin:/usr/bin";
    const ez = std.mem.concatWithSentinel(a, u8, &.{"/proc/self/environ"}, 0) catch return null;
    const fd = linux.open(ez.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) == .SUCCESS) {
        var data: std.ArrayList(u8) = .empty;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = linux.read(@intCast(fd), &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            data.appendSlice(a, buf[0..n]) catch break;
        }
        _ = linux.close(@intCast(fd));
        var it = std.mem.splitScalar(u8, data.items, 0);
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry, "PATH=")) path = entry[5..];
        }
    }
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const cand = std.fmt.allocPrint(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch return null;
        const z = std.mem.concatWithSentinel(a, u8, &.{cand}, 0) catch return null;
        const ok = linux.errno(linux.access(z.ptr, linux.X_OK)) == .SUCCESS;
        if (ok) return cand;
    }
    return null;
}
