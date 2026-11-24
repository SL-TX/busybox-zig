//! Parsing helpers for /etc/group-style files.  `members` is the raw
//! comma-separated member field; use `hasMember` to test membership without
//! allocating.

const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    passwd: []const u8,
    gid: u32,
    members: []const u8,

    pub fn hasMember(self: Entry, user: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.members, ',');
        while (it.next()) |m| {
            if (std.mem.eql(u8, m, user)) return true;
        }
        return false;
    }
};

pub fn parseLine(line_raw: []const u8) !?Entry {
    const line = std.mem.trimEnd(u8, line_raw, "\r\n");
    if (line.len == 0 or line[0] == '#' or line[0] == '+' or line[0] == '-') return null;
    var fields: [4][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, ':');
    for (0..4) |i| fields[i] = it.next() orelse return error.MalformedLine;
    if (it.next() != null) return error.MalformedLine;
    return .{
        .name = fields[0],
        .passwd = fields[1],
        .gid = std.fmt.parseInt(u32, fields[2], 10) catch return error.MalformedLine,
        .members = fields[3],
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

pub fn findByGid(data: []const u8, gid: u32) !?Entry {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (try parseLine(line)) |e| {
            if (e.gid == gid) return e;
        }
    }
    return null;
}

pub fn userInGroup(data: []const u8, group: []const u8, user: []const u8) !bool {
    const entry = (try findByName(data, group)) orelse return false;
    return entry.hasMember(user);
}
