//! POSIX awk subset used by the `awk` applet: BEGIN/END rules, pattern and
//! expression rules, -F/-v, fields ($N, NF, NR), numeric/string expressions,
//! assignments, print/printf.  Patterns use the Task 21 POSIX regex engine.

const std = @import("std");
const regex = @import("libbb_zig").regex;

pub const Var = struct { name: []const u8, value: []const u8 };
pub const Options = struct {
    fs: []const u8 = " ",
    vars: []const Var = &.{},
};

const Phase = enum { begin, main, end };
const Rule = struct {
    phase: Phase = .main,
    pattern: ?[]const u8 = null,
    regex: bool = false,
    action: []const u8,
};

const Value = union(enum) {
    num: f64,
    str: []const u8,

    fn number(v: Value) f64 {
        return switch (v) {
            .num => |n| n,
            .str => |s| std.fmt.parseFloat(f64, s) catch 0,
        };
    }
    fn text(v: Value, a: std.mem.Allocator) []const u8 {
        return switch (v) {
            .str => |s| s,
            .num => |n| numberText(a, n),
        };
    }
    fn truth(v: Value) bool {
        return switch (v) {
            .num => |n| n != 0,
            .str => |s| s.len != 0 and !std.mem.eql(u8, s, "0"),
        };
    }
};

fn numberText(a: std.mem.Allocator, n: f64) []const u8 {
    if (n == @trunc(n) and std.math.isFinite(n) and @abs(n) < 9.0e15) {
        return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(n))}) catch "0";
    }
    return std.fmt.allocPrint(a, "{d}", .{n}) catch "0";
}

const State = struct {
    a: std.mem.Allocator,
    vars: std.StringHashMap(Value),
    fields: [][]const u8 = &.{},
    line: []const u8 = "",
    nr: usize = 0,
    fs: []const u8 = " ",
    nf: usize = 0,

    fn get(self: *State, name: []const u8) Value {
        if (std.mem.eql(u8, name, "NR")) return .{ .num = @floatFromInt(self.nr) };
        if (std.mem.eql(u8, name, "NF")) return .{ .num = @floatFromInt(self.nf) };
        if (std.mem.eql(u8, name, "FS")) return .{ .str = self.fs };
        if (self.vars.get(name)) |v| return v;
        return .{ .num = 0 };
    }
    fn set(self: *State, name: []const u8, value: Value) void {
        if (std.mem.eql(u8, name, "FS")) {
            self.fs = value.text(self.a);
            return;
        }
        self.vars.put(name, value) catch {};
    }
};

const Expr = struct {
    text: []const u8,
    pos: usize = 0,
    st: *State,

    fn skip(self: *Expr) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }
    fn eat(self: *Expr, ch: u8) bool {
        self.skip();
        if (self.pos < self.text.len and self.text[self.pos] == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn parse(self: *Expr) Value {
        return self.comparison();
    }

    fn comparison(self: *Expr) Value {
        var left = self.additive();
        self.skip();
        const ops = [_][]const u8{ "==", "!=", ">=", "<=", ">", "<" };
        for (ops) |op| {
            if (std.mem.startsWith(u8, self.text[self.pos..], op)) {
                self.pos += op.len;
                const right = self.additive();
                const result = if (op[0] == '=' or (op.len == 2 and op[1] == '='))
                    equal(self.st.a, left, right)
                else if (op[0] == '!')
                    !equal(self.st.a, left, right)
                else if (op[0] == '>')
                    if (op.len == 2) left.number() >= right.number() else left.number() > right.number()
                else
                    if (op.len == 2) left.number() <= right.number() else left.number() < right.number();
                return .{ .num = if (result) 1 else 0 };
            }
        }
        return left;
    }

    fn additive(self: *Expr) Value {
        var left = self.multiplicative();
        while (true) {
            self.skip();
            if (self.pos >= self.text.len) break;
            const ch = self.text[self.pos];
            if (ch != '+' and ch != '-') break;
            self.pos += 1;
            const right = self.multiplicative();
            left = .{ .num = if (ch == '+') left.number() + right.number() else left.number() - right.number() };
        }
        return left;
    }

    fn multiplicative(self: *Expr) Value {
        var left = self.primary();
        while (true) {
            self.skip();
            if (self.pos >= self.text.len) break;
            const ch = self.text[self.pos];
            if (ch != '*' and ch != '/' and ch != '%') break;
            self.pos += 1;
            const right = self.primary();
            const b = right.number();
            left = .{ .num = switch (ch) {
                '*' => left.number() * b,
                '/' => if (b == 0) 0 else left.number() / b,
                '%' => if (b == 0) 0 else @mod(left.number(), b),
                else => 0,
            } };
        }
        return left;
    }

    fn primary(self: *Expr) Value {
        self.skip();
        if (self.pos >= self.text.len) return .{ .num = 0 };
        const c = self.text[self.pos];
        if (c == '$') {
            self.pos += 1;
            if (self.eat('0')) return .{ .str = self.st.line };
            var end = self.pos;
            while (end < self.text.len and std.ascii.isDigit(self.text[end])) end += 1;
            const idx = std.fmt.parseInt(usize, self.text[self.pos..end], 10) catch 0;
            self.pos = end;
            if (idx > 0 and idx <= self.st.fields.len) return .{ .str = self.st.fields[idx - 1] };
            return .{ .str = "" };
        }
        if (c == '(') {
            self.pos += 1;
            const v = self.comparison();
            _ = self.eat(')');
            return v;
        }
        if (c == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.text.len and self.text[self.pos] != '"') {
                if (self.text[self.pos] == '\\' and self.pos + 1 < self.text.len) self.pos += 1;
                self.pos += 1;
            }
            const s = self.text[start..self.pos];
            if (self.pos < self.text.len) self.pos += 1;
            return .{ .str = unescape(self.st.a, s) };
        }
        if (c == '-' or c == '!') {
            self.pos += 1;
            const v = self.primary();
            return if (c == '-') .{ .num = -v.number() } else .{ .num = if (v.truth()) 0 else 1 };
        }
        if (std.ascii.isDigit(c) or c == '.') {
            const start = self.pos;
            while (self.pos < self.text.len and (std.ascii.isDigit(self.text[self.pos]) or self.text[self.pos] == '.')) self.pos += 1;
            return .{ .num = std.fmt.parseFloat(f64, self.text[start..self.pos]) catch 0 };
        }
        var end = self.pos;
        while (end < self.text.len and (std.ascii.isAlphanumeric(self.text[end]) or self.text[end] == '_')) end += 1;
        const name = self.text[self.pos..end];
        self.pos = end;
        return self.st.get(name);
    }
};

fn unescape(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            out.append(a, switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => s[i],
            }) catch {};
        } else out.append(a, s[i]) catch {};
    }
    return out.toOwnedSlice(a) catch s;
}

fn equal(a: std.mem.Allocator, x: Value, y: Value) bool {
    const xt = x.text(a);
    const yt = y.text(a);
    const nx = std.fmt.parseFloat(f64, xt) catch null;
    const ny = std.fmt.parseFloat(f64, yt) catch null;
    if (nx != null and ny != null) return nx.? == ny.?;
    return std.mem.eql(u8, xt, yt);
}

fn splitTop(a: std.mem.Allocator, text: []const u8, sep: u8) [][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var quote = false;
    var paren: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (c == '"') quote = !quote;
        if (!quote) {
            if (c == '(') paren += 1;
            if (c == ')' and paren > 0) paren -= 1;
            if (c == sep and paren == 0) {
                list.append(a, std.mem.trim(u8, text[start..i], " \t")) catch {};
                start = i + 1;
            }
        }
    }
    list.append(a, std.mem.trim(u8, text[start..], " \t")) catch {};
    return list.toOwnedSlice(a) catch &.{};
}

fn parseProgram(a: std.mem.Allocator, program: []const u8) []Rule {
    var rules: std.ArrayList(Rule) = .empty;
    var pos: usize = 0;
    while (pos < program.len) {
        const open = std.mem.indexOfScalarPos(u8, program, pos, '{') orelse break;
        var depth: usize = 1;
        var close = open + 1;
        while (close < program.len and depth > 0) : (close += 1) {
            if (program[close] == '{') depth += 1;
            if (program[close] == '}') depth -= 1;
        }
        if (depth != 0) break;
        close -= 1;
        const prefix = std.mem.trim(u8, program[pos..open], " \t\n\r");
        var rule = Rule{ .action = program[open + 1 .. close] };
        if (std.mem.eql(u8, prefix, "BEGIN")) {
            rule.phase = .begin;
        } else if (std.mem.eql(u8, prefix, "END")) {
            rule.phase = .end;
        } else if (prefix.len >= 2 and prefix[0] == '/' and prefix[prefix.len - 1] == '/') {
            rule.pattern = prefix[1 .. prefix.len - 1];
            rule.regex = true;
        } else if (prefix.len > 0) {
            rule.pattern = prefix;
        }
        rules.append(a, rule) catch {};
        pos = close + 1;
    }
    return rules.toOwnedSlice(a) catch &.{};
}

fn splitFields(a: std.mem.Allocator, line: []const u8, fs: []const u8) [][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (fs.len == 0 or std.mem.eql(u8, fs, " ")) {
        var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
        while (it.next()) |f| list.append(a, f) catch {};
    } else if (fs.len == 1) {
        var it = std.mem.splitScalar(u8, line, fs[0]);
        while (it.next()) |f| list.append(a, f) catch {};
    } else {
        var it = std.mem.splitSequence(u8, line, fs);
        while (it.next()) |f| list.append(a, f) catch {};
    }
    return list.toOwnedSlice(a) catch &.{};
}

fn evalExpr(st: *State, text: []const u8) Value {
    var e = Expr{ .text = text, .st = st };
    return e.parse();
}

fn emitPrint(st: *State, out: *std.ArrayList(u8), args: [][]const u8) void {
    if (args.len == 0 or (args.len == 1 and args[0].len == 0)) {
        out.appendSlice(st.a, st.line) catch {};
        out.append(st.a, '\n') catch {};
        return;
    }
    for (args, 0..) |arg, k| {
        if (k > 0) out.append(st.a, ' ') catch {};
        const v = evalExpr(st, arg);
        out.appendSlice(st.a, v.text(st.a)) catch {};
    }
    out.append(st.a, '\n') catch {};
}

fn emitPrintf(st: *State, out: *std.ArrayList(u8), args: [][]const u8) void {
    if (args.len == 0) return;
    var e = Expr{ .text = args[0], .st = st };
    const fmt_v = e.primary();
    const fmt = fmt_v.text(st.a);
    var i: usize = 0;
    var arg_i: usize = 1;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] == '\\' and i + 1 < fmt.len) {
            i += 1;
            out.append(st.a, switch (fmt[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => fmt[i],
            }) catch {};
            continue;
        }
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            out.append(st.a, fmt[i]) catch {};
            continue;
        }
        i += 1;
        if (fmt[i] == '%') {
            out.append(st.a, '%') catch {};
            continue;
        }
        while (i < fmt.len and (std.ascii.isDigit(fmt[i]) or fmt[i] == '.' or fmt[i] == '-' or fmt[i] == '+')) i += 1;
        if (i >= fmt.len) break;
        const spec = fmt[i];
        const v = if (arg_i < args.len) evalExpr(st, args[arg_i]) else Value{ .num = 0 };
        arg_i += 1;
        switch (spec) {
            'd', 'i' => out.appendSlice(st.a, numberText(st.a, @trunc(v.number()))) catch {},
            's' => out.appendSlice(st.a, v.text(st.a)) catch {},
            'f' => {
                const buf = std.fmt.allocPrint(st.a, "{d:.6}", .{v.number()}) catch "";
                out.appendSlice(st.a, buf) catch {};
            },
            else => out.appendSlice(st.a, v.text(st.a)) catch {},
        }
    }
}

fn runAction(st: *State, out: *std.ArrayList(u8), action: []const u8) void {
    const statements = splitTop(st.a, action, ';');
    for (statements) |raw| {
        const s = std.mem.trim(u8, raw, " \t\n\r");
        if (s.len == 0) continue;
        if (std.mem.startsWith(u8, s, "printf")) {
            emitPrintf(st, out, splitTop(st.a, std.mem.trimStart(u8, s[6..], " \t"), ','));
            continue;
        }
        if (std.mem.startsWith(u8, s, "print")) {
            emitPrint(st, out, splitTop(st.a, std.mem.trimStart(u8, s[5..], " \t"), ','));
            continue;
        }
        const assigns = [_][]const u8{ "+=", "-=", "*=", "/=", "=" };
        var done = false;
        for (assigns) |op| {
            if (std.mem.indexOf(u8, s, op)) |p| {
                const name = std.mem.trim(u8, s[0..p], " \t");
                if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) continue;
                const rhs = evalExpr(st, std.mem.trim(u8, s[p + op.len ..], " \t"));
                if (op.len == 1) {
                    st.set(name, rhs);
                } else {
                    const old = st.get(name).number();
                    st.set(name, .{ .num = switch (op[0]) {
                        '+' => old + rhs.number(),
                        '-' => old - rhs.number(),
                        '*' => old * rhs.number(),
                        '/' => if (rhs.number() == 0) 0 else old / rhs.number(),
                        else => old,
                    } });
                }
                done = true;
                break;
            }
        }
        if (!done) _ = evalExpr(st, s);
    }
}

pub fn renderAwkOptions(a: std.mem.Allocator, data: []const u8, program: []const u8, opts: Options) ![]u8 {
    // All scratch storage lives in an arena: awk allocates freely while
    // evaluating expressions, and the caller only owns the final buffer.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const rules = parseProgram(aa, program);
    var vars = std.StringHashMap(Value).init(aa);
    for (opts.vars) |v| {
        const num = std.fmt.parseFloat(f64, v.value) catch null;
        try vars.put(v.name, if (num) |n| .{ .num = n } else .{ .str = v.value });
    }
    var st = State{ .a = aa, .vars = vars, .fs = opts.fs };
    var out: std.ArrayList(u8) = .empty;

    for (rules) |rule| if (rule.phase == .begin) runAction(&st, &out, rule.action);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        st.nr += 1;
        st.line = line;
        st.fields = splitFields(aa, line, st.fs);
        st.nf = st.fields.len;
        for (rules) |rule| {
            if (rule.phase != .main) continue;
            var selected = true;
            if (rule.pattern) |p| {
                if (rule.regex) {
                    var re = try regex.compile(aa, p, .{});
                    var m: [32]regex.Match = undefined;
                    selected = (re.execLongest(line, &m) catch 0) > 0;
                } else {
                    selected = evalExpr(&st, p).truth();
                }
            }
            if (selected) runAction(&st, &out, rule.action);
        }
    }
    for (rules) |rule| if (rule.phase == .end) runAction(&st, &out, rule.action);
    return a.dupe(u8, out.items);
}

/// Legacy entry point used by the existing unit tests.
pub fn renderAwk(a: std.mem.Allocator, data: []const u8, program: []const u8) ![]u8 {
    return renderAwkOptions(a, data, program, .{});
}
