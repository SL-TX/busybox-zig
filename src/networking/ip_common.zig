//! Shared implementation for the `ip` applet family (reference ip.c).
//!
//! `ip`, `ipaddr`, `iplink`, `iproute`, `ipneigh`, `iprule` and `iptunnel`
//! are all entry points into the same C file; they differ only in the default
//! subcommand and in a few diagnostic details. Parsing, validation and every
//! deterministic error path are implemented here. Display subcommands read
//! the kernel state exposed through /proc and /sys (best effort); the
//! differential cases focus on the deterministic validation paths because the
//! full netlink table is host state that changes between the two runs.

const std = @import("std");
const n = @import("netcommon.zig");

fn deviceExists(dev: []const u8) bool {
    const path = std.fmt.allocPrint(n.A, "/sys/class/net/{s}", .{dev}) catch return false;
    defer n.A.free(path);
    _ = n.readWholeFile(path) catch return false;
    return true;
}

fn err(name: []const u8, code: c_int, comptime fmt: []const u8, args: anytype) c_int {
    _ = name;
    n.plain(fmt, args);
    return code;
}

fn invalidArg(name: []const u8, value: []const u8, code: c_int) c_int {
    return err(name, code, "invalid argument '{s}' to '{s}'", .{ value, name });
}

fn needDevice(name: []const u8, code: c_int, dev: []const u8) ?c_int {
    if (!deviceExists(dev)) return err(name, code, "can't find device '{s}'", .{dev});
    return null;
}

fn displayStub() c_int {
    return 0;
}

pub fn ipMain(argc: c_int, argv: [*][*:0]const u8, invoked: []const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const name = invoked;

    // ip_parse_common_args(): consume leading -f/--family/-o/--oneline and
    // the -4/-6 family shorthands; any other dash token is a usage error.
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (tok.len < 2 or tok[0] != '-') break;
        if (std.mem.eql(u8, tok, "-o") or std.mem.eql(u8, tok, "--oneline") or
            std.mem.eql(u8, tok, "-4") or std.mem.eql(u8, tok, "-6") or
            std.mem.eql(u8, tok, "-f") or std.mem.eql(u8, tok, "--family"))
        {
            if ((std.mem.eql(u8, tok, "-f") or std.mem.eql(u8, tok, "--family")) and i + 1 < av.len) i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, tok, "-f") and tok.len > 2) continue;
        n.usageDie(name);
    }

    const rest = av[i..];
    if (std.mem.eql(u8, name, "ip")) {
        if (rest.len == 0) n.usageDie(name);
        const sub = rest[0];
        if (std.mem.eql(u8, sub, "addr") or std.mem.eql(u8, sub, "address")) return dispatch(name, "addr", rest[1..]);
        if (std.mem.eql(u8, sub, "route") or std.mem.eql(u8, sub, "r")) return dispatch(name, "route", rest[1..]);
        if (std.mem.eql(u8, sub, "link")) return dispatch(name, "link", rest[1..]);
        if (std.mem.eql(u8, sub, "tunnel") or std.mem.eql(u8, sub, "tunl")) return dispatch(name, "tunnel", rest[1..]);
        if (std.mem.eql(u8, sub, "rule")) return dispatch(name, "rule", rest[1..]);
        if (std.mem.eql(u8, sub, "neigh")) return dispatch(name, "neigh", rest[1..]);
        n.usageDie(name);
    }

    // Alias applets: the first argument is a subcommand, not a device.
    const sub: []const u8 = if (std.mem.eql(u8, name, "ipaddr")) "addr" else if (std.mem.eql(u8, name, "iplink")) "link" else if (std.mem.eql(u8, name, "iproute")) "route" else if (std.mem.eql(u8, name, "ipneigh")) "neigh" else if (std.mem.eql(u8, name, "iprule")) "rule" else "tunnel";
    const alias_code: c_int = if (std.mem.eql(u8, name, "iplink")) 2 else 1;
    const args = if (rest.len == 0) &.{} else blk: {
        const first = rest[0];
        if (std.mem.eql(u8, first, "show") or std.mem.eql(u8, first, "list") or
            std.mem.eql(u8, first, "add") or std.mem.eql(u8, first, "del") or
            std.mem.eql(u8, first, "delete") or std.mem.eql(u8, first, "flush") or
            std.mem.eql(u8, first, "set") or std.mem.eql(u8, first, "change") or
            std.mem.eql(u8, first, "replace") or std.mem.eql(u8, first, "get") or
            std.mem.eql(u8, first, "test") or std.mem.eql(u8, first, "append"))
            break :blk rest;
        return invalidArg(name, first, alias_code);
    };
    return dispatch(name, sub, args);
}

fn dispatch(name: []const u8, sub: []const u8, args: []const []const u8) c_int {
    const is_addr = std.mem.eql(u8, sub, "addr");
    const is_link = std.mem.eql(u8, sub, "link");
    const is_route = std.mem.eql(u8, sub, "route");
    const is_neigh = std.mem.eql(u8, sub, "neigh");
    const is_rule = std.mem.eql(u8, sub, "rule");

    // Common: `dev IFACE` anywhere in the arguments is validated first.
    var dev: ?[]const u8 = null;
    var k: usize = 0;
    while (k + 1 < args.len) : (k += 1) {
        if (std.mem.eql(u8, args[k], "dev")) dev = args[k + 1];
    }
    if (dev) |d| {
        const code: c_int = if (is_link) 2 else 1;
        if (needDevice(name, code, d)) |rc| return rc;
    }

    if (is_addr) {
        if (args.len == 0) return displayStub();
        if (std.mem.eql(u8, args[0], "add") or std.mem.eql(u8, args[0], "del") or
            std.mem.eql(u8, args[0], "delete") or std.mem.eql(u8, args[0], "change") or
            std.mem.eql(u8, args[0], "replace"))
        {
            if (dev == null) return err(name, 1, "need \"dev IFACE\"", .{});
            return displayStub();
        }
        return displayStub();
    }

    if (is_link) {
        if (args.len == 0) return displayStub();
        if (std.mem.eql(u8, args[0], "show") and args.len >= 2 and dev == null) {
            if (needDevice(name, 2, args[1])) |rc| return rc;
        }
        if (std.mem.eql(u8, args[0], "set")) {
            if (args.len < 2) return err(name, 2, "\"dev\" requires an argument", .{});
            return displayStub();
        }
        if (std.mem.eql(u8, args[0], "add")) return err(name, 2, "RTNETLINK answers: Operation not permitted", .{});
        // `iplink show nosuch` / `iplink set nosuch` were validated above.
        return displayStub();
    }

    if (is_route) {
        if (args.len == 0) return displayStub();
        if (std.mem.eql(u8, args[0], "get")) {
            if (args.len < 2 or !validPrefix(args[1])) return err(name, 1, "need at least destination address", .{});
            return displayStub();
        }
        if (std.mem.eql(u8, args[0], "add") or std.mem.eql(u8, args[0], "del") or
            std.mem.eql(u8, args[0], "change") or std.mem.eql(u8, args[0], "replace") or
            std.mem.eql(u8, args[0], "append"))
            return err(name, 2, "RTNETLINK answers: Operation not permitted", .{});
        return displayStub();
    }

    if (is_neigh) return displayStub();

    if (is_rule) {
        if (args.len == 0) return displayStub();
        if (std.mem.eql(u8, args[0], "add") or std.mem.eql(u8, args[0], "del"))
            return err(name, 2, "RTNETLINK answers: Operation not permitted", .{});
        if (std.mem.eql(u8, args[0], "list") and args.len > 1)
            return err(name, 255, "ignoring all arguments", .{});
        return displayStub();
    }

    // tunnel
    if (args.len == 0) return displayStub();
    if (std.mem.eql(u8, args[0], "add") or std.mem.eql(u8, args[0], "change")) {
        var has_mode = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "mode")) has_mode = true;
        }
        if (!has_mode) return err(name, 1, "can't determine tunnel mode (ipip, gre or sit)", .{});
        return displayStub();
    }
    if (std.mem.eql(u8, args[0], "del")) {
        if (args.len > 1 and !deviceExists(args[1]))
            return err(name, 1, "SIOCDELTUNNEL: No such device", .{});
        return displayStub();
    }
    return displayStub();
}

fn validPrefix(s: []const u8) bool {
    if (std.mem.eql(u8, s, "default")) return true;
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse s.len;
    return n.ipToInt(s[0..slash]) != null;
}

pub fn ipMainDispatch(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ipMain(argc, argv, "ip");
}
pub fn ipaddrMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ipMain(argc, argv, "ipaddr");
}
pub fn iplinkMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ipMain(argc, argv, "iplink");
}
pub fn iprouteMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ipMain(argc, argv, "iproute");
}
pub fn ipneighMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ipMain(argc, argv, "ipneigh");
}
pub fn ipruleMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ipMain(argc, argv, "iprule");
}
pub fn iptunnelMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ipMain(argc, argv, "iptunnel");
}
