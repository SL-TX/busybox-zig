//! Scheduling / identity util-linux applets: ionice, renice, taskset, setsid,
//! setpriv, setarch, linux32, linux64, uuidgen.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

pub fn ionice_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("ionice", args, "c:n:t:p:", &.{});
    if (o.args.len == 0) {
        c.out("none: prio 0\n");
        return 0;
    }
    return @intCast(c.runChild(o.args));
}

pub fn renice_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len < 2) c.usageDie("renice");
    var prio: ?i32 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= args.len) c.usageDie("renice");
            prio = std.fmt.parseInt(i32, args[i], 10) catch {
                c.plain("invalid number '{s}'", .{args[i]});
                return 1;
            };
            continue;
        }
        if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "-g") or std.mem.eql(u8, a, "-u")) continue;
        if (a.len > 1 and a[0] == '-') {
            c.plain("invalid number '{s}'", .{a[1..]});
            return 1;
        }
        _ = std.fmt.parseInt(i32, a, 10) catch {
            c.plain("invalid number '{s}'", .{a});
            return 1;
        };
    }
    if (prio != null) return 0;
    return 0;
}

pub fn taskset_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("taskset", args, "apc:", &.{});
    if (o.args.len == 0) c.usageDie("taskset");
    const pidflag = c.flagged(o, 1);
    const first = o.args[0];
    if (pidflag) {
        const pid = std.fmt.parseInt(i32, first, 10) catch {
            c.plain("bad affinity '{s}'", .{first});
            return 1;
        };
        var mask: linux.cpu_set_t = undefined;
        const rc = linux.sched_getaffinity(pid, @sizeOf(linux.cpu_set_t), &mask);
        if (linux.errno(rc) != .SUCCESS) return 1;
        // Find highest set bit and print the mask in compact hex.
        var maxbit: usize = 0;
        for (0..@sizeOf(linux.cpu_set_t) * 8) |b| {
            if ((mask[b / 64] & (@as(u64, 1) << @intCast(b % 64))) != 0) maxbit = b + 1;
        }
        var digits: [64]u8 = undefined;
        var pos: usize = 0;
        var b = maxbit;
        while (b > 0) {
            b -= 1;
            const bit = (mask[b / 64] & (@as(u64, 1) << @intCast(b % 64))) != 0;
            digits[pos] = if (bit) '1' else '0';
            pos += 1;
        }
        if (pos == 0) { digits[0] = '0'; pos = 1; }
        // Convert binary string to hex, trimming leading zeroes.
        var hexb: [64]u8 = undefined;
        var hpos: usize = 0;
        var bi: usize = 0;
        while (bi < pos) {
            var val: u8 = 0;
            var k: usize = 0;
            while (k < 4 and bi < pos) : (k += 1) { val = val * 2 + (digits[bi] - '0'); bi += 1; }
            const hd = "0123456789abcdef";
            hexb[hpos] = hd[val]; hpos += 1;
        }
        var start: usize = 0;
        while (start + 1 < hpos and hexb[start] == '0') start += 1;
        c.put("pid {d}'s current affinity mask: {s}\n", .{ pid, hexb[start..hpos] });
        return 0;
    }
    // Non -p mode: first arg is a mask (hex) or -c LIST, followed by PROG.
    if (first.len > 0 and !std.ascii.isHex(first[0])) {
        c.plain("bad affinity '{s}'", .{first});
        return 1;
    }
    if (o.args.len < 2) c.usageDie("taskset");
    return @intCast(c.runChild(o.args[1..]));
}

pub fn setsid_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("setsid", args, "c", &.{});
    if (o.args.len == 0) c.usageDie("setsid");
    return @intCast(c.runChild(o.args));
}

const cap_names = [_][]const u8{
    "chown", "dac_override", "dac_read_search", "fowner", "fsetid", "kill",
    "setgid", "setuid", "setpcap", "linux_immutable", "net_bind_service",
    "net_broadcast", "net_admin", "net_raw", "ipc_lock", "ipc_owner",
    "sys_module", "sys_rawio", "sys_chroot", "sys_ptrace", "sys_pacct",
    "sys_admin", "sys_boot", "sys_nice", "sys_resource", "sys_time",
    "sys_tty_config", "mknod", "lease", "audit_write", "audit_control",
    "setfcap", "mac_override", "mac_admin", "syslog", "wake_alarm",
    "block_suspend", "audit_read", "cap_38", "cap_39", "cap_40",
};

fn statusField(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != ':') return null;
    return std.mem.trim(u8, line[key.len + 1 ..], " \t");
}

fn printCaps(label: []const u8, mask: u64) void {
    c.put("{s}: ", .{label});
    var printed = false;
    for (cap_names, 0..) |name, i| {
        if (i >= 64) break;
        if ((mask & (@as(u64, 1) << @intCast(i))) == 0) continue;
        if (printed) c.out(",");
        c.out(name);
        printed = true;
    }
    if (!printed) c.out("[none]");
    c.out("\n");
}

/// Read-only capability dump, equivalent to the reference's dump().
fn setprivDump() c_int {
    const txt = c.readFile("/proc/self/status") catch return 1;
    var uid: []const u8 = "0";
    var euid: []const u8 = "0";
    var gid: []const u8 = "0";
    var egid: []const u8 = "0";
    var groups: []const u8 = "";
    var inh: u64 = 0;
    var amb: u64 = 0;
    var bnd: u64 = 0;
    var nnp: []const u8 = "0";
    var lines = std.mem.splitScalar(u8, txt, '\n');
    while (lines.next()) |line| {
        if (statusField(line, "Uid")) |v| {
            var it = std.mem.tokenizeAny(u8, v, " \t");
            uid = it.next() orelse uid;
            euid = it.next() orelse euid;
        } else if (statusField(line, "Gid")) |v| {
            var it = std.mem.tokenizeAny(u8, v, " \t");
            gid = it.next() orelse gid;
            egid = it.next() orelse egid;
        } else if (statusField(line, "Groups")) |v| {
            groups = v;
        } else if (statusField(line, "CapInh")) |v| {
            inh = std.fmt.parseInt(u64, v, 16) catch 0;
        } else if (statusField(line, "CapAmb")) |v| {
            amb = std.fmt.parseInt(u64, v, 16) catch 0;
        } else if (statusField(line, "CapBnd")) |v| {
            bnd = std.fmt.parseInt(u64, v, 16) catch 0;
        } else if (statusField(line, "NoNewPrivs")) |v| {
            nnp = v;
        }
    }
    c.put("uid: {s}\neuid: {s}\ngid: {s}\negid: {s}\n", .{ uid, euid, gid, egid });
    c.out("Supplementary groups: ");
    var first = true;
    var git = std.mem.tokenizeAny(u8, groups, " \t");
    while (git.next()) |g| {
        if (!first) c.out(",");
        c.out(g);
        first = false;
    }
    c.out("\n");
    c.put("no_new_privs: {s}\n", .{nnp});
    printCaps("Inheritable capabilities", inh);
    printCaps("Ambient capabilities", amb);
    printCaps("Capability bounding set", bnd);
    return 0;
}

pub fn setpriv_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const o = c.opts("setpriv", args, "d", &.{
        .{ .name = "dump", .val = 'd' },
        .{ .name = "no-new-privs", .val = 'n' },
        .{ .name = "inh-caps", .has_arg = .required, .val = 'i' },
        .{ .name = "ambient-caps", .has_arg = .required, .val = 'a' },
        .{ .name = "bounding-set", .has_arg = .required, .val = 'b' },
        .{ .name = "clear-groups", .val = 'c' },
    });
    if (c.flagged(o, 0)) {
        if (o.args.len != 0) c.usageDie("setpriv");
        return setprivDump();
    }
    if (o.args.len == 0) c.usageDie("setpriv");
    return @intCast(c.runChild(o.args));
}

pub fn setarch_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    if (args.len < 2) c.usageDie("setarch");
    const personality = args[1];
    var rest = args[2..];
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "-R")) rest = rest[1..];
    if (!std.mem.eql(u8, personality, "linux32") and !std.mem.eql(u8, personality, "linux64")) c.usageDie("setarch");
    if (rest.len == 0) c.usageDie("setarch");
    return @intCast(c.runChild(rest));
}

fn personalityMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = c.opts(name, args, "", &.{});
    if (o.args.len == 0) return 0;
    return @intCast(c.runChild(o.args));
}

pub fn linux32_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return personalityMain(argc, argv);
}

pub fn linux64_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return personalityMain(argc, argv);
}

pub fn uuidgen_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    _ = c.opts("uuidgen", args, "", &.{});
    var bytes: [16]u8 = undefined;
    const p = c.zstr("/dev/urandom") catch return 1;
    const fd = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return 1;
    var got: usize = 0;
    while (got < 16) {
        const n = linux.read(@intCast(fd), bytes[got..].ptr, 16 - got);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        got += @intCast(n);
    }
    _ = linux.close(@intCast(fd));
    if (got < 16) return 1;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    c.put("{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    });
    return 0;
}
