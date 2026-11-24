//! Parsing helpers for /etc/passwd-style files.  All returned slices point
//! into the caller's buffer; malformed lines are errors, never panics.

const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    passwd: []const u8,
    uid: u32,
    gid: u32,
    gecos: []const u8,
    dir: []const u8,
    shell: []const u8,
};

fn trimEol(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// Parse one line.  Returns null for blank/comment/NIS ('+'/'-') lines.
pub fn parseLine(line_raw: []const u8) !?Entry {
    const line = trimEol(line_raw);
    if (line.len == 0 or line[0] == '#' or line[0] == '+' or line[0] == '-') return null;
    var fields: [7][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, ':');
    for (0..7) |i| fields[i] = it.next() orelse return error.MalformedLine;
    if (it.next() != null) return error.MalformedLine;
    return .{
        .name = fields[0],
        .passwd = fields[1],
        .uid = std.fmt.parseInt(u32, fields[2], 10) catch return error.MalformedLine,
        .gid = std.fmt.parseInt(u32, fields[3], 10) catch return error.MalformedLine,
        .gecos = fields[4],
        .dir = fields[5],
        .shell = fields[6],
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

pub fn findByUid(data: []const u8, uid: u32) !?Entry {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (try parseLine(line)) |e| {
            if (e.uid == uid) return e;
        }
    }
    return null;
}
