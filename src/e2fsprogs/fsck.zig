//! fsck — the generic fsck.<type> driver. Mirrors e2fsprogs/fsck.c.
//!
//! Tests always pass -N so no real filesystem checker is executed. The
//! non-dry-run path genuinely fork/execs fsck.<type>, like the reference.

const std = @import("std");
const c = @import("common.zig");
const linux = c.linux;
const A = c.A;

const FsInfo = struct {
    device: []const u8,
    mountpt: []const u8,
    fstype: []const u8,
    opts: []const u8,
    passno: i32,
    done: bool = false,
};

const Instance = struct {
    pid: i32,
    prog: []const u8,
    device: []const u8,
    base_device: ?[]const u8,
};

const G = struct {
    fargs: std.ArrayList([]const u8),
    devices: std.ArrayList([]const u8),
    filesys: std.ArrayList(FsInfo),
    instances: std.ArrayList(Instance),
    types: std.ArrayList([]const u8),
    type_flags: std.ArrayList(u8),
    fstype: ?[]const u8 = null,
    negated: i8 = -1,
    verbose: i32 = 0,
    num_running: i32 = 0,
    max_running: i32 = std.math.maxInt(i32),
    noexecute: bool = false,
    serialize: bool = false,
    skip_root: bool = false,
    parallel_root: bool = false,
};

const ignored_types = [_][]const u8{ "ignore", "iso9660", "nfs", "proc", "sw", "swap", "tmpfs", "devpts" };

fn append(list: *std.ArrayList([]const u8), s: []const u8) void {
    list.append(A, s) catch {};
}

fn newFsInfo(fses: *std.ArrayList(FsInfo), device: []const u8, mountpt: []const u8, fstype_in: []const u8, opts: []const u8, passno: i32) void {
    const fstype = if (std.mem.indexOfScalar(u8, fstype_in, ',') != null) "auto" else fstype_in;
    fses.append(A, .{
        .device = A.dupe(u8, device) catch device,
        .mountpt = A.dupe(u8, mountpt) catch mountpt,
        .fstype = A.dupe(u8, fstype) catch fstype,
        .opts = A.dupe(u8, opts) catch opts,
        .passno = if (passno < 0) 1 else passno,
    }) catch {};
}

fn loadFstab(g: *G, path: []const u8) void {
    const data = c.readFile(path) orelse {
        c.plain("can't read '{s}'", .{path});
        return;
    };
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const dev = it.next() orelse continue;
        const mnt = it.next() orelse continue;
        const typ = it.next() orelse continue;
        const opts = it.next() orelse "";
        _ = it.next(); // dump frequency
        const pass_str = it.next() orelse "0";
        const pass = std.fmt.parseInt(i32, pass_str, 10) catch 0;
        newFsInfo(&g.filesys, dev, mnt, typ, opts, pass);
    }
}

fn lookupFs(g: *G, name: []const u8) ?*FsInfo {
    for (g.filesys.items) |*fs| {
        if (std.mem.eql(u8, name, fs.device) or std.mem.eql(u8, name, fs.mountpt)) return fs;
    }
    return null;
}

fn optInList(opt: []const u8, optlist: []const u8) bool {
    if (optlist.len == 0) return false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, optlist, pos, opt)) |i| {
        const left_ok = i == 0 or optlist[i - 1] == ',';
        const end = i + opt.len;
        const right_ok = end == optlist.len or optlist[end] == ',';
        if (left_ok and right_ok) return true;
        pos = i + 1;
    }
    return false;
}

fn compileFsType(g: *G, spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        var s = raw;
        var negate = false;
        if (std.mem.startsWith(u8, s, "no")) {
            s = s[2..];
            negate = true;
        } else if (s.len > 0 and s[0] == '!') {
            s = s[1..];
            negate = true;
        }
        var flag: u8 = 0;
        if (std.mem.eql(u8, s, "loop")) {
            flag = if (negate) 2 else 1;
        } else if (std.mem.startsWith(u8, s, "opts=")) {
            s = s[5..];
            flag = if (negate) 2 else 1;
        } else {
            if (g.negated == -1) g.negated = if (negate) 1 else 0;
            if (g.negated != (if (negate) @as(i8, 1) else 0))
                c.plainDie("either all or none of the filesystem types passed to -t must be prefixed with 'no' or '!'", .{});
        }
        append(&g.types, s);
        g.type_flags.append(A, flag) catch {};
    }
}

fn fsMatch(g: *G, fs: *const FsInfo) bool {
    if (g.types.items.len == 0) return true;
    var ret = false;
    var checked: usize = 0;
    for (g.types.items, g.type_flags.items) |name, flag| {
        switch (flag) {
            0 => {
                checked += 1;
                if (std.mem.eql(u8, name, fs.fstype)) ret = true;
            },
            2 => if (optInList(name, fs.opts)) return false,
            1 => if (!optInList(name, fs.opts)) return false,
            else => {},
        }
    }
    if (checked == 0) return true;
    return if (g.negated == 1) !ret else ret;
}

fn ignore(g: *G, fs: *const FsInfo) bool {
    if (fs.passno == 0) return true;
    if (!fsMatch(g, fs)) return true;
    for (ignored_types) |t| if (std.mem.eql(u8, t, fs.fstype)) return true;
    return false;
}

fn baseDevice(device: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, device, "/dev/")) return null;
    const cp = device[5..];
    if (std.mem.startsWith(u8, cp, "md")) return "/dev/md";
    if (std.mem.startsWith(u8, cp, "rd/")) {
        if (cp.len < 6 or cp[3] != 'c' or cp[5] != 'd') return null;
        return A.dupe(u8, device[0..9]) catch null;
    }
    if (cp.len >= 3 and (cp[0] == 'h' or cp[0] == 's') and cp[1] == 'd') {
        var i: usize = 2;
        if (i < cp.len and std.ascii.isDigit(cp[i])) i += 1;
        if (i >= cp.len or !std.ascii.isAlphabetic(cp[i])) return null;
        return A.dupe(u8, device[0 .. 5 + i + 1]) catch null;
    }
    return null;
}

fn deviceAlreadyActive(g: *G, device: []const u8) bool {
    if (g.instances.items.len == 0) return false;
    const base = baseDevice(device) orelse return true;
    defer A.free(base);
    for (g.instances.items) |inst| {
        if (inst.base_device == null or std.mem.eql(u8, base, inst.base_device.?)) return true;
    }
    return false;
}

fn execute(g: *G, fstype: []const u8, device: []const u8, mountpt: []const u8) void {
    var progbuf: [256]u8 = undefined;
    const prog = std.fmt.bufPrint(&progbuf, "fsck.{s}", .{fstype}) catch "fsck.auto";
    g.fargs.items[0] = A.dupe(u8, prog) catch prog;
    g.fargs.items[g.fargs.items.len - 1] = device;

    if (g.verbose != 0 or g.noexecute) {
        c.put("[{s} ({d}) -- {s}]", .{ prog, g.num_running, mountpt });
        for (g.fargs.items) |a| c.put(" {s}", .{a});
        c.out("\n");
    }

    if (g.noexecute) return;
    const av = A.alloc([]const u8, g.fargs.items.len) catch return;
    defer A.free(av);
    @memcpy(av, g.fargs.items);
    const pid = c.spawn(av) orelse {
        c.plain("can't execute '{s}'", .{prog});
        return;
    };
    g.instances.append(A, .{
        .pid = pid,
        .prog = A.dupe(u8, prog) catch prog,
        .device = A.dupe(u8, device) catch device,
        .base_device = baseDevice(device),
    }) catch {};
}

fn fsckDevice(g: *G, fs: *FsInfo) void {
    var fstype: []const u8 = undefined;
    if (!std.mem.eql(u8, fs.fstype, "auto")) {
        fstype = fs.fstype;
        if (g.verbose > 2) c.put("using filesystem type '{s}' from fstab\n", .{fstype});
    } else if (g.fstype) |ft| {
        const not_neg = !(ft.len >= 2 and ft[0] == 'n' and ft[1] == 'o');
        if (not_neg and !std.mem.startsWith(u8, ft, "opts=") and
            !std.mem.startsWith(u8, ft, "loop") and std.mem.indexOfScalar(u8, ft, ',') == null)
        {
            fstype = ft;
            if (g.verbose > 2) c.put("using filesystem type '{s}' from -t\n", .{fstype});
        } else {
            fstype = "auto";
            if (g.verbose > 2) c.out("using filesystem type 'auto' (default)\n");
        }
    } else {
        fstype = "auto";
        if (g.verbose > 2) c.out("using filesystem type 'auto' (default)\n");
    }
    g.num_running += 1;
    execute(g, fstype, fs.device, fs.mountpt);
}

fn waitOne(g: *G, flags: i32) i32 {
    if (g.instances.items.len == 0) return -1;
    if ((flags & linux.W.NOHANG) != 0) return -1;
    var status: i32 = 0;
    const pid = linux.wait4(-1, &status, 0, null);
    if (linux.errno(pid) != .SUCCESS or pid <= 0) return -1;
    var idx: ?usize = null;
    for (g.instances.items, 0..) |inst, i| {
        if (inst.pid == @as(i32, @intCast(pid))) {
            idx = i;
            break;
        }
    }
    if (idx == null) return -1;
    const inst = g.instances.orderedRemove(idx.?);
    const exitcode: i32 = if ((status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else 4;
    if (g.verbose > 1) c.put("Finished with {s} (exit status {d})\n", .{ inst.device, exitcode });
    g.num_running -= 1;
    return exitcode;
}

fn waitMany(g: *G, flags: i32) i32 {
    var global: i32 = 0;
    var first = true;
    while (true) {
        const st = waitOne(g, if (first) 0 else flags);
        first = false;
        if (st == -1) break;
        global |= st;
    }
    return global;
}

fn checkAll(g: *G) i32 {
    var status: i32 = 0;
    if (g.verbose != 0) c.out("Checking all filesystems\n");
    for (g.filesys.items) |*fs| {
        if (ignore(g, fs)) fs.done = true;
    }

    if (!g.parallel_root) {
        for (g.filesys.items) |*fs| {
            if (std.mem.eql(u8, fs.mountpt, "/")) {
                if (!g.skip_root and !ignore(g, fs)) {
                    fsckDevice(g, fs);
                    status |= waitMany(g, 0);
                    if (status > 1) return status;
                }
                fs.done = true;
                break;
            }
        }
    }
    if (g.skip_root) {
        for (g.filesys.items) |*fs| {
            if (std.mem.eql(u8, fs.mountpt, "/")) fs.done = true;
        }
    }

    var not_done = true;
    var passno: i32 = 1;
    while (not_done) {
        not_done = false;
        var pass_done = true;
        for (g.filesys.items) |*fs| {
            if (fs.done) continue;
            if (fs.passno > passno) {
                not_done = true;
                continue;
            }
            if (deviceAlreadyActive(g, fs.device)) {
                pass_done = false;
                continue;
            }
            fsckDevice(g, fs);
            fs.done = true;
            if (g.serialize or g.num_running >= g.max_running) {
                pass_done = false;
                break;
            }
        }
        if (g.verbose > 1) c.put("--waiting-- (pass {d})\n", .{passno});
        status |= waitMany(g, if (pass_done) 0 else linux.W.NOHANG);
        if (pass_done) {
            if (g.verbose > 1) c.out("----------------------------------\n");
            passno += 1;
        } else not_done = true;
    }
    return status;
}

pub fn fsckMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));

    var g = G{
        .fargs = .empty,
        .devices = .empty,
        .filesys = .empty,
        .instances = .empty,
        .types = .empty,
        .type_flags = .empty,
    };
    append(&g.fargs, ""); // slot 0: fsck.<type>

    var opts_for_fsck = false;
    var doall = false;
    var notitle = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((arg.len > 0 and arg[0] == '/' and !opts_for_fsck) or
            std.mem.indexOfScalar(u8, arg, '=') != null)
        {
            append(&g.devices, arg);
            continue;
        }
        if (arg.len == 0 or arg[0] != '-' or opts_for_fsck) {
            append(&g.fargs, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            opts_for_fsck = true;
            continue;
        }
        var options: [256]u8 = undefined;
        var optpos: usize = 0;
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            switch (arg[j]) {
                'A' => doall = true,
                'V' => g.verbose += 1,
                'N' => g.noexecute = true,
                'R' => g.skip_root = true,
                'T' => notitle = true,
                'P' => g.parallel_root = true,
                's' => g.serialize = true,
                't' => {
                    if (g.fstype != null) c.usageDie(name);
                    var tmp: []const u8 = undefined;
                    if (j + 1 < arg.len) {
                        tmp = arg[j + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) c.usageDie(name);
                        tmp = args[i];
                    }
                    g.fstype = A.dupe(u8, tmp) catch tmp;
                    compileFsType(&g, g.fstype.?);
                    break;
                },
                '?' => c.usageDie(name),
                else => {
                    optpos += 1;
                    if (optpos + 1 < options.len) options[optpos] = arg[j];
                },
            }
        }
        if (optpos != 0) {
            options[0] = '-';
            const owned = A.dupe(u8, options[0 .. optpos + 1]) catch continue;
            append(&g.fargs, owned);
        }
    }
    append(&g.fargs, ""); // last slot: device

    if (c.getEnv("FSCK_MAX_INST")) |v| g.max_running = std.fmt.parseInt(i32, v, 10) catch g.max_running;

    if (!notitle) c.put("fsck (busybox 1.39.0.git)\n", .{});

    const fstab = c.getEnv("FSTAB_FILE") orelse "/etc/fstab";
    loadFstab(&g, fstab);

    if (g.devices.items.len == 0) {
        g.serialize = true;
        doall = true;
    }
    if (doall) return @intCast(checkAll(&g) & 0xff);

    var status: i32 = 0;
    for (g.devices.items) |dev| {
        var fallback = FsInfo{
            .device = dev, .mountpt = "", .fstype = "auto", .opts = "", .passno = 1,
        };
        const fs = lookupFs(&g, dev) orelse &fallback;
        fsckDevice(&g, fs);
        if (g.serialize or g.num_running >= g.max_running) {
            const st = waitOne(&g, 0);
            if (st >= 0) status |= st;
            if (g.verbose > 1) c.out("----------------------------------\n");
        }
    }
    status |= waitMany(&g, linux.W.NOHANG);
    return @intCast(status & 0xff);
}

