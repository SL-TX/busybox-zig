//! Parsing helpers for /etc/shadow-style files.  Empty numeric fields are
//! represented as null (BusyBox uses -1 for "unset").  Slices are borrowed
//! from the caller's buffer.

const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    passwd: []const u8,
    lastchg: ?i64,
    min: ?i64,
    max: ?i64,
    warn: ?i64,
    inact: ?i64,
    expire: ?i64,
    flag: ?u64,
};

fn parseNum(comptime T: type, text: []const u8) !?T {
    if (text.len == 0) return null;
    return std.fmt.parseInt(T, text, 10) catch return error.MalformedLine;
}

pub fn parseLine(line_raw: []const u8) !?Entry {
    const line = std.mem.trimEnd(u8, line_raw, "\r\n");
    if (line.len == 0 or line[0] == '#' or line[0] == '+' or line[0] == '-') return null;
    var fields: [9][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, ':');
    for (0..9) |i| fields[i] = it.next() orelse return error.MalformedLine;
    if (it.next() != null) return error.MalformedLine;
    return .{
        .name = fields[0],
        .passwd = fields[1],
        .lastchg = try parseNum(i64, fields[2]),
        .min = try parseNum(i64, fields[3]),
        .max = try parseNum(i64, fields[4]),
        .warn = try parseNum(i64, fields[5]),
        .inact = try parseNum(i64, fields[6]),
        .expire = try parseNum(i64, fields[7]),
        .flag = try parseNum(u64, fields[8]),
    };
}

pub fn findByName(data: []const u8, name: []const u8) !?Entry {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (try parseLine(line)) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
    }
    return null;
}
