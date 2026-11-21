//! rmmod — unload modules by name (modprobe-small flavour).

const std = @import("std");
const c = @import("common.zig");

const SYS_DELETE_MODULE: std.os.linux.SYS = @enumFromInt(176); // x86_64 __NR_delete_module
const O_NONBLOCK: usize = 0x800;
const O_EXCL: usize = 0x80;
const O_TRUNC: usize = 0x200;

pub fn filename2modname(filename: []const u8, buf: []u8) []const u8 {
    const n = @min(buf.len, @min(filename.len, 63));
    var i: usize = 0;
    while (i < n and filename[i] != '.') : (i += 1) {
        buf[i] = if (filename[i] == '-') '_' else filename[i];
    }
    return buf[0..i];
}

pub fn rmmodMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = c.opts(name, args, "^qrfsvwb");
    if (o.args.len == 0) c.usageDie(name);

    var flags: usize = O_NONBLOCK | O_EXCL;
    if ((o.flags & (1 << 5)) != 0) flags &= ~O_NONBLOCK; // -w
    if ((o.flags & (1 << 2)) != 0) flags |= O_TRUNC; // -f
    const quiet = (o.flags & (1 << 0)) != 0; // -q

    for (args[o.index..]) |arg| {
        var modbuf: [64]u8 = undefined;
        const modname = filename2modname(std.fs.path.basename(arg), &modbuf);
        const p = c.zstr(modname) catch continue;
        defer c.A.free(p);
        const rc = std.os.linux.syscall2(SYS_DELETE_MODULE, @intFromPtr(p.ptr), flags);
        const e = c.err(rc);
        if (e != 0 and !quiet) c.msg(e, "remove '{s}'", .{modname});
    }
    return 0;
}
