//! Minimal awk subset: BEGIN/END, empty and /substring/ patterns, print with fields.
//! Full awk expressions and regex are not implemented yet.

const std = @import("std");

const Phase = enum { main, begin, end };
const Rule = struct {
    phase: Phase = .main,
    pattern: ?[]const u8 = null,
    action: []const u8,
};

fn parseProgram(a: std.mem.Allocator, program: []const u8) ![]Rule {
    var rules: std.ArrayList(Rule) = .empty;
    errdefer rules.deinit(a);
    var pos: usize = 0;
    while (pos < program.len) {
        const open = std.mem.indexOfScalarPos(u8, program, pos, '{') orelse break;
        const close = std.mem.indexOfScalarPos(u8, program, open + 1, '}') orelse break;
        const prefix = std.mem.trim(u8, program[pos..open], " \t\n\r");
        var rule = Rule{ .action = program[open + 1 .. close] };
        if (std.mem.eql(u8, prefix, "BEGIN")) {
            rule.phase = .begin;
        } else if (std.mem.eql(u8, prefix, "END")) {
            rule.phase = .end;
        } else if (prefix.len >= 2 and prefix[0] == '/' and prefix[prefix.len - 1] == '/') {
            rule.pattern = prefix[1 .. prefix.len - 1];
        }
        try rules.append(a, rule);
        pos = close + 1;
    }
    return rules.toOwnedSlice(a);
}

fn fieldsOf(a: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer fields.deinit(a);
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |f| try fields.append(a, f);
    return fields.toOwnedSlice(a);
}

fn runAction(a: std.mem.Allocator, out: *std.ArrayList(u8), action: []const u8, line: []const u8, fields: [][]const u8) !void {
    const s = std.mem.trim(u8, action, " \t\n\r");
    if (!std.mem.startsWith(u8, s, "print")) return;
    const rest = std.mem.trim(u8, s[5..], " \t");
    if (rest.len == 0) {
        try out.appendSlice(a, line);
    } else if (rest[0] == '"' and rest.len >= 2 and rest[rest.len - 1] == '"') {
        try out.appendSlice(a, rest[1 .. rest.len - 1]);
    } else {
        var parts = std.mem.splitScalar(u8, rest, ',');
        var first = true;
        while (parts.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t");
            if (!first) try out.append(a, ' ');
            first = false;
            if (p.len >= 2 and p[0] == '$') {
                const idx = std.fmt.parseInt(usize, p[1..], 10) catch 0;
                if (idx > 0 and idx <= fields.len) try out.appendSlice(a, fields[idx - 1]);
            } else if (p.len >= 2 and p[0] == '"' and p[p.len - 1] == '"') {
                try out.appendSlice(a, p[1 .. p.len - 1]);
            } else {
                try out.appendSlice(a, p);
            }
        }
    }
    try out.append(a, '\n');
}

pub fn renderAwk(a: std.mem.Allocator, data: []const u8, program: []const u8) ![]u8 {
    const rules = try parseProgram(a, program);
    defer a.free(rules);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    for (rules) |rule| if (rule.phase == .begin) {
        try runAction(a, &out, rule.action, "", &.{});
    };

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        const fields = try fieldsOf(a, line);
        defer a.free(fields);
        for (rules) |rule| {
            if (rule.phase != .main) continue;
            if (rule.pattern) |p| {
                if (std.mem.indexOf(u8, line, p) == null) continue;
            }
            try runAction(a, &out, rule.action, line, fields);
        }
    }

    for (rules) |rule| if (rule.phase == .end) {
        try runAction(a, &out, rule.action, "", &.{});
    };
    return out.toOwnedSlice(a);
}
