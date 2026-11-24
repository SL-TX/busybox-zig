//! Local process spawning used by ssl_client -e / ssl_server PROG.
//! BusyBox runs PROG with its stdin/stdout wired to a pair of pipes; the TLS
//! engine then encrypts/decrypts the bytes crossing those pipes.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const A = std.heap.page_allocator;

pub const Spawned = struct {
    to_wr: linux.fd_t,
    from_rd: linux.fd_t,
};

fn z(s: []const u8) [*:0]const u8 {
    const p = std.mem.concatWithSentinel(A, u8, &.{s}, 0) catch linux.exit(127);
    return p.ptr;
}

fn childExec(argv: []const []const u8) noreturn {
    var resolved: []const u8 = argv[0];
    if (std.mem.indexOfScalar(u8, argv[0], '/') == null) {
        const path = bb.env.get("PATH") orelse "/usr/bin:/bin";
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const cand = std.fmt.allocPrint(A, "{s}/{s}", .{ dir, argv[0] }) catch continue;
            const pz = z(cand);
            const rc = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(rc) == .SUCCESS) {
                _ = linux.close(@intCast(rc));
                resolved = cand;
                break;
            }
        }
    }
    const args = A.alloc(?[*:0]const u8, argv.len + 1) catch linux.exit(127);
    for (argv, 0..) |arg, i| args[i] = z(arg);
    args[argv.len] = null;
    const envp = bb.env.buildEnvp(A) catch linux.exit(127);
    _ = linux.execve(z(resolved), @ptrCast(args.ptr), bb.env.envpPtr(envp));
    linux.exit(127);
}

pub fn spawn(argv: []const []const u8) !Spawned {
    var to: [2]linux.fd_t = undefined;
    var from: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&to, .{})) != .SUCCESS) return error.PipeFailed;
    if (linux.errno(linux.pipe2(&from, .{})) != .SUCCESS) return error.PipeFailed;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.close(to[1]);
        _ = linux.close(from[0]);
        _ = linux.dup2(to[0], 0);
        _ = linux.dup2(from[1], 1);
        if (to[0] > 1) _ = linux.close(to[0]);
        if (from[1] > 1) _ = linux.close(from[1]);
        childExec(argv);
    }
    _ = linux.close(to[0]);
    _ = linux.close(from[1]);
    return .{ .to_wr = to[1], .from_rd = from[0] };
}
