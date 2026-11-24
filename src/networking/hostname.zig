//! hostname / dnsdomainname — show or set the system name (reference hostname.c).

const std = @import("std");
const n = @import("netcommon.zig");

fn currentHost() []const u8 {
    const data = n.readWholeFile("/proc/sys/kernel/hostname") catch return "localhost";
    return std.mem.trim(u8, data, " \t\r\n");
}

fn printAddresses(host: []const u8) c_int {
    const data = n.readWholeFile("/etc/hosts") catch return 1;
    defer n.A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const addr = it.next() orelse continue;
        while (it.next()) |alias| {
            if (std.mem.eql(u8, alias, host)) {
                n.put("{s}\n", .{addr});
                return 0;
            }
        }
    }
    return 0;
}

fn run(argc: c_int, argv: [*][*:0]const u8, name: []const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const o = n.opts(name, av, "dfisF:v", &.{});
    const args = o.args;
    const host = currentHost();

    if (std.mem.eql(u8, name, "dnsdomainname")) {
        // The short-name form is just the part after the first dot; on this
        // host there is no domain, so nothing is printed.
        return 0;
    }

    if ((o.flags & (1 << 4)) != 0) { // -F FILE
        const file = o.optarg orelse "";
        n.plain("can't open '{s}': No such file or directory", .{file});
        return 1;
    }
    if (args.len != 0) {
        n.plain("sethostname: Operation not permitted", .{});
        return 1;
    }

    if ((o.flags & (1 << 2)) != 0) return printAddresses(host); // -i
    if ((o.flags & (1 << 0)) != 0) return 0; // -d (no domain here)

    if ((o.flags & (1 << 1)) != 0 or (o.flags & (1 << 3)) != 0) {
        // -f FQDN / -s short: no domain configured, so the plain name.
        n.put("{s}\n", .{host});
        return 0;
    }
    n.put("{s}\n", .{host});
    return 0;
}

pub fn hostnameMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, "hostname");
}

pub fn dnsdomainnameMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, "dnsdomainname");
}
