//! Shared helpers for the Task 13b network clients.
//!
//! Numeric-host resolution, `bb_lookup_port`-compatible port parsing,
//! `xmalloc_sockaddr2dotted`-style "ip:port" rendering and raw TCP/UDP socket
//! creation.  All diagnostics go through netcommon so the program-name prefix
//! and the exact `<prog>: <msg>: <strerror>` shape match the reference.

const std = @import("std");
const n = @import("netcommon.zig");
const sock = @import("libbb_zig").socket;
const linux = std.os.linux;

/// True when `host` is a literal IPv4 address (the only address family the
/// statically linked clients resolve; named hosts fail with "bad address",
/// exactly like the reference does when its resolver cannot resolve them).
pub fn isNumericHost(host: []const u8) bool {
    return sock.inet_pton(host) != null;
}

/// `<normalized-ip>:<port>` — the string `xmalloc_sockaddr2dotted()` prints
/// for an AF_INET endpoint (e.g. 127.0.0.1:21).
pub fn dotted(ip_text: []const u8, port: u16, buf: []u8) []const u8 {
    const addr = sock.inet_pton(ip_text) orelse return ip_text;
    var octets: [16]u8 = undefined;
    const ip = sock.inet_ntop(addr, &octets);
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ ip, port }) catch ip_text;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Port lookup equivalent to `bb_lookup_port(port, proto, default)`:
/// numeric ports are parsed directly, service names are resolved from
/// /etc/services.  Invalid names/ranges die with the reference wording.
pub fn lookupPort(text: ?[]const u8, proto: []const u8, default: u16) u16 {
    const t = text orelse return default;
    if (allDigits(t)) {
        const v = std.fmt.parseInt(u32, t, 10) catch n.plainDie("bad port '{s}'", .{t});
        if (v > 65535) n.plainDie("bad port '{s}'", .{t});
        return @intCast(v);
    }
    const data = n.readWholeFile("/etc/services") catch n.plainDie("bad port '{s}'", .{t});
    defer n.A.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, t)) continue;
        const port_proto = fields.next() orelse continue;
        var pp = std.mem.splitScalar(u8, port_proto, '/');
        const num = pp.next() orelse continue;
        const service_proto = pp.next() orelse continue;
        if (!std.mem.startsWith(u8, service_proto, proto)) continue;
        if (std.fmt.parseInt(u16, num, 10)) |v| return v else |_| {}
    }
    n.plainDie("bad port '{s}'", .{t});
}

pub const Connect = union(enum) { fd: linux.fd_t, errno: c_int };

/// Create a blocking TCP socket and connect to a numeric IPv4 endpoint.
pub fn connectV4(host: []const u8, port: u16) Connect {
    const sfd = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(sfd) != .SUCCESS) return .{ .errno = @intFromEnum(linux.errno(sfd)) };
    const fd: linux.fd_t = @intCast(sfd);
    var addr = sock.sockaddr_in(host, port);
    const rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(sock.sockaddr.in));
    if (linux.errno(rc) != .SUCCESS) {
        const e: c_int = @intFromEnum(linux.errno(rc));
        _ = linux.close(fd);
        return .{ .errno = e };
    }
    return .{ .fd = fd };
}

/// `xconnect_stream_or_die()` / `create_and_connect_stream_or_die()` wording.
pub fn connectOrDie(host: []const u8, port: u16) linux.fd_t {
    if (!isNumericHost(host)) n.plainDie("bad address '{s}'", .{host});
    return switch (connectV4(host, port)) {
        .fd => |fd| fd,
        .errno => |e| blk: {
            n.errorMsg(e, "can't connect to remote host ({s})", .{host});
            std.process.exit(1);
            break :blk 0;
        },
    };
}

pub fn sendAll(fd: linux.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        off += @intCast(rc);
    }
    return true;
}

/// Read whatever is available from an fd until EOF or `max` bytes.  Used by
/// the interactive/line-oriented clients once a connection is established.
pub fn readSome(fd: linux.fd_t, buf: []u8) usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return @intCast(rc);
}

/// Relay loop between stdin and a connected socket, echoing socket data to
/// stdout.  Telnet strips IAC negotiation sequences on the way out.
pub fn relay(fd: linux.fd_t, telnet_mode: bool) void {
    var inbuf: [8192]u8 = undefined;
    var outbuf: [8192]u8 = undefined;
    while (true) {
        const nr = readSome(fd, &outbuf);
        if (nr == 0) break;
        if (telnet_mode) {
            var w: usize = 0;
            var i: usize = 0;
            while (i < nr) {
                if (outbuf[i] == 0xff and i + 2 < nr) {
                    i += 3; // skip IAC <verb> <option>
                    continue;
                }
                outbuf[w] = outbuf[i];
                w += 1;
                i += 1;
            }
            n.out(outbuf[0..w]);
        } else {
            n.out(outbuf[0..nr]);
        }
        const nstdin = readSome(0, &inbuf);
        if (nstdin == 0) break;
        if (!sendAll(fd, inbuf[0..nstdin])) break;
    }
    _ = linux.shutdown(fd, linux.SHUT.RDWR);
}
