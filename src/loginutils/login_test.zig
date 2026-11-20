const std = @import("std");
const login = @import("loginutils");

test "parsePasswdLine splits the seven colon fields" {
    const e = login.parsePasswdLine("root:x:0:0:root:/root:/bin/sh").?;
    try std.testing.expectEqualStrings("root", e.name);
    try std.testing.expectEqual(@as(u32, 0), e.uid);
    try std.testing.expectEqual(@as(u32, 0), e.gid);
    try std.testing.expectEqualStrings("/root", e.home);
    try std.testing.expectEqualStrings("/bin/sh", e.shell);
}

test "parsePasswdLine rejects short lines" {
    try std.testing.expect(login.parsePasswdLine("root:x:0") == null);
}

test "findPasswdEntry looks up by name" {
    const data = "root:x:0:0:root:/root:/bin/sh\nsl:x:1000:1000::/home/sl:/bin/bash\n";
    const e = login.findPasswdEntry(data, "sl").?;
    try std.testing.expectEqual(@as(u32, 1000), e.uid);
    try std.testing.expect(login.findPasswdEntry(data, "nobody") == null);
}

test "parseShadowLine splits the nine colon fields" {
    const s = login.parseShadowLine("root:$1$salt$hash:19000:0:99999:7:::").?;
    try std.testing.expectEqualStrings("root", s.name);
    try std.testing.expectEqualStrings("$1$salt$hash", s.hash);
    try std.testing.expectEqual(@as(u64, 19000), s.lastchg);
}

test "formatShadowLine replaces only the hash" {
    const a = std.testing.allocator;
    const s = login.parseShadowLine("sl:OLD:19000:0:99999:7:::").?;
    const line = try login.formatShadowLine(a, s, "$1$newhash$xyz");
    defer a.free(line);
    try std.testing.expectEqualStrings("sl:$1$newhash$xyz:19000:0:99999:7:::", line);
}

test "verifyPassword checks a MD5 crypt hash" {
    const a = std.testing.allocator;
    const hash = "$1$12345678$o2n/JiO/h5VviOInWJ4OQ/";
    try std.testing.expect(try login.verifyPassword(a, hash, "password"));
    try std.testing.expect(!(try login.verifyPassword(a, hash, "wrong")));
    try std.testing.expect(!(try login.verifyPassword(a, "x", "password")));
}
