//! TDD tests for inittab parsing and init action helpers (Task 25).

const std = @import("std");
const bb = @import("libbb_zig");
const init = bb.daemon.init;

fn freeEntries(a: std.mem.Allocator, entries: []init.Entry) void {
    for (entries) |e| {
        a.free(e.id);
        a.free(e.runlevels);
        a.free(e.command);
    }
    a.free(entries);
}

test "action names round-trip in the reference order" {
    try std.testing.expectEqual(init.Action.sysinit, init.actionByName("sysinit").?);
    try std.testing.expectEqual(init.Action.respawn, init.actionByName("respawn").?);
    try std.testing.expectEqual(init.Action.restart, init.actionByName("restart").?);
    try std.testing.expectEqualStrings("askfirst", init.actionName(.askfirst));
    try std.testing.expect(init.actionByName("bogus") == null);
}

test "parseInittab keeps empty id and runlevel fields" {
    const a = std.testing.allocator;
    const text =
        "# /etc/inittab\n" ++
        "::sysinit:/etc/init.d/rcS\n" ++
        "tty1:2345:respawn:/sbin/getty 38400 tty1\n" ++
        "::ctrlaltdel:/sbin/reboot\n";
    const entries = try init.parseInittab(a, text);
    defer freeEntries(a, entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("", entries[0].id);
    try std.testing.expectEqualStrings("", entries[0].runlevels);
    try std.testing.expectEqual(init.Action.sysinit, entries[0].action);
    try std.testing.expectEqualStrings("/etc/init.d/rcS", entries[0].command);
    try std.testing.expectEqualStrings("tty1", entries[1].id);
    try std.testing.expectEqualStrings("2345", entries[1].runlevels);
    try std.testing.expectEqualStrings("/sbin/getty 38400 tty1", entries[1].command);
    try std.testing.expectEqual(init.Action.ctrlaltdel, entries[2].action);
    try std.testing.expectEqual(@as(usize, 4), entries[2].lineno);
}

test "parseInittab rejects unknown actions and short lines" {
    const a = std.testing.allocator;
    const bad_action = init.parseInittab(a, "tty1:2345:bogus:/bin/sh\n");
    if (bad_action) |entries| {
        freeEntries(a, entries);
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.UnknownAction, e);
    }
    try std.testing.expectError(error.InvalidEntry, init.parseInittab(a, "tty1:2345:respawn\n"));
}

test "runlevelMatches honours digit and wildcard sets" {
    try std.testing.expect(init.runlevelMatches("2345", '3'));
    try std.testing.expect(!init.runlevelMatches("2345", '6'));
    try std.testing.expect(init.runlevelMatches("S", 'S'));
    try std.testing.expect(init.runlevelMatches("", '5'));
}

test "resolveTty prefixes bare device names with /dev/" {
    const a = std.testing.allocator;
    const tty = try init.resolveTty(a, "ttyS0");
    defer a.free(tty);
    try std.testing.expectEqualStrings("/dev/ttyS0", tty);
    const absolute = try init.resolveTty(a, "/dev/tty1");
    defer a.free(absolute);
    try std.testing.expectEqualStrings("/dev/tty1", absolute);
    const empty = try init.resolveTty(a, "");
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "defaultActions install sysinit, gettys and shutdown handlers" {
    const a = std.testing.allocator;
    const entries = try init.defaultActions(a);
    defer freeEntries(a, entries);
    try std.testing.expect(entries.len >= 8);
    try std.testing.expectEqual(init.Action.sysinit, entries[0].action);
    var askfirst: usize = 0;
    for (entries) |e| {
        if (e.action == .askfirst) askfirst += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), askfirst);
}
