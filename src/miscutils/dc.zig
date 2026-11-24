//! dc — reverse-Polish calculator (reference bc.c FEATURE_DC_BIG flavour).
//! Numbers are arbitrary-precision bignums carrying their own decimal scale;
//! division obeys the global `k` scale. `-x` enables extended register names.

const std = @import("std");
const c = @import("common.zig");
const big = @import("big.zig");

const Value = struct {
    num: *big.Big,
    scale: u8 = 0,
};

const Dc = struct {
    stack: [8192]Value = undefined,
    depth: usize = 0,
    scale: u8 = 0,
    obase: u8 = 10,
    ibase: u8 = 10,
    extended: bool = false,
    regs: std.StringHashMap(*big.Big),
    reg_stacks: std.StringHashMap(std.ArrayList(*big.Big)),
    failed: bool = false,

    fn init(extended: bool) Dc {
        return .{
            .extended = extended,
            .regs = std.StringHashMap(*big.Big).init(std.heap.page_allocator),
            .reg_stacks = std.StringHashMap(std.ArrayList(*big.Big)).init(std.heap.page_allocator),
        };
    }

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

    fn alignValues(a: Value, b: Value) struct { a: *big.Big, b: *big.Big, scale: u8 } {
        const s = @max(a.scale, b.scale);
        return .{
            .a = big.mul(a.num, big.pow10(s - a.scale)),
            .b = big.mul(b.num, big.pow10(s - b.scale)),
            .scale = s,
        };
    }

    fn printValue(self: *Dc, v: Value) void {
        const absn = big.abs(v.num);
        const d = big.divTrunc(absn, big.pow10(v.scale));
        if (big.isNeg(v.num)) c.out("-");
        if (self.obase != 10) {
            const text = big.toString(d.q, self.obase);
            if (self.obase > 10) {
                for (text) |*ch| ch.* = std.ascii.toUpper(ch.*);
            }
            c.out(text);
            c.out("\n");
            return;
        }
        const whole = big.toString(d.q, 10);
        if (v.scale == 0) {
            c.out(whole);
            c.out("\n");
            return;
        }
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
        c.out("\n");
    }

    fn readRegName(self: *Dc, input: []const u8, idx: *usize) ?[]const u8 {
        var i = idx.*;
        if (self.extended) {
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n' or input[i] == '\r')) i += 1;
        }
        if (i >= input.len) return null;
        const start = i;
        i += 1;
        if (self.extended) {
            while (i < input.len and (std.ascii.isLower(input[i]) or std.ascii.isDigit(input[i]) or input[i] == '_')) i += 1;
        }
        idx.* = i;
        return input[start..i];
    }

    fn key(self: *Dc, name: []const u8) []const u8 {
        _ = self;
        return std.heap.page_allocator.dupe(u8, name) catch name;
    }

    fn execute(self: *Dc, input: []const u8) void {
        var i: usize = 0;
        while (i < input.len and !self.failed) {
            const ch = input[i];
            if (digit(ch, self.ibase) != null) {
                var j = i;
                while (j < input.len and digit(input[j], self.ibase) != null) : (j += 1) {}
                self.push(.{ .num = big.fromString(input[i..j], self.ibase) });
                i = j;
                continue;
            }
            if (ch == '_') {
                i += 1;
                var j = i;
                while (j < input.len and digit(input[j], 10) != null) : (j += 1) {}
                self.push(.{ .num = big.fromString(input[i..j], 10) });
                self.stack[self.depth - 1].num.negate();
                i = j;
                continue;
            }
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                i += 1;
                continue;
            }
            i += 1;
            switch (ch) {
                '+', '-' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    const r = alignValues(aa, b);
                    self.push(.{ .num = if (ch == '+') big.add(r.a, r.b) else big.sub(r.a, r.b), .scale = r.scale });
                },
                '*' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    self.push(.{ .num = big.mul(aa.num, b.num), .scale = aa.scale + b.scale });
                },
                '/' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    if (big.isZero(b.num)) {
                        c.plainMsg("divide by zero", .{});
                        self.failed = true;
                        return;
                    }
                    const r = alignValues(aa, b);
                    const q = big.divTrunc(big.mul(r.a, big.pow10(self.scale)), r.b).q;
                    self.push(.{ .num = q, .scale = self.scale });
                },
                '%' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    if (big.isZero(b.num)) {
                        c.plainMsg("divide by zero", .{});
                        self.failed = true;
                        return;
                    }
                    self.push(.{ .num = big.mod(aa.num, b.num), .scale = aa.scale });
                },
                '^' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    const exp = big.smallExponent(b.num, 100_000) orelse {
                        c.plainMsg("exponent too large", .{});
                        self.failed = true;
                        return;
                    };
                    self.push(.{ .num = big.pow(aa.num, exp) });
                },
                'v' => {
                    const aa = self.pop() orelse return;
                    self.push(.{ .num = big.sqrt(aa.num) });
                },
                '~' => {
                    const b = self.pop() orelse return;
                    const aa = self.pop() orelse return;
                    if (big.isZero(b.num)) {
                        c.plainMsg("divide by zero", .{});
                        self.failed = true;
                        return;
                    }
                    const d = big.divTrunc(aa.num, b.num);
                    self.push(.{ .num = d.q });
                    self.push(.{ .num = d.r });
                },
                '|' => {
                    const m = self.pop() orelse return;
                    const e = self.pop() orelse return;
                    const b = self.pop() orelse return;
                    if (big.isZero(m.num)) {
                        self.push(.{ .num = big.fromU64(0) });
                        continue;
                    }
                    const exp = big.smallExponent(e.num, 1_000_000) orelse {
                        c.plainMsg("exponent too large", .{});
                        self.failed = true;
                        return;
                    };
                    var result = big.fromU64(1);
                    const base = big.mod(b.num, m.num);
                    var k: u32 = 0;
                    while (k < exp) : (k += 1) {
                        result = big.mod(big.mul(result, base), m.num);
                    }
                    self.push(.{ .num = result });
                },
                'k' => {
                    const v = self.pop() orelse return;
                    const n = big.toU64(v.num) orelse 0;
                    self.scale = @intCast(@min(200, n));
                },
                'i' => {
                    const v = self.pop() orelse return;
                    const n = big.toU64(v.num) orelse 0;
                    if (n >= 2 and n <= 16) self.ibase = @intCast(n);
                },
                'o' => {
                    const v = self.pop() orelse return;
                    const n = big.toU64(v.num) orelse 0;
                    if (n == 2 or n == 8 or n == 10 or n == 16) self.obase = @intCast(n);
                },
                's', 'l', 'S', 'L' => {
                    const name = self.readRegName(input, &i) orelse {
                        c.plainMsg("bad character '{c}'", .{ch});
                        self.failed = true;
                        return;
                    };
                    const k = self.key(name);
                    if (ch == 's') {
                        const v = self.pop() orelse return;
                        self.regs.put(k, v.num) catch {};
                    } else if (ch == 'l') {
                        const v = self.regs.get(k) orelse big.fromU64(0);
                        self.push(.{ .num = big.copy(v) });
                    } else if (ch == 'S') {
                        const v = self.pop() orelse return;
                        const gop = self.reg_stacks.getOrPut(k) catch return;
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        gop.value_ptr.append(std.heap.page_allocator, v.num) catch {};
                    } else {
                        const gop = self.reg_stacks.getPtr(k) orelse {
                            c.plainMsg("stack has too few elements", .{});
                            self.failed = true;
                            return;
                        };
                        const v = gop.pop() orelse {
                            c.plainMsg("stack has too few elements", .{});
                            self.failed = true;
                            return;
                        };
                        self.push(.{ .num = v });
                    }
                },
                'r' => {
                    const a = self.pop() orelse return;
                    const b = self.pop() orelse return;
                    self.push(b);
                    self.push(a);
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

fn digit(ch: u8, base: u8) ?u8 {
    const d: ?u8 = if (ch >= '0' and ch <= '9')
        ch - '0'
    else if (ch >= 'a' and ch <= 'z')
        ch - 'a' + 10
    else if (ch >= 'A' and ch <= 'Z')
        ch - 'A' + 10
    else
        null;
    const v = d orelse return null;
    return if (v < base) v else null;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("dc");
    var machine = Dc.init(false);
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
            // Enables extended (multi-character) register names for s/l/S/L.
            machine.extended = true;
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
