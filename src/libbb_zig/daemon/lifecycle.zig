//! Shared daemon lifecycle helpers (Task 25), ported from busybox
//! libbb/vfork_daemon_rexec.c, libbb/pidfile.c, libbb/signals.c and the
//! log-rotation logic in sysklogd/syslogd.c.
//!
//! Every process-level side effect is reached through `Ops` so the orchestration
//! can be unit tested without daemonizing, forking or signalling the test runner.
//! Filesystem helpers only touch paths the caller explicitly supplies.

const std = @import("std");
const io = @import("../io.zig");
const proc = @import("../process.zig");
const signals = @import("../signals_more.zig");

pub const DaemonFlags = struct {
    chdir_root: bool = false,
    devnull_stdio: bool = false,
    close_extra_fds: bool = false,
    only_sanitize: bool = false,
};

/// Injectable system calls for `daemonize`.
pub const Ops = struct {
    fork: *const fn () i32,
    setsid: *const fn () i32,
    chdir: *const fn ([]const u8) i32,
    open_devnull: *const fn () i32,
    dup2: *const fn (i32, i32) i32,
    close: *const fn (i32) void,
};

pub const DaemonError = error{
    ForkFailed,
    SetsidFailed,
    ChdirFailed,
    OpenFailed,
    Dup2Failed,
};

pub const DaemonResult = struct {
    is_parent: bool,
    pid: i32,
};

/// Fork, setsid and sanitize stdio following busybox's daemonize sequence.
/// The parent returns `is_parent = true`; the child returns false.
pub fn daemonize(flags: DaemonFlags, ops: Ops) DaemonError!DaemonResult {
    if (flags.chdir_root) {
        if (ops.chdir("/") < 0) return error.ChdirFailed;
    }

    const null_fd = ops.open_devnull();
    if (null_fd < 0) return error.OpenFailed;

    // Ensure 0,1,2 are open even before we fork (busybox's sanitize step).
    if (!flags.devnull_stdio) {
        var fd = null_fd;
        while (fd < 2) {
            const next = ops.dup2(fd, fd + 1);
            if (next < 0) return error.Dup2Failed;
            fd = next;
        }
    }

    if (!flags.only_sanitize) {
        const pid = ops.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid > 0) return .{ .is_parent = true, .pid = pid };
        if (ops.setsid() < 0) return error.SetsidFailed;
    }

    if (flags.devnull_stdio) {
        if (ops.dup2(null_fd, 0) < 0) return error.Dup2Failed;
        if (ops.dup2(null_fd, 1) < 0) return error.Dup2Failed;
        if (ops.dup2(null_fd, 2) < 0) return error.Dup2Failed;
    }

    var fd = null_fd;
    while (fd > 2) {
        ops.close(fd);
        fd -= 1;
        if (!flags.close_extra_fds) break;
    }

    return .{ .is_parent = false, .pid = 0 };
}

/// Render a pidfile body ("PID\n") into `buf`.
pub fn formatPidfile(pid: i32, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}\n", .{pid});
}

/// Write a pidfile at `path`. Returns true when the target is a regular file
/// (busybox does not consider /dev/null a pidfile).
pub fn writePidfile(path: []const u8, pid: i32) !bool {
    if (path.len == 0) return error.InvalidPath;
    const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer io.close(fd) catch {};

    const st = try io.fstat(fd);
    const wrote = (st.mode & std.os.linux.S.IFMT) == std.os.linux.S.IFREG;
    if (wrote) {
        var buf: [32]u8 = undefined;
        const body = try formatPidfile(pid, &buf);
        try io.writeAll(fd, body);
    }
    return wrote;
}

pub fn removePidfile(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    try io.unlink(path);
}

pub const system_pidfile_dir = "/var/run";

pub const writeSystemPidfile_requires = Requirement{
    .capability = .root,
    .reason = "writing a pidfile under /var/run requires root",
};

/// Build the conventional `/var/run/<name>.pid` path without touching it.
pub fn systemPidfilePath(name: []const u8, buf: []u8) ![]const u8 {
    if (name.len == 0) return error.InvalidName;
    return std.fmt.bufPrint(buf, "{s}/{s}.pid", .{ system_pidfile_dir, name });
}

/// Privileged variant: only callable after the runtime capability check.
pub fn writeSystemPidfile(name: []const u8, pid: i32) !void {
    try checkRequirement(writeSystemPidfile_requires);
    var buf: [256]u8 = undefined;
    const path = try systemPidfilePath(name, &buf);
    _ = try writePidfile(path, pid);
}

pub const SignalError = error{ InvalidSignal, UnknownSignal };

/// A compact bitmap of signals 1..64, used to describe handler sets without
/// installing any handler in the test process.
pub const SignalSet = struct {
    mask: u64 = 0,

    pub fn add(self: *SignalSet, sig: u8) SignalError!void {
        if (sig == 0 or sig > 64) return error.InvalidSignal;
        self.mask |= @as(u64, 1) << @intCast(sig - 1);
    }

    pub fn remove(self: *SignalSet, sig: u8) SignalError!void {
        if (sig == 0 or sig > 64) return error.InvalidSignal;
        self.mask &= ~(@as(u64, 1) << @intCast(sig - 1));
    }

    pub fn contains(self: SignalSet, sig: u8) bool {
        if (sig == 0 or sig > 64) return false;
        return (self.mask & (@as(u64, 1) << @intCast(sig - 1))) != 0;
    }

    pub fn count(self: SignalSet) usize {
        return @popCount(self.mask);
    }

    /// Build a set from SIG-prefixed or plain signal names.
    pub fn fromNames(names: []const []const u8) SignalError!SignalSet {
        var set = SignalSet{};
        for (names) |name| {
            const num = try signals.signalByName(name);
            if (num <= 0 or num > 64) return error.InvalidSignal;
            try set.add(@intCast(num));
        }
        return set;
    }
};

/// Tracks the most recently recorded signal, as busybox's bb_got_signal does,
/// but as a value type so tests never touch a process-global.
pub const SignalState = struct {
    got: u8 = 0,

    pub fn record(self: *SignalState, sig: u8) void {
        self.got = sig;
    }
    pub fn clear(self: *SignalState) void {
        self.got = 0;
    }
};

pub const RotationConfig = struct {
    max_size: u64 = 0,
    keep: u8 = 1,
};

pub const RotationPlan = struct {
    rotate: bool,
    shifts: usize,
    delete_oldest: bool,
};

/// Decide whether a log file has crossed its rotation threshold.
pub fn planRotation(cfg: RotationConfig, current_size: u64) RotationPlan {
    if (cfg.max_size == 0 or current_size < cfg.max_size) {
        return .{ .rotate = false, .shifts = 0, .delete_oldest = false };
    }
    return .{
        .rotate = true,
        .shifts = if (cfg.keep == 0) 0 else @as(usize, cfg.keep) - 1,
        .delete_oldest = true,
    };
}

pub fn rotationName(allocator: std.mem.Allocator, base: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{d}", .{ base, index });
}

/// Rotate `base` into `base.1` .. `base.keep`, discarding the oldest. The base
/// file is left absent so callers can reopen it, matching syslogd behaviour.
pub fn rotateFiles(allocator: std.mem.Allocator, base: []const u8, keep: u8) !void {
    if (keep == 0) {
        io.unlink(base) catch |e| switch (e) {
            error.SyscallFailed => {},
            else => return e,
        };
        const one = try rotationName(allocator, base, 1);
        defer allocator.free(one);
        io.unlink(one) catch {};
        return;
    }

    const oldest = try rotationName(allocator, base, keep);
    defer allocator.free(oldest);
    io.unlink(oldest) catch {};

    var i: usize = keep;
    while (i > 1) {
        i -= 1;
        const from = try rotationName(allocator, base, i);
        defer allocator.free(from);
        const to = try rotationName(allocator, base, i + 1);
        defer allocator.free(to);
        if (io.isRegular(from)) try io.rename(from, to);
    }
    if (io.isRegular(base)) {
        const first = try rotationName(allocator, base, 1);
        defer allocator.free(first);
        try io.rename(base, first);
    }
}

// --- Privileged operations ---------------------------------------------------

pub const Capability = enum { root, cap_net_admin, cap_sys_admin };

pub const Requirement = struct {
    capability: Capability,
    reason: []const u8,
    /// Optional injectable predicate; production helpers leave it null so the
    /// effective uid is consulted at runtime.
    check: ?*const fn () bool = null,
};

pub fn hasCapability(cap: Capability) bool {
    _ = cap;
    // This libc-free build relies on the effective uid for all capabilities;
    // finer-grained capget() probing is delegated to privileged applets.
    return proc.geteuid() == 0;
}

pub fn checkRequirement(req: Requirement) error{InsufficientPrivileges}!void {
    const ok = if (req.check) |predicate| predicate() else hasCapability(req.capability);
    if (!ok) return error.InsufficientPrivileges;
}
