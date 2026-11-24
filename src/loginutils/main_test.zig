//! Task 24 unit tests for loginutils logic that differential cases cannot
//! reach in an unprivileged sandbox (root-only account file updates, pty-only
//! authentication, crypt salt construction).  All file I/O uses temporary
//! paths under /tmp/opencode; no real auth file is ever opened for writing.

const std = @import("std");
const login = @import("loginutils");
const bb = @import("libbb_zig");

const a = std.testing.allocator;

const linux = std.os.linux;

fn tmpPath(comptime name: []const u8) []const u8 {
    return "/tmp/opencode/task24-" ++ name;
}

fn zbuf(path: []const u8, buf: *[512:0]u8) [:0]const u8 {
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn seedFile(path: []const u8, content: []const u8) !void {
    var b: [512:0]u8 = undefined;
    const rc = linux.open(zbuf(path, &b), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < content.len) {
        const n = linux.write(fd, content[done..].ptr, content.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return error.WriteFailed;
        done += n;
    }
}

fn readTestFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var b: [512:0]u8 = undefined;
    const rc = linux.open(zbuf(path, &b), .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

fn unlink(path: []const u8) void {
    var b: [512:0]u8 = undefined;
    _ = linux.unlink(zbuf(path, &b));
}

test "cryptpw salt construction: explicit algorithms get the right prefix" {
    const salts = [_][]const u8{
        login.buildSalt(a, "md5", "abcdefgh"),
        login.buildSalt(a, "sha256", "abcdefgh"),
        login.buildSalt(a, "sha512", "abcdefgh"),
        login.buildSalt(a, "bogus", "abcdefgh"),
        login.buildSalt(a, "des", "ab"),
        login.buildSalt(a, "md5", "$1$salt$"),
    };
    defer for (salts) |salt| a.free(salt);
    try std.testing.expectEqualStrings("$1$abcdefgh", salts[0]);
    try std.testing.expectEqualStrings("$5$abcdefgh", salts[1]);
    try std.testing.expectEqualStrings("$6$abcdefgh", salts[2]);
    try std.testing.expectEqualStrings("$1$abcdefgh", salts[3]);
    // DES and full salts are passed through verbatim.
    try std.testing.expectEqualStrings("ab", salts[4]);
    try std.testing.expectEqualStrings("$1$salt$", salts[5]);
}

test "random salt has the expected algorithm prefix and length" {
    const des = login.makeSalt(a, "des");
    defer a.free(des);
    try std.testing.expectEqual(@as(usize, 2), des.len);
    const md5 = login.makeSalt(a, "md5");
    defer a.free(md5);
    try std.testing.expect(std.mem.startsWith(u8, md5, "$1$"));
    try std.testing.expectEqual(@as(usize, 3 + 16), md5.len);
}

test "verifyPassword supports MD5 and SHA-crypt hashes" {
    const md5 = "$1$12345678$o2n/JiO/h5VviOInWJ4OQ/";
    try std.testing.expect(try login.verifyPassword(a, md5, "password"));
    try std.testing.expect(!(try login.verifyPassword(a, md5, "wrong")));
    const sha = "$5$abcdefgh$gruCpC7VkOTspMQTTSAR8mtlO9Upms.fwqE5y16JVM.";
    try std.testing.expect(try login.verifyPassword(a, sha, "secret"));
    try std.testing.expect(!(try login.verifyPassword(a, sha, "secret2")));
}

test "passwd lock/unlock/delete transitions" {
    const locked = login.adjustLock(a, .lock, "$1$salt$hash");
    try std.testing.expect(locked != null);
    defer a.free(locked.?);
    try std.testing.expectEqualStrings("!$1$salt$hash", locked.?);
    try std.testing.expect(login.adjustLock(a, .lock, "!$1$salt$hash") == null);
    const unlocked = login.adjustLock(a, .unlock, "!$1$salt$hash").?;
    defer a.free(unlocked);
    try std.testing.expectEqualStrings("$1$salt$hash", unlocked);
    try std.testing.expect(login.adjustLock(a, .unlock, "$1$salt$hash") == null);
    const deleted = login.adjustLock(a, .delete, "$1$salt$hash").?;
    defer a.free(deleted);
    try std.testing.expectEqualStrings("", deleted);
}

test "shellsContents adds only missing shells and preserves order" {
    const data = "# shells\n/bin/sh\n/bin/bash\n";
    const added = try login.shellsContents(a, data, &.{ "/bin/zsh", "/bin/bash", "/bin/fish" }, false);
    defer a.free(added);
    try std.testing.expectEqualStrings("# shells\n/bin/sh\n/bin/bash\n/bin/zsh\n/bin/fish\n", added);
}

test "shellsContents removes every occurrence of a shell" {
    const data = "/bin/sh\n/bin/false\n/bin/false\n";
    const removed = try login.shellsContents(a, data, &.{"/bin/false"}, true);
    defer a.free(removed);
    try std.testing.expectEqualStrings("/bin/sh\n", removed);
}

test "shellsContents tolerates a file without a trailing newline" {
    const removed = try login.shellsContents(a, "/bin/sh", &.{"/bin/sh"}, true);
    defer a.free(removed);
    try std.testing.expectEqualStrings("", removed);
}

test "chpasswd line parsing rejects lines without a user" {
    const p = login.parseChpasswdLine("alice:s3cret").?;
    try std.testing.expectEqualStrings("alice", p.user);
    try std.testing.expectEqualStrings("s3cret", p.password);
    try std.testing.expect(login.parseChpasswdLine("no-colon") == null);
    try std.testing.expect(login.parseChpasswdLine(":password") == null);
}

test "group member helpers add and remove without touching other groups" {
    const data = "root:x:0:\nusers:x:100:alice,bob\nwheel:x:10:alice\n";
    const added = (try login.addMember(a, data, "users", "carol")).?;
    defer a.free(added);
    try std.testing.expect(std.mem.indexOf(u8, added, "users:x:100:alice,bob,carol") != null);
    try std.testing.expect(login.addMember(a, data, "users", "alice") catch null == null);
    try std.testing.expect(login.addMember(a, data, "missing", "alice") catch null == null);

    const removed = login.removeMember(a, data, "alice").?;
    defer a.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "users:x:100:bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "wheel:x:10:") != null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "alice") == null);
}

test "removeFromContents removes only matching account names" {
    const data = "root:x:0:0::/root:/bin/sh\nbob:x:1000:1000::/home/bob:/bin/sh\n";
    const out = try login.removeFromContents(a, data, "bob");
    defer a.free(out);
    try std.testing.expectEqualStrings("root:x:0:0::/root:/bin/sh\n", out);
}

test "getty baud validation accepts standard rates and rejects others" {
    try std.testing.expect(login.validBaud("0"));
    try std.testing.expect(login.validBaud("9600"));
    try std.testing.expect(login.validBaud("115200"));
    try std.testing.expect(!login.validBaud("999999"));
    try std.testing.expect(!login.validBaud("abc"));
    try std.testing.expect(!login.validBaud(""));
}

test "account file updates preserve surrounding lines (temp file)" {
    const path = tmpPath("passwd");
    defer unlink(path);
    try seedFile(path, "root:x:0:0::/root:/bin/sh\nbob:x:1000:1000::/home/bob:/bin/sh\n");
    const ok = try bb.login.update_passwd.updateFile(a, path, "bob", "bob:x:1001:1001::/home/bob:/bin/bash");
    try std.testing.expect(ok);
    const data = try readTestFile(a, path);
    defer a.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "bob:x:1001:1001::/home/bob:/bin/bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "root:x:0:0") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, data, "bob:x:1001"));
}

test "shells applet transformation round-trip with duplicate argument" {
    const data = "/bin/sh\n/bin/bash\n";
    const one = try login.shellsContents(a, data, &.{"/bin/zsh"}, false);
    defer a.free(one);
    const two = try login.shellsContents(a, one, &.{"/bin/zsh"}, false);
    defer a.free(two);
    try std.testing.expectEqualStrings(one, two);
    const back = try login.shellsContents(a, two, &.{"/bin/zsh"}, true);
    defer a.free(back);
    try std.testing.expectEqualStrings(data, back);
}

test "chpasswd malformed input is a hard error with the reference message" {
    const bad = login.chpasswdEntry(a, "no-colon", null, false);
    try std.testing.expectError(error.MissingNewPassword, bad);
    const good = try login.chpasswdEntry(a, "alice:s3cret", "md5", false);
    defer a.free(good.hash);
    try std.testing.expectEqualStrings("alice", good.user);
    try std.testing.expect(std.mem.startsWith(u8, good.hash, "$1$"));
}

test "envPolicy mirrors setup_environment for su -p/-m and login -p" {
    const inherited = [_][]const u8{ "FOO=1", "TERM=xterm", "HOME=/old", "PATH=/old" };
    const overrides = [_]login.EnvOverride{
        .{ .key = "HOME", .value = "/home/alice" },
        .{ .key = "SHELL", .value = "/bin/sh" },
    };
    const preserved = try login.envPolicy(a, &inherited, &overrides, false, true, false);
    defer {
        for (preserved) |e| a.free(e);
        a.free(preserved);
    }
    try std.testing.expectEqual(@as(usize, 5), preserved.len);
    try std.testing.expect(std.mem.indexOf(u8, preserved[0], "FOO=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, preserved[1], "TERM=xterm") != null);

    const cleared = try login.envPolicy(a, &inherited, &overrides, true, true, true);
    defer {
        for (cleared) |e| a.free(e);
        a.free(cleared);
    }
    try std.testing.expectEqual(@as(usize, 4), cleared.len); // TERM + 2 overrides + root PATH
    try std.testing.expectEqualStrings("TERM=xterm", cleared[0]);
    try std.testing.expectEqualStrings("PATH=/sbin:/usr/sbin:/bin:/usr/bin", cleared[3]);
}

test "vlock -a selects the plural console banner" {
    try std.testing.expectEqualStrings(
        "Virtual console locked by alice.\n",
        login.vlockBanner(false, "alice"),
    );
    try std.testing.expectEqualStrings(
        "Virtual consoles locked by alice.\n",
        login.vlockBanner(true, "alice"),
    );
}

test "getty modem status parses the first valid baud" {
    try std.testing.expectEqual(@as(?u32, 9600), login.parseModemSpeed("CONNECT 9600/ARQ\r\n"));
    // The reference stops at the first digit run; an invalid first run wins.
    try std.testing.expect(login.parseModemSpeed("ATDT123\r\nCONNECT 9600/ARQ\r\n") == null);
    try std.testing.expect(login.parseModemSpeed("NO CARRIER") == null);
    try std.testing.expect(login.parseModemSpeed("CONNECT 999999") == null);
}

test "applyShellsFile writes atomically to an explicit SHELLS_FILE path (temp file)" {
    const path = tmpPath("shells");
    defer unlink(path);
    try seedFile(path, "/bin/sh\n/bin/bash\n");
    const shells = [_][]const u8{"/bin/zsh"};
    try std.testing.expect(login.applyShellsFile(a, path, &shells, false));
    const data = try readTestFile(a, path);
    defer a.free(data);
    try std.testing.expectEqualStrings("/bin/sh\n/bin/bash\n/bin/zsh\n", data);
    try std.testing.expect(login.applyShellsFile(a, path, &shells, true));
    const removed = try readTestFile(a, path);
    defer a.free(removed);
    try std.testing.expectEqualStrings("/bin/sh\n/bin/bash\n", removed);
}

test "login -h HOST is recorded in the utmp record (temp file)" {
    const path = tmpPath("utmp");
    defer unlink(path);
    const entry = bb.utmp.makeEntry(.{
        .pid = 4242,
        .new_type = .user_process,
        .tty = "/dev/pts/3",
        .user = "alice",
        .host = "example.com",
        .tv_sec = 1234567,
    });
    try bb.utmp.writeEntries(path, &.{entry});
    const entries = try bb.utmp.readEntries(a, path);
    defer a.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    var host_end: usize = 0;
    while (host_end < entries[0].ut_host.len and entries[0].ut_host[host_end] != 0) host_end += 1;
    const host = entries[0].ut_host[0..host_end];
    try std.testing.expectEqualStrings("example.com", host);
    var user_end: usize = 0;
    while (user_end < entries[0].ut_user.len and entries[0].ut_user[user_end] != 0) user_end += 1;
    const user = entries[0].ut_user[0..user_end];
    try std.testing.expectEqualStrings("alice", user);
}
