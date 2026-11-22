//! mim — run a script from a Makefile-like specification file.
//! The reference is a scripted applet: it generates a shell `case` statement
//! from the spec file and feeds it to `sh -s`. This implements that protocol
//! directly so the multicall binary reproduces it without external awk.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

const Target = struct {
    name: []const u8,
    commands: std.ArrayList([]const u8),
};

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("mim");

    var mimfile: []const u8 = "Mimfile";
    var first: usize = 1;
    if (args.len >= 3 and std.mem.eql(u8, args[1], "-f")) {
        mimfile = args[2];
        first = 3;
    }
    const rest = args[first..];

    var en: c_int = 0;
    const content = c.readFile(a, mimfile, &en) orelse {
        c.printfErr("mim: line 7: can't open {s}: {s}\n", .{ mimfile, if (en == 2) "no such file" else "permission denied" });
        return 1;
    };
    defer a.free(content);

    var targets: std.ArrayList(Target) = .empty;
    defer {
        for (targets.items) |*t| {
            for (t.commands.items) |cmd| a.free(cmd);
            t.commands.deinit(a);
        }
        targets.deinit(a);
    }
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[line.len - 1] == ':') {
            const name = line[0 .. line.len - 1];
            targets.append(a, .{ .name = a.dupe(u8, name) catch return 1, .commands = .empty }) catch return 1;
            continue;
        }
        if (targets.items.len == 0) continue;
        var cmd = line;
        while (cmd.len > 0 and (cmd[0] == ' ' or cmd[0] == '\t')) cmd = cmd[1..];
        if (cmd.len == 0) continue;
        targets.items[targets.items.len - 1].commands.append(a, a.dupe(u8, cmd) catch return 1) catch return 1;
    }

    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(a);
    if (rest.len == 0 and targets.items.len > 0) {
        script.appendSlice(a, "[ $# -eq 0 ] && set -- \"") catch return 1;
        script.appendSlice(a, targets.items[0].name) catch return 1;
        script.appendSlice(a, "\"\n") catch return 1;
    }
    script.appendSlice(a, "TARGET=\"$1\"\nshift\ncase \"$TARGET\" in\n") catch return 1;
    for (targets.items) |t| {
        script.appendSlice(a, t.name) catch return 1;
        script.appendSlice(a, ")\n") catch return 1;
        for (t.commands.items) |cmd| {
            script.appendSlice(a, cmd) catch return 1;
            script.append(a, '\n') catch return 1;
        }
        script.appendSlice(a, ";;\n") catch return 1;
    }
    script.appendSlice(a, "*)\necho \"Unknown command $TARGET\"\nexit 1\n;;\nesac\n") catch return 1;

    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return 1;
    const rd: linux.fd_t = fds[0];
    const wr: linux.fd_t = fds[1];
    const child = bb.process.fork() catch return 1;
    if (child == 0) {
        _ = linux.close(wr);
        _ = linux.dup2(rd, 0);
        _ = linux.close(rd);
        const pathvar = bb.env.get("PATH") orelse "/bin:/usr/bin";
        const sh_path = @import("main.zig").resolveCommand(a, "sh", pathvar) catch std.process.exit(127) orelse std.process.exit(127);
        const sh = c.zstr(a, sh_path) catch std.process.exit(127);
        const sharg = c.zstr(a, "sh") catch std.process.exit(127);
        const sflag = c.zstr(a, "-s") catch std.process.exit(127);
        var av: [2 + 64]?[*:0]const u8 = undefined;
        av[0] = sharg;
        av[1] = sflag;
        var n: usize = 2;
        for (rest) |word| {
            if (n >= av.len) break;
            av[n] = c.zstr(a, word) catch std.process.exit(1);
            n += 1;
        }
        av[n] = null;
        const envp_z = a.allocSentinel(?[*:0]const u8, 0, null) catch std.process.exit(1);
        bb.process.execve(sh, @ptrCast(&av), envp_z) catch std.process.exit(127);
        std.process.exit(127);
    }
    _ = linux.close(rd);
    var off: usize = 0;
    while (off < script.items.len) {
        const wrote = linux.write(wr, script.items.ptr + off, script.items.len - off);
        if (linux.errno(wrote) != .SUCCESS or wrote == 0) break;
        off += wrote;
    }
    _ = linux.close(wr);
    var status: i32 = 0;
    _ = bb.process.waitpid(child, &status, 0) catch return 1;
    if ((status & 0x7f) != 0) return @intCast(128 + (status & 0x7f));
    return @intCast((status >> 8) & 0xff);
}
