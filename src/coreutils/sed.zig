//! Minimal streaming editor: literal s///, d, p with numeric, $ and /pattern/ addresses.
//! Full POSIX BRE regex is not implemented yet.

const std = @import("std");

const Addr = union(enum) {
    none,
    number: usize,
    last,
    pattern: []const u8,
};

const Kind = enum { substitute, delete, print };

const Command = struct {
    kind: Kind,
    addr: Addr = .none,
    pattern: []const u8 = "",
    replacement: []const u8 = "",
    global: bool = false,
};

fn parseCommand(text: []const u8) ?Command {
    var s = std.mem.trim(u8, text, " \t\r;");
    if (s.len == 0) return null;
    var cmd = Command{ .kind = .print };

    if (s[0] == '/') {
        const end = std.mem.indexOfScalarPos(u8, s, 1, '/') orelse return null;
        cmd.addr = .{ .pattern = s[1..end] };
        s = s[end + 1 ..];
    } else if (s[0] == '$') {
        cmd.addr = .last;
        s = s[1..];
    } else if (std.ascii.isDigit(s[0])) {
        var i: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        cmd.addr = .{ .number = std.fmt.parseInt(usize, s[0..i], 10) catch return null };
        s = s[i..];
    }
    s = std.mem.trimStart(u8, s, " \t");
    if (s.len == 0) return null;

    switch (s[0]) {
        'd' => cmd.kind = .delete,
        'p' => cmd.kind = .print,
        's' => {
            cmd.kind = .substitute;
            if (s.len < 4) return null;
            const delim = s[1];
            const p1 = std.mem.indexOfScalarPos(u8, s, 2, delim) orelse return null;
            const p2 = std.mem.indexOfScalarPos(u8, s, p1 + 1, delim) orelse return null;
            cmd.pattern = s[2..p1];
            cmd.replacement = s[p1 + 1 .. p2];
            cmd.global = std.mem.indexOfScalar(u8, s[p2 + 1 ..], 'g') != null;
        },
        else => return null,
    }
    return cmd;
}

fn addrMatches(addr: Addr, line_no: usize, total: usize, line: []const u8) bool {
    return switch (addr) {
        .none => true,
        .number => |n| n == line_no,
        .last => line_no == total,
        .pattern => |p| std.mem.indexOf(u8, line, p) != null,
    };
}

fn replaceOnce(a: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return a.dupe(u8, input);
    const pos = std.mem.indexOf(u8, input, needle) orelse return a.dupe(u8, input);
    return std.mem.concat(a, u8, &.{ input[0..pos], replacement, input[pos + needle.len ..] });
}

pub fn renderSed(a: std.mem.Allocator, data: []const u8, script: []const u8, quiet: bool) ![]u8 {
    var commands: std.ArrayList(Command) = .empty;
    defer commands.deinit(a);
    var scripts = std.mem.splitAny(u8, script, "\n;");
    while (scripts.next()) |part| {
        if (parseCommand(part)) |cmd| try commands.append(a, cmd);
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        try lines.append(a, line);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (lines.items, 1..) |original, line_no| {
        var current = original;
        const owned = a.dupe(u8, original) catch return error.OutOfMemory;
        defer a.free(owned);
        var deleted = false;
        var print_flag = false;
        for (commands.items) |cmd| {
            if (!addrMatches(cmd.addr, line_no, lines.items.len, current)) continue;
            switch (cmd.kind) {
                .delete => deleted = true,
                .print => print_flag = true,
                .substitute => {
                    if (cmd.global) {
                        const next = std.mem.replaceOwned(u8, a, current, cmd.pattern, cmd.replacement) catch return error.OutOfMemory;
                        @memcpy(owned[0..next.len], next);
                        a.free(next);
                        current = owned[0..next.len];
                    } else {
                        const next = try replaceOnce(a, current, cmd.pattern, cmd.replacement);
                        defer a.free(next);
                        if (next.len <= owned.len) {
                            @memcpy(owned[0..next.len], next);
                            current = owned[0..next.len];
                        }
                    }
                },
            }
        }
        if (deleted) continue;
        if (!quiet or print_flag) {
            try out.appendSlice(a, current);
            try out.append(a, '\n');
        }
    }
    return out.toOwnedSlice(a);
}
