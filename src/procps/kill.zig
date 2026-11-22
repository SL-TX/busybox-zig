//! kill / killall / killall5 — port of procps/kill.c.
//! The three applets share one main in BusyBox; the split files here keep one
//! source file per applet while delegating to the common implementation.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

pub const Kind = enum { kill, killall, killall5 };

fn isKind(kind: Kind, want: Kind) bool {
    return kind == want;
}

fn name(argv0: []const u8) []const u8 {
    return std.fs.path.basename(argv0);
}

fn usage(prog: []const u8) noreturn {
    c.usageDie(prog);
}

/// Shared implementation of procps/kill.c:kill_main().
pub fn killMain(kind: Kind, argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = name(av[0]);
    c.setName(prog);

    var signo: c_int = 15; // SIGTERM
    var quiet = false;
    var i: usize = 1;

    if (i >= av.len or av[i].len == 0 or av[i][0] != '-') {
        return doIt(kind, prog, av, i, signo, quiet);
    }

    // kill -l [sig...]
    if (av[i].len >= 2 and av[i][1] == 'l' and av[i][2 .. av[i].len].len == 0) {
        i += 1;
        if (i >= av.len) {
            c.printSignames();
            return 0;
        }
        while (i < av.len) : (i += 1) {
            const arg = av[i];
            if (c.allDigits(arg)) {
                const n = std.fmt.parseInt(c_int, arg, 10) catch {
                    c.plainMsg("unknown signal '{s}'", .{arg});
                    return 1;
                };
                var buf: [32]u8 = undefined;
                c.printfOut("{s}\n", .{c.signame(n & 0x7f, &buf)});
            } else {
                const sig = c.getSignum(arg) orelse {
                    c.plainMsg("unknown signal '{s}'", .{arg});
                    return 1;
                };
                c.printfOut("{d}\n", .{sig});
            }
        }
        return 0;
    }

    // killall -q
    if (isKind(kind, .killall) and av[i].len == 2 and av[i][1] == 'q') {
        quiet = true;
        i += 1;
        if (i >= av.len) usage(prog);
        if (av[i].len == 0 or av[i][0] != '-') return doIt(kind, prog, av, i, signo, quiet);
    }

    if (!isKind(kind, .killall5) and eq("--", av[i])) {
        i += 1;
        return doIt(kind, prog, av, i, signo, quiet);
    }
    var arg = av[i][1..]; // skip '-'
    if (isKind(kind, .killall5) and arg.len > 0 and arg[0] == 'o') {
        return doIt(kind, prog, av, i + 1, signo, quiet);
    }
    if (arg.len > 0 and arg[0] == 's') {
        arg = arg[1..];
        if (arg.len == 0 and i + 1 < av.len) {
            i += 1;
            arg = av[i];
        }
    }
    signo = c.getSignum(arg) orelse {
        c.plainMsg("bad signal name '{s}'", .{arg});
        return 1;
    };
    i += 1;
    return doIt(kind, prog, av, i, signo, quiet);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn doIt(kind: Kind, prog: []const u8, av: []const []const u8, start: usize, signo: c_int, quiet: bool) c_int {
    _ = prog;
    const a = std.heap.page_allocator;
    var errors: c_int = 0;

    if (isKind(kind, .killall5)) {
        // Faithful port of the System V loop. Kept for completeness; the
        // differential suite deliberately never reaches this path because it
        // would signal real host processes (hard rule in Task 17).
        errors = 2;
        const sid = linux.getsid(0);
        if (signo != 19 and signo != 18) _ = linux.kill(-1, @enumFromInt(19));
        const pids = c.listPids(a, "/proc") catch return 2;
        defer a.free(pids);
        for (pids) |pid| {
            const stat_path = c.procPath(a, pid, "stat") catch continue;
            defer a.free(stat_path);
            const data = c.readFile(a, stat_path) orelse continue;
            defer a.free(data);
            const close = std.mem.lastIndexOfScalar(u8, data, ')') orelse continue;
            var it = std.mem.tokenizeAny(u8, data[close + 1 ..], " \t");
            _ = it.next() orelse continue; // state
            _ = it.next() orelse continue; // ppid
            _ = it.next() orelse continue; // pgrp
            const session = std.fmt.parseInt(i32, it.next() orelse continue, 10) catch continue;
            if (session == @as(i32, @intCast(sid)) or session == 0 or pid == 1 or pid == linux.getpid()) continue;
            var omit = false;
            var j: usize = start;
            while (j < av.len) : (j += 1) {
                const tok = av[j];
                if (tok.len < 2 or tok[0] != '-' or tok[1] != 'o') {
                    c.plainMsg("bad option '{s}'", .{tok});
                    errors = 1;
                    omit = true;
                    break;
                }
                var num = tok[2..];
                if (num.len == 0 and j + 1 < av.len) {
                    j += 1;
                    num = av[j];
                }
                const o = std.fmt.parseInt(i32, num, 10) catch {
                    c.plainMsg("invalid number '{s}'", .{num});
                    errors = 1;
                    omit = true;
                    break;
                };
                if (pid == o) omit = true;
            }
            if (!omit) {
                _ = linux.kill(pid, @enumFromInt(@as(u32, @bitCast(signo))));
                errors = 0;
            }
        }
        if (signo != 19 and signo != 18) _ = linux.kill(-1, @enumFromInt(18));
        return errors;
    }

    if (start >= av.len) {
        c.plainMsg("you need to specify whom to kill", .{});
        return 1;
    }

    if (isKind(kind, .killall)) {
        var j: usize = start;
        while (j < av.len) : (j += 1) {
            const proc_name = av[j];
            const pids = c.findPidByName(proc_name);
            defer c.freePids(pids);
            if (pids.len == 0) {
                errors += 1;
                if (!quiet) c.plainMsg("{s}: no process killed", .{proc_name});
                continue;
            }
            for (pids) |pid| {
                if (pid == linux.getpid()) continue;
                const rc = linux.kill(pid, @enumFromInt(@as(u32, @bitCast(signo))));
                if (linux.errno(rc) != .SUCCESS) {
                    errors += 1;
                    if (!quiet) c.errorMsg(@intFromEnum(linux.errno(rc)), "can't kill pid {d}", .{pid});
                }
            }
        }
        return errors;
    }

    // kill: all remaining arguments are numeric PIDs.
    var j: usize = start;
    while (j < av.len) : (j += 1) {
        const pid = std.fmt.parseInt(i32, av[j], 10) catch {
            c.plainMsg("invalid number '{s}'", .{av[j]});
            errors += 1;
            continue;
        };
        const rc = linux.kill(pid, @enumFromInt(@as(u32, @bitCast(signo))));
        if (linux.errno(rc) != .SUCCESS) {
            c.errorMsg(@intFromEnum(linux.errno(rc)), "can't kill pid {d}", .{pid});
            errors += 1;
        }
    }
    return errors;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return killMain(.kill, argc, argv);
}
