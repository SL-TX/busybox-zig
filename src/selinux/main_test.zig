//! Task 24 unit tests for SELinux applet logic.  The applets are compiled out
//! of the defconfig and absent from the reference build, so their differential
//! cases are gated by requires:["selinux"]; these tests exercise the real
//! parsing/formatting/matching code unconditionally.

const std = @import("std");
const selinux = @import("selinux");
const bb = @import("libbb_zig");

const a = std.testing.allocator;

test "getenforce mode translation" {
    try std.testing.expectEqualStrings("Enforcing", selinux.enforceName("1").?);
    try std.testing.expectEqualStrings("Enforcing", selinux.enforceName("1\n").?);
    try std.testing.expectEqualStrings("Permissive", selinux.enforceName("0\n").?);
    try std.testing.expect(selinux.enforceName("maybe") == null);
}

test "setenforce accepts both numeric and symbolic modes" {
    try std.testing.expectEqual(@as(?bool, true), selinux.parseSetenforce("1"));
    try std.testing.expectEqual(@as(?bool, true), selinux.parseSetenforce("Enforcing"));
    try std.testing.expectEqual(@as(?bool, true), selinux.parseSetenforce("ENFORCING"));
    try std.testing.expectEqual(@as(?bool, false), selinux.parseSetenforce("0"));
    try std.testing.expectEqual(@as(?bool, false), selinux.parseSetenforce("permissive"));
    try std.testing.expect(selinux.parseSetenforce("2") == null);
}

test "setsebool accepts all documented boolean values" {
    try std.testing.expectEqual(@as(?bool, true), selinux.parseBooleanValue("1"));
    try std.testing.expectEqual(@as(?bool, true), selinux.parseBooleanValue("true"));
    try std.testing.expectEqual(@as(?bool, true), selinux.parseBooleanValue("ON"));
    try std.testing.expectEqual(@as(?bool, false), selinux.parseBooleanValue("0"));
    try std.testing.expectEqual(@as(?bool, false), selinux.parseBooleanValue("False"));
    try std.testing.expectEqual(@as(?bool, false), selinux.parseBooleanValue("off"));
    try std.testing.expect(selinux.parseBooleanValue("2") == null);
}

test "file_contexts rule parsing" {
    const rule = selinux.parseContextRule("/tmp(/.*)?  system_u:object_r:user_tmp_t:s0").?;
    try std.testing.expectEqualStrings("/tmp(/.*)?", rule.pattern);
    try std.testing.expectEqualStrings("system_u:object_r:user_tmp_t:s0", rule.context);
    try std.testing.expect(selinux.parseContextRule("# comment") == null);
    try std.testing.expect(selinux.parseContextRule("/only-pattern") == null);
}

test "matchContext prefers the most specific rule" {
    const rules = [_]selinux.ContextRule{
        .{ .pattern = "/", .context = "root_context" },
        .{ .pattern = "/home(/.*)?", .context = "home_context" },
        .{ .pattern = "/home/user(/.*)?", .context = "user_context" },
        .{ .pattern = "/etc/passwd", .context = "passwd_context" },
    };
    try std.testing.expectEqualStrings("root_context", selinux.matchContext(&rules, "/var/log").?);
    try std.testing.expectEqualStrings("home_context", selinux.matchContext(&rules, "/home").?);
    try std.testing.expectEqualStrings("home_context", selinux.matchContext(&rules, "/home/other").?);
    try std.testing.expectEqualStrings("user_context", selinux.matchContext(&rules, "/home/user/file").?);
    try std.testing.expectEqualStrings("passwd_context", selinux.matchContext(&rules, "/etc/passwd").?);
}

test "matchContext understands ^ anchors and .* suffixes" {
    const rules = [_]selinux.ContextRule{
        .{ .pattern = "^/usr/.*", .context = "usr_context" },
        .{ .pattern = "/bad.*", .context = "bad_context" },
    };
    try std.testing.expectEqualStrings("usr_context", selinux.matchContext(&rules, "/usr/bin/vi").?);
    try std.testing.expect(selinux.matchContext(&rules, "/usr") == null);
}

test "applyComponents replaces only the requested context fields" {
    const base = "unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023";
    const t = try selinux.applyComponents(a, base, null, null, "user_home_t", null);
    defer a.free(t);
    try std.testing.expectEqualStrings("unconfined_u:unconfined_r:user_home_t:s0-s0:c0.c1023", t);
    const u = try selinux.applyComponents(a, base, "staff_u", null, null, "s0:c1");
    defer a.free(u);
    try std.testing.expectEqualStrings("staff_u:unconfined_r:unconfined_t:s0:c1", u);
}

const linux = std.os.linux;

fn zbuf(path: []const u8, buf: *[512:0]u8) [:0]const u8 {
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn writeTestFile(path: []const u8, content: []const u8) !void {
    var b: [512:0]u8 = undefined;
    const rc = linux.open(zbuf(path, &b), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    _ = linux.write(fd, content.ptr, content.len);
}

fn unlink(path: []const u8) void {
    var b: [512:0]u8 = undefined;
    _ = linux.unlink(zbuf(path, &b));
}

test "boolean names are read from a pseudo-directory (temp dir)" {
    const dir = "/tmp/opencode/task24-booleans";
    var db: [512:0]u8 = undefined;
    _ = linux.mkdir(zbuf(dir, &db), 0o755);
    const names_to_create = [_][]const u8{ "httpd_enable_homedirs", "allow_execmem" };
    var paths: [names_to_create.len][]const u8 = undefined;
    for (names_to_create, 0..) |name, idx| {
        paths[idx] = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch unreachable;
        try writeTestFile(paths[idx], "0 0\n");
    }
    defer {
        for (paths) |path| {
            unlink(path);
            a.free(path);
        }
        var b: [512:0]u8 = undefined;
        _ = linux.rmdir(zbuf(dir, &b));
    }
    const names = try selinux.booleanNames(a, dir);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    var found_httpd = false;
    var found_execmem = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "httpd_enable_homedirs")) found_httpd = true;
        if (std.mem.eql(u8, n, "allow_execmem")) found_execmem = true;
    }
    try std.testing.expect(found_httpd and found_execmem);
}

test "SELinux boolean files parse and write through libbb helpers" {
    const path = "/tmp/opencode/task24-boolean-value";
    defer unlink(path);
    try bb.selinux.writeBoolean(path, true);
    const value = try bb.selinux.readBoolean(a, path);
    try std.testing.expect(value.current);
    try std.testing.expect(value.pending);
    try std.testing.expectEqualStrings("task24-boolean-value", value.name);
}

test "booleanPath is rooted at the SELinuxfs mount" {
    const p = selinux.booleanPath("httpd_enable_homedirs");
    try std.testing.expect(std.mem.endsWith(u8, p, "/booleans/httpd_enable_homedirs"));
}

test "sestatus reads SELINUXTYPE from the config file" {
    try std.testing.expectEqualStrings("minimum", selinux.configPolicyType(
        "# comment\nSELINUX=enforcing\nSELINUXTYPE=minimum\n",
    ).?);
    try std.testing.expect(selinux.configPolicyType("SELINUX=permissive\n") == null);
}

test "runcon -t keeps the command positional (would exec /bin/true)" {
    const plan = selinux.parseRunconArgs(&.{ "runcon", "-t", "user_t", "/bin/true" }, "runcon");
    try std.testing.expectEqualStrings("user_t", plan.typ.?);
    try std.testing.expect(plan.context == null);
    try std.testing.expectEqual(@as(usize, 3), plan.command_index);
    const explicit = selinux.parseRunconArgs(&.{ "runcon", "u:r:t:s0", "/bin/true" }, "runcon");
    try std.testing.expectEqualStrings("u:r:t:s0", explicit.context.?);
    try std.testing.expectEqual(@as(usize, 2), explicit.command_index);
    const computed = selinux.parseRunconArgs(&.{ "runcon", "-c", "-u", "staff_u", "/bin/true" }, "runcon");
    try std.testing.expect(computed.compute);
    try std.testing.expectEqualStrings("staff_u", computed.user.?);
    try std.testing.expectEqual(@as(usize, 4), computed.command_index);
}

test "matchpathcon -V verifies or reports the on-disk context" {
    try std.testing.expectEqualStrings(
        "/tmp/x verified\n",
        selinux.verifyLine("/tmp/x", "u:r:t:s0", "u:r:t:s0\x00"),
    );
    try std.testing.expectEqualStrings(
        "/tmp/x has context u:r:old:s0, should be u:r:t:s0\n",
        selinux.verifyLine("/tmp/x", "u:r:t:s0", "u:r:old:s0\x00"),
    );
    try std.testing.expectEqualStrings(
        "actual context unknown: No such file or directory, should be u:r:t:s0\n",
        selinux.verifyLine("/tmp/x", "u:r:t:s0", null),
    );
}

test "setfiles -r/-e path transformations" {
    try std.testing.expectEqualStrings("/tmp/root/etc/passwd", selinux.effectivePath("/tmp/root", "/etc/passwd"));
    try std.testing.expectEqualStrings("/etc/passwd", selinux.effectivePath("", "/etc/passwd"));
    const excludes = [_][]const u8{"/proc", "/sys"};
    try std.testing.expect(selinux.isExcluded(&excludes, "/proc/1"));
    try std.testing.expect(selinux.isExcluded(&excludes, "/sys"));
    try std.testing.expect(!selinux.isExcluded(&excludes, "/procfs"));
}
