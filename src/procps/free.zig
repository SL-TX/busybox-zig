//! free — port of procps/free.c (sysinfo + /proc/meminfo).

const std = @import("std");
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var unit: u64 = 1 << 10;
    if (av.len > 1 and av[1].len > 1 and av[1][0] == '-') {
        switch (av[1][1]) {
            'b' => unit = 1,
            'k' => unit = 1 << 10,
            'm' => unit = 1 << 20,
            'g' => unit = 1 << 30,
            'h' => unit = 0,
            else => c.usageDie(prog),
        }
    }

    c.out("       ");
    inline for (.{ "total", "used", "free", "shared", "buff/cache", "available" }) |name| {
        c.printfOut("{s: >12}", .{name});
    }
    c.out("\nMem:   ");

    const info = c.sysinfo();
    const mem_unit: u64 = if (info.mem_unit != 0) info.mem_unit else 1;
    const data = c.readFile(a, "/proc/meminfo") orelse return 1;
    defer a.free(data);
    const mem = c.parseMemInfo(data);

    const to_bytes = struct {
        fn f(kb: u64, mu: u64) u64 {
            return (kb * 1024) / mu;
        }
    }.f;
    const cached = to_bytes(mem.cached, mem_unit) + info.bufferram + to_bytes(mem.reclaimable, mem_unit);
    const cached_plus_free = cached + info.freeram;
    const available = to_bytes(mem.available, mem_unit);

    var buf: [64]u8 = undefined;
    const cells = [_]u64{
        info.totalram,
        info.totalram -| cached_plus_free,
        info.freeram,
        info.sharedram,
        cached,
        available,
    };
    for (cells) |cell| {
        c.printfOut("{s: >12}", .{c.humanReadable(cell, mem_unit, unit, &buf)});
    }
    c.out("\nSwap:  ");
    const swap = [_]u64{ info.totalswap, info.totalswap -| info.freeswap, info.freeswap };
    for (swap) |cell| {
        c.printfOut("{s: >12}", .{c.humanReadable(cell, mem_unit, unit, &buf)});
    }
    c.out("\n");

    if (!mem.seen_available) {
        c.out("-/+ buffers/cache: ");
        var buf2: [64]u8 = undefined;
        c.printfOut("{s: >12}{s: >12}\n", .{
            c.humanReadable(info.totalram -| cached_plus_free, mem_unit, unit, &buf),
            c.humanReadable(cached_plus_free, mem_unit, unit, &buf2),
        });
    }
    return 0;
}
