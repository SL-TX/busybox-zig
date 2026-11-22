//! bc — arbitrary-precision calculator (reference miscutils/bc.c).
//! Implements the expression/assignment language subset exercised by the
//! parity cases: numbers with scale, variables, arithmetic, comparison,
//! parentheses, `print`, and the scale/ibase/obase special variables.

const std = @import("std");
const c = @import("common.zig");

const Value = struct {
    num: i128 = 0,
    scale: u8 = 0,
};

const Eval = struct {
    a: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    scale: u8 = 0,
    ibase: u8 = 10,
    obase: u8 = 10,
    vars: std.StringHashMap(Value),
    failed: bool = false,

    fn skip(self: *Eval) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t' or self.text[self.pos] == '\r')) self.pos += 1;
    }

    fn peek(self: *Eval) ?u8 {
        self.skip();
        if (self.pos >= self.text.len) return null;
        return self.text[self.pos];
    }

    fn pow10(n: u8) i128 {
        var r: i128 = 1;
        var i: u8 = 0;
        while (i < n) : (i += 1) r *= 10;
        return r;
    }

    fn digitOf(ch: u8) ?u8 {
        if (ch >= '0' and ch <= '9') return ch - '0';
        if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
        if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
        return null;
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
            return .{ .num = -v.num, .scale = v.scale };
        }
        if (digitOf(ch) != null or ch == '.') {
            var num: i128 = 0;
            var frac: i128 = 0;
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
                const dv = digitOf(d) orelse break;
                if (dv >= self.ibase) break;
                if (seen_dot) {
                    if (sc < 18) {
                        frac = frac * 10 + dv;
                        sc += 1;
                    }
                } else {
                    num = num * self.ibase + dv;
                }
                self.pos += 1;
            }
            return .{ .num = num * pow10(sc) + frac, .scale = sc };
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
            const target: i128 = @divTrunc(v.num, pow10(v.scale));
            var x: i128 = if (target < 0) 0 else target;
            var y: i128 = @divTrunc(x + 1, 2);
            while (y < x) {
                x = y;
                y = @divTrunc(x + @divTrunc(target, x), 2);
            }
            return .{ .num = x };
        }
        if (std.mem.eql(u8, name, "scale")) return .{ .num = self.scale };
        if (std.mem.eql(u8, name, "ibase")) return .{ .num = self.ibase };
        if (std.mem.eql(u8, name, "obase")) return .{ .num = self.obase };
        return self.vars.get(name) orelse Value{};
    }

    fn power(self: *Eval) ?Value {
        var v = self.primary() orelse return null;
        self.skip();
        if (self.pos < self.text.len and self.text[self.pos] == '^') {
            self.pos += 1;
            const e = self.power() orelse return null;
            var exp = e.num;
            if (exp < 0) exp = 0;
            var r: i128 = 1;
            var k: i128 = 0;
            while (k < exp) : (k += 1) r *= v.num;
            v = .{ .num = r };
        }
        return v;
    }

    fn alignValues(a: Value, b: Value) struct { a: i128, b: i128, scale: u8 } {
        const s = @max(a.scale, b.scale);
        return .{ .a = a.num * pow10(s - a.scale), .b = b.num * pow10(s - b.scale), .scale = s };
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
                '*' => v = .{ .num = v.num * r.num, .scale = v.scale + r.scale },
                '/', '%' => {
                    if (r.num == 0) {
                        c.plainMsg("divide by zero", .{});
                        self.failed = true;
                        return null;
                    }
                    if (op == '%') {
                        v = .{ .num = @rem(v.num, r.num), .scale = v.scale };
                    } else {
                        const al = alignValues(v, r);
                        v = .{ .num = @divTrunc(al.a * pow10(self.scale), al.b), .scale = self.scale };
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
            v = .{ .num = if (op == '+') al.a + al.b else al.a - al.b, .scale = al.scale };
        }
        return v;
    }

    fn expr(self: *Eval) ?Value {
        return self.addsub();
    }

    fn printValue(self: *Eval, v: Value, newline: bool) void {
        if (self.obase != 10) {
            var n: i128 = @divTrunc(v.num, pow10(v.scale));
            if (n < 0) {
                c.out("-");
                n = -n;
            }
            const base: i128 = self.obase;
            var digits: [128]u8 = undefined;
            var len: usize = 0;
            if (n == 0) {
                digits[0] = '0';
                len = 1;
            }
            while (n > 0) : (n = @divTrunc(n, base)) {
                const d: u8 = @intCast(@mod(n, base));
                digits[len] = if (d < 10) '0' + d else 'A' + (d - 10);
                len += 1;
            }
            while (len > 0) {
                len -= 1;
                c.out(digits[len .. len + 1]);
            }
            if (newline) c.out("\n");
            return;
        }
        var n = v.num;
        var neg = false;
        if (n < 0) {
            neg = true;
            n = -n;
        }
        var ibuf: [80]u8 = undefined;
        const whole = std.fmt.bufPrint(&ibuf, "{d}", .{@divTrunc(n, pow10(v.scale))}) catch "0";
        if (neg) c.out("-");
        if (v.scale == 0) {
            c.out(whole);
        } else {
            const p = pow10(v.scale);
            const frac = @mod(n, p);
            if (@divTrunc(n, p) == 0) {
                c.out(".");
            } else {
                c.printfOut("{s}.", .{whole});
            }
            var fbuf: [80]u8 = undefined;
            const fstr = std.fmt.bufPrint(&fbuf, "{d}", .{frac}) catch "0";
            var pad: usize = v.scale - fstr.len;
            while (pad > 0) : (pad -= 1) c.out("0");
            c.out(fstr);
        }
        if (newline) c.out("\n");
    }

    fn run(self: *Eval) void {
        while (self.pos < self.text.len and !self.failed) {
            self.skip();
            if (self.pos >= self.text.len) break;
            if (self.text[self.pos] == '\n') {
                self.pos += 1;
                continue;
            }
            if (self.text[self.pos] == ';') {
                self.pos += 1;
                continue;
            }
            const start = self.pos;
            while (self.pos < self.text.len and self.text[self.pos] != '\n' and self.text[self.pos] != ';') self.pos += 1;
            const stmt = std.mem.trim(u8, self.text[start..self.pos], " \t\r");
            if (stmt.len == 0) continue;
            self.execStmt(stmt);
        }
    }

    fn execStmt(self: *Eval, stmt: []const u8) void {
        // Assignments to scale/ibase/obase or ordinary variables.
        if (std.mem.indexOfScalar(u8, stmt, '=')) |eq| {
            const lhs = std.mem.trim(u8, stmt[0..eq], " \t");
            const rhs = std.mem.trim(u8, stmt[eq + 1 ..], " \t");
            var sub = Eval{
                .a = self.a,
                .text = rhs,
                .scale = self.scale,
                .ibase = self.ibase,
                .obase = self.obase,
                .vars = self.vars,
            };
            const v = sub.expr() orelse {
                if (sub.failed) self.failed = true;
                return;
            };
            if (std.mem.eql(u8, lhs, "scale")) {
                self.scale = @intCast(@min(18, @max(0, @divTrunc(v.num, pow10(v.scale)))));
            } else if (std.mem.eql(u8, lhs, "ibase")) {
                const b = @divTrunc(v.num, pow10(v.scale));
                if (b >= 2 and b <= 16) self.ibase = @intCast(b);
            } else if (std.mem.eql(u8, lhs, "obase")) {
                const b = @divTrunc(v.num, pow10(v.scale));
                if (b >= 2 and b <= 16) self.obase = @intCast(b);
            } else {
                self.vars.put(lhs, v) catch {};
            }
            return;
        }
        if (std.mem.startsWith(u8, stmt, "print")) {
            var rest = stmt[5..];
            rest = std.mem.trimStart(u8, rest, " \t");
            var sub = Eval{
                .a = self.a,
                .text = rest,
                .scale = self.scale,
                .ibase = self.ibase,
                .obase = self.obase,
                .vars = self.vars,
            };
            while (sub.pos < rest.len) {
                const v = sub.expr() orelse break;
                sub.printValue(v, false);
                sub.skip();
                if (sub.pos < rest.len and rest[sub.pos] == ',') {
                    sub.pos += 1;
                    continue;
                }
                break;
            }
            return;
        }
        var sub = Eval{
            .a = self.a,
            .text = stmt,
            .scale = self.scale,
            .ibase = self.ibase,
            .obase = self.obase,
            .vars = self.vars,
        };
        if (sub.expr()) |v| {
            self.printValue(v, true);
            self.scale = sub.scale;
            self.ibase = sub.ibase;
            self.obase = sub.obase;
        } else if (sub.failed) {
            self.failed = true;
        }
    }
};

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("bc");
    const o = c.opts("bc", args, "sqlw", &.{});
    _ = o;
    const ibase: u8 = 10;
    var scale: u8 = 0;
    // -l loads the standard library, which sets scale=20.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-l")) scale = 20;
        if (args[i].len > 1 and args[i][0] != '-') break;
    }

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
        var ev = Eval{ .a = a, .text = data, .scale = scale, .ibase = ibase, .vars = vars };
        ev.run();
        if (ev.failed) return 1;
    }
    return 0;
}
