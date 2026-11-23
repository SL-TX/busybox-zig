const std = @import("std");
const shadow = @import("libbb_zig").login.shadow;

const sample =
    "root:*:19000:0:99999:7:::\n" ++
    "alice:$6$salt$hash:19000:0:99999:7:30:20000:1\n" ++
    "bob:!:18000::::::\n";

test "shadow parseLine reads numeric fields and treats empty as null" {
    const a = (try shadow.findByName(sample, "alice")).?;
    try std.testing.expectEqualStrings("$6$salt$hash", a.passwd);
    try std.testing.expectEqual(@as(i64, 19000), a.lastchg.?);
    try std.testing.expectEqual(@as(i64, 30), a.inact.?);
    try std.testing.expectEqual(@as(i64, 20000), a.expire.?);
    try std.testing.expectEqual(@as(u64, 1), a.flag.?);

    const b = (try shadow.findByName(sample, "bob")).?;
    try std.testing.expectEqualStrings("!", b.passwd);
    try std.testing.expect(b.lastchg != null);
    try std.testing.expect(b.max == null);
    try std.testing.expect(b.flag == null);
}

test "shadow rejects malformed lines" {
    try std.testing.expectError(error.MalformedLine, shadow.parseLine("only:two:fields\n"));
    try std.testing.expectError(error.MalformedLine, shadow.parseLine("x:*:abc:0:99999:7:::\n"));
    try std.testing.expect((try shadow.parseLine("# comment")) == null);
    try std.testing.expect((try shadow.findByName(sample, "missing")) == null);
}
