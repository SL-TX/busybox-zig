//! Self-contained DNS resolver used by the networking applets.
//!
//! Resolution order: numeric literal -> /etc/hosts -> DNS (UDP) with CNAME
//! chasing. The configuration files can be overridden, which keeps the
//! resolver fully testable against a loopback DNS test server.

const std = @import("std");
const linux = std.os.linux;
const net = @import("socket.zig");
const inet = @import("inet.zig");

fn dupeZ(allocator: std.mem.Allocator, s: []const u8) ?[:0]u8 {
    const buf = allocator.alloc(u8, s.len + 1) catch return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

var id_counter = std.atomic.Value(u32).init(0);
fn randomId() u16 {
    var b: [2]u8 = undefined;
    const rc = linux.getrandom(&b, b.len, 0);
    if (linux.errno(rc) == .SUCCESS) return std.mem.readInt(u16, &b, .big);
    return @truncate(id_counter.fetchAdd(1, .monotonic));
}

/// Read a text file with raw syscalls (no dependency on the Io interface).
fn readTextFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const zpath = dupeZ(allocator, path) orelse return null;
    defer allocator.free(zpath);
    const rc = linux.open(zpath.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: net.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var list = std.ArrayList(u8).empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const nrc = linux.read(fd, &buf, buf.len);
        if (linux.errno(nrc) != .SUCCESS) break;
        const n: usize = @intCast(nrc);
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..n]) catch return null;
    }
    return list.toOwnedSlice(allocator) catch null;
}

pub const DnsError = error{
    NXDomain,
    ServerFailure,
    Timeout,
    NoServers,
    NoAddresses,
    MalformedResponse,
    OutOfMemory,
};

const TYPE_A: u16 = 1;
const TYPE_CNAME: u16 = 5;
const TYPE_AAAA: u16 = 28;
const CLASS_IN: u16 = 1;

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    resolv_conf_path: []const u8 = "/etc/resolv.conf",
    hosts_path: []const u8 = "/etc/hosts",
    timeout_ms: u32 = 3000,
    /// Explicit nameserver list; when set, /etc/resolv.conf is not read.
    servers: ?[]const net.Address = null,

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return .{ .allocator = allocator };
    }

    /// Resolve `name` to zero or more addresses on `port`.
    pub fn lookupHost(self: *Resolver, name: []const u8, port: u16) DnsError![]net.Address {
        if (name.len == 0) return error.NoAddresses;

        // 1. Numeric literal (IPv4 or IPv6).
        if (inet.parse(name)) |ip| {
            const out = try self.allocator.alloc(net.Address, 1);
            out[0] = .{ .ip = ip, .port = port };
            return out;
        }

        // 2. /etc/hosts (supports multiple addresses per line).
        var found = std.ArrayList(net.Address).empty;
        self.readHosts(name, port, &found) catch {};
        if (found.items.len > 0) return found.toOwnedSlice(self.allocator) catch error.OutOfMemory;

        // 3. DNS, following CNAMEs.
        var current: []const u8 = name;
        var owns_current = false;
        defer if (owns_current) self.allocator.free(@constCast(current));
        var hops: usize = 0;
        var first_error: ?DnsError = null;
        while (hops < 4) : (hops += 1) {
            var queried = false;
            for ([_]u16{ TYPE_A, TYPE_AAAA }) |qtype| {
                const addrs = self.query(current, port, qtype) catch |e| {
                    if (first_error == null) first_error = e;
                    continue;
                };
                defer self.allocator.free(addrs);
                queried = true;
                for (addrs) |a| addUnique(self.allocator, &found, a);
            }
            if (queried and found.items.len > 0) break;

            // Follow the first CNAME seen, if any.
            const cname = self.firstCname(current) orelse break;
            if (std.ascii.eqlIgnoreCase(cname, current)) break;
            if (owns_current) self.allocator.free(@constCast(current));
            current = cname;
            owns_current = true;
        }

        if (found.items.len == 0) {
            if (first_error) |e| return e;
            return error.NoAddresses;
        }
        return found.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }

    fn addUnique(allocator: std.mem.Allocator, list: *std.ArrayList(net.Address), a: net.Address) void {
        for (list.items) |existing| {
            if (existing.port == a.port and inet.Ip.eql(existing.ip, a.ip)) return;
        }
        list.append(allocator, a) catch {};
    }

    fn readHosts(self: *Resolver, name: []const u8, port: u16, out: *std.ArrayList(net.Address)) !void {
        const data = readTextFile(self.allocator, self.hosts_path) orelse return;
        defer self.allocator.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const ip_text = fields.next() orelse continue;
            const ip = inet.parse(ip_text) orelse continue;
            while (fields.next()) |alias| {
                if (std.ascii.eqlIgnoreCase(alias, name)) {
                    addUnique(self.allocator, out, .{ .ip = ip, .port = port });
                }
            }
        }
    }

    fn loadServers(self: *Resolver) DnsError![]net.Address {
        if (self.servers) |s| {
            if (s.len == 0) return error.NoServers;
            return @constCast(s);
        }
        const data = readTextFile(self.allocator, self.resolv_conf_path) orelse return error.NoServers;
        defer self.allocator.free(data);

        var list = std.ArrayList(net.Address).empty;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const keyword = fields.next() orelse continue;
            if (!std.mem.eql(u8, keyword, "nameserver")) continue;
            const value = fields.next() orelse continue;
            var host = value;
            var port: u16 = 53;
            if (std.mem.lastIndexOfScalar(u8, value, ':')) |idx| {
                if (std.fmt.parseInt(u16, value[idx + 1 ..], 10)) |p| {
                    port = p;
                    host = value[0..idx];
                } else |_| {}
            }
            // Strip optional IPv6 zone marker used by some resolv.conf files.
            if (std.mem.indexOfScalar(u8, host, '%')) |idx| host = host[0..idx];
            if (inet.parse(host)) |ip| {
                list.append(self.allocator, .{ .ip = ip, .port = port }) catch return error.OutOfMemory;
            }
        }
        if (list.items.len == 0) return error.NoServers;
        return list.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }

    fn buildQuery(name: []const u8, qtype: u16, id: u16, buf: []u8) ?usize {
        if (name.len == 0 or buf.len < 12 + name.len + 8) return null;
        var w: usize = 0;
        std.mem.writeInt(u16, buf[w..][0..2], id, .big);
        w += 2;
        std.mem.writeInt(u16, buf[w..][0..2], 0x0100, .big); // recursion desired
        w += 2;
        std.mem.writeInt(u16, buf[w..][0..2], 1, .big); // QDCOUNT
        w += 2;
        std.mem.writeInt(u16, buf[w..][0..2], 0, .big);
        w += 2;
        std.mem.writeInt(u16, buf[w..][0..2], 0, .big);
        w += 2;
        std.mem.writeInt(u16, buf[w..][0..2], 0, .big);
        w += 2;

        var labels = std.mem.splitScalar(u8, name, '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63) return null;
            buf[w] = @intCast(label.len);
            w += 1;
            @memcpy(buf[w .. w + label.len], label);
            w += label.len;
        }
        buf[w] = 0;
        w += 1;
        std.mem.writeInt(u16, buf[w..][0..2], qtype, .big);
        w += 2;
        std.mem.writeInt(u16, buf[w..][0..2], CLASS_IN, .big);
        w += 2;
        return w;
    }

    fn query(self: *Resolver, name: []const u8, port: u16, qtype: u16) DnsError![]net.Address {
        const servers = try self.loadServers();
        defer if (self.servers == null) self.allocator.free(servers);

        const id: u16 = randomId();
        var qbuf: [512]u8 = undefined;
        const qlen = buildQuery(name, qtype, id, &qbuf) orelse return error.MalformedResponse;

        var last_error: DnsError = error.NoAddresses;
        for (servers) |server| {
            const fd = net.createUdp(.{ .ip = server.ip, .port = 0 }) catch continue;
            defer net.close(fd);
            net.setRecvTimeout(fd, self.timeout_ms) catch {};
            _ = net.sendTo(fd, qbuf[0..qlen], server, 0) catch {
                last_error = error.Timeout;
                continue;
            };

            var rbuf: [4096]u8 = undefined;
            const got = net.recvFrom(fd, &rbuf, 0) catch |e| {
                last_error = switch (e) {
                    error.WouldBlock, error.Timeout => error.Timeout,
                    else => error.NoAddresses,
                };
                continue;
            };
            if (got.n < 12) return error.MalformedResponse;
            const msg = rbuf[0..got.n];
            const resp_id = std.mem.readInt(u16, msg[0..2], .big);
            if (resp_id != id) continue;
            const flags = std.mem.readInt(u16, msg[2..4], .big);
            const rcode = flags & 0x0f;
            if (rcode == 3) return error.NXDomain;
            if (rcode == 2) return error.ServerFailure;
            if (rcode != 0) return error.MalformedResponse;

            const qd = std.mem.readInt(u16, msg[4..6], .big);
            const an = std.mem.readInt(u16, msg[6..8], .big);
            var off: usize = 12;
            for (0..qd) |_| {
                off = skipName(msg, off) catch return error.MalformedResponse;
                if (off + 4 > msg.len) return error.MalformedResponse;
                off += 4;
            }

            var out = std.ArrayList(net.Address).empty;
            var seen_cname = false;
            var i: usize = 0;
            while (i < an) : (i += 1) {
                off = skipName(msg, off) catch return error.MalformedResponse;
                if (off + 10 > msg.len) return error.MalformedResponse;
                const rtype = std.mem.readInt(u16, msg[off..][0..2], .big);
                const rclass = std.mem.readInt(u16, msg[off..][2..4], .big);
                const rdlen = std.mem.readInt(u16, msg[off..][8..10], .big);
                off += 10;
                if (off + rdlen > msg.len) return error.MalformedResponse;
                if (rclass == CLASS_IN) {
                    if (rtype == TYPE_A and rdlen >= 4) {
                        var ip: [4]u8 = undefined;
                        @memcpy(&ip, msg[off .. off + 4]);
                        addUnique(self.allocator, &out, net.Address.initV4(ip, port));
                    } else if (rtype == TYPE_AAAA and rdlen >= 16) {
                        var ip: [16]u8 = undefined;
                        @memcpy(&ip, msg[off .. off + 16]);
                        addUnique(self.allocator, &out, net.Address.initV6(ip, port));
                    } else if (rtype == TYPE_CNAME) {
                        seen_cname = true;
                    }
                }
                off += rdlen;
            }
            if (out.items.len > 0) return out.toOwnedSlice(self.allocator) catch error.OutOfMemory;
            if (seen_cname) return error.NoAddresses;
            last_error = error.NoAddresses;
        }
        return last_error;
    }

    /// Issue a CNAME query and return the first target name, if present.
    fn firstCname(self: *Resolver, name: []const u8) ?[]const u8 {
        const servers = self.loadServers() catch return null;
        defer if (self.servers == null) self.allocator.free(servers);
        const id: u16 = randomId();
        var qbuf: [512]u8 = undefined;
        const qlen = buildQuery(name, TYPE_CNAME, id, &qbuf) orelse return null;
        for (servers) |server| {
            const fd = net.createUdp(.{ .ip = server.ip, .port = 0 }) catch continue;
            defer net.close(fd);
            net.setRecvTimeout(fd, self.timeout_ms) catch {};
            _ = net.sendTo(fd, qbuf[0..qlen], server, 0) catch continue;
            var rbuf: [4096]u8 = undefined;
            const got = net.recvFrom(fd, &rbuf, 0) catch continue;
            if (got.n < 12) continue;
            const msg = rbuf[0..got.n];
            if (std.mem.readInt(u16, msg[0..2], .big) != id) continue;
            const rcode = std.mem.readInt(u16, msg[2..4], .big) & 0xf;
            if (rcode != 0) continue;
            const qd = std.mem.readInt(u16, msg[4..6], .big);
            const an = std.mem.readInt(u16, msg[6..8], .big);
            var off: usize = 12;
            for (0..qd) |_| {
                off = skipName(msg, off) catch return null;
                if (off + 4 > msg.len) return null;
                off += 4;
            }
            var i: usize = 0;
            while (i < an) : (i += 1) {
                off = skipName(msg, off) catch return null;
                if (off + 10 > msg.len) return null;
                const rtype = std.mem.readInt(u16, msg[off..][0..2], .big);
                const rdlen = std.mem.readInt(u16, msg[off..][8..10], .big);
                off += 10;
                if (off + rdlen > msg.len) return null;
                if (rtype == TYPE_CNAME) {
                    var namebuf: [256]u8 = undefined;
                    const n = readName(msg, off, &namebuf) catch return null;
                    if (n.len > 0) return self.allocator.dupe(u8, n) catch null;
                }
                off += rdlen;
            }
            return null;
        }
        return null;
    }
};

/// Skip a (possibly compressed) DNS name and return the offset just after it.
fn skipName(msg: []const u8, offset: usize) DnsError!usize {
    var pos = offset;
    var jumps: usize = 0;
    while (true) {
        if (pos >= msg.len) return error.MalformedResponse;
        const len = msg[pos];
        if (len & 0xc0 == 0xc0) {
            if (pos + 1 >= msg.len) return error.MalformedResponse;
            if (jumps == 0) pos = (@as(usize, len & 0x3f) << 8) | msg[pos + 1];
            jumps += 1;
            if (jumps > 16) return error.MalformedResponse;
            continue;
        }
        if (len & 0xc0 != 0) return error.MalformedResponse;
        pos += 1;
        if (len == 0) break;
        pos += len;
        if (pos > msg.len) return error.MalformedResponse;
    }
    return pos;
}

/// Decode a (possibly compressed) DNS name into dotted text.
fn readName(msg: []const u8, offset: usize, out: []u8) DnsError![]const u8 {
    var pos = offset;
    var w: usize = 0;
    var jumped = false;
    var next_after_jump: usize = 0;
    var jumps: usize = 0;
    while (true) {
        if (pos >= msg.len) return error.MalformedResponse;
        const len = msg[pos];
        if (len & 0xc0 == 0xc0) {
            if (pos + 1 >= msg.len) return error.MalformedResponse;
            if (!jumped) next_after_jump = pos + 2;
            pos = (@as(usize, len & 0x3f) << 8) | msg[pos + 1];
            jumped = true;
            jumps += 1;
            if (jumps > 16) return error.MalformedResponse;
            continue;
        }
        if (len & 0xc0 != 0) return error.MalformedResponse;
        pos += 1;
        if (len == 0) break;
        if (pos + len > msg.len) return error.MalformedResponse;
        if (w > 0) {
            if (w + 1 >= out.len) return error.MalformedResponse;
            out[w] = '.';
            w += 1;
        }
        if (w + len > out.len) return error.MalformedResponse;
        @memcpy(out[w .. w + len], msg[pos .. pos + len]);
        w += len;
        pos += len;
    }
    return out[0..w];
}

/// Convenience entry point mirroring `lookupHost(name, port)` from the brief.
/// Results are allocated with page_allocator; release with `freeAddresses`.
pub fn lookupHost(name: []const u8, port: u16) DnsError![]net.Address {
    var resolver = Resolver.init(std.heap.page_allocator);
    return resolver.lookupHost(name, port);
}

pub fn freeAddresses(addrs: []net.Address) void {
    std.heap.page_allocator.free(addrs);
}
