//! pidof — port of procps/pidof.c using the Task 15 find_pid_by_name helper.

const std = @import("std");
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var single = false;
    var omit: [64]i32 = undefined;
    var omit_count: usize = 0;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                's' => single = true,
                'o' => {
                    var value = tok[j + 1 ..];
                    if (value.len == 0) {
                        if (i + 1 >= av.len) {
                            c.plainMsg("option requires an argument -- 'o'", .{});
                            c.usageDie(prog);
                        }
                        i += 1;
                        value = av[i];
                    }
                    if (omit_count < omit.len) {
                        const val = if (std.mem.eql(u8, value, "%PPID")) @as(i32, @intCast(@import("std").os.linux.getppid())) else std.fmt.parseInt(i32, value, 10) catch {
                            c.plainMsg("invalid number '{s}'", .{value});
                            std.process.exit(1);
                        };
                        omit[omit_count] = val;
                        omit_count += 1;
                    }
                    break;
                },
                else => {
                    c.plainMsg("invalid option -- '{c}'", .{tok[j]});
                    c.usageDie(prog);
                },
            }
        }
    }

    var first = true;
    while (i < av.len) : (i += 1) {
        const list = c.findPidByName(av[i]);
        defer c.freePids(list);
        // findPidByName yields ascending PIDs; GNU pidof prints newest first.
        var n: usize = list.len;
        while (n > 0) {
            n -= 1;
            const pid = list[n];
            var skip = false;
            for (omit[0..omit_count]) |o| {
                if (o == pid) skip = true;
            }
            if (skip) continue;
            if (first) {
                c.printfOut("{d}", .{pid});
                first = false;
            } else {
                c.printfOut(" {d}", .{pid});
            }
            if (single) break;
        }
    }
    if (!first) c.out("\n");
    return if (first) 1 else 0;
}
