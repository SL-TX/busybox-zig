//! inittab parsing helpers (Task 25), ported from busybox init/init.c
//! parse_inittab(). No processes are spawned and no /etc file is read.

const std = @import("std");
const config = @import("config.zig");

pub const lifecycle = @import("lifecycle.zig");

pub const Action = enum {
    sysinit,
    wait,
    once,
    respawn,
    askfirst,
    ctrlaltdel,
    shutdown,
    restart,
};

const action_names = [_][]const u8{
    "sysinit", "wait", "once", "respawn", "askfirst", "ctrlaltdel", "shutdown", "restart",
};

pub fn actionByName(name: []const u8) ?Action {
    for (action_names, 0..) |candidate, i| {
        if (std.mem.eql(u8, name, candidate)) return @enumFromInt(i);
    }
    return null;
}

pub fn actionName(action: Action) []const u8 {
    return action_names[@intFromEnum(action)];
}

pub const Entry = struct {
    id: []u8,
    runlevels: []u8,
    action: Action,
    command: []u8,
    lineno: usize,
};

pub const ParseError = error{ UnknownAction, InvalidEntry } || config.ConfigError;

/// Parse `id:runlevels:action:command`. Delimiters are not collapsed so that
/// empty id/runlevel fields are preserved, and exactly four fields are needed.
pub fn parseInittab(allocator: std.mem.Allocator, text: []const u8) ParseError![]Entry {
    const lines = try config.parse(allocator, text, .{
        .delimiters = "#:",
        .max_tokens = 16,
        .min_tokens = 0,
        .greedy = false,
        .trim = false,
        .collapse = false,
        .ws_comments = true,
    });
    defer {
        for (lines) |line| {
            for (line.tokens) |tok| allocator.free(tok);
            allocator.free(line.tokens);
        }
        allocator.free(lines);
    }

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.runlevels);
            allocator.free(entry.command);
        }
        entries.deinit(allocator);
    }

    for (lines) |line| {
        const tokens = line.tokens;
        if (tokens.len != 4) return error.InvalidEntry;
        const action = actionByName(tokens[2]) orelse return error.UnknownAction;
        if (tokens[3].len == 0) return error.InvalidEntry;

        const entry = Entry{
            .id = try allocator.dupe(u8, tokens[0]),
            .runlevels = try allocator.dupe(u8, tokens[1]),
            .action = action,
            .command = try allocator.dupe(u8, tokens[3]),
            .lineno = line.lineno,
        };
        errdefer {
            allocator.free(entry.id);
            allocator.free(entry.runlevels);
            allocator.free(entry.command);
        }
        try entries.append(allocator, entry);
    }
    return try entries.toOwnedSlice(allocator);
}

pub fn runlevelMatches(runlevels: []const u8, level: u8) bool {
    if (runlevels.len == 0) return true;
    return std.mem.indexOfScalar(u8, runlevels, level) != null;
}

/// Convert a bare inittab device id into the /dev path used by init.
pub fn resolveTty(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    if (id.len == 0) return allocator.dupe(u8, "");
    if (std.mem.startsWith(u8, id, "/dev/")) return allocator.dupe(u8, id);
    return std.fmt.allocPrint(allocator, "/dev/{s}", .{id});
}

fn makeEntry(allocator: std.mem.Allocator, id: []const u8, runlevels: []const u8, action: Action, command: []const u8) !Entry {
    return .{
        .id = try allocator.dupe(u8, id),
        .runlevels = try allocator.dupe(u8, runlevels),
        .action = action,
        .command = try allocator.dupe(u8, command),
        .lineno = 0,
    };
}

/// The behaviour busybox init installs when /etc/inittab is absent.
pub fn defaultActions(allocator: std.mem.Allocator) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.runlevels);
            allocator.free(entry.command);
        }
        entries.deinit(allocator);
    }
    try entries.append(allocator, try makeEntry(allocator, "", "", .sysinit, "/etc/init.d/rcS"));
    try entries.append(allocator, try makeEntry(allocator, "", "", .askfirst, "/bin/sh"));
    try entries.append(allocator, try makeEntry(allocator, "tty2", "", .askfirst, "/bin/sh"));
    try entries.append(allocator, try makeEntry(allocator, "tty3", "", .askfirst, "/bin/sh"));
    try entries.append(allocator, try makeEntry(allocator, "tty4", "", .askfirst, "/bin/sh"));
    try entries.append(allocator, try makeEntry(allocator, "", "", .ctrlaltdel, "reboot"));
    try entries.append(allocator, try makeEntry(allocator, "", "", .shutdown, "umount -a -r"));
    try entries.append(allocator, try makeEntry(allocator, "", "", .shutdown, "swapoff -a"));
    try entries.append(allocator, try makeEntry(allocator, "", "", .restart, "init"));
    return try entries.toOwnedSlice(allocator);
}
