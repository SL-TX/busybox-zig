//! insmod (modprobe-small flavour) — read a module image and call init_module.

const std = @import("std");
const c = @import("common.zig");

const SYS_INIT_MODULE: std.os.linux.SYS = @enumFromInt(105); // x86_64 __NR_init_module

pub fn moderror(e: c_int) []const u8 {
    return switch (e) {
        8 => "invalid module format",
        2 => "unknown symbol in module or invalid parameter",
        3 => "module has wrong symbol version",
        22 => "invalid parameter",
        else => c.strerror(e),
    };
}

pub fn insmodMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = c.opts(name, args, "^qrfsvwb");
    if (o.args.len == 0) c.usageDie(name);
    const filename = o.args[0];

    const image = c.readFile(filename) orelse {
        const r = c.readFileErr(filename);
        c.msg(if (r.errno != 0) r.errno else 2, "can't read '{s}'", .{filename});
        return 1;
    };
    var options: std.ArrayList(u8) = .empty;
    for (args[o.index..]) |extra| {
        options.appendSlice(c.A, " \"") catch {};
        options.appendSlice(c.A, extra) catch {};
        options.appendSlice(c.A, "\"") catch {};
    }
    const opts_z = c.zstr(options.items) catch return 1;
    defer c.A.free(opts_z);
    const rc = std.os.linux.syscall3(SYS_INIT_MODULE, @intFromPtr(image.ptr), image.len, @intFromPtr(opts_z.ptr));
    const e = c.err(rc);
    if (e != 0) {
        c.plain("can't insert '{s}': {s}", .{ filename, moderror(e) });
        return 1;
    }
    return 0;
}
