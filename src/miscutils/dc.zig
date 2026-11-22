//! dc — reverse-Polish calculator (reference bc.c FEATURE_DC_BIG flavour).
//! Numbers carry their own decimal scale; division obeys the global `k` scale.

const std = @import("std");
const c = @import("common.zig");

const Value = struct {
    num: i128 = 0,
    scale: u8 = 0,
};

const Dc = struct {
    stack: [8192]Value = undefined,
    depth: usize = 0,
    scale: u8 = 0,
    obase: u8 = 10,
    ibase: u8 = 10,
    failed: bool = false,

    fn push(self: *Dc, v: Value) void {
        if (self.depth >= self.stack.len) {
            c.plainMsg("stack overflow", .{});
            self.failed = true;
            return;
        }
        self.stack[self.depth] = v;
        self.depth += 1;
    }

    fn pop(self: *Dc) ?Value {
        if (self.depth == 0) {
            c.plainMsg("stack has too few elements", .{});
            self.failed = true;
            return null;
        }
        self.depth -= 1;
        return self.stack[self.depth];
    }

    fn pow10(n: u8) i128 {
        var r: i128 = 1;
        var i: u8 = 0;
        while (i < n) : (i += 1) r *= 10;
        return r;
    }

    fn alignValues(a: Value, b: Value) struct { a: i128, b: i128, scale: u8 } {
        const s = @max(a.scale, b.scale);
        return .{
            .a = a.num * pow10(s - a.scale),
            .b = b.num * pow10(s - b.scale),
            .scale = s,
        };
    }

    fn printValue(self: *Dc, v: Value) void {
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
            c.out("\n");
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
            c.printfOut("{s}\n", .{whole});
            return;
        }
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
        c.out("\n");
    }

    fn execute(self: *Dc, input: []const u8) void {
        var i: usize = 0;
        while (i < input.len and !self.failed) {
            const ch = input[i];
            if (ch >= '0' and ch <= '9') {
                var j = i;
                while (j < input.len and ((input[j] >= '0' and input[j] <= '9') or (self.ibase == 16 and input[j] >= 'a' and input[j] <= 'f'))) : (j += 1) {}
                const txt = input[i..j];
                var val: i128 = 0;
                for (txt) |d| {
                    const digit: i128 = if (d >= '0' and d <= '9') d - '0' else d - 'a' + 10;
                    val = val * self.ibase + digit;
                }
                self.push(.{ .num = val });
                i = j;
                continue;
            }
            if (ch == '_') {
                i += 1;
                var val: i128 = 0;
                while (i < input.len and input[i] >= '0' and input[i] <= '9') : (i += 1) {
                    val = val * 10 + (input[i] - '0');
                }
                self.push(.{ .num = -val });
                continue;
            }
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                i += 1;
                continue;
            }
            i += 1;
            switch (ch) {
                '+' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    const r = alignValues(aa, b);
                    self.push(.{ .num = r.a + r.b, .scale = r.scale });
                },
                '-' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    const r = alignValues(aa, b);
                    self.push(.{ .num = r.a - r.b, .scale = r.scale });
                },
                '*' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    self.push(.{ .num = aa.num * b.num, .scale = aa.scale + b.scale });
                },
                '/' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    if (b.num == 0) {
                        c.plainMsg("divide by zero", .{});
                        self.failed = true;
                        return;
                    }
                    const r = alignValues(aa, b);
                    const extra = pow10(self.scale);
                    self.push(.{ .num = @divTrunc(r.a * extra, r.b), .scale = self.scale });
                },
                '%' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    if (b.num == 0) {
                        c.plainMsg("divide by zero", .{});
                        self.failed = true;
                        return;
                    }
                    self.push(.{ .num = @rem(aa.num, b.num), .scale = aa.scale });
                },
                '^' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    var exp = b.num;
                    if (exp < 0) exp = 0;
                    var r: i128 = 1;
                    var k: i128 = 0;
                    while (k < exp) : (k += 1) r *= aa.num;
                    self.push(.{ .num = r });
                },
                'v' => {
                    const aa = self.pop() orelse return;
                    if (aa.num < 0) {
                        self.push(.{ .num = 0 });
                        continue;
                    }
                    var x: i128 = aa.num;
                    var y: i128 = @divTrunc(x + 1, 2);
                    while (y < x) {
                        x = y;
                        y = @divTrunc(x + @divTrunc(aa.num, x), 2);
                    }
                    self.push(.{ .num = x });
                },
                '~' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    if (b.num == 0) {
                        c.plainMsg("divide by zero", .{});
                        self.failed = true;
                        return;
                    }
                    const q = @divTrunc(aa.num, b.num);
                    self.push(.{ .num = q });
                    self.push(.{ .num = aa.num - q * b.num });
                },
                '|' => {
                    const m = self.pop() orelse return;
                    const e = self.pop() orelse return;
                    const b = self.pop() orelse return;
                    if (m.num == 0) {
                        self.push(.{ .num = 0 });
                        continue;
                    }
                    var result: i128 = 1;
                    var base = @mod(b.num, m.num);
                    var exp = e.num;
                    while (exp > 0) : (exp >>= 1) {
                        if ((exp & 1) != 0) result = @mod(result * base, m.num);
                        base = @mod(base * base, m.num);
                    }
                    self.push(.{ .num = result });
                },
                'k' => {
                    const v = self.pop() orelse return;
                    self.scale = @intCast(@min(18, @max(0, v.num)));
                },
                'i' => {
                    const v = self.pop() orelse return;
                    if (v.num >= 2 and v.num <= 16) self.ibase = @intCast(v.num);
                },
                'o' => {
                    const v = self.pop() orelse return;
                    if (v.num == 2 or v.num == 8 or v.num == 10 or v.num == 16) self.obase = @intCast(v.num);
                },
                'p' => {
                    if (self.depth == 0) {
                        c.plainMsg("stack has too few elements", .{});
                        self.failed = true;
                        return;
                    }
                    self.printValue(self.stack[self.depth - 1]);
                },
                'f' => {
                    var n = self.depth;
                    while (n > 0) {
                        n -= 1;
                        self.printValue(self.stack[n]);
                    }
                },
                else => {
                    c.plainMsg("bad character '{c}'", .{ch});
                    self.failed = true;
                },
            }
        }
    }
};

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("dc");
    var machine = Dc{};
    var script = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e") and i + 1 < args.len) {
            i += 1;
            script = true;
            machine.execute(args[i]);
        } else if (std.mem.startsWith(u8, arg, "-e") and arg.len > 2) {
            script = true;
            machine.execute(arg[2..]);
        } else if (std.mem.eql(u8, arg, "-f") and i + 1 < args.len) {
            i += 1;
            script = true;
            var en: c_int = 0;
            const data = c.readFile(a, args[i], &en) orelse {
                c.errorMsgAndDie(en, "can't open '{s}'", .{args[i]});
            };
            defer a.free(data);
            machine.execute(data);
        } else if (std.mem.eql(u8, arg, "-x")) {
            // Extended registers are accepted but unused by our scripts.
        } else if (arg.len > 1 and arg[0] == '-') {
            c.usageDie("dc");
        } else {
            script = true;
            var en: c_int = 0;
            const data = c.readFile(a, arg, &en) orelse {
                c.errorMsgAndDie(en, "can't open '{s}'", .{arg});
            };
            defer a.free(data);
            machine.execute(data);
        }
        if (machine.failed) return 1;
    }
    if (!script) {
        const data = c.readStdin(a) catch return 1;
        defer a.free(data);
        machine.execute(data);
    }
    return if (machine.failed) 1 else 0;
}
