//! Tests for identity/environment helpers.

const std = @import("std");
const bb = @import("libbb_zig");
const linux = std.os.linux;
const ident = bb.identity;

test "effectiveShell supplies the default shell" {
    try std.testing.expectEqualStrings("/bin/sh", ident.effectiveShell(null));
    try std.testing.expectEqualStrings("/bin/sh", ident.effectiveShell(""));
    try std.testing.expectEqualStrings("/bin/bash", ident.effectiveShell("/bin/bash"));
}

test "defaultPath distinguishes root from ordinary users" {
    try std.testing.expect(ident.defaultPath(0).len > 0);
    try std.testing.expect(ident.defaultPath(1000).len > 0);
    try std.testing.expect(!std.mem.eql(u8, ident.defaultPath(0), ident.defaultPath(1000)));
}

test "changeIdentity to the current uid/gid succeeds" {
    try ident.changeIdentity(linux.getuid(), linux.getgid());
}

test "setupEnvironment with no flags leaves cwd unchanged" {
    const before = try bb.path.xgetcwd(std.testing.allocator);
    defer std.testing.allocator.free(before);

    const pw = ident.PasswdInfo{
        .name = "nobody",
        .dir = "/nonexistent-home-for-test",
        .uid = 65534,
        .gid = 65534,
    };
    try ident.setupEnvironment(null, .{}, pw);

    const after = try bb.path.xgetcwd(std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "setupEnvironment clear_env keeps TERM and installs the standard variables" {
    var m = std.process.Environ.Map.init(std.testing.allocator);
    defer m.deinit();
    try m.put("TERM", "xterm");
    try m.put("UNRELATED", "drop-me");

    const previous = bb.env.map;
    defer bb.env.map = previous;
    bb.env.map = &m;

    const pw = ident.PasswdInfo{
        .name = "alice",
        .dir = "/home/alice",
        .uid = 1000,
        .gid = 1000,
    };
    try ident.setupEnvironment("/bin/bash", .{ .clear_env = true }, pw);

    try std.testing.expectEqualStrings("xterm", m.get("TERM").?);
    try std.testing.expect(m.get("UNRELATED") == null);
    try std.testing.expectEqualStrings(ident.user_path, m.get("PATH").?);
    try std.testing.expectEqualStrings("alice", m.get("USER").?);
    try std.testing.expectEqualStrings("alice", m.get("LOGNAME").?);
    try std.testing.expectEqualStrings("/home/alice", m.get("HOME").?);
    try std.testing.expectEqualStrings("/bin/bash", m.get("SHELL").?);
}

test "setupEnvironment chdir falls back when the home directory is missing" {
    const original = try bb.path.xgetcwd(std.testing.allocator);
    defer {
        // Restore cwd so later tests (which use relative reference paths) are
        // unaffected by this test's chdir.
        bb.process.chdirPath(std.mem.sliceTo(original, 0)) catch {};
        std.testing.allocator.free(original);
    }

    const pw = ident.PasswdInfo{
        .name = "nobody",
        .dir = "/nonexistent-home-for-test",
        .uid = 65534,
        .gid = 65534,
    };
    // to_tmp selects /tmp as the fallback instead of /.
    try ident.setupEnvironment(null, .{ .chdir = true, .to_tmp = true }, pw);
    const cwd = try bb.path.xgetcwd(std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try std.testing.expectEqualStrings("/tmp", std.mem.sliceTo(cwd, 0));
}
