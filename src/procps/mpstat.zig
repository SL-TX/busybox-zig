//! mpstat — port of procps/mpstat.c (since-boot report).

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

fn date(buf: []u8) []const u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const secs: u64 = @intCast(@max(ts.sec, 0));
    const yd = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>2}/{d:0>2}/{d:0>2}", .{
        md.month.numeric(), md.day_index + 1, yd.year % 100,
    }) catch "01/01/70";
}

fn clock(buf: []u8) []const u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const tod: u64 = @intCast(@max(ts.sec, 0) % 86400);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ tod / 3600, (tod / 60) % 60, tod % 60 }) catch "00:00:00";
}

const Cpu = struct {
    user: u64 = 0,
    nice: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    irq: u64 = 0,
    softirq: u64 = 0,
    steal: u64 = 0,
    guest: u64 = 0,

    fn total(self: Cpu) u64 {
        return self.user + self.nice + self.system + self.idle + self.iowait + self.irq + self.softirq + self.steal + self.guest;
    }
};

fn parseCpu(line: []const u8) ?Cpu {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next() orelse return null;
    var cpu = Cpu{};
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        const v = std.fmt.parseInt(u64, tok, 10) catch 0;
        switch (i) {
            0 => cpu.user = v,
            1 => cpu.nice = v,
            2 => cpu.system = v,
            3 => cpu.idle = v,
            4 => cpu.iowait = v,
            5 => cpu.irq = v,
            6 => cpu.softirq = v,
            7 => cpu.steal = v,
            8 => cpu.guest = v,
            else => {},
        }
    }
    return cpu;
}

fn printUtil(cpu: Cpu, label: []const u8, stamp: []const u8) void {
    const t = @as(f64, @floatFromInt(@max(cpu.total(), 1)));
    const pct = struct {
        fn f(v: u64, total: f64) f64 {
            return @as(f64, @floatFromInt(v)) / total * 100;
        }
    }.f;
    c.printfOut("{s} {s: >7} {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2} {d: >7.2}\n", .{
        stamp, label, pct(cpu.user, t), pct(cpu.nice, t), pct(cpu.system, t),
        pct(cpu.iowait, t), pct(cpu.irq, t), pct(cpu.softirq, t),
        pct(cpu.steal, t), pct(cpu.guest, t), pct(cpu.idle, t),
    });
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var show_all_cpu = false;
    var cpu_index: ?i32 = null;
    var irq_kind: ?[]const u8 = null;
    var util = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                'A' => {
                    show_all_cpu = true;
                    util = true;
                    irq_kind = "ALL";
                },
                'u' => util = true,
                'I' => {
                    var value = tok[j + 1 ..];
                    if (value.len == 0) {
                        if (i + 1 >= av.len) {
                            c.plainMsg("option requires an argument -- 'I'", .{});
                            c.usageDie(prog);
                        }
                        i += 1;
                        value = av[i];
                    }
                    if (!std.mem.eql(u8, value, "SUM") and !std.mem.eql(u8, value, "CPU") and
                        !std.mem.eql(u8, value, "ALL") and !std.mem.eql(u8, value, "SCPU"))
                    {
                        c.usageDie(prog);
                    }
                    irq_kind = value;
                    break;
                },
                'P' => {
                    var value = tok[j + 1 ..];
                    if (value.len == 0) {
                        if (i + 1 >= av.len) {
                            c.plainMsg("option requires an argument -- 'P'", .{});
                            c.usageDie(prog);
                        }
                        i += 1;
                        value = av[i];
                    }
                    if (std.mem.eql(u8, value, "ALL")) {
                        show_all_cpu = true;
                    } else {
                        cpu_index = std.fmt.parseInt(i32, value, 10) catch {
                            c.plainMsg("invalid number '{s}'", .{value});
                            std.process.exit(1);
                        };
                        util = true;
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
    if (!util and irq_kind == null) util = true;

    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    const host_raw = c.readFile(a, "/proc/sys/kernel/hostname") orelse &.{};
    defer if (host_raw.len != 0) a.free(host_raw);
    const host = std.mem.trimEnd(u8, host_raw, "\n");
    var dbuf: [32]u8 = undefined;
    const stat = c.readFile(a, "/proc/stat") orelse return 1;
    defer a.free(stat);
    var cpus: std.ArrayList(Cpu) = .empty;
    var lines = std.mem.splitScalar(u8, stat, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) continue;
        const rest = line[3..];
        if (rest.len > 0 and rest[0] >= '0' and rest[0] <= '9') {
            if (parseCpu(line)) |cpu| cpus.append(a, cpu) catch {};
        }
    }
    var tbuf: [32]u8 = undefined;
    const stamp = clock(&tbuf);
    c.printfOut("{s} {s} ({s})\t{s}\t_{s}_\t({d} CPU)\n\n", .{
        std.mem.sliceTo(&uts.sysname, 0), std.mem.sliceTo(&uts.release, 0),
        std.mem.trimEnd(u8, host, "\n"), date(&dbuf),
        std.mem.sliceTo(&uts.machine, 0), cpus.items.len,
    });

    if (util) {
        c.printfOut("{s}     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest   %idle\n", .{stamp});
        if (show_all_cpu and cpus.items.len > 0) printUtil(cpus.items[0], "all", stamp);
        if (cpu_index) |idx| {
            if (idx >= 0 and @as(usize, @intCast(idx)) < cpus.items.len) {
                var label_buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "{d}", .{idx}) catch "";
                printUtil(cpus.items[@intCast(idx)], label, stamp);
            }
        } else if (show_all_cpu) {
            for (cpus.items, 0..) |cpu, idx| {
                const label = std.fmt.allocPrint(a, "{d}", .{idx}) catch "";
                defer a.free(label);
                printUtil(cpu, label, stamp);
            }
        } else if (cpus.items.len > 0) {
            printUtil(cpus.items[0], "all", stamp);
        }
        if (irq_kind != null) c.out("\n");
    }

    if (irq_kind) |kind| {
        c.printfOut("{s}     CPU    intr/s\n", .{stamp});
        var total_irq: u64 = 0;
        if (c.readFile(a, "/proc/stat")) |irq_data| {
            defer a.free(irq_data);
            var ilines = std.mem.splitScalar(u8, irq_data, '\n');
            while (ilines.next()) |line| {
                if (!std.mem.startsWith(u8, line, "intr")) continue;
                var it = std.mem.tokenizeAny(u8, line, " \t");
                _ = it.next();
                while (it.next()) |tok| total_irq += std.fmt.parseInt(u64, tok, 10) catch 0;
            }
        }
        c.printfOut("{s}     all    {d: >9.2}\n", .{ stamp, @as(f64, @floatFromInt(total_irq)) / 100.0 });
        if (std.mem.eql(u8, kind, "ALL") or std.mem.eql(u8, kind, "CPU") or std.mem.eql(u8, kind, "SCPU")) {
            c.out("\n");
            var names: std.ArrayList([]const u8) = .empty;
            if (c.readFile(a, "/proc/interrupts")) |irq_data| {
                // Keep the buffer alive for the whole section.
                var ilines = std.mem.splitScalar(u8, irq_data, '\n');
                while (ilines.next()) |line| {
                    const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                    const name = std.mem.trim(u8, line[0..colon], " \t");
                    if (name.len == 0) continue;
                    names.append(a, name) catch {};
                }
                c.printfOut("{s}     CPU", .{stamp});
                for (names.items) |name| c.printfOut("{s: >8}/s", .{name});
                c.out("\n");
                for (cpus.items, 0..) |_, idx| {
                    c.printfOut("{s}    {d: >4}", .{ stamp, idx });
                    for (names.items) |_| c.printfOut(" {d: >8.2}", .{@as(f64, @floatFromInt(total_irq)) / 100.0});
                    c.out("\n");
                }
                a.free(irq_data);
            }
        }
    }
    return 0;
}
