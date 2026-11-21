//! Tests for utmp record construction and encoding (no real utmp file touched).

const std = @import("std");
const bb = @import("libbb_zig");
const ut = bb.utmp;

test "skipDevPfx strips a leading /dev/" {
    try std.testing.expectEqualStrings("tty1", ut.skipDevPfx("/dev/tty1"));
    try std.testing.expectEqualStrings("pts/0", ut.skipDevPfx("/dev/pts/0"));
    try std.testing.expectEqualStrings("ttyS0", ut.skipDevPfx("ttyS0"));
}

test "makeEntry builds the four-character ut_id" {
    const a = ut.makeEntry(.{
        .pid = 1234,
        .new_type = .user_process,
        .tty = "/dev/tty1",
        .user = "alice",
        .host = "example",
        .tv_sec = 1700000000,
    });
    try std.testing.expectEqualStrings("tty1", std.mem.sliceTo(&a.ut_line, 0));
    try std.testing.expectEqual(@as(i32, 1234), a.ut_pid);
    try std.testing.expectEqual(@as(i16, @intFromEnum(ut.UtType.user_process)), a.ut_type);
    try std.testing.expectEqualStrings("alice", std.mem.sliceTo(&a.ut_user, 0));
    try std.testing.expectEqualStrings("example", std.mem.sliceTo(&a.ut_host, 0));
    // "tty1" -> skip 3 chars -> "1" padded with NULs.
    try std.testing.expectEqual(@as(u8, '1'), a.ut_id[0]);
    try std.testing.expectEqual(@as(u8, 0), a.ut_id[1]);

    const b = ut.makeEntry(.{
        .pid = 7,
        .new_type = .login_process,
        .tty = "pts/12",
        .user = null,
        .host = null,
        .tv_sec = 1,
    });
    try std.testing.expectEqual(@as(u8, 'p'), b.ut_id[0]);
    try std.testing.expectEqual(@as(u8, '/'), b.ut_id[1]);
    try std.testing.expectEqual(@as(u8, '1'), b.ut_id[2]);
    try std.testing.expectEqual(@as(u8, '2'), b.ut_id[3]);
}

test "native utmp record has the expected 384-byte layout" {
    try std.testing.expectEqual(@as(usize, 384), @sizeOf(ut.NativeUt));
}

test "encode/decode round-trips a utmp record through a temp file" {
    const path = "/tmp/opencode/bb-utmp-test.bin";
    defer bb.file.removeFile(path, .{ .force = true }) catch {};

    const ent = ut.makeEntry(.{
        .pid = 4242,
        .new_type = .dead_process,
        .tty = "/dev/tty7",
        .user = "bob",
        .host = "localhost",
        .tv_sec = 1234567890,
    });
    try ut.appendEntry(path, ent);

    const got = try ut.readEntries(std.testing.allocator, path);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(i32, 4242), got[0].ut_pid);
    try std.testing.expectEqual(@as(i16, @intFromEnum(ut.UtType.dead_process)), got[0].ut_type);
    try std.testing.expectEqualStrings("bob", std.mem.sliceTo(&got[0].ut_user, 0));
    try std.testing.expectEqualStrings("tty7", std.mem.sliceTo(&got[0].ut_line, 0));
    try std.testing.expectEqual(@as(u32, 1234567890), got[0].ut_tv.tv_sec);
}
