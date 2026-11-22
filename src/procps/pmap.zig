//! pmap — port of procps/pmap.c (smaps reader + summary).

const std = @import("std");
const c = @import("common.zig");

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var quiet = false;
    var detail = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                'q' => quiet = true,
                'x' => detail = true,
                else => {
                    c.plainMsg("invalid option -- '{c}'", .{tok[j]});
                    c.usageDie(prog);
                },
            }
        }
    }
    if (i >= av.len) c.usageDie(prog);

    var errors: c_int = 0;
    while (i < av.len) : (i += 1) {
        const pid = std.fmt.parseInt(i32, av[i], 10) catch {
            c.plainMsg("invalid number '{s}'", .{av[i]});
            errors = 42;
            continue;
        };
        const cmd = c.cmdline(a, @intCast(pid)) orelse {
            errors = 42;
            continue;
        };
        defer a.free(cmd);
        c.printfOut("{d}: {s}\n", .{ pid, cmd });

        if (!quiet and detail) {
            c.out("Address           Kbytes     PSS   Dirty    Swap  Mode  Mapping\n");
        }
        const smaps_path = c.procPath(a, @intCast(pid), "smaps") catch {
            errors = 42;
            continue;
        };
        defer a.free(smaps_path);
        const data = c.readFile(a, smaps_path) orelse {
            errors = 42;
            continue;
        };
        defer a.free(data);

        var total_kb: u64 = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOfScalar(u8, line, '-') == null) continue;
            var it = std.mem.tokenizeAny(u8, line, " \t");
            const range = it.next() orelse continue;
            const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
            const start = std.fmt.parseInt(u64, range[0..dash], 16) catch continue;
            const end = std.fmt.parseInt(u64, range[dash + 1 ..], 16) catch continue;
            const kb = (end - start) / 1024;
            total_kb += kb;
            if (detail) {
                const mode = it.next() orelse "";
                const name: []const u8 = "  [ anon ]";
                c.printfOut("{s} {d: >7}K  {s}  {s}\n", .{ range, kb, mode, name });
            }
        }
        if (!quiet) {
            if (detail) {
                c.printfOut("--------  ------  ------  ------  ------\ntotal kB {d: >7}       0       0       0\n", .{total_kb});
            } else {
                c.printfOut(" total {d}K\n", .{total_kb});
            }
        }
    }
    return errors;
}
