//! High-level TCP/UDP socket helpers (Wave 3 prerequisites).
//! Built directly on linux syscalls so it stays independent of libc and of
//! the legacy `socket.zig` API, which re-exports the entry points from here.

const std = @import("std");
const linux = std.os.linux;
const inet = @import("inet.zig");

pub const fd_t = linux.fd_t;
pub const socklen_t = linux.socklen_t;
pub const Ip = inet.Ip;

pub const SockError = error{
    SyscallFailed,
    WouldBlock,
    Timeout,
    ConnectionRefused,
    HostUnreachable,
    NetworkUnreachable,
    AddrInUse,
    ConnectionClosed,
    NotConnected,
    InvalidAddress,
};

fn mapErrno(e: linux.E) SockError {
    return switch (e) {
        .AGAIN => error.WouldBlock,
        .TIMEDOUT => error.Timeout,
        .CONNREFUSED => error.ConnectionRefused,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .ADDRINUSE => error.AddrInUse,
        .NOTCONN => error.NotConnected,
        else => error.SyscallFailed,
    };
}

fn check(rc: anytype) SockError!void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

/// A resolved network address: IP bytes plus a host-order port.
pub const Address = struct {
    ip: Ip,
    port: u16,

    pub fn initV4(a: [4]u8, port: u16) Address {
        return .{ .ip = .{ .v4 = a }, .port = port };
    }
    pub fn initV6(a: [16]u8, port: u16) Address {
        return .{ .ip = .{ .v6 = a }, .port = port };
    }

    pub fn family(self: Address) u16 {
        return switch (self.ip) {
            .v4 => linux.AF.INET,
            .v6 => linux.AF.INET6,
        };
    }

    /// Return a kernel-ready sockaddr plus its length.
    pub fn toSockaddr(self: Address) struct { data: linux.sockaddr.storage, len: socklen_t } {
        var st: linux.sockaddr.storage = undefined;
        @memset(&st.padding, 0);
        var len: socklen_t = undefined;
        switch (self.ip) {
            .v4 => |bytes| {
                const sin: *linux.sockaddr.in = @ptrCast(&st);
                var addr_be: u32 = undefined;
                const p: *[4]u8 = @ptrCast(&addr_be);
                p.* = bytes;
                sin.* = .{ .port = @byteSwap(self.port), .addr = addr_be };
                len = @sizeOf(linux.sockaddr.in);
            },
            .v6 => |bytes| {
                const sin6: *linux.sockaddr.in6 = @ptrCast(&st);
                sin6.* = .{ .port = @byteSwap(self.port), .flowinfo = 0, .addr = bytes, .scope_id = 0 };
                len = @sizeOf(linux.sockaddr.in6);
            },
        }
        return .{ .data = st, .len = len };
    }

    pub fn fromSockaddr(st: *const linux.sockaddr.storage, len: socklen_t) SockError!Address {
        const fam = st.family;
        if (fam == linux.AF.INET) {
            if (len < @sizeOf(linux.sockaddr.in)) return error.InvalidAddress;
            const sin: *const linux.sockaddr.in = @ptrCast(st);
            const bytes: *const [4]u8 = @ptrCast(&sin.addr);
            return Address.initV4(bytes.*, @byteSwap(sin.port));
        }
        if (fam == linux.AF.INET6) {
            if (len < @sizeOf(linux.sockaddr.in6)) return error.InvalidAddress;
            const sin6: *const linux.sockaddr.in6 = @ptrCast(st);
            return Address.initV6(sin6.addr, @byteSwap(sin6.port));
        }
        return error.InvalidAddress;
    }

    pub fn format(self: Address, buf: []u8) []const u8 {
        return inet.format(self.ip, buf);
    }
};

fn domainFor(addr: Address) u32 {
    return switch (addr.ip) {
        .v4 => linux.AF.INET,
        .v6 => linux.AF.INET6,
    };
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SockError!fd_t {
    const rc = linux.socket(domain, socket_type, protocol);
    try check(rc);
    return @intCast(rc);
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn shutdown(fd: fd_t, how: i32) SockError!void {
    try check(linux.shutdown(fd, how));
}

pub fn setReuseAddr(fd: fd_t) SockError!void {
    const one: i32 = 1;
    try check(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), @sizeOf(i32)));
}

pub fn setBroadcast(fd: fd_t) SockError!void {
    const one: i32 = 1;
    try check(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.BROADCAST, @ptrCast(&one), @sizeOf(i32)));
}

/// Set SO_RCVTIMEO/SO_SNDTIMEO (milliseconds). Zero means "no timeout".
pub fn setRecvTimeout(fd: fd_t, ms: u32) SockError!void {
    const tv = linux.timeval{ .sec = ms / 1000, .usec = (ms % 1000) * 1000 };
    try check(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval)));
}

pub fn setSendTimeout(fd: fd_t, ms: u32) SockError!void {
    const tv = linux.timeval{ .sec = ms / 1000, .usec = (ms % 1000) * 1000 };
    try check(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval)));
}

pub fn setNonBlocking(fd: fd_t) SockError!void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    try check(flags);
    var o: linux.O = @bitCast(@as(u32, @truncate(flags)));
    o.NONBLOCK = true;
    try check(linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(o))))));
}

pub fn setBlocking(fd: fd_t) SockError!void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    try check(flags);
    var o: linux.O = @bitCast(@as(u32, @truncate(flags)));
    o.NONBLOCK = false;
    try check(linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(o))))));
}

/// Wait until a fd becomes readable, writable, or the timeout (ms) elapses.
/// Returns true if an event occurred, false on timeout.
pub fn wait(fd: fd_t, readable: bool, writable: bool, timeout_ms: i32) SockError!bool {
    var pfd = linux.pollfd{
        .fd = fd,
        .events = (if (readable) @as(i16, linux.POLL.IN) else 0) |
            (if (writable) @as(i16, linux.POLL.OUT) else 0),
        .revents = 0,
    };
    const rc = linux.poll(@ptrCast(&pfd), 1, timeout_ms);
    try check(rc);
    if (rc == 0) return false;
    return (pfd.revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL)) == 0;
}

/// Create a stream socket and connect to `addr`.
pub fn createAndConnect(addr: Address) SockError!fd_t {
    const fd = try socket(domainFor(addr), linux.SOCK.STREAM, 0);
    errdefer close(fd);
    const sa = addr.toSockaddr();
    try check(linux.connect(fd, @ptrCast(&sa.data), sa.len));
    return fd;
}

/// Create a stream socket bound to `addr`, with SO_REUSEADDR set.
pub fn createAndBind(addr: Address) SockError!fd_t {
    const fd = try socket(domainFor(addr), linux.SOCK.STREAM, 0);
    errdefer close(fd);
    try setReuseAddr(fd);
    const sa = addr.toSockaddr();
    try check(linux.bind(fd, @ptrCast(&sa.data), sa.len));
    return fd;
}

/// Bind + listen in one step.
pub fn createAndListen(addr: Address, backlog: u32) SockError!fd_t {
    const fd = try createAndBind(addr);
    errdefer close(fd);
    try check(linux.listen(fd, backlog));
    return fd;
}

pub fn listen(fd: fd_t, backlog: u32) SockError!void {
    try check(linux.listen(fd, backlog));
}

pub fn bind(fd: fd_t, addr: Address) SockError!void {
    const sa = addr.toSockaddr();
    try check(linux.bind(fd, @ptrCast(&sa.data), sa.len));
}

pub fn connect(fd: fd_t, addr: Address) SockError!void {
    const sa = addr.toSockaddr();
    try check(linux.connect(fd, @ptrCast(&sa.data), sa.len));
}

pub fn accept(fd: fd_t) SockError!fd_t {
    const rc = linux.accept(fd, null, null);
    try check(rc);
    return @intCast(rc);
}

pub fn acceptFrom(fd: fd_t) SockError!struct { fd: fd_t, addr: Address } {
    var st: linux.sockaddr.storage = undefined;
    var len: socklen_t = @sizeOf(linux.sockaddr.storage);
    const rc = linux.accept(fd, @ptrCast(&st), &len);
    try check(rc);
    const addr = Address.fromSockaddr(&st, len) catch Address.initV4(.{ 0, 0, 0, 0 }, 0);
    return .{ .fd = @intCast(rc), .addr = addr };
}

pub fn localAddr(fd: fd_t) SockError!Address {
    var st: linux.sockaddr.storage = undefined;
    var len: socklen_t = @sizeOf(linux.sockaddr.storage);
    try check(linux.getsockname(fd, @ptrCast(&st), &len));
    return Address.fromSockaddr(&st, len);
}

pub fn peerAddr(fd: fd_t) SockError!Address {
    var st: linux.sockaddr.storage = undefined;
    var len: socklen_t = @sizeOf(linux.sockaddr.storage);
    try check(linux.getpeername(fd, @ptrCast(&st), &len));
    return Address.fromSockaddr(&st, len);
}

pub fn send(fd: fd_t, bytes: []const u8, flags: u32) SockError!usize {
    if (bytes.len == 0) return 0;
    const rc = linux.sendto(fd, bytes.ptr, bytes.len, flags, null, 0);
    try check(rc);
    return @intCast(rc);
}

/// Send every byte, handling short writes and EINTR.
pub fn sendAll(fd: fd_t, bytes: []const u8, flags: u32) SockError!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(fd, bytes[off..], flags) catch |e| switch (e) {
            error.WouldBlock => {
                if (!try wait(fd, false, true, -1)) return error.Timeout;
                continue;
            },
            else => return e,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

pub fn recv(fd: fd_t, buf: []u8, flags: u32) SockError!usize {
    if (buf.len == 0) return 0;
    const rc = linux.recvfrom(fd, buf.ptr, buf.len, flags, null, null);
    try check(rc);
    return @intCast(rc);
}

/// Receive until `buf` is completely filled. Returns the number of bytes read
/// (always buf.len on success); returns error.ConnectionClosed on early EOF.
pub fn recvAll(fd: fd_t, buf: []u8, flags: u32) SockError!usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = recv(fd, buf[off..], flags) catch |e| switch (e) {
            error.WouldBlock => {
                if (!try wait(fd, true, false, -1)) return error.Timeout;
                continue;
            },
            else => return e,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
    return off;
}

/// Receive once, returning error.ConnectionClosed on EOF.
pub fn recvSome(fd: fd_t, buf: []u8, flags: u32) SockError!usize {
    const n = try recv(fd, buf, flags);
    if (n == 0) return error.ConnectionClosed;
    return n;
}

// ---- UDP helpers ----

pub fn createUdp(addr: Address) SockError!fd_t {
    const fd = try socket(domainFor(addr), linux.SOCK.DGRAM, linux.IPPROTO.UDP);
    errdefer close(fd);
    const sa = addr.toSockaddr();
    try check(linux.bind(fd, @ptrCast(&sa.data), sa.len));
    return fd;
}

pub fn sendTo(fd: fd_t, bytes: []const u8, addr: Address, flags: u32) SockError!usize {
    const sa = addr.toSockaddr();
    const rc = linux.sendto(fd, bytes.ptr, bytes.len, flags, @ptrCast(&sa.data), sa.len);
    try check(rc);
    return @intCast(rc);
}

pub fn recvFrom(fd: fd_t, buf: []u8, flags: u32) SockError!struct { n: usize, addr: Address } {
    var st: linux.sockaddr.storage = undefined;
    var len: socklen_t = @sizeOf(linux.sockaddr.storage);
    const rc = linux.recvfrom(fd, buf.ptr, buf.len, flags, @ptrCast(&st), &len);
    try check(rc);
    const addr = Address.fromSockaddr(&st, len) catch Address.initV4(.{ 0, 0, 0, 0 }, 0);
    return .{ .n = @intCast(rc), .addr = addr };
}

pub const any_v4 = Address.initV4(.{ 0, 0, 0, 0 }, 0);
pub const loopback_v4 = Address.initV4(.{ 127, 0, 0, 1 }, 0);
