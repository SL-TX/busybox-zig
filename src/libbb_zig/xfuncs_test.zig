const std = @import("std");
const linux = std.os.linux;
const lib = @import("libbb_zig");
const xfuncs = lib.xfuncs;
const messages = lib.messages;
const process = lib.process;

const child_path = "/tmp/opencode/bb-xfuncs-child.txt";

const Capture = struct { code: u8, text: []u8 };

/// Fork a child whose stderr is redirected to a temp file, run `body` there,
/// and return the child's exit code together with everything it wrote.
fn captureExit(comptime body: *const fn () noreturn) !Capture {
    const zpath = child_path ++ "\x00";
    const fd: linux.fd_t = @intCast(try std.posix.openatZ(
        std.posix.AT.FDCWD,
        zpath,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    ));
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.dup2(fd, 2);
        body();
    }
    _ = linux.close(fd);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);

    const rf: linux.fd_t = @intCast(linux.open(zpath, .{ .ACCMODE = .RDONLY }, 0));
    defer _ = linux.close(rf);
    var rbuf: [8192]u8 = undefined;
    const n = linux.read(rf, &rbuf, rbuf.len);
    const text = try std.testing.allocator.dupe(u8, rbuf[0..@intCast(n)]);
    return .{
        .code = @intCast((@as(u32, @bitCast(status)) >> 8) & 0xff),
        .text = text,
    };
}

fn dieBoom() noreturn {
    messages.die("boom");
}

fn reportNoent() noreturn {
    messages.errorMsg(2, "cannot open {s}", .{"x"});
    std.process.exit(0);
}

fn openMissing() noreturn {
    // If xopen returns instead of exiting, the child exits 0 and the test fails.
    _ = xfuncs.xopen("/tmp/opencode/bb-xfuncs-does-not-exist", .{ .ACCMODE = .RDONLY }, 0) catch {};
    std.process.exit(0);
}

test "die prints '<prog>: <msg>\\n' to stderr and exits 1" {
    const old = messages.program_name;
    defer messages.program_name = old;
    messages.program_name = "testprog";

    const cap = try captureExit(dieBoom);
    defer std.testing.allocator.free(cap.text);
    try std.testing.expectEqual(@as(u8, 1), cap.code);
    try std.testing.expectEqualStrings("testprog: boom\n", cap.text);
}

test "errorMsg appends the strerror text for its errno" {
    const old = messages.program_name;
    defer messages.program_name = old;
    messages.program_name = "testprog";

    const cap = try captureExit(reportNoent);
    defer std.testing.allocator.free(cap.text);
    try std.testing.expectEqual(@as(u8, 0), cap.code);
    try std.testing.expectEqualStrings("testprog: cannot open x: No such file or directory\n", cap.text);
}

test "xmalloc(0) returns a valid empty slice" {
    const p = try xfuncs.xmalloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(p);
    try std.testing.expectEqual(@as(usize, 0), p.len);
}

test "xmalloc(n) returns writable storage" {
    const p = try xfuncs.xmalloc(std.testing.allocator, 8);
    defer std.testing.allocator.free(p);
    @memset(p, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), p[7]);
}

test "xstrdup duplicates a slice" {
    const d = try xfuncs.xstrdup(std.testing.allocator, "hello");
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("hello", d);
}

test "xopen on a missing file prints an error and exits" {
    const old = messages.program_name;
    defer messages.program_name = old;
    messages.program_name = "testprog";

    const cap = try captureExit(openMissing);
    defer std.testing.allocator.free(cap.text);
    try std.testing.expectEqual(@as(u8, 1), cap.code);
    try std.testing.expect(std.mem.startsWith(u8, cap.text, "testprog: "));
    try std.testing.expect(std.mem.indexOf(u8, cap.text, "No such file or directory") != null);
}

test "xwrite and xread round-trip through a pipe" {
    var fds: [2]linux.fd_t = undefined;
    try process.pipe(&fds);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    try xfuncs.xwrite(fds[1], "abc");
    _ = linux.close(fds[1]);
    var buf: [8]u8 = undefined;
    const n = try xfuncs.xread(fds[0], &buf);
    try std.testing.expectEqualStrings("abc", buf[0..n]);
}
