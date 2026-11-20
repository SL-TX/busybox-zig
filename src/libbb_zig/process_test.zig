const std = @import("std");
const p = @import("libbb_zig").process;

test "errno and optarg are visible from another module" {
    p.errno = 5;
    p.optarg = "value";
    try std.testing.expectEqual(@as(c_int, 5), p.errno);
    try std.testing.expectEqualStrings("value", std.mem.span(p.optarg.?));
}

test "malloc and free" {
    const m = try p.malloc(8);
    @memset(m, 0xAA);
    try std.testing.expectEqual(@as(u8, 0xAA), m[0]);
    p.free(m);
}

test "calloc zeroes memory" {
    const m = try p.calloc(4, 2);
    defer p.free(m);
    for (m) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "realloc preserves contents" {
    var m = try p.malloc(4);
    m[0] = 7;
    m = try p.realloc(m, 16);
    defer p.free(m);
    try std.testing.expectEqual(@as(usize, 16), m.len);
    try std.testing.expectEqual(@as(u8, 7), m[0]);
}

test "process identity syscalls" {
    try std.testing.expect(p.getpid() > 0);
    try std.testing.expect(p.getppid() > 0);
    _ = p.getuid();
    _ = p.geteuid();
    _ = p.getgid();
    _ = p.getegid();
}

test "pipe creates two valid descriptors" {
    var fds: [2]i32 = undefined;
    try p.pipe(&fds);
    try std.testing.expect(fds[0] >= 0);
    try std.testing.expect(fds[1] >= 0);
    try p.close(fds[0]);
    try p.close(fds[1]);
}

test "fork and waitpid" {
    const pid = try p.fork();
    if (pid == 0) {
        std.os.linux.exit(0);
    }
    var status: i32 = 0;
    const waited = try p.waitpid(pid, &status, 0);
    try std.testing.expectEqual(pid, waited);
}
