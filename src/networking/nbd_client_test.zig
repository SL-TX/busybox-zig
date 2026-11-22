//! Focused unit tests for the NBD handshake parameter decoding. The ioctl
//! itself needs a real block device, so tests validate the values that are
//! handed to it against the byte layout of nbd-client.c.

const std = @import("std");
const nb = @import("networking").nbdclient;

fn beSize(value: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, value, .big);
    return out;
}

test "NBD old-style: size_blocks uses blksize and ro uses htons(2)" {
    const size = beSize(1024 * 1024);
    var flags: [4]u8 = .{ 0, 0, 0, 0 };
    var p = nb.decodeOld(&size, &flags, 4096);
    try std.testing.expectEqual(@as(u64, 256), p.size_blocks);
    try std.testing.expect(!nb.isReadOnly(p.flags_raw));
    try std.testing.expectEqual(@as(u16, 0), p.nbd_flags);

    // uint32_t read of network bytes 00 02 00 00 on a little-endian host is
    // 0x00000200 == htons(2), i.e. NBD_FLAG_READ_ONLY.
    flags = .{ 0x00, 0x02, 0, 0 };
    p = nb.decodeOld(&size, &flags, 512);
    try std.testing.expectEqual(@as(u64, 2048), p.size_blocks);
    try std.testing.expect(nb.isReadOnly(p.flags_raw));
}

test "NBD new-style: size_blocks, ntohs(flags) and htons(2) ro mask" {
    const size = beSize(2 * 1024 * 1024);
    var tf: [2]u8 = .{ 0x00, 0x02 };
    var p = nb.decodeNew(&size, &tf, 4096);
    try std.testing.expectEqual(@as(u64, 512), p.size_blocks);
    try std.testing.expectEqual(@as(u16, 2), p.nbd_flags); // NBD_SET_FLAGS
    try std.testing.expect(nb.isReadOnly(p.flags_raw));

    tf = .{ 0x00, 0x00 };
    p = nb.decodeNew(&size, &tf, 1024);
    try std.testing.expectEqual(@as(u64, 2048), p.size_blocks);
    try std.testing.expectEqual(@as(u16, 0), p.nbd_flags);
    try std.testing.expect(!nb.isReadOnly(p.flags_raw));
}
