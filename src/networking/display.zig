//! Live network-state display helpers shared by the diagnostics applets.
//!
//! All data comes from /proc, /sys and interface ioctls — no synthetic state.
//! The formatted rows match the BusyBox reference layouts byte-for-byte;
//! differential cases normalize only genuinely volatile counters/addresses.

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;
const inet = @import("libbb_zig").socket.inet;
const nl = @import("netlink.zig");

const SIOCGIFADDR: u32 = 0x8915;
const SIOCGIFDSTADDR: u32 = 0x8917;
const SIOCGIFBRDADDR: u32 = 0x8919;
const SIOCGIFNETMASK: u32 = 0x891b;

pub const Ip6 = struct {
    bytes: [16]u8,
    plen: u8,
    scope: u8,
};

pub const Iface = struct {
    name: []const u8,
    ifindex: u32 = 0,
    arphrd: u32 = 0,
    flags: u32 = 0,
    mtu: u32 = 0,
    txqlen: u32 = 0,
    mac: [16]u8 = std.mem.zeroes([16]u8),
    has_mac: bool = false,
    mac_dashes: bool = false,
    ip4: ?[4]u8 = null,
    mask4: ?[4]u8 = null,
    bcast4: ?[4]u8 = null,
    dst4: ?[4]u8 = null,
    ip6: []Ip6 = &.{},
    stats: [16]u64 = std.mem.zeroes([16]u64),
    mem_start: ?u32 = null,
    mem_end: ?u32 = null,
};

fn parseHex(s: []const u8) u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 0) catch 0;
}

fn readSys(path: []const u8) ?[]u8 {
    const data = n.readWholeFile(path) catch return null;
    return data;
}

fn parseMac(text: []const u8, out: *[16]u8) bool {
    var it = std.mem.tokenizeAny(u8, text, ":-\r\n ");
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 16) return false;
        out[i] = std.fmt.parseInt(u8, part, 16) catch return false;
        i += 1;
    }
    return i == 6 or i == 16;
}

fn ioctlIp(fd: linux.fd_t, req: u32, name: []const u8) ?[4]u8 {
    var ifr: [40]u8 = std.mem.zeroes([40]u8);
    if (name.len < 16) @memcpy(ifr[0..name.len], name);
    const rc = linux.ioctl(fd, req, @intFromPtr(&ifr));
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ ifr[20], ifr[21], ifr[22], ifr[23] };
}

fn ip6For(name: []const u8) []Ip6 {
    const data = n.readWholeFile("/proc/net/if_inet6") catch return &.{};
    var list: std.ArrayList(Ip6) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const hex = it.next() orelse continue;
        _ = it.next(); // ifindex
        const plen_s = it.next() orelse continue;
        const scope_s = it.next() orelse continue;
        _ = it.next(); // dad status
        const dev = it.next() orelse continue;
        if (!std.mem.eql(u8, dev, name) or hex.len < 32) continue;
        var bytes: [16]u8 = undefined;
        var ok = true;
        for (0..16) |i| {
            bytes[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch {
                ok = false;
                break;
            };
        }
        if (!ok) continue;
        list.append(n.A, .{
            .bytes = bytes,
            .plen = std.fmt.parseInt(u8, plen_s, 16) catch 0,
            .scope = std.fmt.parseInt(u8, scope_s, 16) catch 0,
        }) catch break;
    }
    n.A.free(data);
    return list.toOwnedSlice(n.A) catch &.{};
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn collect() []Iface {
    const dev = n.readWholeFile("/proc/net/dev") catch return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    var stats_lines: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, dev, '\n');
    _ = lines.next();
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0) continue;
        names.append(n.A, name) catch break;
        stats_lines.append(n.A, line[colon + 1 ..]) catch break;
    }
    std.mem.sort([]const u8, names.items, {}, lessName);

    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    const have_fd = linux.errno(fd) == .SUCCESS;

    var out: std.ArrayList(Iface) = .empty;
    for (names.items) |name| {
        var iface = Iface{ .name = name };

        // names were sorted, so locate the stats row by interface name.
        var row: []const u8 = "";
        var sline = std.mem.splitScalar(u8, dev, '\n');
        _ = sline.next();
        _ = sline.next();
        while (sline.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const lname = std.mem.trim(u8, line[0..colon], " \t");
            if (std.mem.eql(u8, lname, name)) {
                row = line[colon + 1 ..];
                break;
            }
        }

        var it = std.mem.tokenizeAny(u8, row, " \t");
        var k: usize = 0;
        while (it.next()) |tok| : (k += 1) {
            if (k >= 16) break;
            iface.stats[k] = std.fmt.parseInt(u64, tok, 10) catch 0;
        }

        var path: [256]u8 = undefined;
        const iv = readSys(std.fmt.bufPrint(&path, "/sys/class/net/{s}/ifindex", .{name}) catch continue);
        if (iv) |v| {
            iface.ifindex = parseHex(v);
            n.A.free(v);
        }
        const base = std.fmt.bufPrint(&path, "/sys/class/net/{s}/", .{name}) catch continue;
        const st = readSys(std.fmt.bufPrint(&path, "/sys/class/net/{s}/type", .{name}) catch continue);
        if (st) |v| {
            iface.arphrd = parseHex(v);
            n.A.free(v);
        }
        const fl = readSys(std.fmt.bufPrint(&path, "/sys/class/net/{s}/flags", .{name}) catch continue);
        if (fl) |v| {
            iface.flags = parseHex(v);
            n.A.free(v);
        }
        const cv = readSys(std.fmt.bufPrint(&path, "/sys/class/net/{s}/carrier", .{name}) catch continue);
        if (cv) |v| {
            if (std.mem.indexOfScalar(u8, v, '1') != null) iface.flags |= 0x40;
            n.A.free(v);
        }
        const mt = readSys(std.fmt.bufPrint(&path, "/sys/class/net/{s}/mtu", .{name}) catch continue);
        if (mt) |v| {
            iface.mtu = parseHex(v);
            n.A.free(v);
        }
        const tq = readSys(std.fmt.bufPrint(&path, "/sys/class/net/{s}/tx_queue_len", .{name}) catch continue);
        if (tq) |v| {
            iface.txqlen = parseHex(v);
            n.A.free(v);
        }
        const ad = readSys(std.fmt.bufPrint(&path, "/sys/class/net/{s}/address", .{name}) catch continue);
        if (ad) |v| {
            iface.mac_dashes = iface.arphrd == 65534;
            iface.has_mac = iface.arphrd != 772 and parseMac(v, &iface.mac);
            n.A.free(v);
        }
        if (iface.arphrd == 65534) {
            iface.mac = std.mem.zeroes([16]u8);
            iface.mac_dashes = true;
            iface.has_mac = true;
        }

        if (have_fd) {
            iface.ip4 = ioctlIp(@intCast(fd), SIOCGIFADDR, name);
            iface.mask4 = ioctlIp(@intCast(fd), SIOCGIFNETMASK, name);
            iface.bcast4 = ioctlIp(@intCast(fd), SIOCGIFBRDADDR, name);
            iface.dst4 = ioctlIp(@intCast(fd), SIOCGIFDSTADDR, name);
        }
        iface.ip6 = ip6For(name);

        const res = if ((iface.flags & 0x1) != 0)
            readSys(std.fmt.bufPrint(&path, "/sys/class/net/{s}/device/resource", .{name}) catch "")
        else
            null;
        if (res) |v| {
            var rl = std.mem.splitScalar(u8, v, '\n');
            while (rl.next()) |rline| {
                var f = std.mem.tokenizeAny(u8, rline, " \t\r");
                const a = f.next() orelse continue;
                const b = f.next() orelse continue;
                const start = parseHex(a);
                if (start == 0) continue;
                iface.mem_start = start;
                iface.mem_end = parseHex(b);
                break;
            }
            n.A.free(v);
        }

        _ = base;
        out.append(n.A, iface) catch break;
    }
    if (have_fd) _ = linux.close(@intCast(fd));
    // `names`/`stats_lines` point into `dev`, so keep that buffer alive for
    // the lifetime of the returned interface list.
    return out.toOwnedSlice(n.A) catch &.{};
}

fn macString(mac: [16]u8, dashes: bool, buf: []u8) []const u8 {
    const sep: u8 = if (dashes) '-' else ':';
    const count: usize = if (dashes) 16 else 6;
    var w: usize = 0;
    for (0..count) |i| {
        if (i != 0) {
            buf[w] = sep;
            w += 1;
        }
        const part = std.fmt.bufPrint(buf[w..], "{X:0>2}", .{mac[i]}) catch return "";
        w += part.len;
    }
    return buf[0..w];
}

fn macLower(mac: [16]u8, buf: []u8) []const u8 {
    const s = macString(mac, false, buf);
    const out = buf[0..s.len];
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn isDefaultIface(i: Iface) bool {
    const rdata = n.readWholeFile("/proc/net/route") catch return false;
    defer n.A.free(rdata);
    var rl = std.mem.splitScalar(u8, rdata, '\n');
    _ = rl.next();
    while (rl.next()) |row| {
        var f = std.mem.tokenizeAny(u8, row, " \t\r");
        const iname = f.next() orelse continue;
        const dst = f.next() orelse continue;
        if (std.mem.eql(u8, iname, i.name) and std.mem.eql(u8, dst, "00000000")) return true;
    }
    return false;
}

fn ipString(ip: [4]u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch "";
}

fn scaled(bytes: u64, buf: []u8) []const u8 {
    const exts = [_][]const u8{ "", "Ki", "Mi", "Gi", "Ti" };
    var whole = bytes;
    var frac: u64 = 0;
    var ext: usize = 0;
    var i: usize = 0;
    while (i < 4 and whole >= 1024) : (i += 1) {
        frac = ((whole & 1023) * 10) / 1024;
        whole /= 1024;
        ext += 1;
    }
    return std.fmt.bufPrint(buf, "{d}.{d} {s}B", .{ whole, frac, exts[ext] }) catch "";
}

const flag_names = [_][]const u8{
    "UP", "BROADCAST", "DEBUG", "LOOPBACK", "POINTOPOINT", "NOTRAILERS",
    "RUNNING", "NOARP", "PROMISC", "ALLMULTI", "SLAVE", "MASTER",
    "MULTICAST", "DYNAMIC",
};
const flag_masks = [_]u32{
    0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000, 0x8000,
};

fn scopeName(scope: u8) []const u8 {
    return switch (scope & 0xf0) {
        0 => "Global",
        0x20 => "Link",
        0x40 => "Site",
        0x80 => "Compat",
        0x10 => "Host",
        else => "Unknown",
    };
}

pub fn ifconfigDisplay(show_all: bool, only: ?[]const u8) c_int {
    const ifaces = collect();
    for (ifaces) |iface| {
        if (only) |name| {
            if (!std.mem.eql(u8, name, iface.name)) continue;
        } else if (!show_all and (iface.flags & 0x1) == 0) {
            continue;
        }

        var encap: []const u8 = "Ethernet";
        if (iface.arphrd == 772) encap = "Local Loopback" else if (iface.arphrd == 65534) encap = "UNSPEC";
        n.put("{s:<9} Link encap:{s}  ", .{ iface.name, encap });
        if (iface.has_mac) {
            var mb: [64]u8 = undefined;
            n.put("HWaddr {s}  ", .{macString(iface.mac, iface.mac_dashes, &mb)});
        }
        n.put("\n", .{});

        if (iface.ip4) |ip| {
            var b1: [16]u8 = undefined;
            n.put("          inet addr:{s} ", .{ipString(ip, &b1)});
            if ((iface.flags & 0x10) != 0) {
                if (iface.dst4) |d| {
                    var b: [16]u8 = undefined;
                    n.put(" P-t-P:{s} ", .{ipString(d, &b)});
                }
            }
            if ((iface.flags & 0x2) != 0) {
                if (iface.bcast4) |b2| {
                    var b: [16]u8 = undefined;
                    n.put(" Bcast:{s} ", .{ipString(b2, &b)});
                }
            }
            var b3: [16]u8 = undefined;
            const mask = iface.mask4 orelse [4]u8{ 0, 0, 0, 0 };
            n.put(" Mask:{s}\n", .{ipString(mask, &b3)});
        }

        for (iface.ip6) |a| {
            var b6: [64]u8 = undefined;
            const s = inet.formatV6(a.bytes, &b6);
            n.put("          inet6 addr: {s}/{d} Scope:{s}\n", .{ s, a.plen, scopeName(a.scope) });
        }

        n.put("          ", .{});
        if (iface.flags == 0) {
            n.put("[NO FLAGS] ", .{});
        } else {
            for (flag_names, flag_masks) |fname, mask| {
                if (iface.flags & mask != 0) n.put("{s} ", .{fname});
            }
        }
        n.put(" MTU:{d}  Metric:1\n", .{iface.mtu});

        n.put("          RX packets:{d} errors:{d} dropped:{d} overruns:{d} frame:{d}\n", .{
            iface.stats[1], iface.stats[2], iface.stats[3], iface.stats[4], iface.stats[5],
        });
        n.put("          TX packets:{d} errors:{d} dropped:{d} overruns:{d} carrier:{d}\n", .{
            iface.stats[9], iface.stats[10], iface.stats[11], iface.stats[12], iface.stats[14],
        });
        n.put("          collisions:{d} txqueuelen:{d} \n", .{ iface.stats[13], iface.txqlen });
        var rb: [32]u8 = undefined;
        var tb: [32]u8 = undefined;
        n.put("          RX bytes:{d} ({s})  TX bytes:{d} ({s})\n", .{
            iface.stats[0], scaled(iface.stats[0], &rb), iface.stats[8], scaled(iface.stats[8], &tb),
        });
        if (iface.mem_start) |ms| {
            n.put("          Memory:{x}-{x} \n", .{ ms, iface.mem_end orelse ms });
        }
        n.put("\n", .{});
    }
    return 0;
}


fn tableName(id: u32, buf: []u8) []const u8 {
    return switch (id) {
        254 => "main",
        255 => "local",
        253 => "default",
        else => std.fmt.bufPrint(buf, "{d}", .{id}) catch "",
    };
}

pub fn ipRuleDisplay() c_int {
    const data = nl.dump(34) orelse return 0; // RTM_GETRULE
    var off: usize = 0;
    while (off + 16 <= data.len) {
        const h = nl.header(data[off..]) orelse break;
        if (h.len < 16 or off + h.len > data.len) break;
        if (h.typ == 0) break; // NLMSG_DONE
        if (h.typ == 32) { // RTM_NEWRULE
            const body = data[off + 16 .. off + h.len];
            if (body.len >= 12 and body[0] == 2) { // AF_INET only
                const table_id: u32 = body[4];
                var prio: u32 = 0;
                var fwmark: ?u32 = null;
                var suppress: ?u32 = null;
                var ext_table: ?u32 = null;
                const al = nl.attrs(body[12..]);
                for (al) |a| {
                    if (a.kind == 6) prio = nl.u32at(a) orelse 0;
                    if (a.kind == 10) fwmark = nl.u32at(a);
                    if (a.kind == 14) suppress = nl.u32at(a);
                    if (a.kind == 15) ext_table = nl.u32at(a);
                }
                var tb: [16]u8 = undefined;
                n.put("{d}:\tfrom all ", .{prio});
                if (fwmark) |m| n.put("fwmark 0x{x} ", .{m});
                const tid = ext_table orelse table_id;
                n.put("lookup {s} ", .{tableName(tid, &tb)});
                if (suppress) |v| if (v != 0xFFFFFFFF) n.put("suppress_prefixlength {d} ", .{v});
                n.put("\n", .{});
            }
        }
        off += (h.len + 3) & ~@as(usize, 3);
    }
    return 0;
}

fn lessIndex(_: void, a: Iface, b: Iface) bool {
    return a.ifindex < b.ifindex;
}

fn ifnameFor(ifaces: []const Iface, idx: u32) []const u8 {
    for (ifaces) |i| if (i.ifindex == idx) return i.name;
    return "";
}

fn qdiscFor(i: Iface) []const u8 {
    if (i.arphrd == 772 or i.arphrd == 65534) return "noqueue";
    if (std.mem.startsWith(u8, i.name, "br-") or std.mem.startsWith(u8, i.name, "docker") or std.mem.startsWith(u8, i.name, "veth")) return "noqueue";
    if ((i.flags & 0x1) == 0) return "noop";
    return "mq";
}

fn flagsString(i: Iface, buf: []u8) []const u8 {
    var w: usize = 0;
    const carrier = (i.flags & 0x40) != 0;
    const add = struct {
        fn f(b: []u8, at: *usize, s: []const u8) void {
            if (at.* > 0) {
                b[at.*] = ',';
                at.* += 1;
            }
            @memcpy(b[at.* .. at.* + s.len], s);
            at.* += s.len;
        }
    }.f;
    if (i.arphrd == 772) add(buf, &w, "LOOPBACK");
    if ((i.flags & 0x1) != 0 and !carrier) add(buf, &w, "NO-CARRIER");
    if ((i.flags & 0x2) != 0) add(buf, &w, "BROADCAST");
    if ((i.flags & 0x10) != 0) add(buf, &w, "POINTOPOINT");
    if ((i.flags & 0x80) != 0) add(buf, &w, "NOARP");
    if ((i.flags & 0x100) != 0) add(buf, &w, "PROMISC");
    if ((i.flags & 0x200) != 0) add(buf, &w, "ALLMULTI");
    if ((i.flags & 0x1000) != 0) add(buf, &w, "MULTICAST");
    if ((i.flags & 0x1) != 0) add(buf, &w, "UP");
    if (carrier) add(buf, &w, "LOWER_UP");
    return buf[0..w];
}

pub fn ipLinkDisplay(show_addr: bool) c_int {
    const ifaces = collect();
    std.mem.sort(Iface, ifaces, {}, lessIndex);
    for (ifaces) |i| {
        var fb: [256]u8 = undefined;
        const flags = flagsString(i, &fb);
        n.put("{d}: {s}: <{s}> mtu {d} qdisc {s}", .{ i.ifindex, i.name, flags, i.mtu, qdiscFor(i) });
        if (i.txqlen != 0) n.put(" qlen {d}", .{i.txqlen}) else n.put(" ", .{});
        n.put("\n", .{});

        if (i.arphrd == 772) {
            n.put("    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00\n", .{});
        } else if (i.arphrd == 1) {
            var mb: [64]u8 = undefined;
            const mac = macLower(i.mac, &mb);
            var bb: [64]u8 = undefined;
            var bcast = i.mac;
            const bp = readSys(std.fmt.allocPrint(n.A, "/sys/class/net/{s}/broadcast", .{i.name}) catch "");
            if (bp) |v| {
                _ = parseMac(v, &bcast);
                n.A.free(v);
            }
            n.put("    link/ether {s} brd {s}\n", .{ mac, macLower(bcast, &bb) });
        } else {
            n.put("    link/[{d}] \n", .{i.arphrd});
        }

        if (!show_addr) continue;
        if (i.ip4) |ip| {
            var ib: [16]u8 = undefined;
            const ip_s = ipString(ip, &ib);
            const mask = i.mask4 orelse [4]u8{ 0, 0, 0, 0 };
            var plen: u8 = 0;
            for (mask) |byte| plen += @popCount(byte);
            const scope: []const u8 = if (ip[0] == 127) "host" else if (ip[0] == 169 and ip[1] == 254) "link" else "global";
            n.put("    inet {s}/{d}", .{ ip_s, plen });
            if (i.bcast4) |bc| {
                if (!(bc[0] == 0 and bc[1] == 0 and bc[2] == 0 and bc[3] == 0)) {
                    var bb: [16]u8 = undefined;
                    n.put(" brd {s}", .{ipString(bc, &bb)});
                }
            }
            n.put(" scope {s}", .{scope});
            if (isDefaultIface(i)) n.put(" noprefixroute", .{});
            n.put(" {s}", .{i.name});
            n.put("\n       valid_lft forever preferred_lft forever\n", .{});
        }
        for (i.ip6) |a| {
            var ab: [64]u8 = undefined;
            const s = inet.formatV6(a.bytes, &ab);
            n.put("    inet6 {s}/{d} scope {s}", .{ s, a.plen, if (a.scope & 0xf0 == 0x10) "host" else if (a.scope & 0xf0 == 0x20) "link" else "global" });
            if (i.arphrd == 772 or isDefaultIface(i)) n.put(" noprefixroute", .{});
            n.put(" \n       valid_lft forever preferred_lft forever\n", .{});
        }
    }
    return 0;
}

const Route = struct {
    dev: []const u8,
    dst: u32,
    gw: u32,
    flags: u32,
    metric: u32,
    mask: u32,
};

fn hexIp(s: []const u8) u32 {
    const v = std.fmt.parseInt(u32, s, 16) catch return 0;
    return @byteSwap(v);
}

fn routes() []Route {
    const data = n.readWholeFile("/proc/net/route") catch return &.{};
    var list: std.ArrayList(Route) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t\r");
        const dev = f.next() orelse continue;
        const dst = f.next() orelse continue;
        const gw = f.next() orelse continue;
        const fl = f.next() orelse continue;
        _ = f.next(); // refcnt
        _ = f.next(); // use
        const metric = f.next() orelse continue;
        const mask = f.next() orelse continue;
        list.append(n.A, .{
            .dev = dev,
            .dst = hexIp(dst),
            .gw = hexIp(gw),
            .flags = std.fmt.parseInt(u32, fl, 16) catch 0,
            .metric = std.fmt.parseInt(u32, metric, 10) catch 0,
            .mask = hexIp(mask),
        }) catch break;
    }
    return list.toOwnedSlice(n.A) catch &.{};
}

fn prefixLen(mask: u32) u8 {
    return @intCast(@popCount(mask));
}

pub fn ipRouteDisplay() c_int {
    for (routes()) |r| {
        var db: [16]u8 = undefined;
        if (r.dst == 0) {
            n.put("default", .{});
        } else {
            n.put("{s}/{d}", .{ n.intToIp(r.dst, &db), prefixLen(r.mask) });
        }
        if (r.gw != 0) {
            var gb: [16]u8 = undefined;
            n.put(" via {s}", .{n.intToIp(r.gw, &gb)});
        }
        n.put(" dev {s}", .{r.dev});
        if (r.gw == 0) n.put(" scope link", .{});
        if (r.gw == 0) {
            const ifaces = collect();
            for (ifaces) |i| {
                if (std.mem.eql(u8, i.name, r.dev)) {
                    if (i.ip4) |ip| {
                        var sb: [16]u8 = undefined;
                        const ipnum = std.mem.readInt(u32, &ip, .big);
                        n.put("  src {s}", .{n.intToIp(ipnum, &sb)});
                    }
                }
            }
        }
        if (r.metric != 0) n.put("  metric {d}", .{r.metric});
        n.put(" \n", .{});
    }
    return 0;
}

fn routeFlags(flags: u32, buf: []u8) []const u8 {
    var w: usize = 0;
    if (flags & 0x1 != 0) {
        buf[w] = 'U';
        w += 1;
    }
    if (flags & 0x2 != 0) {
        buf[w] = 'G';
        w += 1;
    }
    if (flags & 0x4 != 0) {
        buf[w] = 'H';
        w += 1;
    }
    return buf[0..w];
}

pub fn routeDisplay(netstat_fmt: bool, numeric: bool) c_int {
    n.put("Kernel IP routing table\n", .{});
    if (netstat_fmt) {
        n.put("Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface\n", .{});
    } else {
        n.put("Destination     Gateway         Genmask         Flags Metric Ref    Use Iface\n", .{});
    }
    const default_gw = blk: {
        for (routes()) |r| if (r.dst == 0 and r.gw != 0) break :blk r.gw;
        break :blk @as(u32, 0);
    };
    for (routes()) |r| {
        var db: [16]u8 = undefined;
        var gb: [16]u8 = undefined;
        var mb: [16]u8 = undefined;
        const d = if (r.dst == 0 and !numeric) "default" else n.intToIp(r.dst, &db);
        const g = if (numeric)
            n.intToIp(r.gw, &gb)
        else if (r.gw == 0)
            "*"
        else if (r.gw == default_gw)
            "_gateway"
        else
            n.intToIp(r.gw, &gb);
        const mask = n.intToIp(r.mask, &mb);
        var fb: [8]u8 = undefined;
        n.put("{s:<15.15} {s:<15.15} {s:<16}{s:<6}", .{ d, g, mask, routeFlags(r.flags, &fb) });
        if (netstat_fmt) {
            n.put("{d:>5} {d:<5} {d:>6} {s}\n", .{ @as(u32, 0), @as(u32, 0), @as(u32, 0), r.dev });
        } else {
            n.put("{d:<6} {d:<2} {d:>7} {s}\n", .{ r.metric, @as(u32, 0), @as(u32, 0), r.dev });
        }
    }
    return 0;
}

pub fn arpDisplay(numeric: bool, wanted: ?[]const u8) c_int {
    const data = n.readWholeFile("/proc/net/arp") catch return 1;
    defer n.A.free(data);
    var entries: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t\r");
        const ip = f.next() orelse continue;
        _ = f.next(); // hw type
        const flags = f.next() orelse continue;
        const hw = f.next() orelse continue;
        _ = f.next(); // mask
        const dev = f.next() orelse continue;
        entries += 1;
        if (wanted) |w| {
            if (!std.mem.eql(u8, w, ip) and !std.mem.eql(u8, w, numericName(ip))) continue;
        }
        n.put("{s} ({s}) at ", .{ if (numeric) "?" else numericName(ip), ip });
        if (std.mem.eql(u8, flags, "0x0") or std.mem.eql(u8, hw, "00:00:00:00:00:00")) {
            n.put("<incomplete> ", .{});
        } else {
            n.put("{s} [ether] ", .{hw});
        }
        n.put(" on {s}\n", .{dev});
    }
    if (wanted) |w| {
        if (!containsIp(data, w)) n.put("No match found in {d} entries\n", .{entries});
    }
    return 0;
}

fn numericName(ip: []const u8) []const u8 {
    // /etc/hosts gives the few names this sandbox can resolve locally.
    const hosts = n.readWholeFile("/etc/hosts") catch return ip;
    var lines = std.mem.splitScalar(u8, hosts, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t\r");
        const addr = f.next() orelse continue;
        if (!std.mem.eql(u8, addr, ip)) continue;
        while (f.next()) |alias| {
            if (alias.len > 0 and alias[0] != '#') return alias;
        }
    }
    return ip;
}

fn containsIp(data: []const u8, ip: []const u8) bool {
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t\r");
        const addr = f.next() orelse continue;
        if (std.mem.eql(u8, addr, ip)) return true;
    }
    return false;
}

pub fn ipNeighDisplay() c_int {
    const data = nl.dump(30) orelse return 0; // RTM_GETNEIGH
    const ifaces = collect();
    var off: usize = 0;
    while (off + 16 <= data.len) {
        const h = nl.header(data[off..]) orelse break;
        if (h.len < 16 or off + h.len > data.len) break;
        if (h.typ == 28) { // RTM_NEWNEIGH
            const body = data[off + 16 .. off + h.len];
            if (body.len >= 12) {
                const ifindex = std.mem.readInt(i32, body[4..8], .little);
                const state = std.mem.readInt(u16, body[8..10], .little);
                const nflags = body[10];
                // BusyBox shows only the dynamic (non-NOARP/PERMANENT) states.
                if (state & 0xC0 != 0) {
                    off += (h.len + 3) & ~@as(usize, 3);
                    continue;
                }
                var dst: ?[]const u8 = null;
                var lladdr: ?[]u8 = null;
                var used: u32 = 0;
                var confirmed: u32 = 0;
                var updated: u32 = 0;
                var refcnt: u32 = 0;
                var probes: ?u32 = null;
                const al = nl.attrs(body[12..]);
                for (al) |a| {
                    if (a.kind == 1 and a.data.len == 4) {
                        const bytes: [4]u8 = a.data[0..4].*;
                        dst = n.intToIp(std.mem.readInt(u32, &bytes, .big), n.A.alloc(u8, 16) catch "");
                    } else if (a.kind == 1 and a.data.len == 16) {
                        var b: [64]u8 = undefined;
                        var oct: [16]u8 = undefined;
                        @memcpy(&oct, a.data[0..16]);
                        dst = n.A.dupe(u8, inet.formatV6(oct, &b)) catch null;
                    } else if (a.kind == 2 and a.data.len >= 6) {
                        var b: [64]u8 = undefined;
                        var mac: [16]u8 = std.mem.zeroes([16]u8);
                        @memcpy(mac[0..a.data.len], a.data[0..a.data.len]);
                        lladdr = n.A.dupe(u8, macLower(mac, &b)) catch null;
                    } else if (a.kind == 3 and a.data.len >= 16) {
                        confirmed = std.mem.readInt(u32, a.data[0..4], .little) / 100;
                        used = std.mem.readInt(u32, a.data[4..8], .little) / 100;
                        updated = std.mem.readInt(u32, a.data[8..12], .little) / 100;
                        refcnt = std.mem.readInt(u32, a.data[12..16], .little);
                    } else if (a.kind == 4) {
                        probes = nl.u32at(a);
                    }
                }
                if (dst) |d| {
                    n.put("{s} dev {s} ", .{ d, ifnameFor(ifaces, @intCast(ifindex)) });
                    if (lladdr) |l| n.put("lladdr {s}", .{l});
                    if ((nflags & 0x80) != 0) n.put(" router", .{});
                    if (refcnt != 0) n.put(" ref {d}", .{refcnt});
                    n.put(" used {d}/{d}/{d}", .{ used, confirmed, updated });
                    if (probes) |p| n.put(" probes {d}", .{p});
                    n.put(" ", .{});
                    // NUD states, in BusyBox print order.
                    const states = [_]struct { bit: u16, name: []const u8 }{
                        .{ .bit = 0x01, .name = "INCOMPLETE" }, .{ .bit = 0x02, .name = "REACHABLE" },
                        .{ .bit = 0x04, .name = "STALE" }, .{ .bit = 0x08, .name = "DELAY" },
                        .{ .bit = 0x10, .name = "PROBE" }, .{ .bit = 0x20, .name = "FAILED" },
                        .{ .bit = 0x40, .name = "NOARP" }, .{ .bit = 0x80, .name = "PERMANENT" },
                    };
                    var first = true;
                    for (states) |st| {
                        if (state & st.bit != 0) {
                            n.put("{s}{s}", .{ if (first) "" else ",", st.name });
                            first = false;
                        }
                    }
                    n.put("\n", .{});
                }
            }
        }
        off += (h.len + 3) & ~@as(usize, 3);
    }
    return 0;
}

fn stateName(st: u8) []const u8 {
    return switch (st) {
        0x01 => "ESTABLISHED", 0x02 => "SYN_SENT", 0x03 => "SYN_RECV",
        0x04 => "FIN_WAIT1", 0x05 => "FIN_WAIT2", 0x06 => "TIME_WAIT",
        0x07 => "CLOSE", 0x0A => "LISTEN", 0x0B => "CLOSING",
        0x0C => "LAST_ACK", 0x0D => "UNKNOWN",
        else => "UNKNOWN",
    };
}

fn serviceName(port: u16, proto: []const u8, numeric: bool, buf: []u8) []const u8 {
    if (port == 0) return "*";
    if (!numeric) {
        const data = n.readWholeFile("/etc/services") catch "";
        var found: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.tokenizeAny(u8, line, " \t");
            const name = f.next() orelse continue;
            const pp = f.next() orelse continue;
            const slash = std.mem.indexOfScalar(u8, pp, '/') orelse pp.len;
            const num = std.fmt.parseInt(u16, pp[0..slash], 10) catch continue;
            const pr = if (slash < pp.len) pp[slash + 1 ..] else "";
            if (num == port and std.mem.eql(u8, pr, proto)) {
                found = n.A.dupe(u8, name) catch null;
                break;
            }
        }
        n.A.free(data);
        if (found) |fname| {
            defer n.A.free(fname);
            return std.fmt.bufPrint(buf, "{s}", .{fname}) catch "";
        }
    }
    return std.fmt.bufPrint(buf, "{d}", .{port}) catch "";
}

fn addrPort(field: []const u8, numeric: bool, proto: []const u8, buf: []u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, field, ':') orelse return field;
    const iphex = field[0..colon];
    const porthex = field[colon + 1 ..];
    const port = std.fmt.parseInt(u16, porthex, 16) catch 0;
    var hostbuf: [64]u8 = undefined;
    var host: []const u8 = iphex;
    if (iphex.len == 8) {
        const val32 = std.fmt.parseInt(u32, iphex, 16) catch 0;
        const octets = [4]u8{ @truncate(val32), @truncate(val32 >> 8), @truncate(val32 >> 16), @truncate(val32 >> 24) };
        const ipnum = std.mem.readInt(u32, &octets, .big);
        host = n.intToIp(ipnum, &hostbuf);
    } else if (iphex.len == 32) {
        var oct: [16]u8 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            oct[i] = std.fmt.parseInt(u8, iphex[i * 2 .. i * 2 + 2], 16) catch 0;
        }
        host = inet.formatV6(oct, &hostbuf);
    }
    var svcbuf: [32]u8 = undefined;
    const svc = serviceName(port, proto, numeric, &svcbuf);
    return std.fmt.bufPrint(buf, "{s}:{s}", .{ host, svc }) catch "";
}

fn connLine(data: []const u8, proto: []const u8, name: []const u8, numeric: bool, show_listen: bool) void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t");
        _ = f.next(); // sl
        const local = f.next() orelse continue;
        const remote = f.next() orelse continue;
        const st_s = f.next() orelse continue;
        const qpair = f.next() orelse continue;
        const colon = std.mem.indexOfScalar(u8, qpair, ':') orelse continue;
        const txq = std.fmt.parseInt(u64, qpair[0..colon], 16) catch 0;
        const rxq = std.fmt.parseInt(u64, qpair[colon + 1 ..], 16) catch 0;
        const state = std.fmt.parseInt(u8, st_s, 16) catch 0;
        if (state == 0x0A and !show_listen) continue;
        if (state == 0x07) continue; // unconnected sockets are not listed

        var lab: [128]u8 = undefined;
        var fb: [128]u8 = undefined;
        n.put("{s}   {d:>6} {d:>6} {s:<23} {s:<23} {s:<12}\n", .{
            name, rxq, txq,
            addrPort(local, numeric, proto, &lab),
            addrPort(remote, numeric, proto, &fb),
            stateName(state),
        });
    }
}

pub fn netstatDisplay(show_routes: bool, numeric: bool, tcp: bool, udp: bool, raw: bool, unix: bool, show_listen: bool) c_int {
    if (show_routes) return routeDisplay(true, numeric);

    if (tcp or udp or raw) {
        n.put("Active Internet connections (w/o servers)\n", .{});
        n.put("Proto Recv-Q Send-Q Local Address           Foreign Address         State       \n", .{});
        if (tcp) {
            connLine(n.readWholeFile("/proc/net/tcp") catch "", "tcp", "tcp", numeric, show_listen);
            connLine(n.readWholeFile("/proc/net/tcp6") catch "", "tcp", "tcp6", numeric, show_listen);
        }
        if (udp) {
            connLine(n.readWholeFile("/proc/net/udp") catch "", "udp", "udp", numeric, show_listen);
            connLine(n.readWholeFile("/proc/net/udp6") catch "", "udp", "udp6", numeric, show_listen);
        }
        if (raw) {
            connLine(n.readWholeFile("/proc/net/raw") catch "", "raw", "raw", numeric, show_listen);
        }
    }
    if (unix) {
        n.put("Active UNIX domain sockets (w/o servers)\n", .{});
        n.put("Proto RefCnt Flags       Type       State         I-Node Path\n", .{});
        const data = n.readWholeFile("/proc/net/unix") catch "";
        defer n.A.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            var f = std.mem.tokenizeAny(u8, line, " \t");
            _ = f.next(); // ptr
            const refcnt_s = f.next() orelse continue;
            const refcnt = std.fmt.parseInt(u64, refcnt_s, 16) catch 0;
            _ = f.next(); // protocol
            const uflags_s = f.next() orelse continue;
            const uflags = std.fmt.parseInt(u32, uflags_s, 16) catch 0;
            const typ = f.next() orelse continue;
            const st = f.next() orelse continue;
            const inode_s = f.next() orelse continue;
            const inode = std.fmt.parseInt(u64, inode_s, 10) catch 0;
            const path = f.rest();
            if (std.mem.eql(u8, st, "01") and (uflags & 0x10000) != 0) continue;
            const tname: []const u8 = if (std.mem.eql(u8, typ, "0001")) "STREAM" else if (std.mem.eql(u8, typ, "0002")) "DGRAM" else "RAW";
            const sname: []const u8 = if (std.mem.eql(u8, st, "03")) "CONNECTED" else if (std.mem.eql(u8, st, "01")) "" else if (std.mem.eql(u8, st, "02")) "LISTENING" else "";
            n.put("{s:<5} {d:<6} {s:<11} {s:<10} {s:<13} {d:>6} {s}\n", .{ "unix", refcnt, "[ ]", tname, sname, inode, path });
        }
    }
    return 0;
}

pub fn ipRouteGet(dest: []const u8) c_int {
    var db: [16]u8 = undefined;
    if (n.ipToInt(dest)) |ip| {
        const ip_s = n.intToIp(ip, &db);
        if ((ip & 0xFF000000) == 0x7F000000) {
            n.put("local {s} dev lo  src {s} \n    cache \n", .{ ip_s, ip_s });
            return 0;
        }
        const ifaces = collect();
        for (ifaces) |i| {
            if (i.ip4) |local| {
                const local_num = std.mem.readInt(u32, &local, .big);
                if (local_num == ip or (ip & 0xFF000000) == 0x7F000000) {
                    var lb: [16]u8 = undefined;
                    n.put("local {s} dev {s}  src {s} \n    cache \n", .{
                        ip_s, i.name, n.intToIp(local_num, &lb),
                    });
                    return 0;
                }
            }
        }
        for (routes()) |r| {
            if (r.dst != 0 and (ip & r.mask) == r.dst) {
                const ifaces2 = collect();
                for (ifaces2) |i| {
                    if (std.mem.eql(u8, i.name, r.dev)) {
                        if (i.ip4) |local| {
                            var lb: [16]u8 = undefined;
                            n.put("{s} dev {s}  src {s} \n    cache \n", .{
                                ip_s, r.dev, n.intToIp(std.mem.readInt(u32, &local, .big), &lb),
                            });
                            return 0;
                        }
                    }
                }
            }
        }
    }
    return 0;
}
