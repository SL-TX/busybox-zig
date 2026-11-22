//! Minimal NETLINK_ROUTE dump support for `ip rule show`.

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

pub const Nlm = struct { len: u32, typ: u16, flags: u16, seq: u32, pid: u32 };

pub fn header(raw: []const u8) ?Nlm {
    if (raw.len < 16) return null;
    return .{
        .len = std.mem.readInt(u32, raw[0..4], .little),
        .typ = std.mem.readInt(u16, raw[4..6], .little),
        .flags = std.mem.readInt(u16, raw[6..8], .little),
        .seq = std.mem.readInt(u32, raw[8..12], .little),
        .pid = std.mem.readInt(u32, raw[12..16], .little),
    };
}

pub fn dump(msg_type: u16) ?[]u8 {
    const fd = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW, linux.NETLINK.ROUTE);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));

    var addr: linux.sockaddr.nl = std.mem.zeroes(linux.sockaddr.nl);
    addr.family = linux.AF.NETLINK;
    if (linux.bind(@intCast(fd), @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)) != 0) return null;

    var req: [64]u8 = std.mem.zeroes([64]u8);
    std.mem.writeInt(u32, req[0..4], 17, .little);
    std.mem.writeInt(u16, req[4..6], msg_type, .little);
    std.mem.writeInt(u16, req[6..8], 0x301, .little); // REQUEST | DUMP
    std.mem.writeInt(u32, req[8..12], 1, .little);
    if (linux.write(@intCast(fd), &req, 17) < 17) return null;

    var tv = linux.timeval{ .sec = 1, .usec = 0 };
    _ = linux.setsockopt(@intCast(fd), linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));

    var out: std.ArrayList(u8) = .empty;
    var buf: [16384]u8 = undefined;
    const got = linux.read(@intCast(fd), &buf, buf.len);
    if (linux.errno(got) != .SUCCESS or got == 0) return null;
    out.appendSlice(n.A, buf[0..got]) catch return null;
    return out.toOwnedSlice(n.A) catch null;
}

pub const Attr = struct { kind: u16, data: []const u8 };

pub fn attrs(raw: []const u8) []Attr {
    var list: std.ArrayList(Attr) = .empty;
    var off: usize = 0;
    while (off + 4 <= raw.len) {
        const len = std.mem.readInt(u16, raw[off..][0..2], .little);
        if (len < 4 or off + len > raw.len) break;
        const kind = std.mem.readInt(u16, raw[off + 2 ..][0..2], .little) & 0x3fff;
        list.append(n.A, .{ .kind = kind, .data = raw[off + 4 .. off + len] }) catch break;
        off += (len + 3) & ~@as(usize, 3);
    }
    return list.toOwnedSlice(n.A) catch &.{};
}

pub fn u32at(a: Attr) ?u32 {
    if (a.data.len < 4) return null;
    return std.mem.readInt(u32, a.data[0..4], .little);
}
