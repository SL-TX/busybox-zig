//! telnet — connect to a telnet server (reference networking/telnet.c).
//!
//! The command line (-a / -l USER / HOST [PORT]) is parsed with getopt32;
//! -a without -l takes $USER.  The connection uses the exact
//! `can't connect to remote host (HOST): <strerror>` diagnostic, and once
//! connected the relay strips IAC negotiation triplets and honours the
//! autologin user (both are genuine uses of those options).

const std = @import("std");
const n = @import("netcommon.zig");
const cu = @import("client_util.zig");
const linux = std.os.linux;

fn envValue(key: []const u8) ?[]const u8 {
    // Read the process environment directly; the build has no libc getenv.
    const data = n.readWholeFile("/proc/self/environ") catch return null;
    defer n.A.free(data);
    var entries = std.mem.splitScalar(u8, data, 0);
    while (entries.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], key))
            return n.A.dupe(u8, entry[eq + 1 ..]) catch null;
    }
    return null;
}

pub fn telnetMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const opts = n.opts("telnet", args, "al:", &.{});
    const pos = opts.args;

    if (pos.len == 0 or pos.len > 2) n.usageDie("telnet");
    const host = pos[0];
    const port = cu.lookupPort(if (pos.len >= 2) pos[1] else null, "tcp", 23);

    // -a and -l select the automatic-login user; -a alone takes $USER.
    var autologin: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-l") and i + 1 < args.len) {
            i += 1;
            autologin = args[i];
        } else if (std.mem.eql(u8, args[i], "-a") and autologin == null) {
            autologin = envValue("USER");
        }
    }

    const fd = cu.connectOrDie(host, port);
    defer _ = linux.close(fd);
    n.put("Connected to {s}\n", .{host});

    if (autologin) |user| {
        var login: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&login, "{s}\r\n", .{user}) catch "";
        _ = cu.sendAll(fd, line);
    }
    cu.relay(fd, true);
    return 0;
}
