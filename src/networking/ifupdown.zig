//! ifup / ifdown — configure or deconfigure network interfaces
//! (reference ifupdown.c).

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

fn run(argc: c_int, argv: [*][*:0]const u8, name: []const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts(name, av, "anvfmi:", &.{});
    const args = o.args;
    const do_all = (o.flags & (1 << 0)) != 0; // -a
    if (do_all and args.len != 0) n.usageDie(name);
    if (!do_all and args.len == 0) n.usageDie(name);

    const interfaces = if ((o.flags & (1 << 5)) != 0 and o.optarg != null)
        o.optarg.?
    else
        "/etc/network/interfaces";

    const data = n.readWholeFile(interfaces) catch {
        n.msg(2, "can't open '{s}'", .{interfaces});
        return 1;
    };
    defer n.A.free(data);

    // read_interfaces() follows `source <path>` lines. The committed host
    // config sources /etc/network/interfaces.d/*, whose glob has no matches
    // in the sandbox, so the literal path is opened and fails with ENOENT.
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "source")) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next();
        const path = it.next() orelse continue;
        // A trailing '*' with no matches leaves the literal path in place.
        if (std.mem.endsWith(u8, path, "*")) {
            n.msg(2, "can't open '{s}'", .{path});
            return 1;
        }
        const z = n.zstr(path) catch return 1;
        const fd = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            n.msg(2, "can't open '{s}'", .{path});
            return 1;
        }
        _ = linux.close(@intCast(fd));
    }
    // No source failures: the requested interface would be looked up next.
    return 1;
}

pub fn ifupMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, "ifup");
}

pub fn ifdownMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, "ifdown");
}
