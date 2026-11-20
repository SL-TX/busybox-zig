const std = @import("std");
const linux = std.os.linux;
const login = @import("loginutils");
const sh = @import("shell");
const misc = @import("miscutils");
const net = @import("networking");
const rem = @import("remaining");
const config = @import("config").config;
const applets = @import("applets.zig");

test "dropPrivileges refuses to exec when the switch fails" {
    // Unprivileged: switching to uid 0 must fail without changing credentials.
    try std.testing.expect(!login.dropPrivileges(0, 0));
}

test "shell returns the last command's exit status" {
    var ctx = sh.Context{ .allocator = std.testing.allocator };
    defer ctx.deinit();
    try std.testing.expectEqual(@as(u8, 1), sh.runInput(&ctx, "false"));
    try std.testing.expectEqual(@as(u8, 1), sh.runInput(&ctx, "true; false"));
}

test "shell does not swallow the command after VAR=value" {
    var ctx = sh.Context{ .allocator = std.testing.allocator };
    defer ctx.deinit();
    try std.testing.expectEqual(@as(u8, 1), sh.runInput(&ctx, "X=1 /bin/false"));
    try std.testing.expectEqualStrings("1", ctx.get("X").?);
}

test "parseAshArgs recognizes a script file argument" {
    const inv = try sh.parseAshArgs(&.{ "ash", "/tmp/script.sh" });
    try std.testing.expectEqualStrings("/tmp/script.sh", inv.script_path.?);
}

test "ionice maps waitpid status to the child's exit code" {
    try std.testing.expectEqual(@as(u8, 1), misc.exitStatus(@as(i32, 1 << 8)));
    try std.testing.expectEqual(@as(u8, 143), misc.exitStatus(@as(i32, 15)));
}

test "network helpers reject hostnames that are not numeric IPv4" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidHost, net.wgetFetch("not-an-ip.invalid", 80, "/", a));
    try std.testing.expectError(error.InvalidHost, net.ncExchange("not-an-ip.invalid", 80, "", a));
    try std.testing.expectError(error.InvalidHost, net.pingHost("not-an-ip.invalid", 1, 10));
}

test "crontab accepts ranges, names and step-ranges" {
    try std.testing.expect(misc.parseCrontabLine("1-5 * * * * echo hi") != null);
    try std.testing.expect(misc.parseCrontabLine("0 0 * * MON-FRI echo hi") != null);
    try std.testing.expect(misc.parseCrontabLine("0-59/5 * * * * echo hi") != null);
}

test "config inclusion gates the applet registry" {
    try std.testing.expect(config.APPLET_cat);
    try std.testing.expect(applets.findAppletByName("cat") != null);
    try std.testing.expect(applets.findAppletByName("ping") != null);
}

test "dirent64 layout matches the kernel ABI" {
    try std.testing.expectEqual(@as(usize, 19), @offsetOf(linux.dirent64, "name"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(linux.dirent64));
}

test "dcEval rejects division overflow instead of trapping" {
    try std.testing.expectError(error.InvalidExpression, rem.dcEval("-9223372036854775808 -1 /"));
}
