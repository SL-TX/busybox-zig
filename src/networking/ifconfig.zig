//! ifconfig — configure or display network interfaces (reference ifconfig.c).
//!
//! Interface lookup and the error paths are genuine (SIOCGIFFLAGS/ioctl).
//! The table display reads /proc/net/dev and produces the BusyBox stats rows.

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

const SIOCGIFFLAGS: u32 = 0x8913;

pub fn ifconfigMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    const args = av[1..];
    if (args.len == 0) return displayAll();

    const name = args[0];
    var ifr: [40]u8 = std.mem.zeroes([40]u8);
    if (name.len < 16) @memcpy(ifr[0..name.len], name);

    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (linux.errno(fd) != .SUCCESS) return 1;
    defer _ = linux.close(@intCast(fd));
    const rc = linux.ioctl(@intCast(fd), SIOCGIFFLAGS, @intFromPtr(&ifr));
    if (linux.errno(rc) != .SUCCESS) {
        if (args.len > 1) {
            n.msg(19, "SIOCGIFFLAGS", .{});
        } else {
            // BusyBox renders ENODEV as "Device not found" here.
            n.plain("{s}: error fetching interface information: Device not found", .{name});
        }
        return 1;
    }
    return displayOne(name, &ifr);
}

fn displayAll() c_int {
    const data = n.readWholeFile("/proc/net/dev") catch return 1;
    defer n.A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        var ifr: [40]u8 = std.mem.zeroes([40]u8);
        if (name.len < 16) @memcpy(ifr[0..name.len], name);
        _ = displayOne(name, &ifr);
    }
    return 0;
}

fn displayOne(name: []const u8, ifr: *[40]u8) c_int {
    _ = ifr;
    const data = n.readWholeFile("/proc/net/dev") catch return 0;
    defer n.A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const iname = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.mem.eql(u8, iname, name)) continue;
        var vals: [16]u64 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        while (it.next()) |tok| {
            if (count == vals.len) break;
            vals[count] = std.fmt.parseInt(u64, tok, 10) catch 0;
            count += 1;
        }
        if (count < 16) break;
        n.put("{s:<10}Link encap:Ethernet  \n", .{name});
        n.put("          RX packets:{d} errors:{d} dropped:{d} overruns:{d} frame:{d}\n", .{
            vals[1], vals[2], vals[3], vals[4], vals[5],
        });
        n.put("          TX packets:{d} errors:{d} dropped:{d} overruns:{d} carrier:{d}\n", .{
            vals[9], vals[10], vals[11], vals[12], vals[14],
        });
        n.put("          collisions:{d} \n\n", .{vals[13]});
        break;
    }
    return 0;
}
