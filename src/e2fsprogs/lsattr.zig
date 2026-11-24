//! lsattr — list ext2 file attributes. Mirrors e2fsprogs/lsattr.c.

const std = @import("std");
const c = @import("common.zig");
const flags = @import("flags.zig");
const linux = c.linux;

const OPT_RECUR: u32 = 1 << 0;
const OPT_ALL: u32 = 1 << 1;
const OPT_DIRS_OPT: u32 = 1 << 2;
const OPT_PF_LONG: u32 = 1 << 3;
const OPT_GENERATION: u32 = 1 << 4;
const OPT_PROJID: u32 = 1 << 5;

fn on(o: c.Options, bit: u32) bool {
    return (o.flags & bit) != 0;
}

fn listAttributes(name: []const u8, o: c.Options) void {
    const p = c.zstr(name) catch return;
    defer c.A.free(p);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .NOFOLLOW = true }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.msg(c.err(rc), "can't open '{s}'", .{name});
        return;
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    if (on(o, OPT_PROJID)) {
        var fsx: [28]u8 = std.mem.zeroes([28]u8);
        const r = c.err(c.ioctl(fd, c.IOC_FSGETXATTR, &fsx));
        if (r != 0) {
            c.msg(r, "reading {s}", .{name});
            return;
        }
        c.put("{d: >5} ", .{std.mem.readInt(u32, fsx[12..16], .little)});
    }
    if (on(o, OPT_GENERATION)) {
        var gen: u32 = 0;
        const r = c.err(c.ioctl(fd, c.IOC_GETVERSION, &gen));
        if (r != 0) {
            c.msg(r, "reading {s}", .{name});
            return;
        }
        c.put("{d: <10} ", .{gen});
    }
    var fsflags: u32 = 0;
    const r = c.err(c.ioctl(fd, c.IOC_GETFLAGS, &fsflags));
    if (r != 0) {
        c.msg(r, "reading {s}", .{name});
        return;
    }

    if (on(o, OPT_PF_LONG)) {
        c.put("{s: <28} ", .{name});
        var b: [512]u8 = undefined;
        c.out(flags.renderLong(fsflags, &b));
        c.out("\n");
    } else {
        var b: [32]u8 = undefined;
        c.out(flags.render(fsflags, &b));
        c.put(" {s}\n", .{name});
    }
}

fn dirProc(dir_name: []const u8, entry: []const u8, o: c.Options) void {
    const path = std.fmt.allocPrint(c.A, "{s}/{s}", .{ dir_name, entry }) catch return;
    defer c.A.free(path);

    const se = c.lstatErr(path);
    if (se != 0) {
        c.msg(se, "can't stat '{s}'", .{path});
        return;
    }
    const hidden = entry.len > 0 and entry[0] == '.';
    if (hidden and !on(o, OPT_ALL)) return;

    if (c.isReg(path) or c.isLnk(path) or c.isDir(path)) listAttributes(path, o);
    if (c.isDir(path) and on(o, OPT_RECUR) and
        !std.mem.eql(u8, entry, ".") and !std.mem.eql(u8, entry, ".."))
    {
        c.put("\n{s}:\n", .{path});
        for (c.dirNames(path)) |child| dirProc(path, child, o);
        c.out("\n");
    }
}

fn lsattrArgs(name: []const u8, o: c.Options) void {
    const se = c.lstatErr(name);
    if (se != 0) {
        c.msg(se, "can't stat '{s}'", .{name});
        return;
    }
    if (c.isDir(name) and !on(o, OPT_DIRS_OPT)) {
        for (c.dirNames(name)) |entry| dirProc(name, entry, o);
    } else listAttributes(name, o);
}

pub fn lsattrMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = c.opts(name, args, "Radlvp");
    var rest = args[o.index..];
    if (rest.len == 0) rest = &[_][]const u8{"."};
    for (rest) |path| lsattrArgs(path, o);
    return 0;
}
