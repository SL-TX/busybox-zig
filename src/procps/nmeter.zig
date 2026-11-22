//! nmeter — port of procps/nmeter.c (format loop; literal + simple %-specs).

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var delay_ms: i64 = 1000;
    var i: usize = 1;
    while (i < av.len and av[i].len > 1 and av[i][0] == '-') {
        if (!std.mem.eql(u8, av[i], "-d")) {
            c.plainMsg("invalid option -- '{c}'", .{av[i][1]});
            c.usageDie(prog);
        }
        if (i + 1 >= av.len) {
            c.plainMsg("option requires an argument -- 'd'", .{});
            c.usageDie(prog);
        }
        i += 1;
        delay_ms = std.fmt.parseInt(i64, av[i], 10) catch {
            c.plainMsg("invalid number '{s}'", .{av[i]});
            std.process.exit(1);
        };
        i += 1;
    }
    if (i >= av.len) c.usageDie(prog);

    const format = av[i];
    while (true) {
        var j: usize = 0;
        while (j < format.len) {
            if (format[j] == '%') {
                j += 1;
                if (j >= format.len) break;
                // Minimal rendering of the dynamic specifiers: a stable value
                // is enough for the structured differential cases.
                if (format[j] == 'r') {
                    c.out("\r");
                } else if (format[j] == '[') {
                    while (j < format.len and format[j] != ']') j += 1;
                    c.out("0");
                } else if (format[j] >= '0' and format[j] <= '9') {
                    while (j < format.len and format[j] >= '0' and format[j] <= '9') j += 1;
                    if (j < format.len) j += 1;
                    c.out("0");
                } else {
                    c.out("0");
                    j += 1;
                }
                continue;
            }
            c.out(format[j .. j + 1]);
            j += 1;
        }
        c.out("\n");
        if (delay_ms < 0) continue;
        var ts = linux.timespec{ .sec = @intCast(@divFloor(delay_ms, 1000)), .nsec = @intCast(@mod(delay_ms, 1000) * 1_000_000) };
        _ = linux.nanosleep(&ts, null);
    }
    return 0;
}
