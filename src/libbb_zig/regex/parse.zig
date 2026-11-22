//! POSIX BRE/ERE parser and compiler. Produces a small backtracking bytecode
//! consumed by exec.zig. Pure Zig: no libc, no C code, no external regex lib.

const std = @import("std");

pub const Flags = struct {
    extended: bool = false,
    ignore_case: bool = false,
    newline: bool = false,
};

pub const ClassRange = struct { lo: u8, hi: u8 };
pub const CharClass = struct {
    negated: bool,
    ranges: []const ClassRange,
};

pub const Inst = union(enum) {
    char: u8,
    any,
    class: u32,
    bol,
    eol,
    save: u8,
    backref: u8,
    split: struct { x: u32, y: u32 },
    jmp: u32,
    loop_enter: u8,
    loop_check: struct { marker: u8, no_progress: u32 },
    match,
};

pub const Program = struct {
    insts: []Inst,
    classes: []CharClass,
    group_count: u8,
    flags: Flags,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Program) void {
        for (self.classes) |c| self.allocator.free(c.ranges);
        self.allocator.free(self.classes);
        self.allocator.free(self.insts);
    }
};

pub const ParseError = error{
    InvalidPattern,
    UnmatchedParen,
    InvalidClass,
    PatternTooLarge,
    TooManyGroups,
    OutOfMemory,
};

/// Bounds parser/compiler recursion for hostile or random patterns. Well below
/// the native stack limit, but high enough for ordinary nested expressions.
const MAX_DEPTH: usize = 256;
/// Cap the emitted program size so nested bounded repeats cannot blow up memory.
const MAX_INSTS: usize = 65_536;

const NodeIdx = u32;
const Node = union(enum) {
    empty,
    literal: u8,
    any,
    class: u32,
    bol,
    eol,
    concat: []const NodeIdx,
    alt: []const NodeIdx,
    repeat: struct { child: NodeIdx, min: u16, max: ?u16 },
    group: struct { index: u8, child: NodeIdx },
    backref: u8,
};

const Parser = struct {
    a: std.mem.Allocator,
    pat: []const u8,
    pos: usize = 0,
    flags: Flags,
    nodes: std.ArrayList(Node) = .empty,
    classes: std.ArrayList(CharClass) = .empty,
    group_count: u8 = 0,
    closed_groups: u32 = 0,
    depth: usize = 0,

    fn newNode(self: *Parser, node: Node) ParseError!NodeIdx {
        try self.nodes.append(self.a, node);
        return @intCast(self.nodes.items.len - 1);
    }

    fn enterDepth(self: *Parser) ParseError!void {
        self.depth += 1;
        if (self.depth > MAX_DEPTH) return error.PatternTooLarge;
    }

    fn leaveDepth(self: *Parser) void {
        self.depth -= 1;
    }

    /// POSIX numbers groups in the order their opening parenthesis is seen
    /// (pre-order), which is what backreferences and captures must use.
    fn openGroup(self: *Parser) ParseError!u8 {
        if (self.group_count >= 16) return error.TooManyGroups;
        self.group_count += 1;
        return self.group_count;
    }

    fn closeGroup(self: *Parser, index: u8) void {
        self.closed_groups |= @as(u32, 1) << @intCast(index - 1);
    }

    fn noteBackref(self: *Parser, n: u8) ParseError!void {
        // Forward references, self references and references past the last
        // group are invalid in both BRE and ERE; reject them instead of
        // silently matching empty (matches reference regexec behaviour).
        if (n == 0 or n > 16) return error.InvalidPattern;
        if ((self.closed_groups & (@as(u32, 1) << @intCast(n - 1))) == 0) return error.InvalidPattern;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.pat.len) return null;
        return self.pat[self.pos];
    }

    fn isAlt(self: *Parser) bool {
        if (self.flags.extended) return self.peek() == '|';
        return self.peek() == '\\' and self.pos + 1 < self.pat.len and self.pat[self.pos + 1] == '|';
    }

    fn isClose(self: *Parser) bool {
        if (self.flags.extended) return self.peek() == ')';
        return self.peek() == '\\' and self.pos + 1 < self.pat.len and self.pat[self.pos + 1] == ')';
    }

    fn parse(self: *Parser) ParseError!NodeIdx {
        const root = try self.parseAlt();
        if (self.pos != self.pat.len) return error.InvalidPattern;
        return root;
    }

    fn parseAlt(self: *Parser) ParseError!NodeIdx {
        var branches: std.ArrayList(NodeIdx) = .empty;
        defer branches.deinit(self.a);
        try branches.append(self.a, try self.parseConcat());
        while (self.isAlt()) {
            self.pos += if (self.flags.extended) 1 else 2;
            try branches.append(self.a, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.newNode(.{ .alt = try self.a.dupe(NodeIdx, branches.items) });
    }

    fn parseConcat(self: *Parser) ParseError!NodeIdx {
        var items: std.ArrayList(NodeIdx) = .empty;
        defer items.deinit(self.a);
        while (self.pos < self.pat.len and !self.isAlt() and !self.isClose()) {
            try items.append(self.a, try self.parseRepeat());
        }
        if (items.items.len == 0) return self.newNode(.empty);
        if (items.items.len == 1) return items.items[0];
        return self.newNode(.{ .concat = try self.a.dupe(NodeIdx, items.items) });
    }

    fn parseInterval(self: *Parser) ParseError!?struct { min: u16, max: ?u16 } {
        const start = self.pos;
        if (!self.flags.extended) {
            if (self.pos + 1 >= self.pat.len or self.pat[self.pos] != '\\' or self.pat[self.pos + 1] != '{') return null;
            self.pos += 2;
        } else {
            if (self.peek() != '{') return null;
            self.pos += 1;
        }
        const min_start = self.pos;
        while (self.pos < self.pat.len and std.ascii.isDigit(self.pat[self.pos])) self.pos += 1;
        if (self.pos == min_start) {
            self.pos = start;
            return null;
        }
        const min = std.fmt.parseInt(u16, self.pat[min_start..self.pos], 10) catch return error.PatternTooLarge;
        var max: ?u16 = min;
        if (self.pos < self.pat.len and self.pat[self.pos] == ',') {
            self.pos += 1;
            const max_start = self.pos;
            while (self.pos < self.pat.len and std.ascii.isDigit(self.pat[self.pos])) self.pos += 1;
            max = if (self.pos == max_start) null else std.fmt.parseInt(u16, self.pat[max_start..self.pos], 10) catch return error.PatternTooLarge;
        }
        if (self.flags.extended) {
            if (self.pos >= self.pat.len or self.pat[self.pos] != '}') return error.InvalidPattern;
            self.pos += 1;
        } else {
            if (self.pos + 1 >= self.pat.len or self.pat[self.pos] != '\\' or self.pat[self.pos + 1] != '}') return error.InvalidPattern;
            self.pos += 2;
        }
        if (min > 1000 or (max != null and max.? > 1000)) return error.PatternTooLarge;
        if (max != null and min > max.?) return error.InvalidPattern;
        return .{ .min = min, .max = max };
    }

    fn parseRepeat(self: *Parser) ParseError!NodeIdx {
        try self.enterDepth();
        defer self.leaveDepth();
        var atom = try self.parseAtom();
        while (true) {
            const c = self.peek() orelse break;
            if (c == '*') {
                self.pos += 1;
                atom = try self.newNode(.{ .repeat = .{ .child = atom, .min = 0, .max = null } });
                continue;
            }
            if (self.flags.extended and c == '+') {
                self.pos += 1;
                atom = try self.newNode(.{ .repeat = .{ .child = atom, .min = 1, .max = null } });
                continue;
            }
            if (self.flags.extended and c == '?') {
                self.pos += 1;
                atom = try self.newNode(.{ .repeat = .{ .child = atom, .min = 0, .max = 1 } });
                continue;
            }
            // GNU BRE extensions: \+ and \?
            if (!self.flags.extended and c == '\\' and self.pos + 1 < self.pat.len) {
                const n = self.pat[self.pos + 1];
                if (n == '+' or n == '?') {
                    self.pos += 2;
                    atom = try self.newNode(.{ .repeat = .{ .child = atom, .min = if (n == '+') 1 else 0, .max = if (n == '+') null else 1 } });
                    continue;
                }
            }
            if (try self.parseInterval()) |iv| {
                atom = try self.newNode(.{ .repeat = .{ .child = atom, .min = iv.min, .max = iv.max } });
                continue;
            }
            break;
        }
        return atom;
    }

    fn parseAtom(self: *Parser) ParseError!NodeIdx {
        const c = self.peek() orelse return self.newNode(.empty);
        if (c == '(' and self.flags.extended) {
            self.pos += 1;
            const index = try self.openGroup();
            try self.enterDepth();
            defer self.leaveDepth();
            const child = try self.parseAlt();
            if (!self.isClose()) return error.UnmatchedParen;
            self.pos += 1;
            self.closeGroup(index);
            return self.newNode(.{ .group = .{ .index = index, .child = child } });
        }
        if (c == '\\') {
            if (self.pos + 1 >= self.pat.len) return error.InvalidPattern;
            const n = self.pat[self.pos + 1];
            if (!self.flags.extended) {
                if (n == '(') {
                    self.pos += 2;
                    const index = try self.openGroup();
                    try self.enterDepth();
                    defer self.leaveDepth();
                    const child = try self.parseAlt();
                    if (!self.isClose()) return error.UnmatchedParen;
                    self.pos += 2;
                    self.closeGroup(index);
                    return self.newNode(.{ .group = .{ .index = index, .child = child } });
                }
                if (n >= '1' and n <= '9') {
                    self.pos += 2;
                    try self.noteBackref(n - '0');
                    return self.newNode(.{ .backref = n - '0' });
                }
            } else {
                if (n >= '1' and n <= '9') {
                    self.pos += 2;
                    try self.noteBackref(n - '0');
                    return self.newNode(.{ .backref = n - '0' });
                }
            }
            self.pos += 2;
            return self.newNode(.{ .literal = n });
        }
        self.pos += 1;
        return switch (c) {
            '.' => self.newNode(.any),
            '^' => self.newNode(.bol),
            '$' => self.newNode(.eol),
            '[' => self.parseClass(),
            else => self.newNode(.{ .literal = c }),
        };
    }

    fn addNamedClass(self: *Parser, name: []const u8, ranges: *std.ArrayList(ClassRange)) ParseError!bool {
        const defs = [_]struct { name: []const u8, ranges: []const ClassRange }{
            .{ .name = "alpha", .ranges = &.{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' } } },
            .{ .name = "digit", .ranges = &.{.{ .lo = '0', .hi = '9' }} },
            .{ .name = "alnum", .ranges = &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' } } },
            .{ .name = "upper", .ranges = &.{.{ .lo = 'A', .hi = 'Z' }} },
            .{ .name = "lower", .ranges = &.{.{ .lo = 'a', .hi = 'z' }} },
            .{ .name = "space", .ranges = &.{ .{ .lo = 9, .hi = 13 }, .{ .lo = ' ', .hi = ' ' } } },
            .{ .name = "blank", .ranges = &.{ .{ .lo = 9, .hi = 9 }, .{ .lo = ' ', .hi = ' ' } } },
            .{ .name = "xdigit", .ranges = &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'F' }, .{ .lo = 'a', .hi = 'f' } } },
            .{ .name = "cntrl", .ranges = &.{ .{ .lo = 0, .hi = 31 }, .{ .lo = 127, .hi = 127 } } },
            .{ .name = "print", .ranges = &.{.{ .lo = 32, .hi = 126 }} },
            .{ .name = "graph", .ranges = &.{.{ .lo = 33, .hi = 126 }} },
            .{ .name = "punct", .ranges = &.{ .{ .lo = 33, .hi = 47 }, .{ .lo = 58, .hi = 64 }, .{ .lo = 91, .hi = 96 }, .{ .lo = 123, .hi = 126 } } },
        };
        for (defs) |d| {
            if (std.mem.eql(u8, d.name, name)) {
                try ranges.appendSlice(self.a, d.ranges);
                return true;
            }
        }
        return false;
    }

    fn readClassChar(self: *Parser) u8 {
        const c = self.pat[self.pos];
        self.pos += 1;
        if (c == '\\' and self.pos < self.pat.len) {
            const n = self.pat[self.pos];
            self.pos += 1;
            return switch (n) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => n,
            };
        }
        return c;
    }

    fn parseClass(self: *Parser) ParseError!NodeIdx {
        // self.pos points just after '['
        var negated = false;
        if (self.pos < self.pat.len and self.pat[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }
        var ranges: std.ArrayList(ClassRange) = .empty;
        errdefer ranges.deinit(self.a);
        var first = true;
        var closed = false;
        while (self.pos < self.pat.len) {
            if (self.pat[self.pos] == ']' and !first) {
                self.pos += 1;
                closed = true;
                break;
            }
            first = false;
            // POSIX named class [:name:]
            if (self.pos + 1 < self.pat.len and self.pat[self.pos] == '[' and self.pat[self.pos + 1] == ':') {
                const name_start = self.pos + 2;
                if (std.mem.indexOfPos(u8, self.pat, name_start, ":]")) |name_end| {
                    const name = self.pat[name_start..name_end];
                    if (try self.addNamedClass(name, &ranges)) {
                        self.pos = name_end + 2;
                        continue;
                    }
                }
            }
            const lo = self.readClassChar();
            if (self.pos + 1 < self.pat.len and self.pat[self.pos] == '-' and self.pat[self.pos + 1] != ']') {
                self.pos += 1;
                const hi = self.readClassChar();
                if (lo > hi) return error.InvalidClass;
                try ranges.append(self.a, .{ .lo = lo, .hi = hi });
            } else {
                try ranges.append(self.a, .{ .lo = lo, .hi = lo });
            }
        }
        // An unclosed '[' consumed the rest of the pattern: reject it instead
        // of silently compiling a class that swallows trailing literals.
        if (!closed or ranges.items.len == 0) return error.InvalidClass;
        try self.classes.append(self.a, .{ .negated = negated, .ranges = try ranges.toOwnedSlice(self.a) });
        return self.newNode(.{ .class = @intCast(self.classes.items.len - 1) });
    }
};

const Compiler = struct {
    a: std.mem.Allocator,
    insts: std.ArrayList(Inst) = .empty,
    loop_slots: usize = 0,

    fn emit(self: *Compiler, inst: Inst) ParseError!u32 {
        if (self.insts.items.len >= MAX_INSTS) return error.PatternTooLarge;
        try self.insts.append(self.a, inst);
        return @intCast(self.insts.items.len - 1);
    }

    fn compileNode(self: *Compiler, nodes: []const Node, idx: NodeIdx) ParseError!void {
        switch (nodes[idx]) {
            .empty => {},
            .literal => |c| _ = try self.emit(.{ .char = c }),
            .any => _ = try self.emit(.any),
            .class => |c| _ = try self.emit(.{ .class = c }),
            .bol => _ = try self.emit(.bol),
            .eol => _ = try self.emit(.eol),
            .backref => |n| _ = try self.emit(.{ .backref = n }),
            .group => |g| {
                _ = try self.emit(.{ .save = 2 * g.index });
                try self.compileNode(nodes, g.child);
                _ = try self.emit(.{ .save = 2 * g.index + 1 });
            },
            .concat => |items| for (items) |child| try self.compileNode(nodes, child),
            .alt => |branches| try self.compileAlt(nodes, branches),
            .repeat => |rep| try self.compileRepeat(nodes, rep),
        }
    }

    fn compileAlt(self: *Compiler, nodes: []const Node, branches: []const NodeIdx) ParseError!void {
        if (branches.len == 1) {
            try self.compileNode(nodes, branches[0]);
            return;
        }
        const sp = try self.emit(.{ .split = .{ .x = 0, .y = 0 } });
        self.insts.items[sp].split.x = @intCast(self.insts.items.len);
        try self.compileNode(nodes, branches[0]);
        const j = try self.emit(.{ .jmp = 0 });
        self.insts.items[sp].split.y = @intCast(self.insts.items.len);
        try self.compileAlt(nodes, branches[1..]);
        self.insts.items[j].jmp = @intCast(self.insts.items.len);
    }

    fn compileRepeat(self: *Compiler, nodes: []const Node, rep: anytype) ParseError!void {
        var m: usize = rep.min;
        while (m > 0) : (m -= 1) try self.compileNode(nodes, rep.child);
        if (rep.max) |max| {
            var extra: usize = max - rep.min;
            while (extra > 0) : (extra -= 1) {
                const sp = try self.emit(.{ .split = .{ .x = 0, .y = 0 } });
                self.insts.items[sp].split.x = @intCast(self.insts.items.len);
                try self.compileNode(nodes, rep.child);
                self.insts.items[sp].split.y = @intCast(self.insts.items.len);
            }
        } else {
            if (self.loop_slots >= 32) return error.PatternTooLarge;
            const slot: u8 = @intCast(self.loop_slots);
            self.loop_slots += 1;
            const sp = try self.emit(.{ .split = .{ .x = 0, .y = 0 } });
            self.insts.items[sp].split.x = @intCast(self.insts.items.len);
            _ = try self.emit(.{ .loop_enter = slot });
            try self.compileNode(nodes, rep.child);
            const check = try self.emit(.{ .loop_check = .{ .marker = slot, .no_progress = 0 } });
            _ = try self.emit(.{ .jmp = sp });
            const after: u32 = @intCast(self.insts.items.len);
            self.insts.items[sp].split.y = after;
            self.insts.items[check].loop_check.no_progress = after;
        }
    }
};

pub fn compile(a: std.mem.Allocator, pattern: []const u8, flags: Flags) ParseError!Program {
    var parser = Parser{ .a = a, .pat = pattern, .flags = flags };
    defer {
        // The AST is temporary: free every owned slice plus the two lists.
        // On success `classes` has been moved out and the list is empty.
        for (parser.nodes.items) |node| {
            switch (node) {
                .concat => |s| a.free(s),
                .alt => |s| a.free(s),
                else => {},
            }
        }
        parser.nodes.deinit(a);
        for (parser.classes.items) |c| a.free(c.ranges);
        parser.classes.deinit(a);
    }
    const root = try parser.parse();

    var compiler = Compiler{ .a = a };
    errdefer compiler.insts.deinit(a);
    _ = try compiler.emit(.{ .save = 0 });
    try compiler.compileNode(parser.nodes.items, root);
    _ = try compiler.emit(.{ .save = 1 });
    _ = try compiler.emit(.match);

    const classes = try parser.classes.toOwnedSlice(a);
    errdefer {
        for (classes) |c| a.free(c.ranges);
        a.free(classes);
    }
    return .{
        .insts = try compiler.insts.toOwnedSlice(a),
        .classes = classes,
        .group_count = parser.group_count,
        .flags = flags,
        .allocator = a,
    };
}
