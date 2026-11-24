//! Shell lexer. Produces a flat token stream with quote-aware word segments.
//!
//! A word is a list of segments. Each segment records the quoting context it
//! was scanned in, so the expander can decide whether a substitution result
//! is eligible for field splitting and pathname expansion. Backslash-escaped
//! characters are emitted as single-quoted literal segments (no expansion).

const std = @import("std");

pub const Quote = enum { none, single, double };

pub const SegKind = enum { literal, variable, command_sub, arith };

pub const Segment = struct {
    kind: SegKind,
    quote: Quote = .none,
    /// literal: the literal bytes; other kinds: the raw expression body
    text: []const u8,
    /// true for backtick command substitutions (affects nested quote parsing)
    backtick: bool = false,
};

pub const Word = struct {
    segs: []Segment,
};

pub const RedirOp = enum {
    lt,          // <
    gt,          // >
    dgt,         // >>
    dlt,         // <<
    tlt,         // <<<
    dltdash,     // <<-
    lt_and,      // <&
    gt_and,      // >&
    ltgt,        // <>
    gtbar,       // >|
    amp_gt,      // &>
    amp_dgt,     // &>>
};

pub const TokKind = enum {
    word,
    newline,
    semi,
    dsemi,       // ;;
    amp,
    pipe,
    andand,
    oror,
    lparen,
    rparen,
    arith_open,  // ((
    arith_close, // ))
    redir,
    eof,
};

pub const Token = struct {
    kind: TokKind,
    pos: usize = 0,
    line: usize = 1,
    word: ?Word = null,
    redir_op: RedirOp = .lt,
    io_number: ?u8 = null,
    /// Here-document body, captured by the lexer when it consumes the newline
    /// following the redirection operator.
    heredoc_body: ?[]const u8 = null,
    heredoc_quoted: bool = false,
};

pub const LexError = error{ OutOfMemory, UnterminatedQuote, UnterminatedSubstitution };

const PendingDoc = struct {
    token_index: usize,
    delim: []const u8,
    quoted: bool,
    strip_tabs: bool,
};

pub const Lexer = struct {
    a: std.mem.Allocator,
    src: []const u8,
    i: usize = 0,
    line: usize = 1,
    toks: std.ArrayList(Token) = .empty,
    pending: std.ArrayList(PendingDoc) = .empty,

    pub fn init(a: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .a = a, .src = src };
    }

    pub fn lex(self: *Lexer) LexError![]Token {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            switch (c) {
                ' ', '\t', '\r' => self.i += 1,
                '\n' => try self.newline(),
                '#' => self.comment(),
                ';' => {
                    if (self.peek(1) == ';') {
                        try self.push(.{ .kind = .dsemi, .pos = self.i });
                        self.i += 2;
                    } else {
                        try self.push(.{ .kind = .semi, .pos = self.i });
                        self.i += 1;
                    }
                },
                '&' => {
                    if (self.peek(1) == '&') {
                        try self.push(.{ .kind = .andand, .pos = self.i });
                        self.i += 2;
                    } else if (self.peek(1) == '>') {
                        try self.redir(if (self.peek(2) == '>') .amp_dgt else .amp_gt, 3);
                    } else {
                        try self.push(.{ .kind = .amp, .pos = self.i });
                        self.i += 1;
                    }
                },
                '|' => {
                    if (self.peek(1) == '|') {
                        try self.push(.{ .kind = .oror, .pos = self.i });
                        self.i += 2;
                    } else {
                        try self.push(.{ .kind = .pipe, .pos = self.i });
                        self.i += 1;
                    }
                },
                '(' => {
                    if (self.peek(1) == '(') {
                        try self.push(.{ .kind = .arith_open, .pos = self.i });
                        self.i += 2;
                    } else {
                        try self.push(.{ .kind = .lparen, .pos = self.i });
                        self.i += 1;
                    }
                },
                ')' => {
                    if (self.peek(1) == ')') {
                        try self.push(.{ .kind = .arith_close, .pos = self.i });
                        self.i += 2;
                    } else {
                        try self.push(.{ .kind = .rparen, .pos = self.i });
                        self.i += 1;
                    }
                },
                '<' => {
                    if (self.peek(1) == '<') {
                        if (self.peek(2) == '<') {
                            try self.redir(.tlt, 3);
                        } else if (self.peek(2) == '-') {
                            try self.redir(.dltdash, 3);
                        } else {
                            try self.redir(.dlt, 2);
                        }
                    } else if (self.peek(1) == '&') {
                        try self.redir(.lt_and, 2);
                    } else if (self.peek(1) == '>') {
                        try self.redir(.ltgt, 2);
                    } else {
                        try self.redir(.lt, 1);
                    }
                },
                '>' => {
                    if (self.peek(1) == '>') {
                        try self.redir(.dgt, 2);
                    } else if (self.peek(1) == '&') {
                        try self.redir(.gt_and, 2);
                    } else if (self.peek(1) == '|') {
                        try self.redir(.gtbar, 2);
                    } else {
                        try self.redir(.gt, 1);
                    }
                },
                else => {
                    // An IO number (e.g. "2>") is folded into the redirection.
                    if (c >= '0' and c <= '9') {
                        const save = self.i;
                        var n: u8 = 0;
                        while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') {
                            n = n *% 10 +% (self.src[self.i] - '0');
                            self.i += 1;
                        }
                        if (self.i < self.src.len and isRedirStart(self.src[self.i])) {
                            const op_start = self.i;
                            // Re-lex the redirection operator at the current position.
                            const before = self.toks.items.len;
                            try self.redirAt(op_start, n);
                            if (self.toks.items.len > before) continue;
                        }
                        self.i = save;
                    }
                    try self.word();
                },
            }
        }
        try self.push(.{ .kind = .eof, .pos = self.i });
        return self.toks.toOwnedSlice(self.a);
    }

    fn peek(self: *const Lexer, n: usize) u8 {
        return if (self.i + n < self.src.len) self.src[self.i + n] else 0;
    }

    fn push(self: *Lexer, t: Token) LexError!void {
        var tok = t;
        tok.line = self.line;
        try self.toks.append(self.a, tok);
    }

    fn comment(self: *Lexer) void {
        while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
    }

    fn newline(self: *Lexer) LexError!void {
        const start = self.i;
        self.i += 1;
        try self.push(.{ .kind = .newline, .pos = start });
        self.line += 1;
        // Capture any here-document bodies introduced on the line just ended.
        if (self.pending.items.len != 0) {
            const docs = try self.a.dupe(PendingDoc, self.pending.items);
            self.pending.clearRetainingCapacity();
            for (docs) |d| {
                const body = self.readHereDoc(d);
                self.toks.items[d.token_index].heredoc_body = body;
                self.toks.items[d.token_index].heredoc_quoted = d.quoted;
            }
        }
    }

    fn readHereDoc(self: *Lexer, d: PendingDoc) []const u8 {
        var body: std.ArrayList(u8) = .empty;
        while (self.i < self.src.len) {
            const line_start = self.i;
            var end = line_start;
            while (end < self.src.len and self.src[end] != '\n') end += 1;
            var line = self.src[line_start..end];
            if (d.strip_tabs) {
                var k: usize = 0;
                while (k < line.len and line[k] == '\t') k += 1;
                line = line[k..];
            }
            if (std.mem.eql(u8, line, d.delim)) {
                self.i = if (end < self.src.len) end + 1 else end;
                if (end < self.src.len) self.line += 1;
                break;
            }
            body.appendSlice(self.a, line) catch {};
            if (end < self.src.len) {
                body.append(self.a, '\n') catch {};
                self.i = end + 1;
                self.line += 1;
            } else {
                self.i = end;
            }
        }
        return body.toOwnedSlice(self.a) catch "";
    }

    fn isRedirStart(c: u8) bool {
        return c == '<' or c == '>' or c == '&';
    }

    fn redir(self: *Lexer, op: RedirOp, len: usize) LexError!void {
        _ = op;
        _ = len;
        try self.redirAt(self.i, null);
    }

    fn redirAt(self: *Lexer, pos: usize, io: ?u8) LexError!void {
        const start = pos;
        self.i = pos;
        const c = self.src[self.i];
        var op: RedirOp = .lt;
        var len: usize = 1;
        if (c == '<') {
            if (self.peek(1) == '<') {
                if (self.peek(2) == '<') {
                    op = .tlt;
                    len = 3;
                } else if (self.peek(2) == '-') {
                    op = .dltdash;
                    len = 3;
                } else {
                    op = .dlt;
                    len = 2;
                }
            } else if (self.peek(1) == '&') {
                op = .lt_and;
                len = 2;
            } else if (self.peek(1) == '>') {
                op = .ltgt;
                len = 2;
            }
        } else if (c == '>') {
            op = .gt;
            if (self.peek(1) == '>') {
                op = .dgt;
                len = 2;
            } else if (self.peek(1) == '&') {
                op = .gt_and;
                len = 2;
            } else if (self.peek(1) == '|') {
                op = .gtbar;
                len = 2;
            }
        } else if (c == '&') {
            op = if (self.peek(1) == '>') (if (self.peek(2) == '>') .amp_dgt else .amp_gt) else .gt;
            len = if (self.peek(1) == '>') (if (self.peek(2) == '>') @as(usize, 3) else 2) else 1;
        }
        self.i = pos + len;
        const idx = self.toks.items.len;
        try self.push(.{ .kind = .redir, .pos = start, .redir_op = op, .io_number = io });
        if (op == .dlt or op == .dltdash) {
            // The following word (if any) is the delimiter; recorded by word().
            try self.pending.append(self.a, .{
                .token_index = idx,
                .delim = "",
                .quoted = false,
                .strip_tabs = op == .dltdash,
            });
        }
    }

    fn noteHereDocDelim(self: *Lexer, w: Word) void {
        if (self.pending.items.len == 0) return;
        const p = &self.pending.items[self.pending.items.len - 1];
        if (p.delim.len != 0) return;
        var text: std.ArrayList(u8) = .empty;
        var quoted = false;
        for (w.segs) |s| {
            switch (s.kind) {
                .literal => {
                    text.appendSlice(self.a, s.text) catch {};
                    if (s.quote != .none) quoted = true;
                },
                .command_sub => {
                    if (s.backtick) {
                        text.append(self.a, '`') catch {};
                        text.appendSlice(self.a, s.text) catch {};
                        text.append(self.a, '`') catch {};
                    }
                    quoted = true;
                },
                else => quoted = true,
            }
        }
        p.delim = text.toOwnedSlice(self.a) catch "";
        p.quoted = quoted;
    }

    fn word(self: *Lexer) LexError!void {
        const start = self.i;
        var segs: std.ArrayList(Segment) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        var lit_quote: Quote = .none;
        var have_lit = false;

        const flush = struct {
            fn f(l: *Lexer, ls: *std.ArrayList(Segment), lb: *std.ArrayList(u8), q: Quote, h: *bool) LexError!void {
                if (!h.*) return;
                const text = try lb.toOwnedSlice(l.a);
                try ls.append(l.a, .{ .kind = .literal, .quote = q, .text = text });
                h.* = false;
            }
        }.f;

        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0) break;
            if (isOperatorStart(c)) break;
            if (c == '\\') {
                if (self.i + 1 >= self.src.len) {
                    try flush(self, &segs, &lit, lit_quote, &have_lit);
                    try segs.append(self.a, .{ .kind = .literal, .quote = .single, .text = try self.a.dupe(u8, "\\") });
                    self.i += 1;
                    break;
                }
                const n = self.src[self.i + 1];
                if (n == '\n') {
                    // line continuation: drop both bytes
                    self.i += 2;
                    continue;
                }
                try flush(self, &segs, &lit, lit_quote, &have_lit);
                try segs.append(self.a, .{
                    .kind = .literal,
                    .quote = .single,
                    .text = try self.a.dupe(u8, &[_]u8{n}),
                });
                self.i += 2;
                continue;
            }
            if (c == '\'') {
                try flush(self, &segs, &lit, lit_quote, &have_lit);
                self.i += 1;
                const begin = self.i;
                while (self.i < self.src.len and self.src[self.i] != '\'') self.i += 1;
                if (self.i >= self.src.len) return error.UnterminatedQuote;
                try segs.append(self.a, .{
                    .kind = .literal,
                    .quote = .single,
                    .text = try self.a.dupe(u8, self.src[begin..self.i]),
                });
                self.i += 1;
                continue;
            }
            if (c == '"') {
                try flush(self, &segs, &lit, lit_quote, &have_lit);
                try self.doubleQuoted(&segs);
                continue;
            }
            if (c == '$' and self.i + 1 < self.src.len and self.src[self.i + 1] == '\'') {
                try flush(self, &segs, &lit, lit_quote, &have_lit);
                try self.ansiCQuote(&segs);
                continue;
            }
            if (c == '$' and self.i + 1 < self.src.len) {
                try flush(self, &segs, &lit, lit_quote, &have_lit);
                if (try self.dollar(&segs)) continue;
            }
            if (c == '`') {
                try flush(self, &segs, &lit, lit_quote, &have_lit);
                try self.backtick(&segs, .none);
                continue;
            }
            if (lit_quote != .none) lit_quote = .none;
            if (!have_lit) {
                lit_quote = .none;
                have_lit = true;
            }
            try lit.append(self.a, c);
            self.i += 1;
        }
        if (self.i == start) {
            // No progress means we are on an unexpected operator byte.
            self.i += 1;
            return;
        }
        try flush(self, &segs, &lit, lit_quote, &have_lit);
        const w = Word{ .segs = try segs.toOwnedSlice(self.a) };
        try self.push(.{ .kind = .word, .pos = start, .word = w });
        if (self.pending.items.len != 0) self.noteHereDocDelim(w);
    }

    fn isOperatorStart(c: u8) bool {
        return switch (c) {
            ';', '&', '|', '(', ')', '<', '>' => true,
            else => false,
        };
    }

    fn doubleQuoted(self: *Lexer, segs: *std.ArrayList(Segment)) LexError!void {
        self.i += 1; // opening quote
        var lit: std.ArrayList(u8) = .empty;
        const flush = struct {
            fn f(l: *Lexer, s: *std.ArrayList(Segment), b: *std.ArrayList(u8)) LexError!void {
                const text = try b.toOwnedSlice(l.a);
                try s.append(l.a, .{ .kind = .literal, .quote = .double, .text = text });
            }
        }.f;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '"') {
                self.i += 1;
                try flush(self, segs, &lit);
                return;
            }
            if (c == '\\') {
                if (self.i + 1 >= self.src.len) break;
                const n = self.src[self.i + 1];
                if (n == '\n') {
                    self.i += 2;
                    continue;
                }
                if (n == '"' or n == '\\' or n == '$' or n == '`') {
                    try lit.append(self.a, n);
                    self.i += 2;
                    continue;
                }
                try lit.append(self.a, '\\');
                self.i += 1;
                continue;
            }
            if (c == '$') {
                if (self.i + 1 < self.src.len) {
                    try flush(self, segs, &lit);
                    if (try self.dollarSeg(segs, .double)) continue;
                }
            }
            if (c == '`') {
                try flush(self, segs, &lit);
                try self.backtick(segs, .double);
                continue;
            }
            try lit.append(self.a, c);
            self.i += 1;
        }
        return error.UnterminatedQuote;
    }

    fn ansiCQuote(self: *Lexer, segs: *std.ArrayList(Segment)) LexError!void {
        self.i += 2; // $'
        var body: std.ArrayList(u8) = .empty;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\'') {
                self.i += 1;
                try segs.append(self.a, .{
                    .kind = .literal,
                    .quote = .single, // already expanded: no glob/split
                    .text = try body.toOwnedSlice(self.a),
                });
                return;
            }
            if (c != '\\' or self.i + 1 >= self.src.len) {
                try body.append(self.a, c);
                self.i += 1;
                continue;
            }
            self.i += 1;
            const e = self.src[self.i];
            self.i += 1;
            switch (e) {
                'a' => try body.append(self.a, 0x07),
                'b' => try body.append(self.a, 0x08),
                'e', 'E' => try body.append(self.a, 0x1b),
                'f' => try body.append(self.a, 0x0c),
                'n' => try body.append(self.a, '\n'),
                'r' => try body.append(self.a, '\r'),
                't' => try body.append(self.a, '\t'),
                'v' => try body.append(self.a, 0x0b),
                '\\', '\'', '"' => try body.append(self.a, e),
                '0'...'7' => {
                    var value: u32 = e - '0';
                    var count: usize = 1;
                    while (count < 3 and self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '7') {
                        value = value * 8 + (self.src[self.i] - '0');
                        self.i += 1;
                        count += 1;
                    }
                    if (value != 0) try body.append(self.a, @truncate(value));
                },
                'x' => {
                    var value: u32 = 0;
                    var count: usize = 0;
                    while (count < 2 and self.i < self.src.len and std.ascii.isHex(self.src[self.i])) : (count += 1) {
                        const d = std.ascii.toLower(self.src[self.i]);
                        value = value * 16 + (if (d >= 'a') d - 'a' + 10 else d - '0');
                        self.i += 1;
                    }
                    if (value != 0) try body.append(self.a, @truncate(value));
                },
                else => {
                    try body.append(self.a, '\\');
                    try body.append(self.a, e);
                },
            }
        }
        return error.UnterminatedQuote;
    }

    fn dollar(self: *Lexer, segs: *std.ArrayList(Segment)) LexError!bool {
        return self.dollarSeg(segs, .none);
    }

    fn dollarSeg(self: *Lexer, segs: *std.ArrayList(Segment), q: Quote) LexError!bool {
        const c = self.src[self.i + 1];
        if (c == '{') {
            const end = findClose(self.src, self.i + 2, '{', '}') orelse return error.UnterminatedSubstitution;
            try segs.append(self.a, .{
                .kind = .variable,
                .quote = q,
                .text = try self.a.dupe(u8, self.src[self.i + 2 .. end]),
            });
            self.i = end + 1;
            return true;
        }
        if (c == '(') {
            if (self.peek(2) == '(') {
                const end = findArithClose(self.src, self.i + 3) orelse return error.UnterminatedSubstitution;
                try segs.append(self.a, .{
                    .kind = .arith,
                    .quote = q,
                    .text = try self.a.dupe(u8, self.src[self.i + 3 .. end]),
                });
                self.i = end + 2;
                return true;
            }
            const end = findClose(self.src, self.i + 2, '(', ')') orelse return error.UnterminatedSubstitution;
            try segs.append(self.a, .{
                .kind = .command_sub,
                .quote = q,
                .text = try self.a.dupe(u8, self.src[self.i + 2 .. end]),
            });
            self.i = end + 1;
            return true;
        }
        if (isParamStart(c)) {
            var end = self.i + 2;
            if (c >= '0' and c <= '9') {
                // positional parameters are a single digit
            } else {
                while (end < self.src.len and isNameChar(self.src[end])) end += 1;
            }
            try segs.append(self.a, .{
                .kind = .variable,
                .quote = q,
                .text = try self.a.dupe(u8, self.src[self.i + 1 .. end]),
            });
            self.i = end;
            return true;
        }
        return false;
    }

    fn backtick(self: *Lexer, segs: *std.ArrayList(Segment), q: Quote) LexError!void {
        _ = q;
        self.i += 1;
        var body: std.ArrayList(u8) = .empty;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '`') {
                self.i += 1;
                try segs.append(self.a, .{
                    .kind = .command_sub,
                    .quote = .none,
                    .text = try body.toOwnedSlice(self.a),
                    .backtick = true,
                });
                return;
            }
            if (c == '\\') {
                self.i += 1;
                if (self.i >= self.src.len) break;
                const n = self.src[self.i];
                if (n == '$' or n == '`' or n == '\\') {
                    try body.append(self.a, n);
                    self.i += 1;
                    continue;
                }
                try body.append(self.a, '\\');
                continue;
            }
            try body.append(self.a, c);
            self.i += 1;
        }
        return error.UnterminatedSubstitution;
    }

    fn isNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn isParamStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or (c >= '0' and c <= '9') or
            c == '?' or c == '$' or c == '#' or c == '!' or c == '-' or c == '@' or c == '*';
    }
};

/// Find the byte just past the matching close delimiter, tracking nested () and {}.
pub fn findClose(src: []const u8, start: usize, open: u8, close: u8) ?usize {
    var depth: usize = 1;
    var i = start;
    var quote: u8 = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (quote == '\'') {
            if (c == '\'') quote = 0;
            continue;
        }
        if (quote == '"') {
            if (c == '\\' and i + 1 < src.len) {
                i += 1;
                continue;
            }
            if (c == '"') quote = 0;
            continue;
        }
        if (c == '\\' and i + 1 < src.len) {
            i += 1;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Find the byte just past the matching `))` of an arithmetic expansion.
pub fn findArithClose(src: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

test "lexer splits operators and words" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var l = Lexer.init(aa, "echo a >f && (b | c); x=1");
    const toks = try l.lex();
    defer aa.free(toks);
    try std.testing.expectEqual(@as(usize, 13), toks.len);
    try std.testing.expectEqual(TokKind.word, toks[0].kind);
    try std.testing.expectEqual(TokKind.redir, toks[2].kind);
    try std.testing.expectEqual(RedirOp.gt, toks[2].redir_op);
    try std.testing.expectEqual(TokKind.andand, toks[4].kind);
    try std.testing.expectEqual(TokKind.lparen, toks[5].kind);
    try std.testing.expectEqual(TokKind.pipe, toks[7].kind);
}

test "lexer records substitution segments and quote context" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var l = Lexer.init(aa, "echo \"x$HOME\" $(echo hi) 'a b'");
    const toks = try l.lex();
    defer aa.free(toks);
    const w = toks[1].word.?;
    try std.testing.expectEqual(@as(usize, 2), w.segs.len);
    try std.testing.expectEqual(SegKind.literal, w.segs[0].kind);
    try std.testing.expectEqual(SegKind.variable, w.segs[1].kind);
    try std.testing.expectEqual(Quote.double, w.segs[1].quote);
    const w2 = toks[2].word.?;
    try std.testing.expectEqual(SegKind.command_sub, w2.segs[0].kind);
    try std.testing.expectEqualStrings("echo hi", w2.segs[0].text);
}

test "lexer captures here-doc body" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var l = Lexer.init(aa, "cat <<EOF\nhello $X\nEOF\n");
    const toks = try l.lex();
    defer aa.free(toks);
    var found = false;
    for (toks) |t| {
        if (t.kind == .redir and t.redir_op == .dlt) {
            found = true;
            try std.testing.expectEqualStrings("hello $X\n", t.heredoc_body.?);
        }
    }
    try std.testing.expect(found);
}


