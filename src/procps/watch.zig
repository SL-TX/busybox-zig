//! watch — port of procps/watch.c.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

fn durationMs(s: []const u8) ?i64 {
    const value = std.fmt.parseFloat(f64, s) catch return null;
    return @intFromFloat(value * 1000);
}

fn sleepMs(ms: i64) void {
    if (ms <= 0) return;
    var ts = linux.timespec{ .sec = @intCast(@divFloor(ms, 1000)), .nsec = @intCast(@mod(ms, 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

fn execChild(a: std.mem.Allocator, argv: []const []const u8, via_shell: bool) void {
    const envp = a.allocSentinel(?[*:0]const u8, 0, null) catch std.process.exit(127);
    var zargs: [64]?[*:0]const u8 = undefined;
    if (via_shell) {
        zargs[0] = c.zstr(a, "/bin/sh") catch std.process.exit(127);
        zargs[1] = c.zstr(a, "-c") catch std.process.exit(127);
        zargs[2] = c.zstr(a, argv[0]) catch std.process.exit(127);
        zargs[3] = null;
    } else {
        const path = if (std.mem.eql(u8, argv[0], "sh")) "/bin/sh" else argv[0];
        zargs[0] = c.zstr(a, path) catch std.process.exit(127);
        for (argv[1..], 1..) |arg, idx| {
            if (idx >= zargs.len - 1) break;
            zargs[idx] = c.zstr(a, arg) catch std.process.exit(127);
        }
        zargs[@min(argv.len, zargs.len - 1)] = null;
    }
    _ = bb.process.execve(zargs[0].?, @ptrCast(&zargs), envp) catch std.process.exit(127);
    std.process.exit(127);
}

fn spawn(a: std.mem.Allocator, argv: []const []const u8, via_shell: bool) void {
    const pid = bb.process.fork() catch return;
    if (pid == 0) execChild(a, argv, via_shell);
    var status: i32 = 0;
    _ = bb.process.waitpid(pid, &status, 0) catch {};
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    var period_ms: i64 = 2000;
    var no_header = false;
    var direct = false;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            switch (tok[j]) {
                't' => no_header = true,
                'x' => direct = true,
                'n' => {
                    var value = tok[j + 1 ..];
                    if (value.len == 0) {
                        if (i + 1 >= av.len) {
                            c.plainMsg("option requires an argument -- 'n'", .{});
                            c.usageDie(prog);
                        }
                        i += 1;
                        value = av[i];
                    }
                    period_ms = durationMs(value) orelse {
                        c.plainMsg("invalid number '{s}'", .{value});
                        std.process.exit(1);
                    };
                    break;
                },
                else => {
                    c.plainMsg("invalid option -- '{c}'", .{tok[j]});
                    c.usageDie(prog);
                },
            }
        }
    }
    if (i >= av.len) c.usageDie(prog);

    var cmd: std.ArrayList(u8) = .empty;
    for (av[i..], 0..) |arg, idx| {
        if (idx != 0) cmd.append(a, ' ') catch {};
        cmd.appendSlice(a, arg) catch {};
    }
    const cmd_text = cmd.toOwnedSlice(a) catch return 1;
    defer a.free(cmd_text);
    const period_secs = @as(f64, @floatFromInt(period_ms)) / 1000.0;

    while (true) {
        c.out("\x1b[H\x1b[J");
        if (!no_header) {
            var ts: linux.timespec = undefined;
            _ = linux.clock_gettime(.REALTIME, &ts);
            const secs: u64 = @intCast(@max(ts.sec, 0));
            const yd = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay().calculateYearDay();
            const md = yd.calculateMonthDay();
            const tod = secs % 86400;
            var stamp: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&stamp, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
                yd.year, md.month.numeric(), md.day_index + 1, tod / 3600, (tod / 60) % 60, tod % 60,
            }) catch "";
            const time_len: usize = 20; // sizeof("1234-67-90 23:56:89")
            const width: usize = 80;
            var header: [512]u8 = undefined;
            const head = std.fmt.bufPrint(&header, "Every {d:.1}s: {s}", .{ period_secs, cmd_text }) catch return 1;
            const padding = (width - time_len) -| @min(width - time_len, head.len);
            c.out(head);
            var p: usize = 0;
            while (p < padding) : (p += 1) c.out(" ");
            c.printfOut("{s}\n\n", .{text});
        }
        spawn(a, av[i..], !direct);
        sleepMs(period_ms);
    }
    return 0;
}
