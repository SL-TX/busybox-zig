//! Crontab parsing helpers (Task 25), modelled on busybox miscutils/crond.c.

const std = @import("std");
const config = @import("config.zig");

pub const FieldError = error{ InvalidField, InvalidRange, InvalidStep };

const month_names = [_][]const u8{ "", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const day_names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

fn namedValue(text: []const u8) ?u8 {
    for (month_names, 0..) |name, i| {
        if (i != 0 and std.mem.eql(u8, name, text)) return @intCast(i);
    }
    for (day_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, text)) return @intCast(i);
    }
    return null;
}

fn parseValue(text: []const u8, min: u8, max: u8) FieldError!u8 {
    var value: u8 = undefined;
    if (std.fmt.parseInt(u8, text, 10)) |parsed| {
        value = parsed;
    } else |_| {
        value = namedValue(text) orelse return error.InvalidField;
    }
    if (value < min or value > max) return error.InvalidField;
    return value;
}

pub const TimeField = struct {
    mask: u64 = 0,

    pub fn matches(self: TimeField, value: u8) bool {
        if (value >= 64) return false;
        return (self.mask & (@as(u64, 1) << @intCast(value))) != 0;
    }

    pub fn count(self: TimeField) usize {
        return @popCount(self.mask);
    }
};

/// Parse one crontab time field, including `*`, lists, ranges and step values.
pub fn parseField(text: []const u8, min: u8, max: u8) FieldError!TimeField {
    if (text.len == 0) return error.InvalidField;
    var field = TimeField{};
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidField;
        var base = part;
        var step: u8 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
            base = part[0..slash];
            const step_text = part[slash + 1 ..];
            const parsed_step = std.fmt.parseInt(u8, step_text, 10) catch return error.InvalidStep;
            if (parsed_step == 0) return error.InvalidStep;
            step = parsed_step;
        }

        var low: u8 = undefined;
        var high: u8 = undefined;
        if (std.mem.eql(u8, base, "*")) {
            low = min;
            high = max;
        } else if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
            low = try parseValue(base[0..dash], min, max);
            high = try parseValue(base[dash + 1 ..], min, max);
            if (low > high) return error.InvalidRange;
        } else {
            low = try parseValue(base, min, max);
            high = low;
        }

        var value: u16 = low;
        while (value <= high) : (value += step) {
            field.mask |= @as(u64, 1) << @intCast(value);
            if (step == 0) break;
        }
    }
    return field;
}

pub const Env = struct {
    name: []u8,
    value: []u8,
    lineno: usize,
};

pub const Entry = struct {
    minute: TimeField,
    hour: TimeField,
    day_of_month: TimeField,
    month: TimeField,
    dow: TimeField,
    command: []u8,
    lineno: usize,
};

pub const Crontab = struct {
    entries: []Entry,
    env: []Env,
};

pub const CrontabError = error{TooFewTokens} || FieldError || config.ConfigError;

pub fn parseCrontab(allocator: std.mem.Allocator, text: []const u8) CrontabError!Crontab {
    const lines = try config.parseNormal(allocator, text, "# \t", 6, 0);
    defer {
        for (lines) |line| {
            for (line.tokens) |tok| allocator.free(tok);
            allocator.free(line.tokens);
        }
        allocator.free(lines);
    }

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.command);
        entries.deinit(allocator);
    }
    var env: std.ArrayList(Env) = .empty;
    errdefer {
        for (env.items) |item| {
            allocator.free(item.name);
            allocator.free(item.value);
        }
        env.deinit(allocator);
    }

    for (lines) |line| {
        const tokens = line.tokens;
        if (tokens.len == 1) {
            if (std.mem.indexOfScalar(u8, tokens[0], '=')) |eq| {
                try env.append(allocator, .{
                    .name = try allocator.dupe(u8, std.mem.trimEnd(u8, tokens[0][0..eq], " \t")),
                    .value = try allocator.dupe(u8, std.mem.trimStart(u8, tokens[0][eq + 1 ..], " \t")),
                    .lineno = line.lineno,
                });
                continue;
            }
        }
        if (tokens.len < 6) return error.TooFewTokens;
        try entries.append(allocator, .{
            .minute = try parseField(tokens[0], 0, 59),
            .hour = try parseField(tokens[1], 0, 23),
            .day_of_month = try parseField(tokens[2], 1, 31),
            .month = try parseField(tokens[3], 1, 12),
            .dow = try parseField(tokens[4], 0, 7),
            .command = try allocator.dupe(u8, tokens[5]),
            .lineno = line.lineno,
        });
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .env = try env.toOwnedSlice(allocator),
    };
}
