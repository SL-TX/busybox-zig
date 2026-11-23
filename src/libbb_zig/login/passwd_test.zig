const std = @import("std");
const passwd = @import("libbb_zig").login.passwd;

const sample =
    "root:x:0:0:root:/root:/bin/sh\n" ++
    "# a comment\n" ++
    "daemon:x:1:1:daemon:/usr/sbin:/sbin/nologin\n" ++
    "+nisentry\n" ++
    "alice:$6$salt$hash:1000:100:Alice:/home/alice:/bin/ash\n";

test "passwd parseLine reads all seven fields" {
    const e = (try passwd.parseLine("alice:x:1000:100:Alice:/home/alice:/bin/ash\n")).?;
    try std.testing.expectEqualStrings("alice", e.name);
    try std.testing.expectEqual(@as(u32, 1000), e.uid);
    try std.testing.expectEqual(@as(u32, 100), e.gid);
    try std.testing.expectEqualStrings("Alice", e.gecos);
    try std.testing.expectEqualStrings("/home/alice", e.dir);
    try std.testing.expectEqualStrings("/bin/ash", e.shell);
}

test "passwd parseLine skips comments and rejects malformed entries" {
    try std.testing.expect((try passwd.parseLine("# comment")) == null);
    try std.testing.expect((try passwd.parseLine("")) == null);
    try std.testing.expectError(error.MalformedLine, passwd.parseLine("only:four:fields:here\n"));
    try std.testing.expectError(error.MalformedLine, passwd.parseLine("bad:x:not-a-uid:1::/:/bin/sh\n"));
    try std.testing.expectError(error.MalformedLine, passwd.parseLine("too:many:1:1::::extra\n"));
}

test "passwd lookups by name and uid" {
    const by_name = (try passwd.findByName(sample, "daemon")).?;
    try std.testing.expectEqual(@as(u32, 1), by_name.uid);
    const by_uid = (try passwd.findByUid(sample, 1000)).?;
    try std.testing.expectEqualStrings("alice", by_uid.name);
    try std.testing.expect((try passwd.findByName(sample, "nobody")) == null);
}
