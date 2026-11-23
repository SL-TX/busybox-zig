//! TDD tests for syslog.conf parsing and log rotation policy (Task 25).

const std = @import("std");
const bb = @import("libbb_zig");
const syslog = bb.daemon.syslog;

test "facility and priority names round-trip" {
    try std.testing.expectEqual(syslog.Facility.kern, syslog.facilityByName("kern").?);
    try std.testing.expectEqual(syslog.Facility.local7, syslog.facilityByName("local7").?);
    try std.testing.expectEqualStrings("daemon", syslog.facilityName(.daemon));
    try std.testing.expectEqual(syslog.Priority.err, syslog.priorityByName("err").?);
    try std.testing.expectEqual(syslog.Priority.warning, syslog.priorityByName("warning").?);
    try std.testing.expect(syslog.priorityByName("bogus") == null);
    try std.testing.expect(syslog.facilityByName("bogus") == null);
}

test "parseSelector handles wildcard and exact priorities" {
    const all = try syslog.parseSelector("*.info");
    try std.testing.expect(all.facility_mask != 0);
    try std.testing.expect(all.matches(.mail, .info));
    try std.testing.expect(!all.matches(.mail, .debug));

    const exact = try syslog.parseSelector("kern.=err");
    try std.testing.expect(exact.exact);
    try std.testing.expect(exact.matches(.kern, .err));
    try std.testing.expect(!exact.matches(.kern, .crit));
}

// Reference parse_syslogdcfg() expands emerg..named FIRST, then complements.
test "negated selectors expand then complement like busybox" {
    const all_but_debug = try syslog.parseSelector("*.!debug");
    try std.testing.expect(all_but_debug.negate);
    for ([_]syslog.Priority{ .emerg, .alert, .crit, .err, .warning, .notice, .info, .debug }) |prio| {
        try std.testing.expect(!all_but_debug.matches(.mail, prio));
    }

    // The '*' branch sets all eight bits without a complement in the reference.
    const all_but_star = try syslog.parseSelector("*.!*");
    for ([_]syslog.Priority{ .emerg, .err, .notice, .debug }) |prio| {
        try std.testing.expect(all_but_star.matches(.mail, prio));
    }

    const not_err = try syslog.parseSelector("*.!err");
    try std.testing.expect(!not_err.matches(.mail, .emerg));
    try std.testing.expect(!not_err.matches(.mail, .err));
    try std.testing.expect(not_err.matches(.mail, .warning));
    try std.testing.expect(not_err.matches(.mail, .debug));
}

test "none priority vetoes all messages for its facility" {
    const sel = try syslog.parseSelector("mail.none");
    try std.testing.expect(sel.is_none);
    try std.testing.expect(!sel.matches(.mail, .err));
}

test "parseSelector rejects missing or malformed components" {
    try std.testing.expectError(error.InvalidSelector, syslog.parseSelector("no-dot"));
    try std.testing.expectError(error.InvalidFacility, syslog.parseSelector("nope.info"));
    try std.testing.expectError(error.InvalidPriority, syslog.parseSelector("kern.nope"));
    try std.testing.expectError(error.InvalidSelector, syslog.parseSelector("kern."));
}

test "parseSyslogConf builds one rule per selector group" {
    const a = std.testing.allocator;
    const text =
        "*.info;mail.none\t/var/log/messages\n" ++
        "kern.*\t/dev/console\n" ++
        "# comment\n" ++
        "*.err\t/tmp/opencode/errors.log\n";
    const rules = try syslog.parseSyslogConf(a, text);
    defer {
        for (rules) |r| {
            a.free(r.selectors);
            a.free(r.target);
        }
        a.free(rules);
    }
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqual(@as(usize, 2), rules[0].selectors.len);
    try std.testing.expectEqualStrings("/var/log/messages", rules[0].target);
    try std.testing.expect(!rules[0].matches(.mail, .info));
    try std.testing.expect(rules[0].matches(.kern, .info));
    try std.testing.expectEqualStrings("/dev/console", rules[1].target);
    try std.testing.expectEqual(@as(usize, 4), rules[2].lineno);
}

test "parseSyslogConf rejects a line with a trailing token" {
    const a = std.testing.allocator;
    const r = syslog.parseSyslogConf(a, "*.info /var/log/a extra\n");
    if (r) |rules| {
        for (rules) |rule| {
            a.free(rule.selectors);
            a.free(rule.target);
        }
        a.free(rules);
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.TooManyTokens, e);
    }
}

test "parseSyslogConf rejects a malformed selector" {
    const a = std.testing.allocator;
    const r = syslog.parseSyslogConf(a, "bogus.info /var/log/a\n");
    if (r) |rules| {
        for (rules) |rule| {
            a.free(rule.selectors);
            a.free(rule.target);
        }
        a.free(rules);
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.InvalidFacility, e);
    }
}

test "syslog rotation policy reuses the lifecycle helper" {
    try std.testing.expect(!syslog.planRotation(.{ .max_size = 10, .keep = 2 }, 10).rotate);
    const plan = syslog.planRotation(.{ .max_size = 10, .keep = 2 }, 11);
    try std.testing.expect(plan.rotate);
    try std.testing.expectEqual(@as(usize, 1), plan.shifts);
}
