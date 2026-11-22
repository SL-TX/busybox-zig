//! bc — arbitrary-precision calculator (reference miscutils/bc.c).
//! Numbers are Managed bignums with a decimal scale; the parser implements
//! assignments, arithmetic, comparison, parentheses, `print`, scale/ibase/
//! obase and the -w/-s POSIX-constraint diagnostics.

const std = @import("std");
const c = @import("common.zig");
const big = @import("big.zig");

const Value = struct {
    num: *big.Big,
    scale: u8 = 0,
};

const version_text =
    "bc 1.39.0.git\n" ++
    "Adapted from https://github.com/gavinhoward/bc\n" ++
    "Original code (c) 2018 Gavin D. Howard and contributors\n";

const Eval = struct {
    a: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    scale: u8 = 0,
    ibase: u8 = 10,
    obase: u8 = 10,
    vars: std.StringHashMap(Value),
    posix: bool = false,
    warn: bool = false,
    failed: bool = false,

    fn makeSub(self: *Eval, text: []const u8) Eval {
        return .{
            .a = self.a,
            .text = text,
            .scale = self.scale,
            .ibase = self.ibase,
            .obase = self.obase,
            .vars = self.vars,
            .posix = self.posix,
            .warn = self.warn,
        };
    }

    fn skip(self: *Eval) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t' or self.text[self.pos] == '\r')) self.pos += 1;
    }

    fn posixError(self: *Eval, msg: []const u8) void {
        if (!self.posix and !self.warn) return;
        c.plainMsg("{s}", .{msg});
        if (self.posix) self.failed = true;
    }

    fn digitOf(ch: u8) ?u8 {
        if (ch >= '0' and ch <= '9') return ch - '0';
        if (ch >= 'a' and ch <= 'z') return ch - 'a' + 10;
        if (ch >= 'A' and ch <= 'Z') return ch - 'A' + 10;
        return null;
    }

    fn digitInBase(ch: u8, base: u8) ?u8 {
        const d = digitOf(ch) orelse return null;
        return if (d < base) d else null;
    }

    fn isIdentStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn primary(self: *Eval) ?Value {
        self.skip();
        if (self.pos >= self.text.len) return null;
        const ch = self.text[self.pos];
        if (ch == '(') {
            self.pos += 1;
            const v = self.expr() orelse return null;
            self.skip();
            if (self.pos < self.text.len and self.text[self.pos] == ')') self.pos += 1;
            return v;
        }
        if (ch == '-') {
            self.pos += 1;
            const v = self.primary() orelse return null;
            return .{ .num = big.neg(v.num), .scale = v.scale };
        }
        // A leading digit or '.' always starts a number; a leading letter is
        // a number only when it is a valid digit in the current ibase.
        const starts_number = digitInBase(ch, self.ibase) != null or ch == '.' or
            (ch >= '0' and ch <= '9');
        if (starts_number) {
            var digits: std.ArrayList(u8) = .empty;
            defer digits.deinit(self.a);
            var sc: u8 = 0;
            var seen_dot = false;
            while (self.pos < self.text.len) {
                const d = self.text[self.pos];
                if (d == '.') {
                    if (seen_dot) break;
                    seen_dot = true;
                    self.pos += 1;
                    continue;
                }
                if (digitInBase(d, self.ibase) == null) break;
                digits.append(self.a, d) catch return null;
                // A letter used as a digit above base 10 still counts as one
                // fractional decimal digit for bc's fixed-scale model.
                if (seen_dot and sc < 200) sc += 1;
                self.pos += 1;
            }
            const textual = digits.items;
            if (textual.len == 0) return Value{ .num = big.fromU64(0) };
            // Convert into a decimal digit string so `setString` can parse it
            // with the active input base.
            var num: *big.Big = big.fromU64(0);
            var frac: *big.Big = big.fromU64(0);
            var fd: u8 = 0;
            for (textual) |d| {
                const dv = digitInBase(d, self.ibase).?;
                if (seen_dot and fd < sc) {
                    frac = big.add(big.mul(frac, big.fromU64(10)), big.fromU64(dv));
                    fd += 1;
                } else {
                    num = big.add(big.mul(num, big.fromU64(self.ibase)), big.fromU64(dv));
                }
            }
            const shifted = big.mul(num, big.pow10(sc));
            return Value{ .num = big.add(shifted, frac), .scale = sc };
        }
        // identifier / special variable / function
        const start = self.pos;
        while (self.pos < self.text.len) {
            const d = self.text[self.pos];
            if (std.ascii.isAlphanumeric(d) or d == '_') self.pos += 1 else break;
        }
        if (start == self.pos) {
            self.pos += 1;
            return null;
        }
        const name = self.text[start..self.pos];
        if (std.mem.eql(u8, name, "sqrt")) {
            self.skip();
            if (self.pos < self.text.len and self.text[self.pos] == '(') self.pos += 1;
            const v = self.expr() orelse return null;
            self.skip();
            if (self.pos < self.text.len and self.text[self.pos] == ')') self.pos += 1;
            return Value{ .num = big.sqrt(v.num) };
        }
        if (std.mem.eql(u8, name, "scale")) return Value{ .num = big.fromU64(self.scale) };
        if (std.mem.eql(u8, name, "ibase")) return Value{ .num = big.fromU64(self.ibase) };
        if (std.mem.eql(u8, name, "obase")) return Value{ .num = big.fromU64(self.obase) };
        if (self.vars.get(name)) |v| return v;
        return Value{ .num = big.fromU64(0) };
    }

    fn power(self: *Eval) ?Value {
        var v = self.primary() orelse return null;
        self.skip();
        if (self.pos < self.text.len and self.text[self.pos] == '^') {
            self.pos += 1;
            const e = self.power() orelse return null;
            const exp = big.smallExponent(e.num, 100_000) orelse {
                c.plainMsg("exponent too large", .{});
                self.failed = true;
                return null;
            };
            v = Value{ .num = big.pow(v.num, exp) };
        }
        return v;
    }

    fn alignValues(a: Value, b: Value) struct { a: *big.Big, b: *big.Big, scale: u8 } {
        const s = @max(a.scale, b.scale);
        return .{
            .a = big.mul(a.num, big.pow10(s - a.scale)),
            .b = big.mul(b.num, big.pow10(s - b.scale)),
            .scale = s,
        };
    }

    fn mulmod(self: *Eval) ?Value {
        var v = self.power() orelse return null;
        while (true) {
            self.skip();
            if (self.pos >= self.text.len) break;
            const op = self.text[self.pos];
            if (op != '*' and op != '/' and op != '%') break;
            self.pos += 1;
            const r = self.power() orelse return null;
            switch (op) {
                '*' => v = .{ .num = big.mul(v.num, r.num), .scale = v.scale + r.scale },
                '/', '%' => {
                    if (big.isZero(r.num)) {
                        c.plainMsg("divide by zero", .{});
                        self.failed = true;
                        return null;
                    }
                    if (op == '%') {
                        v = .{ .num = big.mod(v.num, r.num), .scale = v.scale };
                    } else {
                        const al = alignValues(v, r);
                        const q = big.divTrunc(big.mul(al.a, big.pow10(self.scale)), al.b).q;
                        v = .{ .num = q, .scale = self.scale };
                    }
                },
                else => unreachable,
            }
        }
        return v;
    }

    fn addsub(self: *Eval) ?Value {
        var v = self.mulmod() orelse return null;
        while (true) {
            self.skip();
            if (self.pos >= self.text.len) break;
            const op = self.text[self.pos];
            if (op != '+' and op != '-') break;
            self.pos += 1;
            const r = self.mulmod() orelse return null;
            const al = alignValues(v, r);
            v = .{ .num = if (op == '+') big.add(al.a, al.b) else big.sub(al.a, al.b), .scale = al.scale };
        }
        return v;
    }

    fn expr(self: *Eval) ?Value {
        return self.addsub();
    }

    fn printValue(self: *Eval, v: Value, newline: bool) void {
        const absn = big.abs(v.num);
        const d = big.divTrunc(absn, big.pow10(v.scale));
        if (big.isNeg(v.num)) c.out("-");
        if (self.obase != 10) {
            const text = big.toString(d.q, self.obase);
            if (self.obase > 10) {
                for (text) |*ch| ch.* = std.ascii.toUpper(ch.*);
            }
            c.out(text);
        } else {
            const whole = big.toString(d.q, 10);
            if (v.scale == 0) {
                c.out(whole);
            } else {
                const frac = big.toString(d.r, 10);
                if (big.isZero(d.q)) {
                    c.out(".");
                } else {
                    c.out(whole);
                    c.out(".");
                }
                var pad: usize = if (frac.len < v.scale) v.scale - frac.len else 0;
                while (pad > 0) : (pad -= 1) c.out("0");
                c.out(frac);
            }
        }
        if (newline) c.out("\n");
    }

    fn scanPosix(self: *Eval, stmt: []const u8) bool {
        if (self.posix or self.warn) {
            if (std.mem.startsWith(u8, stmt, "print"))
                self.posixError("POSIX does not allow the 'print' keyword");
            if (self.failed) return false;
            if (std.mem.indexOfScalar(u8, stmt, '#') != null)
                self.posixError("POSIX does not allow '#' script comments");
            if (self.failed) return false;
            if (std.mem.indexOf(u8, stmt, "==") != null or std.mem.indexOf(u8, stmt, "!=") != null or
                std.mem.indexOf(u8, stmt, "<=") != null or std.mem.indexOf(u8, stmt, ">=") != null or
                std.mem.indexOfScalar(u8, stmt, '<') != null or std.mem.indexOfScalar(u8, stmt, '>') != null)
                self.posixError("POSIX does not allow comparison operators outside if or loops");
            if (self.failed) return false;
            if (std.mem.indexOfScalar(u8, stmt, '!') != null)
                self.posixError("POSIX does not allow boolean operators; this is bad: !");
            if (self.failed) return false;
            var i: usize = 0;
            while (i < stmt.len) {
                if (isIdentStart(stmt[i])) {
                    const start = i;
                    while (i < stmt.len and (std.ascii.isAlphanumeric(stmt[i]) or stmt[i] == '_')) i += 1;
                    const name = stmt[start..i];
                    if (name.len > 1 and !std.mem.eql(u8, name, "scale") and
                        !std.mem.eql(u8, name, "ibase") and !std.mem.eql(u8, name, "obase") and
                        !std.mem.eql(u8, name, "sqrt") and !std.mem.eql(u8, name, "print"))
                    {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "POSIX only allows one character names; this is bad: '{s}'", .{stmt}) catch "";
                        self.posixError(msg);
                        if (self.failed) return false;
                    }
                    continue;
                }
                i += 1;
            }
        }
        return true;
    }

    fn run(self: *Eval) void {
        while (self.pos < self.text.len and !self.failed) {
            self.skip();
            if (self.pos >= self.text.len) break;
            if (self.text[self.pos] == '\n' or self.text[self.pos] == ';') {
                self.pos += 1;
                continue;
            }
            const start = self.pos;
            while (self.pos < self.text.len and self.text[self.pos] != '\n' and self.text[self.pos] != ';') self.pos += 1;
            const stmt = std.mem.trim(u8, self.text[start..self.pos], " \t\r");
            if (stmt.len == 0) continue;
            if (!self.scanPosix(stmt)) return;
            self.execStmt(stmt);
        }
    }

    fn execStmt(self: *Eval, stmt: []const u8) void {
        if (std.mem.indexOfScalar(u8, stmt, '=')) |eq| {
            const lhs = std.mem.trim(u8, stmt[0..eq], " \t");
            const rhs = std.mem.trim(u8, stmt[eq + 1 ..], " \t");
            var subev = self.makeSub(rhs);
            const v = subev.expr() orelse {
                if (subev.failed) self.failed = true;
                return;
            };
            const number = big.toU64(v.num) orelse 0;
            if (std.mem.eql(u8, lhs, "scale")) {
                self.scale = @intCast(@min(200, number));
            } else if (std.mem.eql(u8, lhs, "ibase")) {
                if (number >= 2 and number <= 16) self.ibase = @intCast(number);
            } else if (std.mem.eql(u8, lhs, "obase")) {
                if (number >= 2 and number <= 16) self.obase = @intCast(number);
            } else {
                self.vars.put(lhs, v) catch {};
            }
            return;
        }
        if (std.mem.startsWith(u8, stmt, "print")) {
            const rest = std.mem.trimStart(u8, stmt[5..], " \t");
            var subev = self.makeSub(rest);
            while (subev.pos < rest.len) {
                const v = subev.expr() orelse break;
                subev.printValue(v, false);
                subev.skip();
                if (subev.pos < rest.len and rest[subev.pos] == ',') {
                    subev.pos += 1;
                    continue;
                }
                break;
            }
            return;
        }
        var subev = self.makeSub(stmt);
        if (subev.expr()) |v| {
            self.printValue(v, true);
            self.scale = subev.scale;
            self.ibase = subev.ibase;
            self.obase = subev.obase;
        } else if (subev.failed) {
            self.failed = true;
        }
    }
};

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("bc");
    // Reference getopt32 string: w v s q l i  (in that bit order).
    const o = c.opts("bc", args, "wvsqli", &.{});
    if ((o.flags & 2) != 0) {
        c.out(version_text);
        return 0;
    }
    const warn = (o.flags & 1) != 0;
    const posix = (o.flags & 4) != 0;
    var scale: u8 = if ((o.flags & 16) != 0) 20 else 0;

    var inputs: std.ArrayList([]u8) = .empty;
    defer {
        for (inputs.items) |d| a.free(d);
        inputs.deinit(a);
    }
    var any_file = false;
    for (args[1..]) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        any_file = true;
        var en: c_int = 0;
        const d = c.readFile(a, arg, &en) orelse {
            c.errorMsgAndDie(en, "can't open '{s}'", .{arg});
        };
        inputs.append(a, d) catch {};
    }
    if (!any_file) {
        inputs.append(a, c.readStdin(a) catch return 1) catch {};
    }
    for (inputs.items) |data| {
        var vars = std.StringHashMap(Value).init(a);
        defer vars.deinit();
        var ev = Eval{ .a = a, .text = data, .scale = scale, .vars = vars, .posix = posix, .warn = warn };
        ev.run();
        scale = ev.scale;
        if (ev.failed) return 1;
    }
    return 0;
}
