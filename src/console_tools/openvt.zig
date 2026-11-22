//! openvt: start a command on a (usually new) virtual terminal.
//!
//! In an unprivileged container there is no VT fd and /dev/ttyN cannot be
//! opened, so every case stops at the reference's two documented error paths
//! ("can't find open VT" or "can't open '/dev/ttyN': ..."). The activation and
//! spawn path is still implemented for completeness.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const console = @import("libbb_zig").term.console;

const VT_GETSTATE: u32 = 0x5603;
const VT_OPENQRY: u32 = 0x5602;
const VT_ACTIVATE: u32 = 0x5606;
const VT_WAITACTIVE: u32 = 0x5607;
const VT_DISALLOCATE: u32 = 0x5608;
const TIOCSCTTY: u32 = 0x540E;

fn avFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return c.argsFrom(std.heap.page_allocator, argv, argc) catch &.{};
}

fn optionArg(av: []const []const u8, ch: u8) ?[]const u8 {
    for (av, 0..) |a, i| {
        if (a.len >= 2 and a[0] == '-' and a[1] == ch) {
            if (a.len > 2) return a[2..];
            if (i + 1 < av.len) return av[i + 1];
        }
    }
    return null;
}

fn isVtFd(fd: linux.fd_t) bool {
    var stat: extern struct { v_active: u16, v_signal: u16, v_state: u16 } = undefined;
    return linux.errno(linux.ioctl(fd, VT_GETSTATE, @intFromPtr(&stat))) == .SUCCESS;
}

fn findFreeVtno() u32 {
    for (0..3) |fd| {
        if (isVtFd(@intCast(fd))) return queryFreeVt(@intCast(fd));
    }
    const z = "/dev/console";
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    if (linux.errno(rc) == .SUCCESS) {
        const fd: linux.fd_t = @intCast(rc);
        if (isVtFd(fd)) return queryFreeVt(fd);
        _ = linux.close(fd);
    }
    c.plainDie("can't find open VT", .{});
}

fn queryFreeVt(fd: linux.fd_t) u32 {
    var vtno: c_int = 0;
    const rc = linux.ioctl(fd, VT_OPENQRY, @intFromPtr(&vtno));
    if (linux.errno(rc) != .SUCCESS or vtno <= 0) {
        c.errorMsgAndDie(@intFromEnum(linux.errno(rc)), "can't find open VT", .{});
    }
    return @intCast(vtno);
}

pub fn openvtMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setName("openvt");
    const av = avFrom(argv, argc);
    const o = c.opts("openvt", av, "+c:wslfv", &.{});
    const flags = o.flags;
    const vtno: u32 = if ((flags & 1) != 0)
        c.xatouRange(optionArg(av, 'c') orelse "", 1, 63)
    else
        findFreeVtno();

    var vtname: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&vtname, "/dev/tty{d}", .{vtno}) catch unreachable;
    const fd = c.openRdWr(path);
    var vtstat: extern struct { v_active: u16, v_signal: u16, v_state: u16 } = undefined;
    c.xioctl(fd, VT_GETSTATE, @intFromPtr(&vtstat), "VT_GETSTATE");

    if ((flags & 4) != 0) {
        c.xioctl(fd, VT_ACTIVATE, vtno, "VT_ACTIVATE");
        c.xioctl(fd, VT_WAITACTIVE, vtno, "VT_WAITACTIVE");
    }

    var prog: []const u8 = "sh";
    if (o.args.len > 0) {
        prog = o.args[0];
    } else if (@import("libbb_zig").env.get("SHELL")) |shell| {
        if (shell.len > 0) prog = shell;
    }

    _ = linux.dup2(fd, 1);
    _ = linux.dup2(fd, 2);

    const pid_raw = linux.fork();
    if (linux.errno(pid_raw) != .SUCCESS) c.errorMsgAndDie(@intFromEnum(linux.errno(pid_raw)), "fork", .{});
    const pid: linux.pid_t = @intCast(pid_raw);
    if (pid == 0) {
        _ = linux.syscall0(.setsid);
        _ = linux.ioctl(0, TIOCSCTTY, 0);
        var exec_args: [65]?[*:0]const u8 = @splat(null);
        const count = @min(o.args.len + 1, exec_args.len - 1);
        const pz = c.zstr(std.heap.page_allocator, prog) catch linux.exit(127);
        exec_args[0] = pz.ptr;
        for (o.args[1..count], 1..) |arg, i| {
            const az = c.zstr(std.heap.page_allocator, arg) catch linux.exit(127);
            exec_args[i] = az.ptr;
        }
        exec_args[count] = null;
        const env_mod = @import("libbb_zig").env;
        const envp = env_mod.buildEnvp(std.heap.page_allocator) catch &[_]?[*:0]const u8{null};
        _ = linux.execve(pz.ptr, @ptrCast(&exec_args), env_mod.envpPtr(@constCast(envp)));
        linux.exit(127);
    }

    if ((flags & 2) != 0) {
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        if ((flags & 4) != 0) {
            c.xioctl(fd, VT_ACTIVATE, vtstat.v_active, "VT_ACTIVATE");
            c.xioctl(fd, VT_DISALLOCATE, vtno, "VT_DISALLOCATE");
        }
    }
    return 0;
}
