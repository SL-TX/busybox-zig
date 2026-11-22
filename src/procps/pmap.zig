//! pmap — port of procps/pmap.c (smaps reader, per-mapping details and totals).

const std = @import("std");
const c = @import("common.zig");

const Record = struct {
    range: []const u8,
    mode: []const u8,
    name: []const u8,
    size: u64 = 0,
    pss: u64 = 0,
    private_dirty: u64 = 0,
    swap: u64 = 0,
};

fn field(line: []const u8, key: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    var it = std.mem.tokenizeAny(u8, line[key.len..], " \t");
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, tok, 10) catch null;
}

fn readSmaps(a: std.mem.Allocator, pid: i32, records: *std.ArrayList(Record), total: *Record) bool {
    const path = c.procPath(a, pid, "smaps") catch return false;
    defer a.free(path);
    const data = c.readFile(a, path) orelse return false;
    defer a.free(data);

    var current: ?Record = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (field(line, "Pss:")) |v| {
            if (current) |*r| r.pss = v;
            total.pss += v;
            continue;
        }
        if (field(line, "Private_Dirty:")) |v| {
            if (current) |*r| r.private_dirty = v;
            total.private_dirty += v;
            continue;
        }
        if (field(line, "Swap:")) |v| {
            if (current) |*r| r.swap = v;
            total.swap += v;
            continue;
        }
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        _ = std.fmt.parseInt(u64, line[0..dash], 16) catch continue;
        if (current) |r| records.append(a, r) catch {};
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const range = it.next() orelse continue;
        const mode = it.next() orelse "";
        // Skip offset, dev, inode; the rest (if any) is the mapping name.
        var p: usize = 0;
        while (p < 3) : (p += 1) _ = it.next();
        var name: []const u8 = "  [ anon ]";
        if (it.next()) |first_name| {
            const nl = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
            const start = @intFromPtr(first_name.ptr) - @intFromPtr(line.ptr);
            if (start < nl) name = line[start..nl];
        }
        const endpos = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start_addr = std.fmt.parseInt(u64, range[0..endpos], 16) catch continue;
        const end_addr = std.fmt.parseInt(u64, range[endpos + 1 ..], 16) catch continue;
        const kb = (end_addr - start_addr) / 1024;
        total.size += kb;
        current = .{
            .range = a.dupe(u8, range) catch range,
            .mode = a.dupe(u8, mode) catch mode,
            .name = a.dupe(u8, name) catch name,
            .size = kb,
        };
    }
    if (current) |r| records.append(a, r) catch {};
    return true;
}

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
        for (tok[1..]) |ch| switch (ch) {
            'q' => quiet = true,
            'x' => detail = true,
            else => {
                c.plainMsg("invalid option -- '{c}'", .{ch});
                c.usageDie(prog);
            },
        };
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

        if (!quiet and detail) c.out("Address\t\t  Kbytes     PSS   Dirty    Swap  Mode  Mapping\n");
        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(a);
        var total = Record{ .range = "", .mode = "", .name = "" };
        if (!readSmaps(a, pid, &records, &total)) {
            errors = 42;
            continue;
        }
        if (detail) {
            for (records.items) |r| {
                const dash = std.mem.indexOfScalar(u8, r.range, '-') orelse continue;
                const start_addr = std.fmt.parseInt(u64, r.range[0..dash], 16) catch continue;
                c.printfOut("{x:0>16} {d: >7} {d: >7} {d: >7} {d: >7}  {s: <5} {s}\n", .{
                    start_addr, r.size, r.pss, r.private_dirty, r.swap, r.mode, r.name,
                });
            }
        }
        if (!quiet) {
            if (detail) {
                c.out("----------------  ------  ------  ------  ------\n");
                c.printfOut("total kB {d: >16} {d: >7} {d: >7} {d: >7}\n", .{
                    total.size, total.pss, total.private_dirty, total.swap,
                });
            } else {
                c.printfOut(" total {d}K\n", .{total.size});
            }
        }
    }
    return errors;
}
