//! pwdx — port of procps/pwdx.c.

const std = @import("std");
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var i: usize = 1;
    while (i < av.len and av[i].len > 1 and av[i][0] == '-') : (i += 1) {
        const ch = av[i][1];
        c.plainMsg("invalid option -- '{c}'", .{ch});
        c.usageDie(prog);
    }
    if (i >= av.len) c.usageDie(prog);

    while (i < av.len) : (i += 1) {
        const original = av[i];
        var text = original;
        if (std.mem.startsWith(u8, text, "/proc/")) text = text[6..];
        const pid = std.fmt.parseInt(u32, text, 10) catch {
            c.plainMsg("invalid process id: '{s}'", .{text});
            std.process.exit(1);
        };
        const path = std.fmt.allocPrint(a, "/proc/{d}/cwd", .{pid}) catch return 1;
        defer a.free(path);
        var buf: [4096]u8 = undefined;
        if (c.readLink(path, &buf)) |target| {
            c.printfOut("{s}: {s}\n", .{ original, target });
        } else {
            c.printfOut("{s}: No such process\n", .{original});
        }
    }
    return 0;
}
