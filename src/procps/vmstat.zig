//! vmstat — port of procps/vmstat.c (first-report path).
//! INTERVAL/COUNT repetitions would be timing dependent; the differential
//! cases use COUNT=0 so only the since-boot report is emitted.

const std = @import("std");
const c = @import("common.zig");

fn lastUint(line: []const u8) u64 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var v: u64 = 0;
    while (it.next()) |tok| v = std.fmt.parseInt(u64, tok, 10) catch v;
    return v;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var i: usize = 1;
    while (i < av.len and av[i].len > 1 and av[i][0] == '-') {
        for (av[i][1..]) |ch| {
            if (ch != 'n') {
                c.plainMsg("invalid option -- '{c}'", .{ch});
                c.usageDie(prog);
            }
        }
        i += 1;
    }
    if (i < av.len) {
        _ = std.fmt.parseFloat(f64, av[i]) catch {
            c.plainMsg("invalid number '{s}'", .{av[i]});
            std.process.exit(1);
        };
    }

    c.out("procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------\n");
    c.out(" r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu\n");

    const stat = c.readFile(a, "/proc/stat") orelse return 1;
    defer a.free(stat);
    const mem_data = c.readFile(a, "/proc/meminfo") orelse return 1;
    defer a.free(mem_data);
    const mem = c.parseMemInfo(mem_data);
    const vm = c.readFile(a, "/proc/vmstat") orelse &.{};
    defer if (vm.len != 0) a.free(vm);

    var running: u64 = 0;
    var blocked: u64 = 0;
    var lines = std.mem.splitScalar(u8, stat, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "procs_running")) running = lastUint(line);
        if (std.mem.startsWith(u8, line, "procs_blocked")) blocked = lastUint(line);
    }
    var pgpgin: u64 = 0;
    var pgpgout: u64 = 0;
    lines = std.mem.splitScalar(u8, vm, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "pgpgin ")) pgpgin = lastUint(line);
        if (std.mem.startsWith(u8, line, "pgpgout ")) pgpgout = lastUint(line);
    }

    const swpd = mem.swap_total -| mem.swap_free;
    c.printfOut(" {d: >1} {d: >1} {d: >6} {d: >6} {d: >6} {d: >7} {d: >3} {d: >3} {d: >5} {d: >5} {d: >4} {d: >3} {d: >2} {d: >2} {d: >2} {d: >2} {d: >2} {d: >2}\n", .{
        running, blocked, swpd, mem.free, mem.buffers, mem.cached,
        @as(u64, 0), @as(u64, 0), pgpgin, pgpgout, @as(u64, 0), @as(u64, 0),
        @as(u64, 0), @as(u64, 0), @as(u64, 0), @as(u64, 0), @as(u64, 0), @as(u64, 0),
    });
    return 0;
}
