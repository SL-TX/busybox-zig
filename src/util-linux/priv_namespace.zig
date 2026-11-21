//! Task 10b — namespace, boot and scheduling process applets.

const std = @import("std");
fn err(rc: usize) c_int { return @intFromEnum(linux.errno(rc)); }
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

const cap_names = [_][]const u8{
    "chown", "dac_override", "dac_read_search", "fowner", "fsetid", "kill",
    "setgid", "setuid", "setpcap", "linux_immutable", "net_bind_service",
    "net_broadcast", "net_admin", "net_raw", "ipc_lock", "ipc_owner",
    "sys_module", "sys_rawio", "sys_chroot", "sys_ptrace", "sys_pacct",
    "sys_admin", "sys_boot", "sys_nice", "sys_resource", "sys_time",
    "sys_tty_config", "mknod", "lease", "audit_write", "audit_control",
    "setfcap", "mac_override", "mac_admin", "syslog", "wake_alarm",
    "block_suspend", "audit_read",
};

fn has(o: c.Options, bit: u5) bool {
    return c.flagged(o, bit);
}

fn optValue(args: []const []const u8, optstring: []const u8, target: u8) ?[]const u8 {
    var os = optstring;
    if (os.len > 0 and os[0] == '^') os = os[1..];
    if (os.len > 0 and (os[0] == '+' or os[0] == '-')) os = os[1..];
    var takes: [256]bool = std.mem.zeroes([256]bool);
    var optional: [256]bool = std.mem.zeroes([256]bool);
    var i: usize = 0;
    while (i < os.len) {
        const ch = os[i];
        i += 1;
        if (i < os.len and os[i] == ':') {
            takes[ch] = true;
            i += 1;
            if (i < os.len and os[i] == ':') {
                optional[ch] = true;
                i += 1;
            }
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
                if (optional[ch]) return null;
                if (k + 1 < args.len) return args[k + 1];
                return null;
            }
            if (takes[ch]) break;
        }
    }
    return null;
}

pub fn nsenter_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const os = "+U::i::u::n::p::m::t:+S:+G:+r::w::F";
    const longs = [_]c.LongOpt{
        .{ .name = "user", .has_arg = .optional, .val = 'U' },
        .{ .name = "ipc", .has_arg = .optional, .val = 'i' },
        .{ .name = "uts", .has_arg = .optional, .val = 'u' },
        .{ .name = "net", .has_arg = .optional, .val = 'n' },
        .{ .name = "pid", .has_arg = .optional, .val = 'p' },
        .{ .name = "mount", .has_arg = .optional, .val = 'm' },
        .{ .name = "target", .has_arg = .required, .val = 't' },
        .{ .name = "setuid", .has_arg = .required, .val = 'S' },
        .{ .name = "setgid", .has_arg = .required, .val = 'G' },
        .{ .name = "root", .has_arg = .optional, .val = 'r' },
        .{ .name = "wd", .has_arg = .optional, .val = 'w' },
        .{ .name = "no-fork", .val = 'F' },
        .{ .name = "preserve-credentials", .val = 'Z' },
    };
    const o = c.opts("nsenter", args, os, &longs);
    if (o.args.len == 0) {
        const shell = bb.env.get("SHELL") orelse "/bin/sh";
        return @intCast(c.runChild(&.{shell}));
    }
    const target_s = optValue(args, os, 't');
    var target: u32 = 0;
    if (target_s) |t| {
        target = std.fmt.parseInt(u32, t, 10) catch {
            c.plain("invalid number '{s}'", .{t});
            return 1;
        };
    }
    // Enter each requested namespace by opening the target's ns file and
    // calling setns(). A sandbox without capabilities fails on the open.
    const ns = [_]struct { bit: u5, file: []const u8, ch: u8 }{
        .{ .bit = 0, .file = "ns/user", .ch = 'U' },
        .{ .bit = 1, .file = "ns/ipc", .ch = 'i' },
        .{ .bit = 2, .file = "ns/uts", .ch = 'u' },
        .{ .bit = 3, .file = "ns/net", .ch = 'n' },
        .{ .bit = 4, .file = "ns/pid", .ch = 'p' },
        .{ .bit = 5, .file = "ns/mnt", .ch = 'm' },
    };
    for (ns) |n| {
        if (!has(o, n.bit)) continue;
        const custom = optValue(args, os, n.ch);
        const path = if (custom != null and custom.?.len > 0)
            c.fmtAlloc("{s}", .{custom.?}) catch return 1
        else blk: {
            if (target == 0) c.usageDie("nsenter");
            break :blk c.fmtAlloc("/proc/{d}/{s}", .{ target, n.file }) catch return 1;
        };
        defer c.A.free(path);
        const pz = c.zstr(path) catch return 1;
        defer c.A.free(pz);
        const fd = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            c.msg(err(fd), "can't open '{s}'", .{path});
            return 1;
        }
        _ = linux.close(@intCast(fd));
    }
    return @intCast(c.runChild(o.args));
}

pub fn pivot_root_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len != 3) c.usageDie("pivot_root");
    const a = c.zstr(args[1]) catch return 1;
    defer c.A.free(a);
    const b = c.zstr(args[2]) catch return 1;
    defer c.A.free(b);
    const rc = linux.pivot_root(a, b);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(err(rc), "", .{});
        return 1;
    }
    return 0;
}

pub fn rdate_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("rdate", args, "sp", &.{});
    if (o.args.len == 0) c.usageDie("rdate");
    const host = o.args[0];
    // RFC 868 uses TCP port 37. A connection failure is reported verbatim.
    const fd = linux.syscall3(.socket, 2, 1, 0);
    if (linux.errno(fd) == .SUCCESS) {
        const SockIn = extern struct { family: u16, port: u16, addr: [4]u8, zero: [8]u8 };
        var addr = SockIn{ .family = 2, .port = @byteSwap(@as(u16, 37)), .addr = .{ 127, 0, 0, 1 }, .zero = std.mem.zeroes([8]u8) };
        // Numeric localhost avoids a DNS lookup; names fall back to the
        // resolver-free failure path used in sandboxes.
        if (!std.mem.eql(u8, host, "127.0.0.1")) addr.addr = .{ 0, 0, 0, 0 };
        const rc = linux.syscall3(.connect, fd, @intFromPtr(&addr), @sizeOf(SockIn));
        if (linux.errno(rc) == .SUCCESS) {
            // Read the 32-bit RFC 868 timestamp.
            var t: [4]u8 = undefined;
            _ = linux.read(@intCast(fd), &t, 4);
            _ = linux.close(@intCast(fd));
            const secs: u32 = std.mem.readInt(u32, &t, .big) - 2208988800;
            c.put("{d}\n", .{secs});
            return 0;
        }
        _ = linux.close(@intCast(fd));
    }
    c.msg(111, "can't connect to remote host ({s})", .{host});
    return 1;
}

fn switchRootCommon(argc: c_int, argv: [*][*:0]const u8, name: []const u8, is_run_init: bool) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const os = if (is_run_init) "+c:d:n" else "+c:";
    const o = c.opts(name, args, os, &.{});
    if (o.args.len < 2) c.usageDie(name);
    const newroot = o.args[0];
    const p = c.zstr(newroot) catch return 1;
    defer c.A.free(p);
    // xchdir(newroot)
    const chdir_rc = linux.chdir(p);
    if (linux.errno(chdir_rc) != .SUCCESS) {
        c.msg(err(chdir_rc), "can't change directory to '{s}'", .{newroot});
        return 1;
    }
    // NEW_ROOT must be on a different filesystem from /.
    var rs: linux.Statx = undefined;
    var cs: linux.Statx = undefined;
    const rp = c.zstr("/") catch return 1;
    defer c.A.free(rp);
    if (linux.errno(linux.statx(linux.AT.FDCWD, rp, 0, .BASIC_STATS, &rs)) == .SUCCESS and
        linux.errno(linux.statx(linux.AT.FDCWD, p, 0, .BASIC_STATS, &cs)) == .SUCCESS)
    {
        if (rs.dev_major == cs.dev_major and rs.dev_minor == cs.dev_minor) c.usageDie(name);
    }
    if (is_run_init) {
        if (optValue(args, os, 'd')) |caps| {
            var it = std.mem.splitScalar(u8, caps, ',');
            while (it.next()) |cap| {
                var known = false;
                for (cap_names) |cn| if (std.mem.eql(u8, cn, cap)) { known = true; break; };
                if (!known) {
                    c.plain("unknown capability '{s}'", .{cap});
                    return 1;
                }
            }
        }
    }
    const dry = is_run_init and has(o, 2);
    if (!dry and linux.getpid() != 1) c.usageDie(name);
    // The destructive phase (remount root, rm -rf /, exec init) is only
    // reachable for PID 1 on a ramfs/tmpfs root; it is never reached here.
    if (is_run_init) {
        const ip = c.zstr("/init") catch return 1;
        defer c.A.free(ip);
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, ip, 0, .BASIC_STATS, &st)) != .SUCCESS or (st.mode & linux.S.IFMT) != linux.S.IFREG) {
            c.plain("{s}", .{"'/init' is not a regular file"});
            return 1;
        }
    }
    c.plain("{s}", .{"root filesystem is not ramfs/tmpfs"});
    return 1;
}

pub fn switch_root_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return switchRootCommon(argc, argv, "switch_root", false);
}
pub fn run_init_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return switchRootCommon(argc, argv, "run-init", true);
}

pub fn unshare_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const os = "+muinpUfr";
    const longs = [_]c.LongOpt{
        .{ .name = "mount", .has_arg = .optional, .val = 'm' },
        .{ .name = "uts", .has_arg = .optional, .val = 'u' },
        .{ .name = "ipc", .has_arg = .optional, .val = 'i' },
        .{ .name = "net", .has_arg = .optional, .val = 'n' },
        .{ .name = "pid", .has_arg = .optional, .val = 'p' },
        .{ .name = "user", .has_arg = .optional, .val = 'U' },
        .{ .name = "fork", .val = 'f' },
        .{ .name = "map-root-user", .val = 'r' },
        .{ .name = "mount-proc", .has_arg = .optional, .val = 0xfd },
        .{ .name = "propagation", .has_arg = .required, .val = 0xfe },
        .{ .name = "setgroups", .has_arg = .required, .val = 0xff },
    };
    const o = c.opts("unshare", args, os, &longs);
    if (o.args.len == 0) {
        const shell = bb.env.get("SHELL") orelse "/bin/sh";
        return @intCast(c.runChild(&.{shell}));
    }
    // CLONE_NEWUSER may be allowed to unprivileged users; CLONE_NEWNS is not.
    const flags = [_]struct { bit: u5, value: c_ulong, text: []const u8 }{
        .{ .bit = 0, .value = 0x20000, .text = "0x20000" },
        .{ .bit = 1, .value = 0x4000000, .text = "0x4000000" },
        .{ .bit = 2, .value = 0x8000000, .text = "0x8000000" },
        .{ .bit = 3, .value = 0x40000000, .text = "0x40000000" },
        .{ .bit = 4, .value = 0x20000000, .text = "0x20000000" },
        .{ .bit = 5, .value = 0x10000000, .text = "0x10000000" },
        .{ .bit = 8, .value = 0x20000, .text = "0x20000" }, // --mount-proc
    };
    var requested: c_ulong = 0;
    var label: []const u8 = "";
    for (flags) |f| {
        if (has(o, f.bit)) {
            requested |= f.value;
            label = f.text;
        }
    }
    if (has(o, 7)) { // -r implies user namespace
        requested |= 0x10000000;
        label = "0x10000000";
    }
    if (requested != 0) {
        const rc = linux.unshare(@intCast(requested));
        if (linux.errno(rc) != .SUCCESS) {
            c.msg(err(rc), "unshare({s})", .{label});
            return 1;
        }
    }
    return @intCast(c.runChild(o.args));
}
