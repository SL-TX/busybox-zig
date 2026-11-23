//! Recursive-descent shell parser. Builds an AST consumed by exec.zig.

const std = @import("std");
const lx = @import("lexer.zig");

pub const Redir = struct {
    op: lx.RedirOp,
    io: u8,
    target: lx.Word,
    body: ?[]const u8 = null,
    quoted: bool = false,
};

pub const Assignment = struct {
    name: []const u8,
    append: bool = false,
    value: lx.Word,
};

pub const Simple = struct {
    assigns: []Assignment,
    words: []lx.Word,
};

pub const BinaryOp = enum { andand, oror };

pub const Binary = struct {
    op: BinaryOp,
    left: *Node,
    right: *Node,
};

pub const Pipeline = struct {
    negate: bool = false,
    stages: []*Node,
};

pub const IfArm = struct { cond: *Node, body: *Node };
pub const IfStmt = struct { arms: []IfArm, else_body: ?*Node = null };
pub const Loop = struct { cond: *Node, body: *Node };

pub const ForStmt = struct {
    name: []const u8,
    words: []lx.Word,
    body: *Node,
    arith: ?[]const u8 = null,
};

pub const CaseArm = struct { patterns: []lx.Word, body: *Node };
pub const CaseStmt = struct { word: lx.Word, arms: []CaseArm };
pub const FuncDef = struct { name: []const u8, body: *Node };

pub const Body = union(enum) {
    sequence: []*Node,
    simple: Simple,
    and_or: Binary,
    pipeline: Pipeline,
    background: *Node,
    subshell: *Node,
    group: *Node,
    if_stmt: IfStmt,
    while_stmt: Loop,
    until_stmt: Loop,
    for_stmt: ForStmt,
    case_stmt: CaseStmt,
    func_def: FuncDef,
    arith_cmd: []const u8,
    empty,
};

pub const Node = struct {
    redirects: []Redir = &.{},
    body: Body,
    line: usize = 1,
};

pub const ParseError = error{ OutOfMemory, Syntax };

pub const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    toks: []lx.Token,
    i: usize = 0,
    error_detail: ?[]const u8 = null,
    cmd_line: usize = 1,

    pub fn init(a: std.mem.Allocator, src: []const u8, toks: []lx.Token) Parser {
        return .{ .a = a, .src = src, .toks = toks };
    }

    fn cur(self: *const Parser) lx.Token {
        return self.toks[@min(self.i, self.toks.len - 1)];
    }

    fn advance(self: *Parser) lx.Token {
        const t = self.cur();
        if (self.i + 1 < self.toks.len) self.i += 1;
        return t;
    }

    fn check(self: *const Parser, k: lx.TokKind) bool {
        return self.cur().kind == k;
    }

    fn accept(self: *Parser, k: lx.TokKind) bool {
        if (self.check(k)) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn wordIs(t: lx.Token, s: []const u8) bool {
        if (t.kind != .word or t.word == null) return false;
        const segs = t.word.?.segs;
        var total: usize = 0;
        for (segs) |sg| total += sg.text.len;
        if (total != s.len) return false;
        var pos: usize = 0;
        for (segs) |sg| {
            if (sg.kind != .literal or sg.quote != .none) return false;
            if (!std.mem.eql(u8, sg.text, s[pos .. pos + sg.text.len])) return false;
            pos += sg.text.len;
        }
        return true;
    }

    fn isReserved(self: *const Parser, s: []const u8) bool {
        return wordIs(self.cur(), s);
    }

    fn node(self: *Parser, b: Body) ParseError!*Node {
        const n = try self.a.create(Node);
        n.* = .{ .body = b, .line = self.cmd_line };
        return n;
    }

    /// Parse the whole input into a list of top-level commands.
    pub fn parseAll(self: *Parser) ParseError![]*Node {
        const list = try self.parseList(&.{});
        return list;
    }

    fn isTerminator(self: *const Parser, terms: []const []const u8) bool {
        if (self.check(.eof)) return true;
        if (self.check(.rparen) or self.check(.arith_close)) return true;
        for (terms) |t| {
            if (std.mem.eql(u8, t, ";;") and self.check(.dsemi)) return true;
            if (self.isReserved(t)) return true;
        }
        return false;
    }

    /// A list is one or more and-or constructs separated by ; newline or &.
    pub fn parseList(self: *Parser, terms: []const []const u8) ParseError![]*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (!self.isTerminator(terms)) {
            // Skip stray separators.
            if (self.check(.newline) or self.check(.semi)) {
                self.i += 1;
                continue;
            }
            const cmd = try self.parseAndOr();
            if (self.accept(.amp)) {
                const wrapped = try self.node(.{ .background = cmd });
                try items.append(self.a, wrapped);
                continue;
            }
            try items.append(self.a, cmd);
            if (self.check(.semi) or self.check(.newline)) {
                while (self.check(.semi) or self.check(.newline)) self.i += 1;
                continue;
            }
            if (self.check(.eof)) break;
            if (self.isTerminator(terms)) break;
            // Missing separator is a syntax error.
            return error.Syntax;
        }
        return items.toOwnedSlice(self.a);
    }

    fn parseAndOr(self: *Parser) ParseError!*Node {
        var left = try self.parsePipeline();
        while (self.check(.andand) or self.check(.oror)) {
            const op: BinaryOp = if (self.cur().kind == .andand) .andand else .oror;
            self.i += 1;
            while (self.check(.newline)) self.i += 1;
            const right = try self.parsePipeline();
            left = try self.node(.{ .and_or = .{ .op = op, .left = left, .right = right } });
        }
        return left;
    }

    fn parsePipeline(self: *Parser) ParseError!*Node {
        var negate = false;
        while (self.check(.newline)) self.i += 1;
        if (self.isReserved("!")) {
            negate = true;
            self.i += 1;
        }
        var stages: std.ArrayList(*Node) = .empty;
        try stages.append(self.a, try self.parseCommand());
        while (self.check(.pipe)) {
            self.i += 1;
            while (self.check(.newline)) self.i += 1;
            try stages.append(self.a, try self.parseCommand());
        }
        const items = try stages.toOwnedSlice(self.a);
        if (items.len == 1 and !negate) return items[0];
        return self.node(.{ .pipeline = .{ .negate = negate, .stages = items } });
    }

    fn parseCommand(self: *Parser) ParseError!*Node {
        self.cmd_line = self.cur().line;
        while (self.check(.newline)) self.i += 1;

        // Redirections may precede a compound command.
        var prefix_redirs: std.ArrayList(Redir) = .empty;
        while (self.check(.redir)) {
            try prefix_redirs.append(self.a, try self.parseRedir());
        }

        var redirs: std.ArrayList(Redir) = .empty;
        try redirs.appendSlice(self.a, prefix_redirs.items);
        var result: *Node = undefined;
        if (self.isReserved("if")) {
            result = try self.parseIf();
        } else if (self.isReserved("while")) {
            self.i += 1;
            const cond = try self.parseList(&.{"do"});
            try self.expectReserved("do");
            const body = try self.parseList(&.{"done"});
            try self.expectReserved("done");
            result = try self.node(.{ .while_stmt = .{ .cond = try listNode(self.a, cond), .body = try listNode(self.a, body) } });
        } else if (self.isReserved("until")) {
            self.i += 1;
            const cond = try self.parseList(&.{"do"});
            try self.expectReserved("do");
            const body = try self.parseList(&.{"done"});
            try self.expectReserved("done");
            result = try self.node(.{ .until_stmt = .{ .cond = try listNode(self.a, cond), .body = try listNode(self.a, body) } });
        } else if (self.isReserved("for")) {
            result = try self.parseFor();
        } else if (self.isReserved("case")) {
            result = try self.parseCase();
        } else if (self.check(.lparen)) {
            self.i += 1;
            const inner = try self.parseList(&.{});
            try self.expect(.rparen);
            result = try self.node(.{ .subshell = try listNode(self.a, inner) });
        } else if (self.isReserved("{")) {
            self.i += 1;
            const inner = try self.parseList(&.{"}"});
            try self.expectReserved("}");
            result = try self.node(.{ .group = try listNode(self.a, inner) });
        } else if (self.check(.arith_open)) {
            const start = self.cur().pos;
            const end = findArithEnd(self.src, start + 2) orelse return error.Syntax;
            // Advance the token cursor past the inner tokens and the closing )).
            while (self.i < self.toks.len and self.toks[self.i].pos < end + 2) self.i += 1;
            const text = std.mem.trim(u8, self.src[start + 2 .. end], " \t\r\n");
            result = try self.node(.{ .arith_cmd = try self.a.dupe(u8, text) });
        } else if (self.isReserved("function")) {
            self.i += 1;
            const name = self.plainWord();
            if (name.len == 0) return error.Syntax;
            if (self.check(.lparen)) {
                self.i += 1;
                try self.expect(.rparen);
            }
            const body = try self.parseCommand();
            result = try self.node(.{ .func_def = .{ .name = name, .body = body } });
        } else if (self.functionDefAhead()) {
            const name = self.plainWord();
            self.i += 3; // name, (, )
            const body = try self.parseCommand();
            result = try self.node(.{ .func_def = .{ .name = name, .body = body } });
        } else {
            result = try self.parseSimple(&redirs);
        }

        // Redirections may follow a compound command as well.
        while (self.check(.redir)) {
            try redirs.append(self.a, try self.parseRedir());
        }
        if (redirs.items.len != 0) result.redirects = try redirs.toOwnedSlice(self.a);
        return result;
    }

    fn functionDefAhead(self: *const Parser) bool {
        if (self.i + 2 >= self.toks.len) return false;
        if (self.cur().kind != .word) return false;
        const name = self.cur().word.?;
        if (name.segs.len == 0 or name.segs[0].kind != .literal or name.segs[0].quote != .none) return false;
        for (name.segs) |sg| if (sg.kind != .literal or sg.text.len == 0) return false;
        return self.toks[self.i + 1].kind == .lparen and self.toks[self.i + 2].kind == .rparen;
    }

    fn plainWord(self: *const Parser) []const u8 {
        if (self.cur().kind != .word) return "";
        const segs = self.cur().word.?.segs;
        if (segs.len == 0) return "";
        var len: usize = 0;
        for (segs) |sg| len += sg.text.len;
        const out = self.a.alloc(u8, len) catch return "";
        var p: usize = 0;
        for (segs) |sg| {
            @memcpy(out[p .. p + sg.text.len], sg.text);
            p += sg.text.len;
        }
        return out;
    }

    fn expect(self: *Parser, k: lx.TokKind) ParseError!void {
        if (!self.accept(k)) return error.Syntax;
    }

    fn expectReserved(self: *Parser, s: []const u8) ParseError!void {
        if (!self.isReserved(s)) {
            self.error_detail = std.fmt.allocPrint(self.a, "unexpected end of file (expecting \"{s}\")", .{s}) catch null;
            return error.Syntax;
        }
        self.i += 1;
    }

    fn parseIf(self: *Parser) ParseError!*Node {
        self.i += 1; // if
        var arms: std.ArrayList(IfArm) = .empty;
        const cond = try self.parseList(&.{"then"});
        try self.expectReserved("then");
        const body = try self.parseList(&.{ "elif", "else", "fi" });
        try arms.append(self.a, .{
            .cond = try listNode(self.a, cond),
            .body = try listNode(self.a, body),
        });
        var else_body: ?*Node = null;
        while (self.isReserved("elif")) {
            self.i += 1;
            const c = try self.parseList(&.{"then"});
            try self.expectReserved("then");
            const b = try self.parseList(&.{ "elif", "else", "fi" });
            try arms.append(self.a, .{
                .cond = try listNode(self.a, c),
                .body = try listNode(self.a, b),
            });
        }
        if (self.isReserved("else")) {
            self.i += 1;
            const b = try self.parseList(&.{"fi"});
            else_body = try listNode(self.a, b);
        }
        try self.expectReserved("fi");
        return self.node(.{ .if_stmt = .{ .arms = try arms.toOwnedSlice(self.a), .else_body = else_body } });
    }

    fn parseFor(self: *Parser) ParseError!*Node {
        self.i += 1; // for
        if (self.isReserved("((")) {
            // for ((init;cond;inc)) — uncommon; consume tokens up to ))
            while (self.i < self.toks.len and !self.check(.arith_close)) self.i += 1;
            try self.expect(.arith_close);
        }
        const name = self.plainWord();
        if (name.len == 0) return error.Syntax;
        self.i += 1;
        while (self.check(.newline)) self.i += 1;
        var words: std.ArrayList(lx.Word) = .empty;
        if (self.isReserved("in")) {
            self.i += 1;
            while (self.cur().kind == .word and !self.isReserved("do")) {
                try words.append(self.a, self.cur().word.?);
                self.i += 1;
            }
        }
        while (self.check(.semi) or self.check(.newline)) self.i += 1;
        try self.expectReserved("do");
        const body = try self.parseList(&.{"done"});
        try self.expectReserved("done");
        return self.node(.{ .for_stmt = .{
            .name = name,
            .words = try words.toOwnedSlice(self.a),
            .body = try listNode(self.a, body),
        } });
    }

    fn parseCase(self: *Parser) ParseError!*Node {
        self.i += 1;
        if (self.cur().kind != .word) return error.Syntax;
        const subject = self.cur().word.?;
        self.i += 1;
        while (self.check(.newline)) self.i += 1;
        try self.expectReserved("in");
        while (self.check(.newline)) self.i += 1;
        var arms: std.ArrayList(CaseArm) = .empty;
        while (!self.isReserved("esac") and (self.check(.word) or self.check(.lparen))) {
            if (self.accept(.lparen)) {}
            var pats: std.ArrayList(lx.Word) = .empty;
            while (true) {
                try pats.append(self.a, self.cur().word.?);
                self.i += 1;
                if (self.check(.pipe)) {
                    self.i += 1;
                    continue;
                }
                break;
            }
            try self.expect(.rparen);
            const body = try self.parseList(&.{ ";;", "esac" });
            try arms.append(self.a, .{
                .patterns = try pats.toOwnedSlice(self.a),
                .body = try listNode(self.a, body),
            });
            if (self.check(.dsemi)) {
                self.i += 1;
                while (self.check(.newline)) self.i += 1;
            } else if (!self.isReserved("esac")) {
                return error.Syntax;
            }
        }
        try self.expectReserved("esac");
        return self.node(.{ .case_stmt = .{
            .word = subject,
            .arms = try arms.toOwnedSlice(self.a),
        } });
    }

    fn parseRedir(self: *Parser) ParseError!Redir {
        const t = self.cur();
        self.i += 1;
        var io: u8 = switch (t.redir_op) {
            .lt, .dlt, .dltdash, .tlt, .lt_and, .ltgt => 0,
            else => 1,
        };
        if (t.io_number) |n| io = n;
        if (t.redir_op == .amp_gt or t.redir_op == .amp_dgt) io = 0;
        var target: lx.Word = .{ .segs = &.{} };
        if (self.cur().kind == .word) {
            target = self.cur().word.?;
            self.i += 1;
        } else if (t.redir_op == .lt_and or t.redir_op == .gt_and) {
            return error.Syntax;
        }
        return .{
            .op = t.redir_op,
            .io = io,
            .target = target,
            .body = t.heredoc_body,
            .quoted = t.heredoc_quoted,
        };
    }

    fn parseSimple(self: *Parser, redirs: *std.ArrayList(Redir)) ParseError!*Node {
        var assigns: std.ArrayList(Assignment) = .empty;
        var words: std.ArrayList(lx.Word) = .empty;
        var seen_command = false;
        while (true) {
            if (self.check(.redir)) {
                try redirs.append(self.a, try self.parseRedir());
                continue;
            }
            if (self.cur().kind != .word) break;
            if (!seen_command and !self.isReserved("!")) {
                if (assignmentFromWord(self.a, self.cur().word.?)) |asg| {
                    try assigns.append(self.a, asg);
                    self.i += 1;
                    continue;
                }
            }
            seen_command = true;
            try words.append(self.a, self.cur().word.?);
            self.i += 1;
        }
        if (assigns.items.len == 0 and words.items.len == 0 and self.check(.redir)) {
            // redirection-only command; handled by parseCommand's redir loop
        }
        return self.node(.{ .simple = .{
            .assigns = try assigns.toOwnedSlice(self.a),
            .words = try words.toOwnedSlice(self.a),
        } });
    }
};

fn listNode(a: std.mem.Allocator, items: []*Node) ParseError!*Node {
    if (items.len == 1) return items[0];
    const n = try a.create(Node);
    n.* = .{ .body = .{ .sequence = items }, .line = if (items.len != 0) items[0].line else 1 };
    return n;
}

fn findArithEnd(src: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i + 1 < src.len) : (i += 1) {
        if (src[i] == '(') depth += 1;
        if (src[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn assignmentFromWord(a: std.mem.Allocator, w: lx.Word) ?Assignment {
    if (w.segs.len == 0 or w.segs[0].kind != .literal) return null;
    const text = w.segs[0].text;
    var i: usize = 0;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    if (i == 0) return null;
    var append = false;
    if (i < text.len and text[i] == '+') {
        append = true;
        i += 1;
    }
    if (i >= text.len or text[i] != '=') return null;
    const name = text[0 .. i - @as(usize, if (append) 1 else 0)];
    var segs: std.ArrayList(lx.Segment) = .empty;
    const rest = text[i + 1 ..];
    if (rest.len != 0) segs.append(a, .{ .kind = .literal, .quote = w.segs[0].quote, .text = a.dupe(u8, rest) catch return null }) catch return null;
    for (w.segs[1..]) |sg| segs.append(a, sg) catch return null;
    return .{ .name = a.dupe(u8, name) catch return null, .append = append, .value = .{ .segs = segs.toOwnedSlice(a) catch return null } };
}

test "parser builds a pipeline and and-or tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lxr = lx.Lexer.init(a, "a | b && c");
    const toks = try lxr.lex();
    var p = Parser.init(a, "a | b && c", toks);
    const nodes = try p.parseAll();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Body.and_or, std.meta.activeTag(nodes[0].body));
}

test "parser recognizes compound commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "if true; then echo yes; fi";
    var lxr = lx.Lexer.init(a, src);
    const toks = try lxr.lex();
    var p = Parser.init(a, src, toks);
    const nodes = try p.parseAll();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Body.if_stmt, std.meta.activeTag(nodes[0].body));
}
