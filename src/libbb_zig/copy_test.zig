//! Tests for copyFile / copyFd.

const std = @import("std");
const bb = @import("libbb_zig");
const linux = std.os.linux;
const copy = bb.copy;

const base = "/tmp/opencode/bb-copy-test";

fn zpath(path: []const u8, buf: *[512:0]u8) ! [*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn writeFile(path: []const u8, content: []const u8) void {
    var z: [512:0]u8 = undefined;
    const p = zpath(path, &z) catch return;
    const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    _ = linux.write(fd, content.ptr, content.len);
}

fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var z: [512:0]u8 = undefined;
    const p = try zpath(path, &z);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

fn exists(path: []const u8) bool {
    return stat(path) != null;
}

fn stat(path: []const u8) ?linux.Statx {
    var z: [512:0]u8 = undefined;
    const p = zpath(path, &z) catch return null;
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    return if (linux.errno(rc) == .SUCCESS) st else null;
}

fn readLink(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [1024]u8 = undefined;
    const n = try bb.io.readlink(path, &buf);
    return a.dupe(u8, buf[0..n]);
}

fn clean() void {
    bb.file.removeFile(base, .{ .force = true, .recurse = true }) catch {};
}

test "copyFd copies all bytes and returns the count" {
    clean();
    defer clean();
    bb.file.makeDirectory(base, 0o755) catch {};

    const src = base ++ "/src.bin";
    const dst = base ++ "/dst.bin";
    // More than one internal buffer chunk would be ideal; a moderate payload is enough.
    const chunk = "The quick brown fox jumps over the lazy dog. ";
    var payload_buf: [chunk.len * 64]u8 = undefined;
    for (0..64) |i| @memcpy(payload_buf[i * chunk.len ..][0..chunk.len], chunk);
    const payload: []const u8 = &payload_buf;
    writeFile(src, payload);

    var zs: [512:0]u8 = undefined;
    var zd: [512:0]u8 = undefined;
    const sp = try zpath(src, &zs);
    const dp = try zpath(dst, &zd);
    const sfd: linux.fd_t = @intCast(linux.open(sp, .{ .ACCMODE = .RDONLY }, 0));
    const dfd: linux.fd_t = @intCast(linux.open(dp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644));
    defer _ = linux.close(sfd);
    defer _ = linux.close(dfd);

    const n = try copy.copyFd(sfd, dfd);
    try std.testing.expectEqual(@as(u64, payload.len), n);
    const got = try readFile(std.testing.allocator, dst);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(payload, got);
}

test "copyFile copies a regular file" {
    clean();
    defer clean();
    bb.file.makeDirectory(base, 0o755) catch {};

    const src = base ++ "/hello.txt";
    const dst = base ++ "/copy.txt";
    const payload = "hello world\n";
    writeFile(src, payload);

    try copy.copyFile(src, dst, .{});
    const got = try readFile(std.testing.allocator, dst);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(payload, got);
}

test "copyFile recurses into directories" {
    clean();
    defer clean();

    const src = base ++ "/tree";
    const dst = base ++ "/treecopy";
    bb.file.makeDirectory(src ++ "/sub", 0o755) catch {};
    writeFile(src ++ "/top.txt", "top");
    writeFile(src ++ "/sub/deep.txt", "deep");

    try copy.copyFile(src, dst, .{ .recurse = true });
    try std.testing.expect(exists(dst ++ "/top.txt"));
    try std.testing.expect(exists(dst ++ "/sub/deep.txt"));
    const deep = try readFile(std.testing.allocator, dst ++ "/sub/deep.txt");
    defer std.testing.allocator.free(deep);
    try std.testing.expectEqualStrings("deep", deep);
}

test "copyFile requires recurse for a directory" {
    clean();
    defer clean();

    const src = base ++ "/tree";
    bb.file.makeDirectory(src, 0o755) catch {};
    try std.testing.expectError(error.IsDirectory, copy.copyFile(src, base ++ "/out", .{}));
}

test "copyFile with force overwrites an existing destination" {
    clean();
    defer clean();
    bb.file.makeDirectory(base, 0o755) catch {};

    const src = base ++ "/src.txt";
    const dst = base ++ "/dst.txt";
    writeFile(src, "new");
    writeFile(dst, "old-longer-contents");

    try copy.copyFile(src, dst, .{ .force = true });
    const got = try readFile(std.testing.allocator, dst);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("new", got);
}

test "sameFile compares device and inode, not inode alone" {
    var a = std.mem.zeroes(linux.Statx);
    var b = std.mem.zeroes(linux.Statx);
    a.ino = 42;
    b.ino = 42;
    a.dev_major = 8;
    a.dev_minor = 1;
    b.dev_major = 8;
    b.dev_minor = 1;
    try std.testing.expect(copy.sameFile(a, b));

    // Same inode on a different device must NOT be reported as the same file.
    // A real cross-device inode collision is impractical to construct
    // deterministically, so the comparison logic is tested with synthetic
    // stat results (exactly the fields .BASIC_STATS fills).
    b.dev_major = 0;
    try std.testing.expect(!copy.sameFile(a, b));

    b.dev_major = 8;
    b.ino = 43;
    try std.testing.expect(!copy.sameFile(a, b));
}

test "sameFile distinguishes two real files on the same filesystem" {
    clean();
    defer clean();
    bb.file.makeDirectory(base, 0o755) catch {};
    const a_path = base ++ "/devstat-a.txt";
    const b_path = base ++ "/devstat-b.txt";
    writeFile(a_path, "a");
    writeFile(b_path, "b");
    const a = stat(a_path).?;
    const b = stat(b_path).?;
    try std.testing.expectEqual(a.dev_major, b.dev_major);
    try std.testing.expectEqual(a.dev_minor, b.dev_minor);
    try std.testing.expect(a.ino != b.ino);
    try std.testing.expect(!copy.sameFile(a, b));
    try std.testing.expect(copy.sameFile(a, stat(a_path).?));
}

test "copyFile rejects copying a file onto itself" {
    clean();
    defer clean();
    bb.file.makeDirectory(base, 0o755) catch {};
    const src = base ++ "/self.txt";
    writeFile(src, "data");
    try std.testing.expectError(error.SameFile, copy.copyFile(src, src, .{}));
    const got = try readFile(std.testing.allocator, src);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("data", got); // source untouched
}

test "make_hardlink on a regular file links the inode without reading a target" {
    clean();
    defer clean();
    bb.file.makeDirectory(base, 0o755) catch {};
    const src = base ++ "/hard-src.txt";
    const dst = base ++ "/hard-dst.txt";
    writeFile(src, "hard payload");

    try copy.copyFile(src, dst, .{ .make_hardlink = true });

    const s = stat(src).?;
    const d = stat(dst).?;
    try std.testing.expectEqual(s.ino, d.ino);
    try std.testing.expectEqual(s.dev_major, d.dev_major);
    try std.testing.expectEqual(s.dev_minor, d.dev_minor);
    const got = try readFile(std.testing.allocator, dst);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hard payload", got);
}

test "make_softlink on a regular file symlinks the source path" {
    clean();
    defer clean();
    bb.file.makeDirectory(base, 0o755) catch {};
    const src = base ++ "/soft-src.txt";
    const dst = base ++ "/soft-dst.txt";
    writeFile(src, "soft payload");

    try copy.copyFile(src, dst, .{ .make_softlink = true });

    const target = try readLink(std.testing.allocator, dst);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(src, target);
    const got = try readFile(std.testing.allocator, dst);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("soft payload", got);
}

test "copyFile without dereference preserves an existing symlink by its target" {
    clean();
    defer clean();
    bb.file.makeDirectory(base, 0o755) catch {};
    const real = base ++ "/real.txt";
    const link = base ++ "/orig-link";
    const dst = base ++ "/copied-link";
    writeFile(real, "via link");
    try bb.io.symlink(real, link);

    try copy.copyFile(link, dst, .{});

    const target = try readLink(std.testing.allocator, dst);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(real, target);
}
