//! Self-contained expansion primitives: arithmetic evaluation, glob/pattern
//! matching and shell field splitting helpers. The orchestration that ties
//! these to a live shell lives in exec.zig.

const std = @import("std");

pub const ArithError = error{ OutOfMemory, Syntax, DivideByZero, Recursion };

pub const ArithEnv = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
    set: *const fn (ctx: *anyopaque, name: []const u8, value: i64) void,
};

const Arith = struct {
    src: []const u8,
    i: usize = 0,
    env: ArithEnv,
    depth: usize = 0,
    last_ident: ?[]const u8 = null,

    fn skip(self: *Arith) void {
        while (self.i < self.src.len and (self.src[self.i] == ' ' or self.src[self.i] == '\t' or self.src[self.i] == '\n' or self.src[self.i] == '\r')) self.i += 1;
    }

    fn peek(self: *Arith) ?u8 {
        self.skip();
        return if (self.i < self.src.len) self.src[self.i] else null;
    }

    fn eat(self: *Arith, c: u8) bool {
        self.skip();
        if (self.i < self.src.len and self.src[self.i] == c) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn expr(self: *Arith) ArithError!i64 {
        return self.comma();
    }

    fn comma(self: *Arith) ArithError!i64 {
        var v = try self.assign();
        while (self.eat(',')) v = try self.assign();
        return v;
    }

    fn assign(self: *Arith) ArithError!i64 {
        const save = self.i;
        const name = self.identRaw() orelse {
            self.i = save;
            return self.ternary();
        };
        self.skip();
        const ops = [_][]const u8{ "<<=", ">>=", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=", "=" };
        for (ops) |op| {
            if (std.mem.startsWith(u8, self.src[self.i..], op)) {
                self.i += op.len;
                const rhs = try self.assign();
                const old = self.varValue(name);
                const val = if (op.len == 1) rhs else blk: {
                    if (std.mem.eql(u8, op, "+=")) break :blk old +% rhs;
                    if (std.mem.eql(u8, op, "-=")) break :blk old -% rhs;
                    if (std.mem.eql(u8, op, "*=")) break :blk old *% rhs;
                    if (std.mem.eql(u8, op, "/=")) break :blk try div(old, rhs);
                    if (std.mem.eql(u8, op, "%=")) break :blk try mod(old, rhs);
                    if (std.mem.eql(u8, op, "<<=")) break :blk old << @intCast(@as(u6, @truncate(@as(u64, @bitCast(rhs)))));
                    if (std.mem.eql(u8, op, ">>=")) break :blk old >> @intCast(@as(u6, @truncate(@as(u64, @bitCast(rhs)))));
                    if (std.mem.eql(u8, op, "&=")) break :blk old & rhs;
                    if (std.mem.eql(u8, op, "^=")) break :blk old ^ rhs;
                    break :blk old | rhs;
                };
                self.env.set(self.env.ctx, name, val);
                return val;
            }
        }
        self.i = save;
        return self.ternary();
    }

    fn ternary(self: *Arith) ArithError!i64 {
        const cond = try self.lor();
        if (self.eat('?')) {
            const a = try self.comma();
            if (!self.eat(':')) return error.Syntax;
            const b = try self.assign();
            return if (cond != 0) a else b;
        }
        return cond;
    }

    fn lor(self: *Arith) ArithError!i64 {
        var v = try self.land();
        while (self.take("||")) {
            const r = try self.land();
            v = if (v != 0 or r != 0) 1 else 0;
        }
        return v;
    }

    fn land(self: *Arith) ArithError!i64 {
        var v = try self.bitor();
        while (self.take("&&")) {
            const r = try self.bitor();
            v = if (v != 0 and r != 0) 1 else 0;
        }
        return v;
    }

    fn bitor(self: *Arith) ArithError!i64 {
        var v = try self.bitxor();
        while (self.takeSingle('|')) v |= try self.bitxor();
        return v;
    }

    fn bitxor(self: *Arith) ArithError!i64 {
        var v = try self.bitand();
        while (self.takeSingle('^')) v ^= try self.bitand();
        return v;
    }

    fn bitand(self: *Arith) ArithError!i64 {
        var v = try self.equality();
        while (self.takeSingle('&')) v &= try self.equality();
        return v;
    }

    fn equality(self: *Arith) ArithError!i64 {
        var v = try self.relational();
        while (true) {
            if (self.take("==")) {
                v = if (v == try self.relational()) 1 else 0;
            } else if (self.take("!=")) {
                v = if (v != try self.relational()) 1 else 0;
            } else break;
        }
        return v;
    }

    fn relational(self: *Arith) ArithError!i64 {
        var v = try self.shift();
        while (true) {
            if (self.take("<=")) {
                v = if (v <= try self.shift()) 1 else 0;
            } else if (self.take(">=")) {
                v = if (v >= try self.shift()) 1 else 0;
            } else if (self.takeSingle('<')) {
                v = if (v < try self.shift()) 1 else 0;
            } else if (self.takeSingle('>')) {
                v = if (v > try self.shift()) 1 else 0;
            } else break;
        }
        return v;
    }

    fn shift(self: *Arith) ArithError!i64 {
        var v = try self.additive();
        while (true) {
            if (self.take("<<")) {
                const r = try self.additive();
                v = v << @intCast(@as(u6, @truncate(@as(u64, @bitCast(r)))));
            } else if (self.take(">>")) {
                const r = try self.additive();
                v = v >> @intCast(@as(u6, @truncate(@as(u64, @bitCast(r)))));
            } else break;
        }
        return v;
    }

    fn additive(self: *Arith) ArithError!i64 {
        var v = try self.mult();
        while (true) {
            if (self.takeSingle('+')) {
                v +%= try self.mult();
            } else if (self.takeSingle('-')) {
                v -%= try self.mult();
            } else break;
        }
        return v;
    }

    fn mult(self: *Arith) ArithError!i64 {
        var v = try self.power();
        while (true) {
            if (self.takeSingle('*')) {
                v *%= try self.power();
            } else if (self.takeSingle('/')) {
                v = try div(v, try self.power());
            } else if (self.takeSingle('%')) {
                v = try mod(v, try self.power());
            } else break;
        }
        return v;
    }

    fn power(self: *Arith) ArithError!i64 {
        var v = try self.unary();
        if (self.take("**")) {
            const e = try self.power();
            if (e < 0) return 0;
            var result: i64 = 1;
            var b = v;
            var n: u64 = @intCast(e);
            while (n != 0) : (n >>= 1) {
                if (n & 1 != 0) result *%= b;
                b *%= b;
            }
            v = result;
        }
        return v;
    }

    fn unary(self: *Arith) ArithError!i64 {
        if (self.take("++")) {
            const name = self.identRaw() orelse return error.Syntax;
            const v = self.varValue(name) +% 1;
            self.env.set(self.env.ctx, name, v);
            return v;
        }
        if (self.take("--")) {
            const name = self.identRaw() orelse return error.Syntax;
            const v = self.varValue(name) -% 1;
            self.env.set(self.env.ctx, name, v);
            return v;
        }
        if (self.takeSingle('!')) return if (try self.unary() == 0) 1 else 0;
        if (self.takeSingle('~')) return ~try self.unary();
        if (self.takeSingle('+')) return try self.unary();
        if (self.takeSingle('-')) return -% (try self.unary());
        return self.postfix();
    }

    fn postfix(self: *Arith) ArithError!i64 {
        const v = try self.primary();
        if (self.take("++")) {
            const name = self.last_ident orelse return error.Syntax;
            self.env.set(self.env.ctx, name, v +% 1);
        } else if (self.take("--")) {
            const name = self.last_ident orelse return error.Syntax;
            self.env.set(self.env.ctx, name, v -% 1);
        }
        return v;
    }

    fn primary(self: *Arith) ArithError!i64 {
        self.skip();
        self.last_ident = null;
        if (self.eat('(')) {
            const v = try self.comma();
            if (!self.eat(')')) return error.Syntax;
            return v;
        }
        if (self.peek()) |c| {
            if (std.ascii.isDigit(c)) return self.number();
            if (std.ascii.isAlphabetic(c) or c == '_' or c == '$') {
                const name = self.identRaw().?;
                self.last_ident = name;
                return self.varValue(name);
            }
        }
        return error.Syntax;
    }

    fn number(self: *Arith) ArithError!i64 {
        self.skip();
        const start = self.i;
        while (self.i < self.src.len and (std.ascii.isAlphanumeric(self.src[self.i]) or self.src[self.i] == '#')) self.i += 1;
        const tok = self.src[start..self.i];
        if (std.mem.indexOfScalar(u8, tok, '#')) |hash| {
            const base = std.fmt.parseInt(u8, tok[0..hash], 10) catch return error.Syntax;
            if (base < 2 or base > 64) return error.Syntax;
            if (hash + 1 >= tok.len) return error.Syntax;
            var value: i64 = 0;
            for (tok[hash + 1 ..]) |c| {
                const digit: u8 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'z') c - 'a' + 10 else if (c >= 'A' and c <= 'Z') c - 'A' + 10 else if (c == '@') 62 else if (c == '_') 63 else return error.Syntax;
                if (digit >= base) return error.Syntax;
                value = value *% @as(i64, base) +% digit;
            }
            return value;
        }
        var base: u8 = 10;
        var digits = tok;
        if (tok.len > 2 and tok[0] == '0' and (tok[1] == 'x' or tok[1] == 'X')) {
            base = 16;
            digits = tok[2..];
        } else if (tok.len > 1 and tok[0] == '0') {
            base = 8;
            digits = tok[1..];
        }
        return std.fmt.parseInt(i64, digits, base) catch return error.Syntax;
    }

    fn identRaw(self: *Arith) ?[]const u8 {
        self.skip();
        if (self.i >= self.src.len) return null;
        const c = self.src[self.i];
        if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$')) return null;
        const start = self.i;
        self.i += 1;
        while (self.i < self.src.len and (std.ascii.isAlphanumeric(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
        return self.src[start..self.i];
    }

    fn varValue(self: *Arith, name: []const u8) i64 {
        if (self.depth > 16) return 0;
        const text = self.env.get(self.env.ctx, name) orelse return 0;
        if (text.len == 0) return 0;
        self.depth += 1;
        defer self.depth -= 1;
        var sub = Arith{ .src = text, .env = self.env, .depth = self.depth };
        return sub.expr() catch 0;
    }

    fn take(self: *Arith, op: []const u8) bool {
        self.skip();
        if (std.mem.startsWith(u8, self.src[self.i..], op)) {
            self.i += op.len;
            return true;
        }
        return false;
    }

    fn takeSingle(self: *Arith, c: u8) bool {
        self.skip();
        if (self.i < self.src.len and self.src[self.i] == c and
            !(c == '|' and self.i + 1 < self.src.len and self.src[self.i + 1] == '|') and
            !(c == '&' and self.i + 1 < self.src.len and self.src[self.i + 1] == '&') and
            !(c == '<' and self.i + 1 < self.src.len and self.src[self.i + 1] == '<') and
            !(c == '>' and self.i + 1 < self.src.len and self.src[self.i + 1] == '>') and
            !(c == '=' and self.i + 1 < self.src.len and self.src[self.i + 1] == '=') and
            !(c == '!' and self.i + 1 < self.src.len and self.src[self.i + 1] == '=') and
            !(c == '*' and self.i + 1 < self.src.len and self.src[self.i + 1] == '*'))
        {
            self.i += 1;
            return true;
        }
        return false;
    }
};

fn div(a: i64, b: i64) ArithError!i64 {
    if (b == 0) return error.DivideByZero;
    if (a == std.math.minInt(i64) and b == -1) return a;
    return @divTrunc(a, b);
}

fn mod(a: i64, b: i64) ArithError!i64 {
    if (b == 0) return error.DivideByZero;
    if (a == std.math.minInt(i64) and b == -1) return 0;
    return @rem(a, b);
}

pub fn eval(src: []const u8, env: ArithEnv) ArithError!i64 {
    if (std.mem.trim(u8, src, " \t\r\n").len == 0) return 0;
    var a = Arith{ .src = src, .env = env };
    const v = try a.expr();
    a.skip();
    if (a.i != src.len and src.len != 0) return error.Syntax;
    return v;
}

/// fnmatch-style pathname matching with `*`, `?`, `[...]` and backslash escapes.
pub fn pathMatch(pattern: []const u8, name: []const u8) bool {
    return match(pattern, name, true);
}

fn match(pat: []const u8, str: []const u8, slash_sensitive: bool) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pat: ?usize = null;
    var star_str: usize = 0;
    while (si < str.len) {
        if (pi < pat.len) {
            const c = pat[pi];
            if (c == '*') {
                star_pat = pi;
                star_str = si;
                pi += 1;
                continue;
            }
            if (c == '?' and !(slash_sensitive and str[si] == '/')) {
                pi += 1;
                si += 1;
                continue;
            }
            if (c == '[') {
                if (matchClass(pat, &pi, str[si])) {
                    si += 1;
                    continue;
                }
            } else if (c == '\\' and pi + 1 < pat.len) {
                pi += 1;
                if (pat[pi] == str[si]) {
                    pi += 1;
                    si += 1;
                    continue;
                }
            } else if (c == str[si]) {
                pi += 1;
                si += 1;
                continue;
            }
        }
        if (star_pat) |sp| {
            star_str += 1;
            si = star_str;
            if (slash_sensitive and si < str.len and str[si - 1] == '/') return false;
            pi = sp + 1;
            continue;
        }
        return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

fn matchClass(pat: []const u8, pi: *usize, c: u8) bool {
    const start = pi.*;
    var i = start + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    if (i < pat.len and pat[i] == ']') {
        if (c == ']') matched = true;
        i += 1;
    }
    while (i < pat.len and pat[i] != ']') {
        var lo = pat[i];
        if (lo == '\\' and i + 1 < pat.len) {
            i += 1;
            lo = pat[i];
        }
        i += 1;
        if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
            i += 1;
            var hi = pat[i];
            if (hi == '\\' and i + 1 < pat.len) {
                i += 1;
                hi = pat[i];
            }
            i += 1;
            if (c >= lo and c <= hi) matched = true;
        } else if (c == lo) {
            matched = true;
        }
    }
    if (i >= pat.len) {
        // Unclosed '[': treat as a literal bracket.
        pi.* = start;
        return c == '[';
    }
    pi.* = i + 1;
    return if (negate) !matched else matched;
}

/// Match a shell pattern (no pathname slash restrictions) against a string.
pub fn patternMatch(pattern: []const u8, str: []const u8) bool {
    return match(pattern, str, false);
}

const TestCtx = struct {
    vals: *[16]i64,
    fn get(c: *anyopaque, name: []const u8) ?[]const u8 {
        _ = c;
        _ = name;
        return null;
    }
    fn set(c: *anyopaque, name: []const u8, v: i64) void {
        const self: *TestCtx = @ptrCast(@alignCast(c));
        if (name.len == 1 and name[0] >= 'a' and name[0] <= 'p') self.vals[name[0] - 'a'] = v;
    }
};

test "arithmetic evaluator handles precedence and assignments" {
    var store: [16]i64 = std.mem.zeroes([16]i64);
    var ctx = TestCtx{ .vals = &store };
    const env = ArithEnv{ .ctx = &ctx, .get = TestCtx.get, .set = TestCtx.set };
    try std.testing.expectEqual(@as(i64, 11), try eval("3+2*4", env));
    try std.testing.expectEqual(@as(i64, 7), try eval("(3+2)*4-13", env));
    try std.testing.expectEqual(@as(i64, 20), try eval("1 ? 20 : 30", env));
    try std.testing.expectEqual(@as(i64, 255), try eval("0xff", env));
    try std.testing.expectEqual(@as(i64, 10), try eval("16#a", env));
}

test "glob matching" {
    try std.testing.expect(pathMatch("*.txt", "a.txt"));
    try std.testing.expect(!pathMatch("*.txt", "a.txt/b"));
    try std.testing.expect(pathMatch("a[bc]d", "acd"));
    try std.testing.expect(pathMatch("a[!x]d", "abd"));
    try std.testing.expect(!pathMatch("a[!x]d", "ax d"));
}

