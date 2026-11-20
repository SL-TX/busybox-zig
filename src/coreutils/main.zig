//! coreutils applet implementations (first working applets).

const std = @import("std");
const linux = std.os.linux;

pub const init = struct {
    pub fn init() void {}
};

const stdout: linux.fd_t = 1;
const stdin: linux.fd_t = 0;

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return;
        done += n;
    }
}

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const out = std.heap.page_allocator.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

pub fn renderEcho(a: std.mem.Allocator, args: []const []const u8, no_nl: bool, escapes: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (args, 0..) |arg, i| {
        if (i != 0) try out.append(a, ' ');
        if (escapes) {
            var j: usize = 0;
            while (j < arg.len) {
                if (arg[j] == '\\' and j + 1 < arg.len) {
                    j += 1;
                    switch (arg[j]) {
                        'n' => try out.append(a, '\n'),
                        't' => try out.append(a, '\t'),
                        'r' => try out.append(a, '\r'),
                        '\\' => try out.append(a, '\\'),
                        else => {
                            try out.append(a, '\\');
                            try out.append(a, arg[j]);
                        },
                    }
                } else try out.append(a, arg[j]);
                j += 1;
            }
        } else try out.appendSlice(a, arg);
    }
    if (!no_nl) try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

pub fn renderPrintf(a: std.mem.Allocator, fmt: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var ai: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '\\' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                'n' => try out.append(a, '\n'),
                't' => try out.append(a, '\t'),
                'r' => try out.append(a, '\r'),
                '\\' => try out.append(a, '\\'),
                else => try out.append(a, fmt[i]),
            }
            i += 1;
            continue;
        }
        if (fmt[i] == '%' and i + 1 < fmt.len and ai < args.len) {
            i += 1;
            switch (fmt[i]) {
                's' => try out.appendSlice(a, args[ai]),
                'd' => {
                    const n = std.fmt.parseInt(i64, args[ai], 10) catch 0;
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "";
                    try out.appendSlice(a, s);
                },
                '%' => try out.append(a, '%'),
                else => {
                    try out.append(a, '%');
                    try out.append(a, fmt[i]);
                },
            }
            ai += 1;
            i += 1;
            continue;
        }
        try out.append(a, fmt[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

// --- applets ----------------------------------------------------------------

pub fn echo_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var no_nl = false;
    var escapes = false;
    var first: usize = 1;
    while (first < args.len and args[first].len > 1 and args[first][0] == '-') {
        var valid = true;
        for (args[first][1..]) |c| switch (c) {
            'n' => no_nl = true,
            'e' => escapes = true,
            else => valid = false,
        };
        if (!valid) break;
        first += 1;
    }
    const out = renderEcho(std.heap.page_allocator, args[first..], no_nl, escapes) catch return 1;
    defer std.heap.page_allocator.free(out);
    writeAll(stdout, out);
    return 0;
}

fn catFd(fd: linux.fd_t) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) return;
        writeAll(stdout, buf[0..n]);
    }
}

pub fn cat_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    if (args.len <= 1) {
        catFd(stdin);
        return 0;
    }
    for (args[1..]) |name| {
        if (std.mem.eql(u8, name, "-")) {
            catFd(stdin);
            continue;
        }
        var z: [4096:0]u8 = undefined;
        if (name.len >= z.len) return 1;
        @memcpy(z[0..name.len], name);
        z[name.len] = 0;
        const rc = linux.open(@ptrCast(&z), .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(rc) != .SUCCESS) return 1;
        const fd: linux.fd_t = @intCast(rc);
        catFd(fd);
        _ = linux.close(fd);
    }
    return 0;
}

pub fn ls_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var path: []const u8 = ".";
    var show_all = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-a")) show_all = true else if (arg.len > 0 and arg[0] != '-') path = arg;
    }
    var z: [4096:0]u8 = undefined;
    if (path.len >= z.len) return 1;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = linux.open(@ptrCast(&z), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return 1;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var buf: [16384]u8 align(8) = undefined;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.heap.page_allocator);
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off + @sizeOf(linux.dirent64) <= n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const name_len = dent.reclen - @sizeOf(linux.dirent64);
            const name = buf[off + @sizeOf(linux.dirent64) ..][0..name_len];
            const end = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
            const nm = name[0..end];
            if (nm.len > 0 and !std.mem.eql(u8, nm, ".") and !std.mem.eql(u8, nm, "..") and (show_all or nm[0] != '.')) {
                names.append(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, nm) catch break) catch break;
            }
            off += dent.reclen;
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    for (names.items) |nm| {
        writeAll(stdout, nm);
        writeAll(stdout, "\n");
    }
    return 0;
}

pub fn printf_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    if (args.len < 2) return 0;
    const out = renderPrintf(std.heap.page_allocator, args[1], args[2..]) catch return 1;
    defer std.heap.page_allocator.free(out);
    writeAll(stdout, out);
    return 0;
}

pub fn true_main(_: c_int, _: [*][*:0]const u8) c_int {
    return 0;
}

pub fn false_main(_: c_int, _: [*][*:0]const u8) c_int {
    return 1;
}
