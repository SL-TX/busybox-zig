//! POSIX-ish streaming editor used by the `sed` applet.
//!
//! Supports numeric/$ /regex/ addresses and ranges, s/// with `g`, `i`, an
//! occurrence count, \\1..\\9 and & back references, y///, d, p and { ... }
//! groups.  Patterns are compiled with the Task 21 POSIX regex engine (BRE by
//! default, ERE with -E), including character classes and leftmost-longest
//! semantics.

const std = @import("std");
const regex = @import("libbb_zig").regex;

pub const Options = struct {
    quiet: bool = false,
    extended: bool = false,
};

const AddrKind = enum { none, number, last, pattern };
const Addr = struct {
    kind: AddrKind = .none,
    number: usize = 0,
    pattern: []const u8 = "",
    re: ?*regex.Regex = null,
    active: bool = false,
};

const Kind = enum { substitute, delete, print, translate, block };
const Command = struct {
    kind: Kind,
    a1: Addr = .{},
    a2: ?Addr = null,
    pattern: []const u8 = "",
    replacement: []const u8 = "",
    global: bool = false,
    nth: usize = 0,
    ignore_case: bool = false,
    re: ?*regex.Regex = null,
    from: []const u8 = "",
    to: []const u8 = "",
    children: []Command = &.{},
};

const Parser = struct {
    a: std.mem.Allocator,
    script: []const u8,
    pos: usize = 0,
    extended: bool,
    compiled: std.ArrayList(*regex.Regex),

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.script.len and (self.script[self.pos] == ' ' or self.script[self.pos] == '\t' or self.script[self.pos] == '\r')) self.pos += 1;
    }

    fn parseAddr(self: *Parser) ?Addr {
        self.skipSpace();
        if (self.pos >= self.script.len) return null;
        const c = self.script[self.pos];
        if (std.ascii.isDigit(c)) {
            var end = self.pos;
            while (end < self.script.len and std.ascii.isDigit(self.script[end])) end += 1;
            const n = std.fmt.parseInt(usize, self.script[self.pos..end], 10) catch return null;
            self.pos = end;
            return .{ .kind = .number, .number = n };
        }
        if (c == '$') {
            self.pos += 1;
            return .{ .kind = .last };
        }
        if (c == '/') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.script.len) : (self.pos += 1) {
                if (self.script[self.pos] == '\\' and self.pos + 1 < self.script.len) {
                    self.pos += 1;
                    continue;
                }
                if (self.script[self.pos] == '/') break;
            }
            if (self.pos >= self.script.len) return null;
            const text = self.script[start..self.pos];
            self.pos += 1;
            return self.makePatternAddr(text, false);
        }
        return null;
    }

    fn makePatternAddr(self: *Parser, text: []const u8, ignore_case: bool) ?Addr {
        const re = self.a.create(regex.Regex) catch return null;
        const compiled = regex.compile(self.a, text, .{ .extended = self.extended, .ignore_case = ignore_case }) catch return null;
        re.* = compiled;
        self.compiled.append(self.a, re) catch return null;
        return .{ .kind = .pattern, .pattern = text, .re = re };
    }

    fn parseUntil(self: *Parser, delim: u8) ?[]const u8 {
        const start = self.pos;
        while (self.pos < self.script.len) : (self.pos += 1) {
            const c = self.script[self.pos];
            if (c == '\\' and self.pos + 1 < self.script.len) {
                self.pos += 1;
                continue;
            }
            if (c == delim) break;
        }
        if (self.pos >= self.script.len) return null;
        const text = self.script[start..self.pos];
        self.pos += 1;
        return text;
    }

    fn parseDelimited(self: *Parser, delim: u8) ?[]const u8 {
        _ = delim;
        if (self.pos >= self.script.len) return null;
        const dc = self.script[self.pos];
        if (dc == '\\') return null;
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.script.len) : (self.pos += 1) {
            const c = self.script[self.pos];
            if (c == '\\' and self.pos + 1 < self.script.len) {
                self.pos += 1;
                continue;
            }
            if (c == dc) break;
        }
        if (self.pos >= self.script.len) return null;
        const text = self.script[start..self.pos];
        self.pos += 1;
        return text;
    }

    fn parseCommands(self: *Parser, in_block: bool) []Command {
        var list: std.ArrayList(Command) = .empty;
        while (self.pos < self.script.len) {
            self.skipSpace();
            while (self.pos < self.script.len and (self.script[self.pos] == ';' or self.script[self.pos] == '\n')) {
                self.pos += 1;
                self.skipSpace();
            }
            if (self.pos >= self.script.len) break;
            if (in_block and self.script[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            var cmd = Command{ .kind = .print };
            if (self.parseAddr()) |first| {
                cmd.a1 = first;
                if (self.pos < self.script.len and self.script[self.pos] == ',') {
                    self.pos += 1;
                    if (self.parseAddr()) |second| cmd.a2 = second;
                }
            }
            self.skipSpace();
            if (self.pos >= self.script.len) break;
            const ch = self.script[self.pos];
            self.pos += 1;
            switch (ch) {
                'd' => cmd.kind = .delete,
                'p' => cmd.kind = .print,
                's' => {
                    cmd.kind = .substitute;
                    if (self.pos >= self.script.len) break;
                    const delim = self.script[self.pos];
                    const pat = self.parseDelimited(delim) orelse break;
                    const rep = self.parseUntil(delim) orelse break;
                    cmd.pattern = pat;
                    cmd.replacement = rep;
                    while (self.pos < self.script.len) {
                        const f = self.script[self.pos];
                        if (f == 'g') cmd.global = true else if (f == 'i') {
                            cmd.ignore_case = true;
                        } else if (std.ascii.isDigit(f)) {
                            cmd.nth = std.fmt.parseInt(usize, self.script[self.pos .. self.pos + 1], 10) catch 0;
                        } else break;
                        self.pos += 1;
                    }
                    // The substitution body needs its own compiled regex: a1 may be
                    // an address regex; use a fresh copy for the body.
                    const body_re = self.a.create(regex.Regex) catch null;
                    if (body_re) |br| {
                        br.* = regex.compile(self.a, pat, .{ .extended = self.extended, .ignore_case = cmd.ignore_case }) catch regex.Regex{ .prog = .{ .insts = &.{}, .classes = &.{}, .group_count = 0, .flags = .{}, .allocator = self.a }, .max_steps = 0 };
                        cmd.re = br;
                        self.compiled.append(self.a, br) catch {};
                    }
                },
                'y' => {
                    cmd.kind = .translate;
                    if (self.pos >= self.script.len) break;
                    const delim = self.script[self.pos];
                    cmd.from = self.parseDelimited(delim) orelse "";
                    cmd.to = self.parseUntil(delim) orelse "";
                },
                '{' => {
                    cmd.kind = .block;
                    cmd.children = self.parseCommands(true);
                },
                else => {},
            }
            list.append(self.a, cmd) catch {};
        }
        return list.toOwnedSlice(self.a) catch &.{};
    }
};

fn addrMatches(ad: *Addr, line_no: usize, total: usize, line: []const u8, re_for_body: ?*regex.Regex) bool {
    switch (ad.kind) {
        .none => return true,
        .number => return ad.number == line_no,
        .last => return line_no == total,
        .pattern => {},
    }
    const re = ad.re orelse re_for_body orelse return false;
    var matches: [32]regex.Match = undefined;
    return (re.execLongest(line, &matches) catch 0) > 0;
}

fn selected(cmd: *Command, line_no: usize, total: usize, line: []const u8) bool {
    const body_re = if (cmd.kind == .substitute) cmd.re else null;
    if (cmd.a2) |*second| {
        const from = addrMatches(&cmd.a1, line_no, total, line, body_re);
        if (!cmd.a1.active) {
            if (from) {
                cmd.a1.active = true;
                second.active = true;
                return true;
            }
            return false;
        }
        if (second.active) {
            const to = addrMatches(second, line_no, total, line, body_re);
            if (to) {
                second.active = false;
                cmd.a1.active = false;
            }
            return true;
        }
        return addrMatches(&cmd.a1, line_no, total, line, body_re);
    }
    return addrMatches(&cmd.a1, line_no, total, line, body_re);
}

fn expandReplacement(a: std.mem.Allocator, rep: []const u8, line: []const u8, m: []const regex.Match) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        if (rep[i] == '&') {
            if (m.len > 0) try out.appendSlice(a, line[m[0].start..m[0].end]);
            continue;
        }
        if (rep[i] == '\\' and i + 1 < rep.len) {
            const c = rep[i + 1];
            if (c >= '1' and c <= '9') {
                const idx: usize = c - '0';
                if (idx < m.len and m[idx].start <= m[idx].end and m[idx].end <= line.len) {
                    try out.appendSlice(a, line[m[idx].start..m[idx].end]);
                }
                i += 1;
                continue;
            }
            if (c == '&') {
                if (m.len > 0) try out.appendSlice(a, line[m[0].start..m[0].end]);
                i += 1;
                continue;
            }
            try out.append(a, c);
            i += 1;
            continue;
        }
        try out.append(a, rep[i]);
    }
    return out.toOwnedSlice(a);
}

fn findFrom(re: *const regex.Regex, text: []const u8, start: usize, matches: []regex.Match) ?usize {
    var at = start;
    while (at <= text.len) : (at += 1) {
        if (re.execLongestAt(text, at, matches) catch null) |n| {
            if (n > 0) return n;
        }
    }
    return null;
}

fn substitute(a: std.mem.Allocator, current: []const u8, cmd: *Command) ![]u8 {
    const re = cmd.re orelse return a.dupe(u8, current);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    var count: usize = 0;
    while (pos <= current.len) {
        var matches: [32]regex.Match = undefined;
        const n = findFrom(re, current, pos, &matches) orelse break;
        const whole = matches[0];
        try out.appendSlice(a, current[pos..whole.start]);
        count += 1;
        if (cmd.nth == 0 or count >= cmd.nth) {
            const rep = try expandReplacement(a, cmd.replacement, current, matches[0..n]);
            defer a.free(rep);
            try out.appendSlice(a, rep);
        } else {
            try out.appendSlice(a, current[whole.start..whole.end]);
        }
        const was_empty = whole.start == whole.end;
        pos = whole.end;
        if (!cmd.global) break;
        if (was_empty) {
            if (pos < current.len) {
                try out.append(a, current[pos]);
                pos += 1;
            } else break;
        }
    }
    try out.appendSlice(a, current[pos..]);
    return out.toOwnedSlice(a);
}

fn execCommands(a: std.mem.Allocator, cmds: []Command, current_ptr: *[]const u8, line_no: usize, total: usize, quiet: bool, printed: *bool, deleted: *bool, out: *std.ArrayList(u8)) !void {
    for (cmds) |*cmd| {
        if (deleted.*) break;
        if (!selected(cmd, line_no, total, current_ptr.*)) continue;
        switch (cmd.kind) {
            .delete => {
                deleted.* = true;
            },
            .print => {
                printed.* = true;
                if (!quiet) {
                    try out.appendSlice(a, current_ptr.*);
                    try out.append(a, '\n');
                }
            },
            .substitute => {
                const next = try substitute(a, current_ptr.*, cmd);
                current_ptr.* = next;
            },
            .translate => {
                const next = try a.dupe(u8, current_ptr.*);
                for (next) |*c| {
                    if (std.mem.indexOfScalar(u8, cmd.from, c.*)) |idx| {
                        if (idx < cmd.to.len) c.* = cmd.to[idx];
                    }
                }
                current_ptr.* = next;
            },
            .block => {
                try execCommands(a, cmd.children, current_ptr, line_no, total, quiet, printed, deleted, out);
            },
        }
    }
}

pub fn renderSedOptions(a: std.mem.Allocator, data: []const u8, script: []const u8, opts: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var parser = Parser{ .a = aa, .script = script, .extended = opts.extended, .compiled = .empty };
    const cmds = parser.parseCommands(false);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        try lines.append(aa, line);
    }
    var out: std.ArrayList(u8) = .empty;
    for (lines.items, 1..) |original, line_no| {
        var current: []const u8 = original;
        var printed = false;
        var deleted = false;
        try execCommands(aa, cmds, &current, line_no, lines.items.len, opts.quiet, &printed, &deleted, &out);
        if (deleted) continue;
        if (!opts.quiet or printed) {
            try out.appendSlice(aa, current);
            try out.append(aa, '\n');
        }
    }
    return a.dupe(u8, out.items);
}

/// Legacy entry point used by the existing unit tests.
pub fn renderSed(a: std.mem.Allocator, data: []const u8, script: []const u8, quiet: bool) ![]u8 {
    return renderSedOptions(a, data, script, .{ .quiet = quiet });
}
