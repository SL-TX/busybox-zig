//! util-linux applet implementations (system utilities).

const std = @import("std");
const linux = std.os.linux;

pub const init = struct {
    pub fn init() void {}
};

fn out(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const a = std.heap.page_allocator.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| a[i] = std.mem.span(argv[i]);
    return a;
}

fn zstr(a: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    const owned = try std.mem.concatWithSentinel(a, u8, &.{s}, 0);
    return owned.ptr;
}

fn readWholeFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const p = try zstr(a, path);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try result.appendSlice(a, buf[0..n]);
    }
    return result.toOwnedSlice(a);
}

pub fn mount_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const a = std.heap.page_allocator;
    if (args.len == 1) {
        const mounts = readWholeFile(a, "/proc/mounts") catch return 1;
        defer a.free(mounts);
        out(mounts);
        return 0;
    }
    var fstype: []const u8 = "";
    var options: []const u8 = "";
    var positional: [2][]const u8 = .{ "", "" };
    var count: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            i += 1;
            fstype = args[i];
        } else if (std.mem.eql(u8, arg, "-o") and i + 1 < args.len) {
            i += 1;
            options = args[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            // ignore other options
        } else if (count < 2) {
            positional[count] = arg;
            count += 1;
        }
    }
    if (count < 2) return 1;
    const dev = zstr(a, positional[0]) catch return 1;
    const dir = zstr(a, positional[1]) catch return 1;
    const type_z: ?[*:0]const u8 = if (fstype.len > 0) zstr(a, fstype) catch return 1 else null;
    var flags: u32 = 0;
    if (std.mem.indexOf(u8, options, "ro") != null) flags |= linux.MS.RDONLY;
    const data: usize = 0;
    const rc = linux.mount(dev, dir, type_z, flags, data);
    if (linux.errno(rc) != .SUCCESS) return 1;
    return 0;
}

pub fn umount_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    if (args.len < 2) return 1;
    const a = std.heap.page_allocator;
    const target = zstr(a, args[args.len - 1]) catch return 1;
    const rc = linux.umount2(target, 0);
    if (linux.errno(rc) != .SUCCESS) return 1;
    return 0;
}

pub fn dmesg_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    // SYSLOG action 10 = READ_ALL
    var buf: [65536]u8 = undefined;
    const rc = linux.syscall3(.syslog, 10, @intFromPtr(&buf), buf.len);
    if (linux.errno(rc) != .SUCCESS or rc > buf.len) {
        // Kernel ring buffer is often unreadable in containers; stay quiet.
        return 0;
    }
    out(buf[0..@intCast(rc)]);
    return 0;
}

pub fn blkid_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    const a = std.heap.page_allocator;
    const rc = linux.open("/dev/disk/by-uuid", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return 1;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    const name_off = @offsetOf(linux.dirent64, "name");
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + name_off <= n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const raw = buf[off + name_off ..][0 .. dent.reclen - name_off];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const name = raw[0..end];
            off += dent.reclen;
            if (name.len == 0 or name[0] == '.') continue;
            const uuid = a.dupe(u8, name) catch continue;
            defer a.free(uuid);
            out(uuid);
            out("\n");
        }
    }
    return 0;
}
