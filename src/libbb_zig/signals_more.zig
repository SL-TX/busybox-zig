//! Signal-name lookup and signal-aware polling, ported from busybox
//! libbb/u_signal_names.c, libbb/safe_poll.c and libbb/poll_with_signals.c.

const std = @import("std");
const linux = std.os.linux;
const proc = @import("process.zig");

pub const Error = error{UnknownSignal};

const SignalName = struct { num: c_int, name: []const u8 };

// Values are the Linux/x86-64 signal numbers (matching the kernel ABI this
// libc-free build targets). Numeric names are accepted first, like busybox.
const signals = [_]SignalName{
    .{ .num = 0, .name = "EXIT" },
    .{ .num = 1, .name = "HUP" },
    .{ .num = 2, .name = "INT" },
    .{ .num = 3, .name = "QUIT" },
    .{ .num = 4, .name = "ILL" },
    .{ .num = 5, .name = "TRAP" },
    .{ .num = 6, .name = "ABRT" },
    .{ .num = 7, .name = "BUS" },
    .{ .num = 8, .name = "FPE" },
    .{ .num = 9, .name = "KILL" },
    .{ .num = 10, .name = "USR1" },
    .{ .num = 11, .name = "SEGV" },
    .{ .num = 12, .name = "USR2" },
    .{ .num = 13, .name = "PIPE" },
    .{ .num = 14, .name = "ALRM" },
    .{ .num = 15, .name = "TERM" },
    .{ .num = 16, .name = "STKFLT" },
    .{ .num = 17, .name = "CHLD" },
    .{ .num = 18, .name = "CONT" },
    .{ .num = 19, .name = "STOP" },
    .{ .num = 20, .name = "TSTP" },
    .{ .num = 21, .name = "TTIN" },
    .{ .num = 22, .name = "TTOU" },
    .{ .num = 23, .name = "URG" },
    .{ .num = 24, .name = "XCPU" },
    .{ .num = 25, .name = "XFSZ" },
    .{ .num = 26, .name = "VTALRM" },
    .{ .num = 27, .name = "PROF" },
    .{ .num = 28, .name = "WINCH" },
    .{ .num = 29, .name = "POLL" },
    .{ .num = 30, .name = "PWR" },
    .{ .num = 31, .name = "SYS" },
    .{ .num = 32, .name = "RTMIN" },
};

const rt_min: c_int = 32;
const rt_max: c_int = 64;

fn aliasNumber(name: []const u8) ?c_int {
    // Common aliases that do not have a dedicated slot in the name table.
    if (std.ascii.eqlIgnoreCase(name, "CLD")) return 17;
    if (std.ascii.eqlIgnoreCase(name, "IOT")) return 6;
    if (std.ascii.eqlIgnoreCase(name, "IO")) return 29;
    if (std.ascii.eqlIgnoreCase(name, "UNUSED")) return 31;
    return null;
}

/// Convert a signal name (optionally SIG-prefixed, case-insensitive), a
/// decimal number, or RTMIN/RTMAX with an offset into a signal number.
pub fn signalByName(name: []const u8) Error!c_int {
    if (name.len == 0) return Error.UnknownSignal;
    if (std.fmt.parseInt(c_int, name, 10)) |n| {
        if (n >= 0 and n <= 64) return n;
    } else |_| {}

    var n = name;
    if (n.len >= 3 and std.ascii.eqlIgnoreCase(n[0..3], "SIG")) n = n[3..];
    for (signals) |entry| {
        if (std.ascii.eqlIgnoreCase(n, entry.name)) return entry.num;
    }
    if (aliasNumber(n)) |num| return num;

    if (std.ascii.startsWithIgnoreCase(n, "RTMIN")) {
        if (n.len == 5) return rt_min;
        if (n[5] == '+' and n.len > 6) {
            if (std.fmt.parseInt(c_int, n[6..], 10)) |delta| {
                if (delta >= 0 and rt_min + delta <= rt_max) return rt_min + delta;
            } else |_| {}
        }
    } else if (std.ascii.startsWithIgnoreCase(n, "RTMAX")) {
        if (n.len == 5) return rt_max;
        if (n[5] == '-' and n.len > 6) {
            if (std.fmt.parseInt(c_int, n[6..], 10)) |delta| {
                if (delta >= 0 and rt_max - delta >= rt_min) return rt_max - delta;
            } else |_| {}
        }
    }
    return Error.UnknownSignal;
}

/// Reverse lookup; writes the decimal value into `buf` when there is no name.
pub fn signalName(sig: c_int, buf: []u8) []const u8 {
    for (signals) |entry| {
        if (entry.num == sig) return entry.name;
    }
    return std.fmt.bufPrint(buf, "{d}", .{sig}) catch "";
}

/// Set by signal handlers installed through `gotSignalHandler`. Polling
/// helpers use it to avoid the check-then-poll race described in busybox.
pub var got_signal: bool = false;

pub fn gotSignalHandler(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    got_signal = true;
}

pub const PollFn = *const fn (fds: [*]linux.pollfd, n: linux.nfds_t, timeout: i32) i32;

fn rawPoll(fds: [*]linux.pollfd, n: linux.nfds_t, timeout: i32) i32 {
    const rc = linux.poll(fds, n, timeout);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        proc.errno = @backingInt(e);
        return -1;
    }
    return @intCast(rc);
}

/// poll(2) with EINTR/ENOMEM retries. On retry the timeout is decremented so
/// the caller still observes an upper bound on the wait (as busybox does).
pub fn safePollWith(fds: []linux.pollfd, timeout: i32, poll_fn: PollFn) i32 {
    var remaining = timeout;
    while (true) {
        const n = poll_fn(fds.ptr, fds.len, remaining);
        if (n >= 0) return n;
        if (remaining > 0) remaining -= 1;
        if (proc.errno == @backingInt(linux.E.INTR)) continue;
        if (proc.errno == @backingInt(linux.E.NOMEM)) continue;
        return n;
    }
}

pub fn safePoll(fds: []linux.pollfd, timeout: i32) i32 {
    return safePollWith(fds, timeout, rawPoll);
}

/// Signal-race-free poll of one descriptor. Returns -1 with errno EINTR when
/// a signal was already caught, otherwise ppoll()s with the original mask.
pub fn checkGotSignalAndPoll(pfd: *[1]linux.pollfd, timeout: i32) i32 {
    if (got_signal) {
        proc.errno = @backingInt(linux.E.INTR);
        return -1;
    }
    var tv: linux.timespec = undefined;
    var tvp: ?*linux.timespec = null;
    if (timeout >= 0) {
        tv = .{
            .sec = @divTrunc(timeout, 1000),
            .nsec = @as(i64, @mod(timeout, 1000)) * 1_000_000,
        };
        tvp = &tv;
    }

    const all = linux.sigfillset();
    var orig_mask: linux.sigset_t = undefined;
    // Block every signal across the check and the ppoll, then restore.
    _ = linux.sigprocmask(linux.SIG.BLOCK, &all, &orig_mask);
    if (got_signal) {
        _ = linux.sigprocmask(linux.SIG.SETMASK, &orig_mask, null);
        proc.errno = @backingInt(linux.E.INTR);
        return -1;
    }
    const rc = linux.ppoll(pfd, 1, tvp, &orig_mask);
    _ = linux.sigprocmask(linux.SIG.SETMASK, &orig_mask, null);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        proc.errno = @backingInt(e);
        return -1;
    }
    return @intCast(rc);
}

/// Generalisation of busybox's one-fd check_got_signal_and_poll().
pub fn pollWithSignals(fds: []linux.pollfd, timeout: i32) i32 {
    if (fds.len == 1) return checkGotSignalAndPoll(@ptrCast(fds.ptr), timeout);
    if (got_signal) {
        proc.errno = @backingInt(linux.E.INTR);
        return -1;
    }
    var tv: linux.timespec = undefined;
    var tvp: ?*linux.timespec = null;
    if (timeout >= 0) {
        tv = .{
            .sec = @divTrunc(timeout, 1000),
            .nsec = @as(i64, @mod(timeout, 1000)) * 1_000_000,
        };
        tvp = &tv;
    }
    const all = linux.sigfillset();
    var orig_mask: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, &all, &orig_mask);
    if (got_signal) {
        _ = linux.sigprocmask(linux.SIG.SETMASK, &orig_mask, null);
        proc.errno = @backingInt(linux.E.INTR);
        return -1;
    }
    const rc = linux.ppoll(fds.ptr, fds.len, tvp, &orig_mask);
    _ = linux.sigprocmask(linux.SIG.SETMASK, &orig_mask, null);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        proc.errno = @backingInt(e);
        return -1;
    }
    return @intCast(rc);
}
