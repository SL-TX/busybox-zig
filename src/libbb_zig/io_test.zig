const std = @import("std");
const io = @import("libbb_zig").io;

const path = "/tmp/opencode/bb-io-test.txt";

test "writeAll then read returns the same bytes" {
    {
        const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        try io.writeAll(fd, "hello\n");
        try io.close(fd);
    }
    {
        const fd = try io.open(path, .{}, 0);
        defer io.close(fd) catch {};
        var buf: [16]u8 = undefined;
        const n = try io.read(fd, &buf);
        try std.testing.expectEqualStrings("hello\n", buf[0..n]);
    }
    try io.unlink(path);
}

test "stat and fstat report size" {
    {
        const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        try io.writeAll(fd, "12345");
        try io.close(fd);
    }
    const st = try io.stat(path);
    try std.testing.expectEqual(@as(u64, 5), st.size);
    const fd = try io.open(path, .{}, 0);
    defer io.close(fd) catch {};
    const fst = try io.fstat(fd);
    try std.testing.expectEqual(@as(u64, 5), fst.size);
    try io.unlink(path);
}

test "access succeeds for existing file, fails for missing" {
    const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try io.close(fd);
    try io.access(path, 0);
    try std.testing.expectError(error.SyscallFailed, io.access(path ++ ".missing", 0));
    try io.unlink(path);
}

test "mkdir, rename and rmdir" {
    const dir = "/tmp/opencode/bb-io-testdir";
    const dst = "/tmp/opencode/bb-io-testdir2";
    io.rmdir(dir) catch {};
    io.rmdir(dst) catch {};
    try io.mkdir(dir, 0o755);
    try std.testing.expect(io.isDir(dir));
    try io.rename(dir, dst);
    try std.testing.expect(io.isDir(dst));
    try io.rmdir(dst);
}

test "lseek positions the file offset" {
    {
        const fd = try io.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        try io.writeAll(fd, "abcdef");
        try io.close(fd);
    }
    const fd = try io.open(path, .{}, 0);
    defer io.close(fd) catch {};
    _ = try io.lseek(fd, 2, 0);
    var buf: [4]u8 = undefined;
    const n = try io.read(fd, &buf);
    try std.testing.expectEqualStrings("cdef", buf[0..n]);
    try io.unlink(path);
}

test "printf helper formats into fd" {
    // Writing to stdout is harmless in tests; this checks formatting compiles
    // and produces no error.
    try io.print(2, "value={d}\n", .{42});
}
