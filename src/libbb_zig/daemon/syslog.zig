//! syslog.conf parsing and log-rotation policy (Task 25), ported from the
//! selector handling in busybox sysklogd/syslogd.c.

const std = @import("std");
const config = @import("config.zig");
const lifecycle = @import("lifecycle.zig");

pub const Facility = enum(u8) {
    kern = 0,
    user = 1,
    mail = 2,
    daemon = 3,
    auth = 4,
    syslog = 5,
    lpr = 6,
    news = 7,
    uucp = 8,
    cron = 9,
    authpriv = 10,
    ftp = 11,
    local0 = 16,
    local1 = 17,
    local2 = 18,
    local3 = 19,
    local4 = 20,
    local5 = 21,
    local6 = 22,
    local7 = 23,
};

const facility_names = [_]struct { name: []const u8, value: Facility }{
    .{ .name = "kern", .value = .kern },
    .{ .name = "user", .value = .user },
    .{ .name = "mail", .value = .mail },
    .{ .name = "daemon", .value = .daemon },
    .{ .name = "auth", .value = .auth },
    .{ .name = "security", .value = .auth },
    .{ .name = "syslog", .value = .syslog },
    .{ .name = "lpr", .value = .lpr },
    .{ .name = "news", .value = .news },
    .{ .name = "uucp", .value = .uucp },
    .{ .name = "cron", .value = .cron },
    .{ .name = "authpriv", .value = .authpriv },
    .{ .name = "ftp", .value = .ftp },
    .{ .name = "local0", .value = .local0 },
    .{ .name = "local1", .value = .local1 },
    .{ .name = "local2", .value = .local2 },
    .{ .name = "local3", .value = .local3 },
    .{ .name = "local4", .value = .local4 },
    .{ .name = "local5", .value = .local5 },
    .{ .name = "local6", .value = .local6 },
    .{ .name = "local7", .value = .local7 },
};

pub fn facilityByName(name: []const u8) ?Facility {
    for (facility_names) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.value;
    }
    return null;
}

pub fn facilityName(facility: Facility) []const u8 {
    for (facility_names) |entry| {
        if (entry.value == facility) return entry.name;
    }
    return "unknown";
}

pub const Priority = enum(u8) {
    emerg = 0,
    alert = 1,
    crit = 2,
    err = 3,
    warning = 4,
    notice = 5,
    info = 6,
    debug = 7,
};

const priority_names = [_]struct { name: []const u8, value: Priority }{
    .{ .name = "emerg", .value = .emerg },
    .{ .name = "panic", .value = .emerg },
    .{ .name = "alert", .value = .alert },
    .{ .name = "crit", .value = .crit },
    .{ .name = "err", .value = .err },
    .{ .name = "error", .value = .err },
    .{ .name = "warning", .value = .warning },
    .{ .name = "warn", .value = .warning },
    .{ .name = "notice", .value = .notice },
    .{ .name = "info", .value = .info },
    .{ .name = "debug", .value = .debug },
};

pub fn priorityByName(name: []const u8) ?Priority {
    for (priority_names) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.value;
    }
    return null;
}

pub fn priorityName(priority: Priority) []const u8 {
    for (priority_names) |entry| {
        if (entry.value == priority) return entry.name;
    }
    return "unknown";
}

pub const SelectorError = error{ InvalidSelector, InvalidFacility, InvalidPriority };

pub const Selector = struct {
    facility_mask: u32,
    priority_mask: u8,
    negate: bool = false,
    exact: bool = false,
    is_none: bool = false,

    pub fn matches(self: Selector, facility: Facility, priority: Priority) bool {
        if (self.is_none) return false;
        const bit: u32 = @as(u32, 1) << @as(u5, @intCast(@intFromEnum(facility)));
        if ((self.facility_mask & bit) == 0) return false;
        return (self.priority_mask & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(priority))))) != 0;
    }
};

pub fn parseSelector(text: []const u8) SelectorError!Selector {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return error.InvalidSelector;
    const facility_text = text[0..dot];
    var priority_text = text[dot + 1 ..];
    if (facility_text.len == 0 or priority_text.len == 0) return error.InvalidSelector;

    var facility_mask: u32 = 0;
    if (std.mem.eql(u8, facility_text, "*")) {
        facility_mask = 0x00ffffff;
    } else {
        var parts = std.mem.splitScalar(u8, facility_text, ',');
        while (parts.next()) |part| {
            const facility = facilityByName(part) orelse return error.InvalidFacility;
            facility_mask |= @as(u32, 1) << @as(u5, @intCast(@intFromEnum(facility)));
        }
    }

    var negate = false;
    if (priority_text[0] == '!') {
        negate = true;
        priority_text = priority_text[1..];
    }
    var exact = false;
    if (priority_text.len > 0 and priority_text[0] == '=') {
        exact = true;
        priority_text = priority_text[1..];
    }
    if (priority_text.len == 0) return error.InvalidPriority;

    if (std.mem.eql(u8, priority_text, "none")) {
        return .{
            .facility_mask = facility_mask,
            .priority_mask = 0,
            .negate = negate,
            .exact = exact,
            .is_none = !negate,
        };
    }

    var priority_mask: u8 = 0;
    if (std.mem.eql(u8, priority_text, "*")) {
        // Reference's '*' branch assigns all eight bits and never applies the
        // complement, so "*.!*" still matches every priority.
        priority_mask = 0xff;
    } else {
        const priority = priorityByName(priority_text) orelse return error.InvalidPriority;
        const value: u3 = @intCast(@intFromEnum(priority));
        priority_mask = @as(u8, 1) << value;
        // Reference expands emerg..named first ("info" means emerg..info);
        // "=" keeps only the named bit. The complement comes afterwards.
        if (!exact) {
            var bit = priority_mask;
            while (bit != 0) : (bit >>= 1) priority_mask |= bit;
        }
        if (negate) priority_mask = ~priority_mask;
    }

    return .{
        .facility_mask = facility_mask,
        .priority_mask = priority_mask,
        .negate = negate,
        .exact = exact,
    };
}

pub fn matches(selector: Selector, facility: Facility, priority: Priority) bool {
    return selector.matches(facility, priority);
}

pub const Rule = struct {
    selectors: []Selector,
    target: []u8,
    lineno: usize,

    /// A `none` selector vetoes a facility even when an earlier selector matches.
    pub fn matches(self: Rule, facility: Facility, priority: Priority) bool {
        var matched = false;
        var vetoed = false;
        for (self.selectors) |sel| {
            const bit: u32 = @as(u32, 1) << @as(u5, @intCast(@intFromEnum(facility)));
            if ((sel.facility_mask & bit) == 0) continue;
            if (sel.is_none) {
                vetoed = true;
            } else if ((sel.priority_mask & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(priority))))) != 0) {
                matched = true;
            }
        }
        return matched and !vetoed;
    }
};

pub const ParseError = error{TooManyTokens} || SelectorError || config.ConfigError;

/// Parse the restricted syslog.conf grammar: `selector[;selector...] target`.
pub fn parseSyslogConf(allocator: std.mem.Allocator, text: []const u8) ParseError![]Rule {
    const entries = try config.parseNormal(allocator, text, "# \t", 3, 2);
    defer {
        for (entries) |entry| {
            for (entry.tokens) |tok| allocator.free(tok);
            allocator.free(entry.tokens);
        }
        allocator.free(entries);
    }

    var rules: std.ArrayList(Rule) = .empty;
    errdefer {
        for (rules.items) |rule| {
            allocator.free(rule.selectors);
            allocator.free(rule.target);
        }
        rules.deinit(allocator);
    }

    for (entries) |entry| {
        if (entry.tokens.len > 2) return error.TooManyTokens;
        const target = try allocator.dupe(u8, entry.tokens[1]);
        errdefer allocator.free(target);

        var selectors: std.ArrayList(Selector) = .empty;
        errdefer selectors.deinit(allocator);
        var selector_text = std.mem.splitScalar(u8, entry.tokens[0], ';');
        while (selector_text.next()) |part| {
            try selectors.append(allocator, try parseSelector(part));
        }
        try rules.append(allocator, .{
            .selectors = try selectors.toOwnedSlice(allocator),
            .target = target,
            .lineno = entry.lineno,
        });
    }
    return try rules.toOwnedSlice(allocator);
}

pub const RotationConfig = lifecycle.RotationConfig;
pub const RotationPlan = lifecycle.RotationPlan;
pub const planRotation = lifecycle.planRotation;
pub const rotateFiles = lifecycle.rotateFiles;
