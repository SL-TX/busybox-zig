//! coreutils applet implementations (first working applets).

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const simple = @import("simple.zig");
pub const sed = @import("sed.zig");
pub const awk = @import("awk.zig");

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
    return simple.echoMain(argc, argv);
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
    return simple.catMain(argc, argv);
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
        while (off + @offsetOf(linux.dirent64, "name") <= n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            if (dent.reclen == 0) break;
            const name_len = dent.reclen - @offsetOf(linux.dirent64, "name");
            const name = buf[off + @offsetOf(linux.dirent64, "name") ..][0..name_len];
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
    return simple.printfMain(argc, argv);
}

// --- file operations --------------------------------------------------------

fn toZ(path: []const u8, buf: *[4096:0]u8) ![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

pub fn copyFile(src: []const u8, dst: []const u8) !void {
    var a: [4096:0]u8 = undefined;
    var b: [4096:0]u8 = undefined;
    const s = try toZ(src, &a);
    const d = try toZ(dst, &b);
    const in_fd: linux.fd_t = @intCast(linux.open(s, .{ .ACCMODE = .RDONLY }, 0));
    if (linux.errno(@as(usize, @intCast(in_fd))) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(in_fd);
    const out_fd: linux.fd_t = @intCast(linux.open(d, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644));
    if (linux.errno(@as(usize, @intCast(out_fd))) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(out_fd);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(in_fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) off += linux.write(out_fd, buf[off..].ptr, n - off);
    }
}

pub fn mkdirP(path: []const u8) !void {
    var buf: [4096:0]u8 = undefined;
    const full = try toZ(path, &buf);
    _ = full;
    for (path, 0..) |c, i| {
        if (c != '/' or i == 0) continue;
        buf[i] = 0;
        const rc = linux.mkdir(@ptrCast(&buf), 0o755);
        const e = linux.errno(rc);
        if (e != .SUCCESS and e != .EXIST) return error.MkdirFailed;
        buf[i] = '/';
    }
    const rc = linux.mkdir(@ptrCast(&buf), 0o755);
    const e = linux.errno(rc);
    if (e != .SUCCESS and e != .EXIST) return error.MkdirFailed;
}

pub fn pathIsDir(path: []const u8) bool {
    var buf: [4096:0]u8 = undefined;
    const p = toZ(path, &buf) catch return false;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

pub fn renamePath(src: []const u8, dst: []const u8) !void {
    var a: [4096:0]u8 = undefined;
    var b: [4096:0]u8 = undefined;
    const s = try toZ(src, &a);
    const d = try toZ(dst, &b);
    const rc = linux.rename(s, d);
    if (linux.errno(rc) != .SUCCESS) return error.RenameFailed;
}

pub fn removePath(path: []const u8) !void {
    var buf: [4096:0]u8 = undefined;
    const p = try toZ(path, &buf);
    var rc = linux.unlink(p);
    if (linux.errno(rc) == .SUCCESS) return;
    rc = linux.rmdir(p);
    if (linux.errno(rc) != .SUCCESS) return error.RemoveFailed;
}

// --- more applets -----------------------------------------------------------

pub fn cp_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var recursive = false;
    var first: usize = 1;
    while (first < args.len and args[first].len > 0 and args[first][0] == '-') {
        if (std.mem.indexOfScalar(u8, args[first], 'r') != null) recursive = true;
        first += 1;
    }
    if (first + 1 >= args.len) return 1;
    const dst = args[args.len - 1];
    for (args[first .. args.len - 1]) |src| {
        const target = if (pathIsDir(dst))
            std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dst, std.fs.path.basename(src) }) catch return 1
        else
            dst;
        if (recursive and pathIsDir(src)) {
            copyDirRecursive(std.heap.page_allocator, src, target) catch return 1;
        } else {
            copyFile(src, target) catch return 1;
        }
    }
    return 0;
}

pub fn mv_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var first: usize = 1;
    while (first < args.len and args[first].len > 0 and args[first][0] == '-') first += 1;
    if (first + 1 >= args.len) return 1;
    const dst = args[args.len - 1];
    for (args[first .. args.len - 1]) |src| {
        const target = if (pathIsDir(dst))
            std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dst, std.fs.path.basename(src) }) catch return 1
        else
            dst;
        renamePath(src, target) catch {
            copyFile(src, target) catch return 1;
            removePath(src) catch return 1;
        };
    }
    return 0;
}

pub fn rm_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var recursive = false;
    var first: usize = 1;
    while (first < args.len and args[first].len > 0 and args[first][0] == '-') {
        if (std.mem.indexOfScalar(u8, args[first], 'r') != null or std.mem.indexOfScalar(u8, args[first], 'R') != null) recursive = true;
        first += 1;
    }
    if (first >= args.len) return 1;
    for (args[first..]) |path| {
        if (recursive and pathIsDir(path)) {
            removeRecursive(std.heap.page_allocator, path) catch return 1;
        } else {
            removePath(path) catch return 1;
        }
    }
    return 0;
}

pub fn mkdir_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return simple.mkdirMain(argc, argv);
}

pub fn touch_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var first: usize = 1;
    while (first < args.len and args[first].len > 0 and args[first][0] == '-') first += 1;
    if (first >= args.len) return 1;
    for (args[first..]) |path| {
        var buf: [4096:0]u8 = undefined;
        const p = toZ(path, &buf) catch return 1;
        const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        if (linux.errno(rc) != .SUCCESS) return 1;
        _ = linux.close(@intCast(rc));
    }
    return 0;
}

// --- line-oriented text helpers --------------------------------------------

pub const Counts = struct { lines: usize = 0, words: usize = 0, bytes: usize = 0 };

fn lineSlices(a: std.mem.Allocator, data: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(a);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break; // trailing newline
        try lines.append(a, line);
    }
    return lines.toOwnedSlice(a);
}

fn joinLines(a: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (lines) |line| {
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

pub fn headLines(data: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    var seen: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            seen += 1;
            if (seen == n) return data[0 .. i + 1];
        }
    }
    return data;
}

pub fn tailLines(data: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    var total: usize = 0;
    for (data) |c| if (c == '\n') { total += 1; };
    if (total <= n) return data;
    var seen: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            seen += 1;
            if (seen == total - n) return data[i + 1 ..];
        }
    }
    return data;
}

pub fn wordCount(data: []const u8) Counts {
    var c = Counts{ .bytes = data.len };
    var in_word = false;
    for (data) |ch| {
        if (ch == '\n') c.lines += 1;
        const ws = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
        if (!ws and !in_word) c.words += 1;
        in_word = !ws;
    }
    return c;
}

fn lessLine(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
fn greaterLine(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .gt;
}

pub fn sortLines(a: std.mem.Allocator, data: []const u8, reverse: bool, unique: bool) ![]u8 {
    const lines = try lineSlices(a, data);
    defer a.free(lines);
    if (reverse) std.mem.sort([]const u8, lines, {}, greaterLine) else std.mem.sort([]const u8, lines, {}, lessLine);
    if (unique) {
        var out: std.ArrayList([]const u8) = .empty;
        defer out.deinit(a);
        for (lines) |line| {
            if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], line)) continue;
            try out.append(a, line);
        }
        return joinLines(a, out.items);
    }
    return joinLines(a, lines);
}

pub fn uniqLines(a: std.mem.Allocator, data: []const u8) ![]u8 {
    const lines = try lineSlices(a, data);
    defer a.free(lines);
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    for (lines) |line| {
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], line)) continue;
        try out.append(a, line);
    }
    return joinLines(a, out.items);
}

pub fn cutFields(a: std.mem.Allocator, data: []const u8, delim: u8, field: usize) ![]u8 {
    const lines = try lineSlices(a, data);
    defer a.free(lines);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (lines) |line| {
        var it = std.mem.splitScalar(u8, line, delim);
        var idx: usize = 1;
        while (it.next()) |part| : (idx += 1) {
            if (idx == field) {
                try out.appendSlice(a, part);
                break;
            }
        }
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

// --- more applets -----------------------------------------------------------

fn readInput(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-") or path.len == 0) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = linux.read(stdin, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS) break;
            if (n == 0) break;
            try out.appendSlice(a, buf[0..n]);
        }
        return out.toOwnedSlice(a);
    }
    var z: [4096:0]u8 = undefined;
    const p = try toZ(path, &z);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) break;
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

pub fn head_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return simple.headMain(argc, argv);
}

pub fn tail_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return simple.tailMain(argc, argv);
}

pub fn wc_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return simple.wcMain(argc, argv);
}

pub fn sort_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var reverse = false;
    var unique = false;
    var path: []const u8 = "-";
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-r")) reverse = true else if (std.mem.eql(u8, arg, "-u")) unique = true else if (arg.len == 0 or arg[0] != '-') path = arg;
    }
    const data = readInput(std.heap.page_allocator, path) catch return 1;
    defer std.heap.page_allocator.free(data);
    const out = sortLines(std.heap.page_allocator, data, reverse, unique) catch return 1;
    defer std.heap.page_allocator.free(out);
    writeAll(stdout, out);
    return 0;
}

pub fn uniq_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const data = readInput(std.heap.page_allocator, if (args.len > 1) args[1] else "-") catch return 1;
    defer std.heap.page_allocator.free(data);
    const out = uniqLines(std.heap.page_allocator, data) catch return 1;
    defer std.heap.page_allocator.free(out);
    writeAll(stdout, out);
    return 0;
}

pub fn cut_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var delim: u8 = '\t';
    var field: usize = 1;
    var path: []const u8 = "-";
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-d") and arg.len > 2) {
            delim = arg[2];
        } else if (std.mem.startsWith(u8, arg, "-f")) {
            field = std.fmt.parseInt(usize, arg[2..], 10) catch 1;
        } else if (arg.len == 0 or arg[0] != '-') path = arg;
    }
    const data = readInput(std.heap.page_allocator, path) catch return 1;
    defer std.heap.page_allocator.free(data);
    const out = cutFields(std.heap.page_allocator, data, delim, field) catch return 1;
    defer std.heap.page_allocator.free(out);
    writeAll(stdout, out);
    return 0;
}

const CopyCtx = struct {
    src: []const u8,
    dst: []const u8,
    allocator: std.mem.Allocator,
};

fn copyCb(path: []const u8, is_dir: bool, ctx: ?*anyopaque) bb.util.Action {
    const c: *CopyCtx = @ptrCast(@alignCast(ctx.?));
    var rel = path[c.src.len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    const target = std.fmt.allocPrint(c.allocator, "{s}/{s}", .{ c.dst, rel }) catch return .abort;
    defer c.allocator.free(target);
    if (is_dir) {
        mkdirP(target) catch return .abort;
    } else {
        copyFile(path, target) catch return .abort;
    }
    return .continue_walk;
}

pub fn copyDirRecursive(a: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    try mkdirP(dst);
    var ctx = CopyCtx{ .src = src, .dst = dst, .allocator = a };
    try bb.util.recursiveAction(a, src, copyCb, &ctx);
}

const RemoveCtx = struct {
    paths: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
};

fn collectCb(path: []const u8, is_dir: bool, ctx: ?*anyopaque) bb.util.Action {
    const c: *RemoveCtx = @ptrCast(@alignCast(ctx.?));
    _ = is_dir;
    const copy = c.allocator.dupe(u8, path) catch return .abort;
    c.paths.append(c.allocator, copy) catch return .abort;
    return .continue_walk;
}

pub fn removeRecursive(a: std.mem.Allocator, path: []const u8) !void {
    var ctx = RemoveCtx{ .paths = .empty, .allocator = a };
    defer {
        for (ctx.paths.items) |p| a.free(p);
        ctx.paths.deinit(a);
    }
    try bb.util.recursiveAction(a, path, collectCb, &ctx);
    var i = ctx.paths.items.len;
    while (i > 0) {
        i -= 1;
        removePath(ctx.paths.items[i]) catch return error.RemoveFailed;
    }
    try removePath(path);
}

pub fn awk_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var program: []const u8 = "";
    var path: []const u8 = "-";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-f") and arg.len > 2) {
            const script = readInput(std.heap.page_allocator, arg[2..]) catch return 1;
            defer std.heap.page_allocator.free(script);
            program = script;
        } else if (arg.len > 0 and arg[0] == '-') {
            // ignore other options
        } else if (program.len == 0) {
            program = arg;
        } else {
            path = arg;
        }
    }
    if (program.len == 0) return 1;
    const data = readInput(std.heap.page_allocator, path) catch return 1;
    defer std.heap.page_allocator.free(data);
    const out = awk.renderAwk(std.heap.page_allocator, data, program) catch return 1;
    defer std.heap.page_allocator.free(out);
    writeAll(stdout, out);
    return 0;
}

pub fn sed_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var quiet = false;
    var script: []const u8 = "";
    var path: []const u8 = "-";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i < args.len) script = args[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            // ignore other options for now
        } else if (script.len == 0) {
            script = arg;
        } else {
            path = arg;
        }
    }
    if (script.len == 0) return 1;
    const data = readInput(std.heap.page_allocator, path) catch return 1;
    defer std.heap.page_allocator.free(data);
    const out = sed.renderSed(std.heap.page_allocator, data, script, quiet) catch return 1;
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

// --- Task 7a wrappers -------------------------------------------------------
// One canonical `<name>_main` symbol per applet. The implementations live in
// simple.zig so this module root stays the single registry entry point.

pub fn pwd_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.pwdMain(argc, argv); }
pub fn basename_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.basenameMain(argc, argv); }
pub fn dirname_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.dirnameMain(argc, argv); }
pub fn tee_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.teeMain(argc, argv); }
pub fn yes_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.yesMain(argc, argv); }
pub fn sleep_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.sleepMain(argc, argv); }
pub fn usleep_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.usleepMain(argc, argv); }
pub fn nproc_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.nprocMain(argc, argv); }
pub fn sync_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.syncMain(argc, argv); }
pub fn fsync_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.fsyncMain(argc, argv); }
pub fn link_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.linkMain(argc, argv); }
pub fn unlink_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.unlinkMain(argc, argv); }
pub fn rmdir_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.rmdirMain(argc, argv); }
pub fn mkfifo_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.mkfifoMain(argc, argv); }
pub fn mknod_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.mknodMain(argc, argv); }
pub fn mktemp_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.mktempMain(argc, argv); }
pub fn readlink_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.readlinkMain(argc, argv); }
pub fn realpath_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.realpathMain(argc, argv); }
pub fn truncate_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.truncateMain(argc, argv); }
pub fn install_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.installMain(argc, argv); }
pub fn printenv_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.printenvMain(argc, argv); }
pub fn env_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.envMain(argc, argv); }
pub fn id_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.idMain(argc, argv); }
pub fn whoami_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.whoamiMain(argc, argv); }
pub fn logname_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.lognameMain(argc, argv); }
pub fn groups_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.idMain(argc, argv); }
pub fn users_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.usersMain(argc, argv); }
pub fn who_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.whoMain(argc, argv); }
pub fn w_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.whoMain(argc, argv); }
pub fn tty_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.ttyMain(argc, argv); }
pub fn hostid_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.hostidMain(argc, argv); }
pub fn uname_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.unameMain(argc, argv); }
pub fn arch_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.unameMain(argc, argv); }
pub fn nice_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.niceMain(argc, argv); }
pub fn nohup_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.nohupMain(argc, argv); }
pub fn timeout_main(argc: c_int, argv: [*][*:0]const u8) c_int { return simple.timeoutMain(argc, argv); }

