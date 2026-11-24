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

/// Extract the value of an option from argv, accepting all the forms the
/// reference getopt32 accepts: `-X value`, `-Xvalue`, `-abcXvalue` (attached
/// to the end of a short-option cluster) and `--long=value` / `--long value`.
pub fn optionValue(args: []const []const u8, start: usize, end: usize, short: u8, long: ?[]const u8, flag_chars: []const u8) ?[]const u8 {
    var i = start;
    while (i < end) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-') continue;
        if (a[1] == '-') {
            if (long) |l| {
                const body = a[2..];
                if (std.mem.startsWith(u8, body, l)) {
                    if (body.len > l.len and body[l.len] == '=') return body[l.len + 1 ..];
                    if (body.len == l.len and i + 1 < end) return args[i + 1];
                }
            }
            continue;
        }
        // Walk the short-option cluster; everything after an argument-taking
        // option is its value and must not be mistaken for another option.
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const ch = a[j];
            if (ch == short) {
                if (j + 1 < a.len) return a[j + 1 ..];
                if (i + 1 < end) return args[i + 1];
                return null;
            }
            if (std.mem.indexOfScalar(u8, flag_chars, ch) == null) break;
        }
    }
    return null;
}

pub fn sleepSec(seconds: u32) void {
    if (seconds == 0) return;
    var req = linux.timespec{ .sec = @intCast(seconds), .nsec = 0 };
    _ = linux.nanosleep(&req, &req);
}

pub fn stderrRaw(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        done += @intCast(rc);
    }
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
fn hexLog(log_fd: ?linux.fd_t, direction: u8, bytes: []const u8) void {
    const lf = log_fd orelse return;
    var line: [256]u8 = undefined;
    var at: usize = 0;
    line[at] = direction;
    at += 1;
    for (bytes) |b| {
        const h = std.fmt.bufPrint(line[at..], " {x:0>2}", .{b}) catch break;
        at += h.len;
    }
    line[at] = '\n';
    at += 1;
    _ = linux.write(lf, line[0..at].ptr, at);
}

pub const RelayOpts = struct {
    wait_sec: u32 = 0,
    interval_sec: u32 = 0,
    verbose: u32 = 0,
    telnet_mode: bool = false,
    log_fd: ?linux.fd_t = null,
};

pub const RelayStats = struct {
    sent: u64 = 0,
    received: u64 = 0,
    timed_out: bool = false,
};

/// The readwrite() loop from nc_bloaty.c: poll stdin and the socket, honour
/// -w (poll timeout, with the two-strike `netretry` before "net timeout") and
/// -i (sleep before the first write and between individual lines).
pub fn relay(fd: linux.fd_t, opts: RelayOpts) RelayStats {
    var stats = RelayStats{};
    var inbuf: [8192]u8 = undefined;
    var outbuf: [8192]u8 = undefined;
    var in_len: usize = 0;
    var out_len: usize = 0;
    var stdin_open = true;
    var net_open = true;
    var netretry: u8 = 2;

    if (opts.interval_sec != 0) sleepSec(opts.interval_sec);

    while (stdin_open or net_open) {
        var pfds: [2]linux.pollfd = undefined;
        var count: usize = 0;
        if (stdin_open) {
            pfds[count] = .{ .fd = 0, .events = linux.POLL.IN, .revents = 0 };
            count += 1;
        }
        const net_index = count;
        if (net_open) {
            pfds[count] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            count += 1;
        }
        const tmout: i32 = if (opts.wait_sec != 0) @intCast(opts.wait_sec * 1000) else -1;
        const rr = linux.poll(&pfds, count, tmout);
        if (linux.errno(rr) != .SUCCESS) break;
        if (rr == 0) {
            if (opts.wait_sec != 0 and in_len == 0) {
                netretry -= 1;
                if (netretry == 0) {
                    if (opts.verbose > 1) stderrRaw("net timeout\n");
                    stats.timed_out = true;
                    break;
                }
            }
            continue;
        }

        if (net_open and (pfds[net_index].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) != 0) {
            const got = readSome(fd, &outbuf);
            if (got == 0) {
                net_open = false;
            } else {
                out_len = got;
            }
        }
        var stdin_ready = false;
        if (stdin_open) {
            for (pfds[0..net_index]) |p| {
                if ((p.revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) != 0) stdin_ready = true;
            }
        }
        if (stdin_ready and in_len == 0) {
            const got = readSome(0, &inbuf);
            if (got == 0) {
                stdin_open = false;
                _ = linux.shutdown(fd, linux.SHUT.WR);
            } else {
                in_len = got;
            }
        }

        if (out_len > 0) {
            hexLog(opts.log_fd, '<', outbuf[0..out_len]);
            var write_buf = outbuf[0..out_len];
            if (opts.telnet_mode) {
                var w: usize = 0;
                var k: usize = 0;
                while (k < write_buf.len) {
                    if (write_buf[k] == 0xff and k + 2 < write_buf.len) {
                        k += 3; // IAC <verb> <option>
                        continue;
                    }
                    outbuf[w] = write_buf[k];
                    w += 1;
                    k += 1;
                }
                write_buf = outbuf[0..w];
            }
            n.out(write_buf);
            stats.received += write_buf.len;
            out_len = 0;
        }
        if (in_len > 0 and net_open) {
            var chunk = inbuf[0..in_len];
            if (opts.interval_sec != 0) {
                if (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| chunk = chunk[0 .. nl + 1];
            }
            hexLog(opts.log_fd, '>', chunk);
            if (sendAll(fd, chunk)) {
                stats.sent += chunk.len;
                in_len -= chunk.len;
                if (in_len > 0) std.mem.copyForwards(u8, inbuf[0..in_len], inbuf[chunk.len .. chunk.len + in_len]);
            } else {
                net_open = false;
            }
            if (opts.interval_sec != 0) sleepSec(opts.interval_sec);
        }
    }
    _ = linux.shutdown(fd, linux.SHUT.RDWR);
    return stats;
}
