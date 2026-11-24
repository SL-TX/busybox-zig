//! chattr — change ext2 file attributes.
//!
//! The state machine and diagnostics mirror e2fsprogs/chattr.c. Attribute
//! changes are genuine EXT2_IOC_* ioctls; on a regular file the kernel rejects
//! them exactly as it does for the reference binary.

const std = @import("std");
const c = @import("common.zig");
const linux = c.linux;

const OPT_ADD: u32 = 1 << 0;
const OPT_REM: u32 = 1 << 1;
const OPT_SET: u32 = 1 << 2;
const OPT_SET_VER: u32 = 1 << 3;
const OPT_SET_PROJ: u32 = 1 << 4;

/// chattr's accepted letters (e2attr_flags_sname_chattr), in flag-bit order.
pub const letters = "uSDiadAcEjItTeCFNPV";
pub const values = [_]u32{
    0x00000002, // u undelete
    0x00000008, // S synchronous updates
    0x00010000, // D synchronous directory updates
    0x00000010, // i immutable
    0x00000020, // a append only
    0x00000040, // d no dump
    0x00000080, // A no atime
    0x00000004, // c compressed
    0x00000800, // E encrypted
    0x00004000, // j journal data
    0x00001000, // I indexed directory
    0x00008000, // t no tailmerging
    0x00020000, // T top of dir hierarchy
    0x00080000, // e extents
    0x00800000, // C no COW
    0x40000000, // F casefold
    0x10000000, // N inline data
    0x20000000, // P project hierarchy
    0x00100000, // V verity
};

pub const State = struct {
    version: u32 = 0,
    af: u32 = 0,
    rf: u32 = 0,
    projid: u32 = 0,
    flags: u32 = 0,
    recursive: bool = false,

    pub fn getFlag(ch: u8) ?u32 {
        for (letters, 0..) |l, i| if (l == ch) return values[i];
        return null;
    }
};

fn parseUnsigned(v: []const u8) u32 {
    if (v.len == 0 or v[0] == '-') c.plainDie("invalid number '{s}'", .{v});
    const n = std.fmt.parseInt(u64, v, 10) catch c.plainDie("invalid number '{s}'", .{v});
    if (n > std.math.maxInt(u32)) c.plainDie("invalid number '{s}'", .{v});
    return @intCast(n);
}

/// Decode one "-", "+" or "=" argument. Returns the next argument index.
pub fn decodeArg(args: []const []const u8, start: usize, g: *State, name: []const u8) usize {
    const arg = args[start];
    const opt = arg[0];
    var idx = start;
    const fl: *u32 = if (opt == '-') &g.rf else &g.af;
    if (opt == '+') g.flags |= OPT_ADD else if (opt == '=') g.flags |= OPT_SET;
    var j: usize = 1;
    while (j < arg.len) : (j += 1) {
        const ch = arg[j];
        if (opt == '-') {
            switch (ch) {
                'R' => {
                    g.recursive = true;
                    continue;
                },
                'V', 'f' => continue,
                'v' => {
                    idx += 1;
                    if (idx >= args.len) c.usageDie(name);
                    g.version = parseUnsigned(args[idx]);
                    g.flags |= OPT_SET_VER;
                    continue;
                },
                'p' => {
                    idx += 1;
                    if (idx >= args.len) c.usageDie(name);
                    g.projid = parseUnsigned(args[idx]);
                    g.flags |= OPT_SET_PROJ;
                    continue;
                },
                else => g.flags |= OPT_REM,
            }
        }
        fl.* |= State.getFlag(ch) orelse c.usageDie(name);
    }
    return idx + 1;
}

fn changeAttributes(name: []const u8, g: *const State) void {
    const stat_errno = c.lstatErr(name);
    if (stat_errno != 0) {
        c.msg(stat_errno, "can't stat '{s}'", .{name});
        return;
    }
    const regular = c.isReg(name);
    const link = c.isLnk(name);
    const dir = c.isDir(name);
    if (!regular and !link and !dir) return;

    const p = c.zstr(name) catch return;
    defer c.A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .NOFOLLOW = true }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(c.err(rc), "can't open '{s}'", .{name});
        return;
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    if ((g.flags & OPT_SET_VER) != 0) {
        var ver: u32 = g.version;
        const r = c.err(c.ioctl(fd, c.IOC_SETVERSION, &ver));
        if (r != 0) c.msg(r, "setting version on {s}", .{name});
    }
    if ((g.flags & OPT_SET_PROJ) != 0) {
        var fsx: [28]u8 = std.mem.zeroes([28]u8);
        const r = c.err(c.ioctl(fd, c.IOC_FSGETXATTR, &fsx));
        if (r != 0) {
            c.msg(r, "getting project ID on {s}", .{name});
        } else {
            std.mem.writeInt(u32, fsx[12..16], g.projid, .little);
            const w = c.err(c.ioctl(fd, c.IOC_FSSETXATTR, &fsx));
            if (w != 0) c.msg(w, "setting project ID on {s}", .{name});
        }
    }

    var fsflags: u32 = 0;
    if ((g.flags & OPT_SET) != 0) {
        fsflags = g.af;
    } else {
        const r = c.err(c.ioctl(fd, c.IOC_GETFLAGS, &fsflags));
        if (r != 0) {
            c.msg(r, "getting flags on {s}", .{name});
            return;
        }
        fsflags = (fsflags & ~g.rf) | g.af;
        if (!dir) fsflags &= ~@as(u32, 0x10000); // EXT2_DIRSYNC_FL
    }
    const w = c.err(c.ioctl(fd, c.IOC_SETFLAGS, &fsflags));
    if (w != 0) c.msg(w, "setting flags on {s}", .{name});

    if (g.recursive and dir) {
        for (c.dirNames(name)) |entry| {
            if (std.mem.eql(u8, entry, ".") or std.mem.eql(u8, entry, "..")) continue;
            const path = std.fmt.allocPrint(c.A, "{s}/{s}", .{ name, entry }) catch continue;
            defer c.A.free(path);
            changeAttributes(path, g);
        }
    }
}

pub fn chattrMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));

    var g = State{};
    var i: usize = 1;
    while (true) {
        if (i >= args.len) c.usageDie(name);
        const a = args[i];
        if (a.len == 0 or (a[0] != '-' and a[0] != '+' and a[0] != '=')) break;
        i = decodeArg(args, i, &g, name);
    }
    if (i >= args.len) c.usageDie(name);

    if ((g.flags & OPT_SET) != 0 and (g.flags & (OPT_ADD | OPT_REM)) != 0)
        c.plainDie("= is incompatible with - and +", .{});
    if ((g.rf & g.af) != 0) c.plainDie("can't set and unset a flag", .{});
    if (g.flags == 0) c.plainDie("must use -v, -p, =, - or +", .{});

    while (i < args.len) : (i += 1) changeAttributes(args[i], &g);
    return 0;
}
