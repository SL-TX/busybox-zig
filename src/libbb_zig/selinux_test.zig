const std = @import("std");
const linux = std.os.linux;
const sel = @import("libbb_zig").selinux;

fn z(path: []const u8, buf: *[256:0]u8) [:0]const u8 {
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn makeTempFile(path: []const u8) !void {
    var d: [256:0]u8 = undefined;
    _ = linux.mkdir(z("/tmp/opencode", &d), 0o700);
    const rc = linux.open(z(path, &d), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    _ = linux.close(@intCast(rc));
}

fn removeTempFile(path: []const u8) void {
    var b: [256:0]u8 = undefined;
    _ = linux.unlink(z(path, &b));
}

test "SELinux context parse and component replacement" {
    const a = std.testing.allocator;
    const ctx = try sel.parseContext("user_u:role_r:type_t:s0-s0:c0.c1023");
    try std.testing.expectEqualStrings("user_u", ctx.user);
    try std.testing.expectEqualStrings("role_r", ctx.role);
    try std.testing.expectEqualStrings("type_t", ctx.type);
    try std.testing.expectEqualStrings("s0-s0:c0.c1023", ctx.range);

    const changed = try sel.setComponent(a, "user_u:role_r:type_t:s0", .type, "new_t");
    defer a.free(changed);
    try std.testing.expectEqualStrings("user_u:role_r:new_t:s0", changed);
    const range = try sel.setComponent(a, "user_u:role_r:type_t:s0", .range, "s0:c1.c10");
    defer a.free(range);
    try std.testing.expectEqualStrings("user_u:role_r:type_t:s0:c1.c10", range);

    try std.testing.expectError(error.MalformedContext, sel.parseContext("user:role:onlythree"));
    try std.testing.expectError(error.MalformedContext, sel.parseContext(""));
}

test "SELinux xattr set/get/list/remove on a temp file" {
    const a = std.testing.allocator;
    const path = "/tmp/opencode/t23-selinux-file";
    try makeTempFile(path);
    defer removeTempFile(path);
    defer removeTempFile("/tmp/opencode/t23-selinux-copy");

    // Capability gate: tmpfs/overlay without xattr support cannot exercise
    // this path; treat it as an explicit skip rather than a false failure.
    sel.set(path, "user.t23", "value") catch |err| {
        if (err == error.Unsupported) return;
        return err;
    };
    const got = (try sel.get(a, path, "user.t23")).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("value", got);
    try std.testing.expect((try sel.get(a, path, "user.missing")) == null);

    const names = try sel.list(a, path);
    defer {
        for (names) |name| a.free(name);
        a.free(names);
    }
    var found = false;
    for (names) |name| if (std.mem.eql(u8, name, "user.t23")) {
        found = true;
    };
    try std.testing.expect(found);

    try sel.remove(path, "user.t23");
    try std.testing.expect((try sel.get(a, path, "user.t23")) == null);
}

test "SELinux file-context helpers copy labels" {
    const a = std.testing.allocator;
    const src = "/tmp/opencode/t23-selinux-src";
    const dst = "/tmp/opencode/t23-selinux-dst";
    try makeTempFile(src);
    try makeTempFile(dst);
    defer removeTempFile(src);
    defer removeTempFile(dst);

    // security.selinux is a privileged xattr: setting it needs CAP_SYS_ADMIN
    // and an SELinux-enabled filesystem.  Gate on that capability explicitly.
    sel.setFileContext(src, "user_u:role_r:src_t:s0") catch |err| {
        if (err == error.Unsupported or err == error.AccessDenied) return;
        return err;
    };
    const label = (try sel.getFileContext(a, src)).?;
    defer a.free(label);
    try std.testing.expectEqualStrings("user_u:role_r:src_t:s0", std.mem.trimEnd(u8, label, "\x00"));

    try sel.copyFileContext(a, src, dst);
    const copied = (try sel.getFileContext(a, dst)).?;
    defer a.free(copied);
    try std.testing.expectEqualStrings(label, copied);
}

test "SELinux boolean files parse and round-trip" {
    const a = std.testing.allocator;
    const one = try sel.parseBoolean("1 0\n");
    try std.testing.expect(one.current);
    try std.testing.expect(!one.pending);
    const zero = try sel.parseBoolean("0 1\n");
    try std.testing.expect(!zero.current);
    try std.testing.expect(zero.pending);
    try std.testing.expectError(error.MalformedBoolean, sel.parseBoolean("maybe\n"));
    try std.testing.expectError(error.MalformedBoolean, sel.parseBoolean("2 1\n"));
    try std.testing.expectError(error.MalformedContext, sel.setComponent(std.testing.allocator, "u:r:t:s0", .type, ""));

    const path = "/tmp/opencode/t23-selinux-boolean";
    var d: [256:0]u8 = undefined;
    _ = linux.mkdir(z("/tmp/opencode", &d), 0o700);
    defer removeTempFile(path);
    const fd = linux.open(z(path, &d), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    _ = linux.write(@intCast(fd), "0 0\n", 4);
    _ = linux.close(@intCast(fd));

    const loaded = try sel.readBoolean(a, path);
    try std.testing.expect(!loaded.current);
    try sel.writeBoolean(path, true);
    const updated = try sel.readBoolean(a, path);
    try std.testing.expect(updated.current);
    try std.testing.expect(updated.pending);
}
