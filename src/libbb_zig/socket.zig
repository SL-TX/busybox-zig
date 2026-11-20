//! Socket and address helpers ported from busybox libbb.

const std = @import("std");
const linux = std.os.linux;
const process = @import("process.zig");

pub const sockaddr = linux.sockaddr;
pub const socklen_t = linux.socklen_t;
pub const fd_t = linux.fd_t;

fn check(rc: anytype) !void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        process.errno = @intFromEnum(e);
        return error.SyscallFailed;
    }
}

/// Returns the address in network byte order as stored in memory.
pub fn inet_pton(text: []const u8) ?u32 {
    var parts = std.mem.splitScalar(u8, text, '.');
    var octets: [4]u8 = undefined;
    for (0..4) |i| {
        const part = parts.next() orelse return null;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (parts.next() != null) return null;
    const big = (@as(u32, octets[0]) << 24) | (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) | octets[3];
    return @byteSwap(big);
}

pub fn inet_ntop(addr: u32, buf: []u8) []const u8 {
    const big = @byteSwap(addr);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        @as(u8, @truncate(big >> 24)),
        @as(u8, @truncate(big >> 16)),
        @as(u8, @truncate(big >> 8)),
        @as(u8, @truncate(big)),
    }) catch "";
}

pub fn sockaddr_in(ip: []const u8, port: u16) sockaddr.in {
    return .{
        .port = @byteSwap(port),
        .addr = inet_pton(ip) orelse 0,
    };
}

pub fn portOf(a: *const sockaddr.in) u16 {
    return @byteSwap(a.port);
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) !fd_t {
    const rc = linux.socket(domain, socket_type, protocol);
    try check(rc);
    return @intCast(rc);
}

pub fn close(fd: fd_t) !void {
    try check(linux.close(fd));
}

pub fn bind(fd: fd_t, addr: *const anyopaque) !void {
    const rc = linux.bind(fd, @alignCast(@ptrCast(addr)), @sizeOf(sockaddr));
    try check(rc);
}

pub fn listen(fd: fd_t, backlog: u32) !void {
    try check(linux.listen(fd, backlog));
}

pub fn accept(fd: fd_t, addr: ?*sockaddr, len: ?*socklen_t) !fd_t {
    const rc = linux.accept(fd, addr, len);
    try check(rc);
    return @intCast(rc);
}

pub fn connect(fd: fd_t, addr: *const anyopaque, len: socklen_t) !void {
    try check(linux.connect(fd, @alignCast(@ptrCast(addr)), len));
}

pub fn getsockname(fd: fd_t, addr: *anyopaque, len: *socklen_t) !void {
    try check(linux.getsockname(fd, @alignCast(@ptrCast(addr)), len));
}

pub fn getpeername(fd: fd_t, addr: *anyopaque, len: *socklen_t) !void {
    try check(linux.getpeername(fd, @alignCast(@ptrCast(addr)), len));
}

pub fn send(fd: fd_t, bytes: []const u8, flags: u32) !usize {
    const rc = linux.sendto(fd, bytes.ptr, bytes.len, flags, null, 0);
    try check(rc);
    return @intCast(rc);
}

pub fn recv(fd: fd_t, buf: []u8, flags: u32) !usize {
    const rc = linux.recvfrom(fd, buf.ptr, buf.len, flags, null, null);
    try check(rc);
    return @intCast(rc);
}
