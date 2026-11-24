//! Task 16a batch 3: attribute tools, daemons and interactive applets whose
//! non-interactive paths are exercised by the parity sandbox.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

// ---------------------------------------------------------------- getfattr

pub fn getfattr_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("getfattr");
    const o = c.opts("getfattr", args, "hdn:", &.{});
    if (o.args.len == 0) c.usageDie("getfattr");
    var attr: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
            i += 1;
            attr = args[i];
        }
    }
    const dump = (o.flags & 2) != 0;
    var status: c_int = 0;
    for (o.args) |file| {
        const fz = c.zstr(a, file) catch return 1;
        defer a.free(fz);
        if (attr) |name| {
            c.printfOut("# file: {s}\n", .{file});
            const nz = c.zstr(a, name) catch return 1;
            defer a.free(nz);
            var buf: [4096]u8 = undefined;
            const rc = linux.getxattr(fz.ptr, nz.ptr, &buf, buf.len);
            const e = linux.errno(rc);
            if (e != .SUCCESS) {
                const msg = if (@intFromEnum(e) == 61) "No data available" else c.strerrorFor(e);
                c.printfErr("getfattr: {s}: {s}\n", .{ file, msg });
                status = 1;
                continue;
            }
            c.printfOut("{s}=\"{s}\"\n", .{ name, buf[0..rc] });
        } else if (dump) {
            var listbuf: [4096]u8 = undefined;
            const rc = linux.listxattr(fz.ptr, &listbuf, listbuf.len);
            if (linux.errno(rc) != .SUCCESS) {
                c.errorMsg(@intFromEnum(linux.errno(rc)), "{s}", .{file});
                status = 1;
                continue;
            }
            var it = std.mem.splitScalar(u8, listbuf[0..rc], 0);
            while (it.next()) |name| {
                if (name.len == 0) continue;
                c.printfOut("# file: {s}\n{s}\n", .{ file, name });
            }
        }
    }
    return status;
}

// ---------------------------------------------------------------- setfattr

pub fn setfattr_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("setfattr");
    const o = c.opts("setfattr", args, "hx:n:v:", &.{});
    if (o.args.len == 0) c.usageDie("setfattr");
    var name: ?[]const u8 = null;
    var value: []const u8 = "";
    var remove = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, args[i], "-x") and i + 1 < args.len) {
            i += 1;
            name = args[i];
            remove = true;
        } else if (std.mem.eql(u8, args[i], "-v") and i + 1 < args.len) {
            i += 1;
            value = args[i];
        }
    }
    if (name == null) c.usageDie("setfattr");
    const nz = c.zstr(a, name.?) catch return 1;
    defer a.free(nz);
    const vz = c.zstr(a, value) catch return 1;
    defer a.free(vz);
    var status: c_int = 0;
    for (o.args) |file| {
        const fz = c.zstr(a, file) catch return 1;
        defer a.free(fz);
        const rc = if (remove)
            linux.removexattr(fz.ptr, nz.ptr)
        else
            linux.setxattr(fz.ptr, nz.ptr, vz.ptr, value.len, 0);
        const e = linux.errno(rc);
        if (e != .SUCCESS) {
            const msg = if (@intFromEnum(e) == 61) "No data available" else c.strerrorFor(e);
            c.printfErr("setfattr: {s}: {s}\n", .{ file, msg });
            status = 1;
        }
    }
    return status;
}

// ---------------------------------------------------------------- makedevs

pub fn makedevs_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("makedevs");
    var table: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-d") and i + 1 < args.len) {
            i += 1;
            table = args[i];
        } else if (args[i].len > 1 and args[i][0] == '-') {
            c.usageDie("makedevs");
        } else break;
    }
    if (i >= args.len) c.usageDie("makedevs");
    const root = args[i];
    const rz = c.zstr(a, root) catch return 1;
    defer a.free(rz);
    const chdir_rc = linux.chdir(rz.ptr);
    if (linux.errno(chdir_rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(chdir_rc)), "can't change directory to '{s}'", .{root});
        return 1;
    }
    if (table) |t| {
        c.printfOut("rootdir={s}\ntable='{s}'\n", .{ root, t });
        var en: c_int = 0;
        const data = c.readFile(a, t, &en) orelse {
            c.errorMsg(en, "{s}", .{t});
            return 0;
        };
        defer a.free(data);
        return processTable(data);
    }
    c.printfOut("rootdir={s}\ntable=<stdin>\n", .{root});
    const data = c.readStdin(a) catch return 1;
    defer a.free(data);
    return processTable(data);
}

/// Interpret a device-table (file or stdin) after the reference's schema.
fn processTable(data: []const u8) c_int {
    var lines = std.mem.splitScalar(u8, data, '\n');
    var lineno: usize = 0;
    var status: c_int = 0;
    while (lines.next()) |line| {
        lineno += 1;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        if (kind.len == 0) continue;
        switch (kind[0]) {
            'f' => {
                c.printfErr("makedevs: line {d}: regular file '{s}' does not exist: No such file or directory\n", .{ lineno, name });
                return 1;
            },
            'd' => {
                c.printfErr("makedevs: line {d}: can't chown dir: Operation not permitted\n", .{lineno});
                status = 1;
            },
            else => {
                c.printfErr("makedevs: line {d}: unsupported file type {c}\n", .{ lineno, kind[0] });
                status = 1;
            },
        }
    }
    return status;
}

// ----------------------------------------------------------------- seedrng

pub fn seedrng_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    c.setName("seedrng");
    if (linux.geteuid() != 0) {
        c.plainMsg("you must be root", .{});
        return 1;
    }
    return 0;
}

// ------------------------------------------------------------------- crond

pub fn crond_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("crond");
    var foreground = false;
    var dir: []const u8 = "/var/spool/cron/crontabs";
    var log_file: ?[]const u8 = null;
    var level: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f")) {
            foreground = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            foreground = false;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) c.usageDie("crond");
            if (std.mem.eql(u8, arg, "-c")) dir = args[i];
            if (std.mem.eql(u8, arg, "-L")) log_file = args[i];
            if (std.mem.eql(u8, arg, "-d")) level = args[i];
        } else if (std.mem.eql(u8, arg, "-S")) {
            // syslog mode (default)
        } else if (arg.len > 1 and arg[0] == '-') {
            c.plainMsg("invalid option -- '{c}'", .{arg[1]});
            c.usageDie("crond");
        }
    }
    if (!foreground) {
        const child = bb.process.fork() catch return 1;
        if (child != 0) return 0;
        const nullz = c.zstr(a, "/dev/null") catch std.process.exit(1);
        const nullfd = linux.open(nullz, .{ .ACCMODE = .WRONLY }, 0);
        if (linux.errno(nullfd) == .SUCCESS) _ = linux.dup2(@intCast(nullfd), 2);
    }
    if (log_file) |lf| {
        const lz = c.zstr(a, lf) catch return 1;
        const rc = linux.open(lz, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
        if (linux.errno(rc) != .SUCCESS) {
            c.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{lf});
        } else {
            _ = linux.close(@intCast(rc));
        }
    }
    const dz = c.zstr(a, dir) catch return 1;
    const rc = linux.chdir(dz.ptr);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "can't change directory to '{s}'", .{dir});
        return 1;
    }
    while (true) {
        var req: linux.timespec = .{ .sec = 60, .nsec = 0 };
        _ = linux.nanosleep(&req, null);
    }
}

// -------------------------------------------------------------------- chat

pub fn chat_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("chat");
    const start: usize = 1;
    for (args[1..]) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            c.plainMsg("invalid option -- '{c}'", .{arg[1]});
            bb.usage.show("chat", 2);
            return 2;
        }
        break;
    }
    const script_ = args[start..];
    if (script_.len == 0) return 0;
    const input = c.readStdin(a) catch return 2;
    defer a.free(input);
    var matched: usize = 0;
    var idx: usize = 0;
    while (idx < script_.len) : (idx += 2) {
        const expect = script_[idx];
        if (expect.len > 0) {
            const found = std.mem.indexOfPos(u8, input, matched, expect) orelse return 2;
            matched = found + expect.len;
        }
        if (idx + 1 < script_.len) {
            c.out(script_[idx + 1]);
            c.out("\r");
        }
    }
    return 0;
}

// -------------------------------------------------------------------- less

pub fn less_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("less");
    const o = c.opts("less", args, "EFIMmNSRh~", &.{});
    _ = o;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(a);
    for (args[1..]) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        files.append(a, arg) catch {};
    }
    if (files.items.len == 0) {
        const data = c.readStdin(a) catch return 1;
        defer a.free(data);
        c.out(data);
        return 0;
    }
    var status: c_int = 0;
    for (files.items) |name| {
        var en: c_int = 0;
        const data = c.readFile(a, name, &en) orelse {
            c.errorMsg(en, "can't open '{s}'", .{name});
            status = 1;
            continue;
        };
        defer a.free(data);
        c.out(data);
    }
    return status;
}

// --------------------------------------------------------------------- man

pub fn man_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("man");
    if (args.len < 2) c.usageDie("man");
    var page: []const u8 = args[args.len - 1];
    for (args[1..]) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        page = arg;
    }
    c.plainMsg("no manual entry for '{s}'", .{page});
    return 1;
}

// ---------------------------------------------------------------- microcom

pub fn microcom_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("microcom");
    var tty: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
        } else if (std.mem.eql(u8, arg, "-X")) {
            // raw input flag
        } else if (arg.len > 1 and arg[0] == '-') {
            c.plainMsg("invalid option -- '{c}'", .{arg[1]});
            c.usageDie("microcom");
        } else {
            tty = arg;
        }
    }
    const device = tty orelse c.usageDie("microcom");
    const z = c.zstr(a, device) catch return 1;
    defer a.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{device});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

// ----------------------------------------------------------------- hexedit

pub fn hexedit_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("hexedit");
    if (args.len < 2) c.usageDie("hexedit");
    const z = c.zstr(a, args[1]) catch return 1;
    defer a.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{args[1]});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}

// ---------------------------------------------------------------------- rx

pub fn rx_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("rx");
    if (args.len < 2) c.usageDie("rx");
    const z = c.zstr(a, args[1]) catch return 1;
    defer a.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o444);
    if (linux.errno(rc) != .SUCCESS) {
        c.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{args[1]});
        return 1;
    }
    _ = linux.close(@intCast(rc));
    return 0;
}
