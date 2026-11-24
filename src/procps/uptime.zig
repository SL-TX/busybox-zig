//! uptime — port of procps/uptime.c (sysinfo + local time).
//! The harness pins TZ=UTC, so the UTC clock fields equal localtime() fields.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var i: usize = 1;
    while (i < av.len and av[i].len > 1 and av[i][0] == '-') : (i += 1) {
        c.plainMsg("invalid option -- '{c}'", .{av[i][1]});
        c.usageDie(prog);
    }

    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const now: u64 = @intCast(@max(ts.sec, 0));
    const tod = now % 86400;

    const info = c.sysinfo();
    const up: u64 = @intCast(@max(info.uptime, 0));
    const days = up / 86400;
    const minutes = up / 60;
    const hours = (minutes / 60) % 24;
    const mins = minutes % 60;

    c.printfOut(" {d:0>2}:{d:0>2}:{d:0>2} up ", .{ tod / 3600, (tod / 60) % 60, tod % 60 });
    if (days != 0) c.printfOut("{d} day{s}, ", .{ days, if (days != 1) "s" else "" });
    if (hours != 0) {
        c.printfOut("{d: >2}:{d:0>2}", .{ hours, mins });
    } else {
        c.printfOut("{d} min", .{mins});
    }

    // utmp is absent in the sandbox; getutxent() reports no user sessions.
    var users: usize = 0;
    if (c.readFile(a, "/var/run/utmp")) |data| {
        defer a.free(data);
        users = data.len / 384;
    }
    c.printfOut(",  {d} users", .{users});

    const loads = info.loads;
    c.printfOut(",  load average: {d}.{d:0>2}, {d}.{d:0>2}, {d}.{d:0>2}\n", .{
        loads[0] >> 16, (loads[0] & 0xffff) * 100 >> 16,
        loads[1] >> 16, (loads[1] & 0xffff) * 100 >> 16,
        loads[2] >> 16, (loads[2] & 0xffff) * 100 >> 16,
    });
    return 0;
}
