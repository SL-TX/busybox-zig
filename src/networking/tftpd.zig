//! tftpd — TFTP server (networking/tftp.c).
//!
//! The reference checks that stdin is a socket before parsing options, so a
//! pipe stdin always produces the usage banner. With a socket stdin a single
//! TFTP RRQ/WRQ is serviced: the request is read from fd 0 and the DATA/ERROR
//! reply is sent back to the peer via sendto() on fd 0.

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const sock = @import("libbb_zig").socket;
const linux = std.os.linux;

fn stdinIsSocket() bool {
    var storage: [128]u8 = undefined;
    var len: sock.socklen_t = @sizeOf(sock.sockaddr.in);
    sock.getsockname(0, &storage, &len) catch return false;
    return true;
}

fn cstrEnd(bytes: []const u8, start: usize) ?usize {
    var i = start;
    while (i < bytes.len) : (i += 1) if (bytes[i] == 0) return i;
    return null;
}

fn sendPacket(fd: linux.fd_t, peer: *const linux.sockaddr, len: linux.socklen_t, packet: []const u8) void {
    _ = linux.sendto(fd, packet.ptr, packet.len, 0, peer, len);
}

/// Handle one TFTP request arriving on fd 0 (the inetd/udpsvd socket).
fn serveOne() c_int {
    var buf: [4096]u8 = undefined;
    var peer: linux.sockaddr = undefined;
    var plen: linux.socklen_t = @sizeOf(linux.sockaddr);
    const got = linux.recvfrom(0, &buf, buf.len, 0, &peer, &plen);
    if (linux.errno(got) != .SUCCESS) return 1;
    const nread: usize = @intCast(got);
    if (nread < 4) return 1;
    const opcode = (@as(u16, buf[0]) << 8) | buf[1];
    const name_end = cstrEnd(buf[0..nread], 2) orelse return 1;
    const mode_end = cstrEnd(buf[0..nread], name_end + 1) orelse return 1;
    const filename = buf[2..name_end];
    _ = mode_end;

    if (opcode == 1) { // RRQ
        const z = n.zstr(filename) catch return 1;
        const fd = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd) != .SUCCESS) {
            const err = "file not found";
            var pkt: [64]u8 = undefined;
            std.mem.writeInt(u16, pkt[0..2], 5, .big); // ERROR
            std.mem.writeInt(u16, pkt[2..4], 1, .big); // not found
            @memcpy(pkt[4 .. 4 + err.len], err);
            pkt[4 + err.len] = 0;
            sendPacket(0, &peer, plen, pkt[0 .. 5 + err.len]);
            return 0;
        }
        const fdi: linux.fd_t = @intCast(fd);
        defer _ = linux.close(fdi);
        var data: [512]u8 = undefined;
        const rd = linux.read(fdi, &data, data.len);
        const count: usize = if (linux.errno(rd) == .SUCCESS) @intCast(rd) else 0;
        var pkt: [516]u8 = undefined;
        std.mem.writeInt(u16, pkt[0..2], 3, .big); // DATA
        std.mem.writeInt(u16, pkt[2..4], 1, .big); // block 1
        @memcpy(pkt[4 .. 4 + count], data[0..count]);
        sendPacket(0, &peer, plen, pkt[0 .. 4 + count]);
        return 0;
    }
    // WRQ without -c: refuse creation.
    if (opcode == 2) {
        const msg = "access violation";
        var pkt: [64]u8 = undefined;
        std.mem.writeInt(u16, pkt[0..2], 5, .big);
        std.mem.writeInt(u16, pkt[2..4], 2, .big);
        @memcpy(pkt[4 .. 4 + msg.len], msg);
        pkt[4 + msg.len] = 0;
        sendPacket(0, &peer, plen, pkt[0 .. 5 + msg.len]);
    }
    return 0;
}

pub fn tftpdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    if (!stdinIsSocket()) n.usageDie("tftpd");
    const parsed = sc.opts("tftpd", args, "rcu:l", &.{});
    _ = parsed;
    return serveOne();
}
