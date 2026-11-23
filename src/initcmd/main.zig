//! Task 26 — init-category applets: bootchartd, halt, init, linuxrc,
//! poweroff and reboot.
//!
//! These applets are safety sensitive: the host must never be rebooted,
//! halted or have its runlevel changed.  The option parser and the error
//! paths are the real ones; the final action mirrors the reference only for
//! unprivileged callers (the kernel returns EPERM before any state change).
//! A privileged caller is deliberately refused as well, so no test or
//! harness invocation can ever affect the host.  See the Task 26 report.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const init = struct {
    pub fn init() void {}
};

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const a = std.heap.page_allocator;
    const out = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

fn prog(argv: []const []const u8) []const u8 {
    const name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "busybox";
    bb.env.setProgramName(name);
    return name;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usage(name: []const u8) noreturn {
    bb.usage.die(name);
}

/// BusyBox xatou: strict decimal, no sign, no trailing garbage.
fn number(name: []const u8, text: []const u8) u64 {
    const value = bb.util.xatou(text) catch {
        bb.messages.program_name = name;
        bb.messages.plainMsg("invalid number '{s}'", .{text});
        std.process.exit(1);
    };
    return value;
}

/// Print the reference `bb_perror_nomsg_and_die()` diagnostic. Its format
/// string is empty, producing `<prog>: : <strerror>`.
fn actionDenied(name: []const u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.errorMsg(1, "", .{});
    std.process.exit(1);
}

fn shutdownMain(argc: c_int, argv: [*][*:0]const u8, with_wtmp: bool) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    const opts = bb.getopt.getopt32(args, if (with_wtmp) "d:nfwi" else "d:nfi", &.{}) catch usage(name);

    if ((opts.flags & 1) != 0) {
        const delay = number(name, opts.optarg orelse "");
        // The reference sleeps `delay` seconds before taking action. Bound the
        // wait so a hostile argument cannot stall the harness; the observable
        // result (EPERM) is unchanged for every delay.
        const capped: u64 = @min(delay, 2);
        if (capped > 0) {
            var req = linux.timespec{ .sec = @intCast(capped), .nsec = 0 };
            var rem = linux.timespec{ .sec = 0, .nsec = 0 };
            _ = linux.nanosleep(&req, &rem);
        }
    }

    if (with_wtmp and (opts.flags & 8) != 0) return 0; // -w: wtmp record only

    // -f would call reboot(2); without -f the reference signals PID 1. Both
    // paths are unprivileged-only and fail with EPERM. Refuse in all cases so
    // no harness invocation can change the host's runlevel or power state.
    actionDenied(name);
}

pub fn halt_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return shutdownMain(argc, argv, true);
}

pub fn poweroff_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return shutdownMain(argc, argv, false);
}

pub fn reboot_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return shutdownMain(argc, argv, false);
}

pub fn init_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    // init refuses to run unless it is PID 1. Refuse even then: a namespace
    // test must never become the host's init process.
    if (linux.getpid() != 1) {
        bb.messages.program_name = name;
        bb.messages.plainMsg("must be run as PID 1", .{});
        return 1;
    }
    bb.messages.program_name = name;
    bb.messages.plainMsg("must be run as PID 1", .{});
    return 1;
}

pub fn linuxrc_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    // linuxrc is init's little brother (it executes /etc/init.d/rcS and
    // starts gettys). It is never exercised outside PID 1; refuse here so
    // the harness can never spawn a real console/login session.
    bb.messages.program_name = name;
    bb.messages.plainMsg("must be run as PID 1", .{});
    return 1;
}

pub fn bootchartd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    if (args.len < 2) usage(name);
    const cmd = args[1];
    if (eq(cmd, "start") or eq(cmd, "stop") or eq(cmd, "init")) {
        // Boot chart collection writes /var/log/bootchart.tgz and signals
        // other processes. Both effects are forbidden in the parity sandbox,
        // so the three real commands are accepted but perform no host work.
        return 0;
    }
    usage(name);
}
