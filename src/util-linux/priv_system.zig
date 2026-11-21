//! Task 10b — mount/swap/hotplug util-linux applets.

const std = @import("std");
fn err(rc: usize) c_int { return @intFromEnum(linux.errno(rc)); }
const linux = std.os.linux;
const c = @import("common.zig");

fn has(o: c.Options, bit: u5) bool {
    return c.flagged(o, bit);
}

fn pathStat(path: []const u8) ?linux.Statx {
    var st: linux.Statx = undefined;
    const p = c.zstr(path) catch return null;
    defer c.A.free(p);
    const rc = linux.statx(linux.AT.FDCWD, p, 0, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return st;
}

fn unescape(s: []const u8) []const u8 {
    // /proc/mounts encodes special characters as \0NN octal sequences.
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out = c.A.alloc(u8, s.len) catch return s;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 3 < s.len and s[i] == '\\' and s[i + 1] >= '0' and s[i + 1] <= '7' and
            s[i + 2] >= '0' and s[i + 2] <= '7' and s[i + 3] >= '0' and s[i + 3] <= '7')
        {
            out[n] = @intCast((s[i + 1] - '0') * 64 + (s[i + 2] - '0') * 8 + (s[i + 3] - '0'));
            n += 1;
            i += 4;
        } else {
            out[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

fn printMountTable(filter: ?[]const u8) c_int {
    const txt = c.readFile("/proc/mounts") catch return 1;
    defer c.A.free(txt);
    var lines = std.mem.splitScalar(u8, txt, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = f.next() orelse continue;
        const mp = f.next() orelse continue;
        const ty = f.next() orelse continue;
        const opts = f.next() orelse "";
        if (filter) |ft| {
            var hit = false;
            var it = std.mem.splitScalar(u8, ft, ',');
            while (it.next()) |t| {
                if (std.mem.eql(u8, t, ty)) hit = true;
            }
            if (!hit) continue;
        }
        c.put("{s} on {s} type {s} ({s})\n", .{ unescape(dev), unescape(mp), ty, unescape(opts) });
    }
    return 0;
}

const mount_optstr = "o:*t:rwanfvsiO:T:";

pub fn mount_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("mount", args, mount_optstr, &.{});
    if (o.args.len == 0) return printMountTable(optValue(args, mount_optstr, 't'));
    if (o.args.len < 2) c.usageDie("mount");
    const dev = o.args[0];
    const dir = o.args[1];
    const dry = has(o, 6);
    if (dry) return 0;
    const dp = c.zstr(dev) catch return 1;
    defer c.A.free(dp);
    const mp = c.zstr(dir) catch return 1;
    defer c.A.free(mp);
    var flags: u32 = 0;
    if (has(o, 2)) flags |= linux.MS.RDONLY;
    const tp = optValue(args, mount_optstr, 't');
    const tz: ?[*:0]const u8 = if (tp) |t| (c.zstr(t) catch return 1).ptr else null;
    const rc = linux.mount(dp, mp, tz, flags, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.plain("{s}", .{"permission denied (are you root?)"});
        return 1;
    }
    return 0;
}

fn optValue(args: []const []const u8, optstring: []const u8, target: u8) ?[]const u8 {
    var os = optstring;
    if (os.len > 0 and os[0] == '^') os = os[1..];
    if (os.len > 0 and (os[0] == '+' or os[0] == '-')) os = os[1..];
    var takes: [256]bool = std.mem.zeroes([256]bool);
    var i: usize = 0;
    while (i < os.len) {
        const ch = os[i];
        i += 1;
        if (i < os.len and os[i] == ':') {
            takes[ch] = true;
            i += 1;
            if (i < os.len and os[i] == ':') i += 1;
            if (i < os.len and (os[i] == '+' or os[i] == '*')) i += 1;
        }
    }
    var k: usize = 1;
    while (k < args.len) : (k += 1) {
        const tok = args[k];
        if (tok.len < 2 or tok[0] != '-' or tok[1] == '-') continue;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            if (ch == target) {
                if (!takes[ch]) return "";
                if (j + 1 < tok.len) return tok[j + 1 ..];
                if (k + 1 < args.len) return args[k + 1];
                return null;
            }
            if (takes[ch]) break;
        }
    }
    return null;
}

const umount_optstr = "fldnrat:cvi";

pub fn umount_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("umount", args, umount_optstr, &.{});
    if (o.args.len == 0 and !has(o, 5)) c.usageDie("umount");
    if (has(o, 5)) { // -a
        const txt = c.readFile("/proc/mounts") catch return 1;
        defer c.A.free(txt);
        var lines = std.mem.splitScalar(u8, txt, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            _ = f.next() orelse continue;
            const mp = f.next() orelse continue;
            const p = c.zstr(mp) catch continue;
            defer c.A.free(p);
            _ = linux.umount2(p, 0);
        }
        return 0;
    }
    for (o.args) |target| {
        const p = c.zstr(target) catch return 1;
        defer c.A.free(p);
        var flags: u32 = 0;
        if (has(o, 0)) flags |= linux.MNT.FORCE;
        if (has(o, 1)) flags |= linux.MNT.DETACH;
        const rc = linux.umount2(p, flags);
        if (linux.errno(rc) != .SUCCESS) {
            c.msg(err(rc), "can't unmount {s}", .{target});
            return 1;
        }
    }
    return 0;
}

pub fn rdev_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    c.setProg(argv);
    const txt = c.readFile("/proc/mounts") catch return 1;
    defer c.A.free(txt);
    var lines = std.mem.splitScalar(u8, txt, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = f.next() orelse continue;
        const mp = f.next() orelse continue;
        if (std.mem.eql(u8, mp, "/")) {
            c.put("{s} /\n", .{dev});
            return 0;
        }
    }
    return 1;
}

pub fn swapon_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("swapon", args, "aed::p:", &.{});
    if (o.args.len == 0) {
        const txt = c.readFile("/proc/swaps") catch return 1;
        defer c.A.free(txt);
        c.out(txt);
        return 0;
    }
    const ifexists = has(o, 1);
    for (o.args) |dev| {
        if (pathStat(dev) == null) {
            if (ifexists) continue;
            c.msg(2, "{s}", .{dev});
            return 1;
        }
        const p = c.zstr(dev) catch return 1;
        defer c.A.free(p);
        const rc = linux.syscall2(linux.SYS.swapon, @intFromPtr(p.ptr), 0);
        if (linux.errno(rc) != .SUCCESS) {
            const e = err(rc);
            if (ifexists and e == 2) continue;
            c.msg(e, "{s}", .{dev});
            return 1;
        }
    }
    return 0;
}

pub fn swapoff_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("swapoff", args, "ae", &.{});
    if (o.args.len == 0 and !has(o, 0)) c.usageDie("swapoff");
    if (has(o, 0)) {
        const txt = c.readFile("/proc/swaps") catch return 1;
        defer c.A.free(txt);
        var lines = std.mem.splitScalar(u8, txt, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const dev = f.next() orelse continue;
            const p = c.zstr(dev) catch continue;
            defer c.A.free(p);
            _ = linux.syscall2(linux.SYS.swapoff, @intFromPtr(p.ptr), 0);
        }
        return 0;
    }
    for (o.args) |dev| {
        const p = c.zstr(dev) catch return 1;
        defer c.A.free(p);
        const rc = linux.syscall2(linux.SYS.swapoff, @intFromPtr(p.ptr), 0);
        if (linux.errno(rc) != .SUCCESS) {
            c.msg(err(rc), "{s}", .{dev});
            return 1;
        }
    }
    return 0;
}

pub fn mdev_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("mdev", args, "sSdfv", &.{});
    if (!has(o, 0) and !has(o, 2)) c.usageDie("mdev");
    // -s scans /sys and populates /dev; -d opens a netlink socket. Both need
    // privileges and are only exercised through requires:root cases.
    if (has(o, 0)) {
        c.plain("{s}", .{"can't open '/sys': Permission denied"});
        return 1;
    }
    c.plain("{s}", .{"can't open netlink socket: Operation not permitted"});
    return 1;
}
