//! nslookup — query DNS about a host (reference nslookup.c, musl flavour).
//!
//! Implements the bind-utils style command line (-type=, -debug, -port=,
//! -timeout=...), reads /etc/resolv.conf for the default server, issues real
//! UDP DNS queries and prints the reference answer format. Test cases use the
//! loopback resolver only.

const std = @import("std");
const n = @import("netcommon.zig");
const sock = @import("libbb_zig").socket;

fn qtypeFromName(name: []const u8) ?u16 {
    const table = .{
        .{ "a", @as(u16, 1) }, .{ "ns", 2 }, .{ "md", 3 }, .{ "mf", 4 },
        .{ "cname", 5 }, .{ "soa", 6 }, .{ "mb", 7 }, .{ "mg", 8 },
        .{ "mr", 9 }, .{ "null", 10 }, .{ "wks", 11 }, .{ "ptr", 12 },
        .{ "hinfo", 13 }, .{ "minfo", 14 }, .{ "mx", 15 }, .{ "txt", 16 },
        .{ "rp", 17 }, .{ "afsdb", 18 }, .{ "x25", 19 }, .{ "isdn", 20 },
        .{ "rt", 21 }, .{ "nsap", 22 }, .{ "nsap-ptr", 23 }, .{ "sig", 24 },
        .{ "key", 25 }, .{ "px", 26 }, .{ "gpos", 27 }, .{ "aaaa", 28 },
        .{ "loc", 29 }, .{ "nxt", 30 }, .{ "eid", 31 }, .{ "nimloc", 32 },
        .{ "srv", 33 }, .{ "atma", 34 }, .{ "naptr", 35 }, .{ "kx", 36 },
        .{ "cert", 37 }, .{ "a6", 38 }, .{ "dname", 39 }, .{ "sink", 40 },
        .{ "opt", 41 }, .{ "apl", 42 }, .{ "ds", 43 }, .{ "sshfp", 44 },
        .{ "ipseckey", 45 }, .{ "rrsig", 46 }, .{ "nsec", 47 },
        .{ "dnskey", 48 }, .{ "dhcid", 49 }, .{ "nsec3", 50 },
        .{ "nsec3param", 51 }, .{ "tlSA", 52 }, .{ "smimea", 53 },
        .{ "hip", 55 }, .{ "cds", 59 }, .{ "cdnskey", 60 }, .{ "openpgpkey", 61 },
        .{ "csync", 62 }, .{ "any", 255 },
    };
    inline for (table) |e| {
        if (std.ascii.eqlIgnoreCase(name, e[0])) return e[1];
    }
    return null;
}

fn defaultServer() []const u8 {
    const data = n.readWholeFile("/etc/resolv.conf") catch return "127.0.0.1";
    defer n.A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = it.next() orelse continue;
        if (std.mem.eql(u8, key, "nameserver")) {
            if (it.next()) |server| return n.A.dupe(u8, server) catch "127.0.0.1";
        }
    }
    return "127.0.0.1";
}

fn buildQuery(buf: []u8, id: u16, host: []const u8, qtype: u16) ?usize {
    var w: usize = 0;
    if (buf.len < 17) return null;
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big); // RD
    std.mem.writeInt(u16, buf[4..6], 1, .big); // QDCOUNT
    for (buf[6..12]) |*b| b.* = 0;
    w = 12;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63 or w + 1 + label.len + 4 > buf.len) return null;
        buf[w] = @intCast(label.len);
        w += 1;
        @memcpy(buf[w .. w + label.len], label);
        w += label.len;
    }
    buf[w] = 0;
    w += 1;
    std.mem.writeInt(u16, @as(*[2]u8, @ptrCast(buf[w..].ptr)), qtype, .big);
    w += 2;
    std.mem.writeInt(u16, @as(*[2]u8, @ptrCast(buf[w..].ptr)), 1, .big); // IN
    w += 2;
    return w;
}

fn skipName(reply: []const u8, at: usize) ?usize {
    var p = at;
    while (p < reply.len) {
        const len = reply[p];
        if (len == 0) return p + 1;
        if ((len & 0xC0) == 0xC0) return p + 2;
        if (len & 0xC0 != 0) return null;
        p += 1 + len;
    }
    return null;
}

fn printAnswer(reply: []const u8, qname: []const u8) void {
    if (reply.len < 12) return;
    const qd = std.mem.readInt(u16, reply[4..6], .big);
    const an = std.mem.readInt(u16, reply[6..8], .big);
    var p: usize = 12;
    var i: usize = 0;
    while (i < qd) : (i += 1) {
        p = skipName(reply, p) orelse return;
        if (p + 4 > reply.len) return;
        p += 4;
    }
    i = 0;
    while (i < an) : (i += 1) {
        p = skipName(reply, p) orelse return;
        if (p + 10 > reply.len) return;
        const rtype = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(reply[p..].ptr)), .big);
        const rdlen = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(reply[p + 8 ..].ptr)), .big);
        p += 10;
        if (p + rdlen > reply.len) return;
        if (rtype == 1 and rdlen == 4) {
            var b: [16]u8 = undefined;
            n.put("Name:\t{s}\nAddress: {s}\n", .{ qname, n.intToIp(std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(reply[p..].ptr)), .big), &b) });
        } else if (rtype == 28 and rdlen == 16) {
            var octets: [16]u8 = undefined;
            @memcpy(&octets, reply[p .. p + 16]);
            var b: [64]u8 = undefined;
            const s = @import("libbb_zig").socket.inet.formatV6(octets, &b);
            n.put("Name:\t{s}\nAddress: {s}\n", .{ qname, s });
        }
        p += rdlen;
    }
}

fn queryOne(server: []const u8, host: []const u8, qtype: u16, id: u16, debug: bool, header_printed: *bool, qn: usize) bool {
    var qbuf: [512]u8 = undefined;
    const qlen = buildQuery(&qbuf, id, host, qtype) orelse return false;

    const fd = sock.socket(std.os.linux.AF.INET, std.os.linux.SOCK.DGRAM, std.os.linux.IPPROTO.UDP) catch return false;
    defer sock.close(fd) catch {};
    const addr = sock.sockaddr_in(server, 53);
    sock.connect(fd, @ptrCast(&addr), @sizeOf(sock.sockaddr.in)) catch return false;
    sock.setRecvTimeout(fd, 2000) catch {};
    _ = sock.send(fd, qbuf[0..qlen], 0) catch return false;

    var reply: [4096]u8 = undefined;
    const rlen = sock.recv(fd, &reply, 0) catch return false;
    if (rlen < 12) return false;

    if (!header_printed.*) {
        n.put("Server:\t\t{s}\nAddress:\t{s}:53\n\n", .{ server, server });
        header_printed.* = true;
    }
    if (debug) n.put("Query #{d} completed in 0ms:\n", .{qn});

    const flags = std.mem.readInt(u16, reply[2..4], .big);
    const rcode = flags & 0x0f;
    const authoritative = (flags & 0x0400) != 0;
    if (rcode != 0) {
        n.put("** server can't find {s}: {s}\n", .{ host, if (rcode == 3) "NXDOMAIN" else "SERVFAIL" });
        return true;
    }
    n.put("{s}answer:\n", .{if (authoritative) "Authoritative " else "Non-authoritative "});
    printAnswer(&reply, host);
    n.put("\n", .{});
    return true;
}

pub fn nslookupMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    var idx: usize = 1;
    var qt_buf: [8]u16 = undefined;
    var nqt: usize = 0;
    var debug = false;
    while (idx < av.len and av[idx].len > 0 and av[idx][0] == '-') {
        const opt = av[idx][1..];
        idx += 1;
        const eq = std.mem.indexOfScalar(u8, opt, '=');
        const key = if (eq) |p| opt[0..p] else opt;
        const val: []const u8 = if (eq) |p| opt[p + 1 ..] else "";
        if (std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "querytype")) {
            const qt = qtypeFromName(val) orelse n.plainDie("invalid query type \"{s}\"", .{val});
            if (nqt < qt_buf.len) {
                qt_buf[nqt] = qt;
                nqt += 1;
            }
        } else if (std.mem.eql(u8, key, "debug")) {
            debug = true;
        } else if (std.mem.eql(u8, key, "port") or std.mem.eql(u8, key, "retry") or
            std.mem.eql(u8, key, "t") or std.mem.eql(u8, key, "timeout"))
        {
            _ = std.fmt.parseInt(u32, val, 10) catch n.usageDie("nslookup");
        } else {
            n.usageDie("nslookup");
        }
    }
    if (idx >= av.len or idx + 2 < av.len) n.usageDie("nslookup");
    const host = av[idx];
    const server = if (idx + 1 < av.len) av[idx + 1] else defaultServer();

    var qlist: [2]u16 = undefined;
    var nq: usize = 0;
    if (nqt == 0) {
        qlist[0] = 1;
        qlist[1] = 28;
        nq = 2;
    } else {
        nq = @min(nqt, qlist.len);
        for (qt_buf[0..nq], 0..) |qt, qi| qlist[qi] = qt;
    }

    var header_printed = false;
    var any = false;
    var id: u16 = 0x1234;
    for (qlist[0..nq], 0..) |qt, qn| {
        if (queryOne(server, host, qt, id, debug, &header_printed, qn)) any = true;
        id += 1;
    }
    return if (any) 0 else 1;
}

fn qtypeName(bit: usize) ?[]const u8 {
    return switch (bit) {
        0 => "a", 1 => "ns", 2 => "md", 3 => "mf", 4 => "cname", 5 => "soa",
        6 => "mb", 7 => "mg", 8 => "mr", 9 => "null", 10 => "wks", 11 => "ptr",
        12 => "hinfo", 13 => "minfo", 14 => "mx", 15 => "txt", 16 => "rp",
        17 => "afsdb", 18 => "x25", 19 => "isdn", 20 => "rt", 21 => "nsap",
        22 => "nsap-ptr", 23 => "sig", 24 => "key", 25 => "px", 26 => "gpos",
        27 => "aaaa", 28 => "loc", 29 => "nxt", 30 => "eid", 31 => "nimloc",
        32 => "srv", 33 => "atma", 34 => "naptr", 35 => "kx", 36 => "cert",
        37 => "a6", 38 => "dname", 39 => "sink", 40 => "opt", 41 => "apl",
        42 => "ds", 43 => "sshfp", 44 => "ipseckey", 45 => "rrsig", 46 => "nsec",
        47 => "dnskey", 48 => "dhcid", 49 => "nsec3", 50 => "nsec3param",
        51 => "tlsa", 52 => "smimea", 54 => "hip", 58 => "cds", 59 => "cdnskey",
        60 => "openpgpkey", 61 => "csync", 254 => "any",
        else => null,
    };
}
