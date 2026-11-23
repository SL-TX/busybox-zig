const std = @import("std");
const group = @import("libbb_zig").login.group;

const sample =
    "root:x:0:\n" ++
    "wheel:x:10:root,alice\n" ++
    "nogroup:x:65534:\n";

test "group parseLine and membership" {
    const wheel = (try group.findByName(sample, "wheel")).?;
    try std.testing.expectEqual(@as(u32, 10), wheel.gid);
    try std.testing.expectEqualStrings("root,alice", wheel.members);
    try std.testing.expect(wheel.hasMember("alice"));
    try std.testing.expect(wheel.hasMember("root"));
    try std.testing.expect(!wheel.hasMember("bob"));

    try std.testing.expect(try group.userInGroup(sample, "wheel", "alice"));
    try std.testing.expect(!(try group.userInGroup(sample, "wheel", "bob")));
    try std.testing.expect(!(try group.userInGroup(sample, "missing", "bob")));
}

test "group lookup by gid and malformed input" {
    const g = (try group.findByGid(sample, 65534)).?;
    try std.testing.expectEqualStrings("nogroup", g.name);
    try std.testing.expect((try group.findByGid(sample, 1234)) == null);
    try std.testing.expectError(error.MalformedLine, group.parseLine("root:x:bad:\n"));
    try std.testing.expectError(error.MalformedLine, group.parseLine("root:x:0\n"));
}
