const std = @import("std");
const linux = std.os.linux;
const up = @import("libbb_zig").login.update_passwd;

fn z(path: []const u8, buf: *[256:0]u8) [:0]const u8 {
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn writeTestFile(path: []const u8, data: []const u8) !void {
    var b: [256:0]u8 = undefined;
    const p = z(path, &b);
    const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < data.len) {
        const n = linux.write(fd, data[done..].ptr, data.len - done);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        done += n;
    }
}

fn readTestFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var b: [256:0]u8 = undefined;
    const p = z(path, &b);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

test "updateContents replaces the named entry in place" {
    const a = std.testing.allocator;
    const data = "root:x:0:0::/root:/bin/sh\nalice:x:1000:100::/home/alice:/bin/sh\nbob:x:1001:100::/home/bob:/bin/sh\n";
    const out = try up.updateContents(a, data, "alice", "alice:x:1000:200::/home/alice:/bin/ash");
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "root:x:0:0::/root:/bin/sh\nalice:x:1000:200::/home/alice:/bin/ash\nbob:x:1001:100::/home/bob:/bin/sh\n",
        out,
    );
}

test "updateContents appends when the name is absent" {
    const a = std.testing.allocator;
    const out = try up.updateContents(a, "root:x:0:0::/root:/bin/sh", "alice", "alice:x:1000:100::/home/alice:/bin/sh");
    defer a.free(out);
    try std.testing.expectEqualStrings("root:x:0:0::/root:/bin/sh\nalice:x:1000:100::/home/alice:/bin/sh\n", out);

    const empty = try up.updateContents(a, "", "alice", "alice:x:1:1::/:/bin/sh");
    defer a.free(empty);
    try std.testing.expectEqualStrings("alice:x:1:1::/:/bin/sh\n", empty);
}

test "updateContents keeps CRLF and final lines without newline" {
    const a = std.testing.allocator;
    const out = try up.updateContents(a, "a:x:1:1::/:/bin/sh\r\nb:x:2:2::/:/bin/sh", "b", "b:x:2:3::/:/bin/sh");
    defer a.free(out);
    try std.testing.expectEqualStrings("a:x:1:1::/:/bin/sh\r\nb:x:2:3::/:/bin/sh", out);
}

test "updateFile writes atomically and is idempotent" {
    const a = std.testing.allocator;
    const dir = "/tmp/opencode";
    var db: [256:0]u8 = undefined;
    _ = linux.mkdir(z(dir, &db), 0o700);
    const path = "/tmp/opencode/t23-update-passwd";

    try writeTestFile(path, "root:x:0:0::/root:/bin/sh\n");
    defer {
        var b: [256:0]u8 = undefined;
        _ = linux.unlink(z(path, &b));
        _ = linux.unlink(z("/tmp/opencode/t23-update-passwd.tmp", &b));
    }
    try std.testing.expect(try up.updateFile(a, path, "alice", "alice:x:1000:100::/home/alice:/bin/sh"));
    const data = try readTestFile(a, path);
    defer a.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "alice:x:1000:100") != null);
    try std.testing.expect(!(try up.updateFile(a, path, "alice", "alice:x:1000:100::/home/alice:/bin/sh")));
}
