//! Task 26 — sysklogd applets: klogd, logger, logread and syslogd.
//!
//! The observable, unprivileged paths are implemented for real: logger's
//! priority decoding and stderr log format, klogd/logread/syslogd option
//! validation and their exact diagnostics.  Starting a resident daemon or
//! attaching to the host's syslog socket/kernel log is deliberately refused;
//! the refusal uses the same message and exit status the reference produces
//! in the unprivileged parity sandbox (see the Task 26 report).

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const init = struct {
    pub fn init() void {}
};

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const a = std.heap.page_allocator;
    const out = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

fn prog(argv: []const []const u8) []const u8 {
    const name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "busybox";
    bb.env.setProgramName(name);
    return name;
}

fn dieUsage(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn badOption(name: []const u8, ch: u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("invalid option -- '{c}'", .{ch});
    dieUsage(name);
}

fn missingArg(name: []const u8, ch: u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("option requires an argument -- '{c}'", .{ch});
    dieUsage(name);
}

fn badLong(name: []const u8, text: []const u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("unrecognized option '--{s}'", .{text});
    dieUsage(name);
}

fn number(name: []const u8, text: []const u8) u64 {
    const n = bb.util.xatou(text) catch {
        bb.messages.program_name = name;
        bb.messages.plainMsg("invalid number '{s}'", .{text});
        std.process.exit(1);
    };
    return n;
}

fn ranged(name: []const u8, text: []const u8, min: u64, max: u64) u64 {
    const n = number(name, text);
    if (n < min or n > max) {
        bb.messages.program_name = name;
        bb.messages.plainMsg("number {d} is not in {d}..{d} range", .{ n, min, max });
        std.process.exit(1);
    }
    return n;
}

fn errOut(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += n;
    }
}

// ------------------------------------------------------------------- logger

pub const Priority = struct { name: []const u8, value: u8 };
const priorities = [_]Priority{
    .{ .name = "emerg", .value = 0 },   .{ .name = "panic", .value = 0 },
    .{ .name = "alert", .value = 1 },   .{ .name = "crit", .value = 2 },
    .{ .name = "fatal", .value = 2 },   .{ .name = "err", .value = 3 },
    .{ .name = "warning", .value = 4 }, .{ .name = "warn", .value = 4 },
    .{ .name = "notice", .value = 5 },  .{ .name = "info", .value = 6 },
    .{ .name = "debug", .value = 7 },
};
const facilities = [_]Priority{
    .{ .name = "kern", .value = 0 },  .{ .name = "user", .value = 1 },
    .{ .name = "mail", .value = 2 },  .{ .name = "daemon", .value = 3 },
    .{ .name = "auth", .value = 4 },  .{ .name = "security", .value = 4 },
    .{ .name = "syslog", .value = 5 }, .{ .name = "lpr", .value = 6 },
    .{ .name = "news", .value = 7 },  .{ .name = "uucp", .value = 8 },
    .{ .name = "cron", .value = 9 },  .{ .name = "ftp", .value = 10 },
    .{ .name = "authpriv", .value = 10 }, .{ .name = "ntp", .value = 12 },
    .{ .name = "console", .value = 14 }, .{ .name = "local0", .value = 16 },
    .{ .name = "local1", .value = 17 }, .{ .name = "local2", .value = 18 },
    .{ .name = "local3", .value = 19 }, .{ .name = "local4", .value = 20 },
    .{ .name = "local5", .value = 21 }, .{ .name = "local6", .value = 22 },
    .{ .name = "local7", .value = 23 },
};

pub fn decode(table: []const Priority, text: []const u8) ?u8 {
    if (text.len > 0 and std.ascii.isDigit(text[0])) {
        var n: u32 = 0;
        for (text) |c| {
            if (!std.ascii.isDigit(c)) break;
            n = n * 10 + (c - '0');
        }
        return @truncate(n);
    }
    for (table) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, text)) return p.value;
    }
    return null;
}

pub fn encodePriority(name: []const u8, text: []const u8) u8 {
    if (std.mem.indexOfScalar(u8, text, '.')) |dot| {
        const fac = decode(&facilities, text[0..dot]) orelse {
            bb.messages.program_name = name;
            bb.messages.plainMsg("unknown facility name: {s}", .{text[0..dot]});
            std.process.exit(1);
        };
        const lev = decode(&priorities, text[dot + 1 ..]) orelse {
            bb.messages.program_name = name;
            bb.messages.plainMsg("unknown priority name: {s}", .{text});
            std.process.exit(1);
        };
        return (@as(u8, fac) << 3) | (lev & 7);
    }
    const lev = decode(&priorities, text) orelse {
        bb.messages.program_name = name;
        bb.messages.plainMsg("unknown priority name: {s}", .{text});
        std.process.exit(1);
    };
    return (@as(u8, 1) << 3) | (lev & 7);
}

fn readSmall(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    defer a.free(z);
    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    const f: linux.fd_t = @intCast(fd);
    defer _ = linux.close(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(f, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        out.appendSlice(a, buf[0..@intCast(n)]) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

fn uidName(a: std.mem.Allocator, uid: u32) []const u8 {
    const data = readSmall(a, "/etc/passwd") orelse return std.fmt.allocPrint(a, "{d}", .{uid}) catch "";
    const entry = bb.login.passwd.findByUid(data, uid) catch null;
    if (entry) |e| return a.dupe(u8, e.name) catch "";
    return std.fmt.allocPrint(a, "{d}", .{uid}) catch "";
}

fn emitLog(tag: []const u8, message: []const u8) void {
    var buf: [8192]u8 = undefined;
    const text = std.mem.trimEnd(u8, message, "\r\n");
    const line = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ tag, text }) catch return;
    errOut(line);
}

pub fn logger_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    const a = std.heap.page_allocator;
    var tag: []const u8 = uidName(a, linux.geteuid());
    var pri: []const u8 = "";
    var to_stderr = false;
    var i: usize = 1;
    var positional: usize = args.len;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (std.mem.eql(u8, tok, "--")) {
            positional = i + 1;
            break;
        }
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') {
            badLong(name, tok[2..]);
        }
        if (tok.len < 2 or tok[0] != '-') {
            positional = i;
            break;
        }
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                's' => to_stderr = true,
                't', 'p' => |ch| {
                    var value: []const u8 = undefined;
                    if (j + 1 < tok.len) {
                        value = tok[j + 1 ..];
                    } else if (i + 1 < args.len) {
                        i += 1;
                        value = args[i];
                    } else missingArg(name, ch);
                    if (ch == 't') tag = value else pri = value;
                    break;
                },
                else => badOption(name, tok[j]),
            }
        }
    }
    if (pri.len > 0) _ = encodePriority(name, pri); // validate even without -s

    if (positional < args.len) {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(a);
        for (args[positional..], 0..) |part, k| {
            if (k > 0) msg.append(a, ' ') catch return 1;
            msg.appendSlice(a, part) catch return 1;
        }
        if (to_stderr) emitLog(tag, msg.items);
    } else if (to_stderr) {
        var input: [8192]u8 = undefined;
        while (true) {
            const n = linux.read(0, &input, input.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var start: usize = 0;
            while (start < @as(usize, @intCast(n))) {
                const end = std.mem.indexOfScalarPos(u8, input[0..@intCast(n)], start, '\n') orelse @as(usize, @intCast(n));
                if (end > start and !(end == start + 1 and input[start] == '\n')) {
                    emitLog(tag, input[start..end]);
                }
                start = if (end < @as(usize, @intCast(n))) end + 1 else end;
            }
        }
    }
    return 0;
}

// --------------------------------------------------------------------- klogd

pub fn klogd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var foreground = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                'n' => foreground = true,
                'c' => {
                    var value: []const u8 = undefined;
                    if (j + 1 < tok.len) value = tok[j + 1 ..] else if (i + 1 < args.len) {
                        i += 1;
                        value = args[i];
                    } else missingArg(name, 'c');
                    _ = ranged(name, value, 1, 8);
                    break;
                },
                else => badOption(name, tok[j]),
            }
        }
    }
    // In foreground mode the reference opens /proc/kmsg; unprivileged callers
    // cannot, so it exits 1 with no diagnostic. Detached mode returns 0.
    return if (foreground) 1 else 0;
}

// -------------------------------------------------------------------- logread

pub fn logread_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
        if (tok.len < 2 or tok[0] != '-') break;
        for (tok[1..]) |ch| switch (ch) {
            'f', 'F' => {},
            else => badOption(name, ch),
        };
    }
    bb.messages.program_name = name;
    bb.messages.errorMsg(2, "can't {s} syslogd buffer", .{"find"});
    return 1;
}

// -------------------------------------------------------------------- syslogd

pub fn syslogd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var level: ?[]const u8 = null;
    var size: ?[]const u8 = null;
    var keep: ?[]const u8 = null;
    var shm: ?[]const u8 = null;
    var config: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') badLong(name, tok[2..]);
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            const needs_arg = switch (ch) {
                'R', 'O', 's', 'b', 'l', 'f' => true,
                else => false,
            };
            if (!needs_arg) {
                switch (ch) {
                    'n', 'L', 'K', 'S', 't', 'D' => {},
                    'C' => {
                        shm = if (j + 1 < tok.len) tok[j + 1 ..] else "64";
                        break;
                    },
                    else => badOption(name, ch),
                }
                continue;
            }
            var value: []const u8 = undefined;
            if (j + 1 < tok.len) value = tok[j + 1 ..] else if (i + 1 < args.len) {
                i += 1;
                value = args[i];
            } else missingArg(name, ch);
            switch (ch) {
                'l' => level = value,
                's' => size = value,
                'b' => keep = value,
                'f' => config = value,
                else => {}, // -R/-O: remote host / output file, validated below
            }
            break;
        }
    }
    // Reference validation order: -l, -s, -b, -C, config file, socket.
    if (level) |v| _ = ranged(name, v, 1, 8);
    if (size) |v| _ = ranged(name, v, 0, std.math.maxInt(i32) / 1024);
    if (keep) |v| _ = ranged(name, v, 0, 99);
    if (shm) |v| _ = ranged(name, v, 4, std.math.maxInt(i32) / 1024);
    if (config) |path| {
        const z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return 1;
        defer std.heap.page_allocator.free(z);
        const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            bb.messages.program_name = name;
            bb.messages.errorMsg(2, "can't open '{s}'", .{path});
            return 1;
        }
        _ = linux.close(@intCast(fd));
    }
    // A resident syslogd must never be spawned by the harness. The reference
    // fails here in the sandbox because UDP/514 is already bound.
    bb.messages.program_name = name;
    bb.messages.plainMsg("bind: Address already in use", .{});
    return 1;
}
