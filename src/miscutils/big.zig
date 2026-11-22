//! Shared arbitrary-precision integer helpers for the bc/dc applets.
//!
//! Values are `Managed` bignums reached through pointers. Allocations use the
//! page allocator and live until process exit (these are short-lived CLIs),
//! which keeps `Value` a small copyable struct for the evaluator stacks and
//! variable tables. Every arithmetic operation builds a fresh result.

const std = @import("std");
const c = @import("common.zig");

pub const Big = std.math.big.int.Managed;
pub const Order = std.math.Order;

pub fn create() *Big {
    const p = std.heap.page_allocator.create(Big) catch @panic("big: out of memory");
    p.* = Big.init(std.heap.page_allocator) catch @panic("big: out of memory");
    return p;
}

pub fn fromU64(v: u64) *Big {
    const b = create();
    b.set(v) catch @panic("big: out of memory");
    return b;
}

pub fn fromI64(v: i64) *Big {
    const b = create();
    b.set(v) catch @panic("big: out of memory");
    return b;
}

/// Parse a sign-magnitude integer. `value` may start with '-' or '_'.
pub fn fromString(value: []const u8, base: u8) *Big {
    const b = create();
    var s = value;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '_')) {
        negative = true;
        s = s[1..];
    }
    if (s.len == 0) s = "0";
    b.setString(base, s) catch {
        c.plainMsg("invalid number", .{});
        return b;
    };
    if (negative) b.negate();
    return b;
}

pub fn copy(a: *const Big) *Big {
    const r = std.heap.page_allocator.create(Big) catch @panic("big: out of memory");
    r.* = a.clone() catch @panic("big: out of memory");
    return r;
}

pub fn add(a: *const Big, b: *const Big) *Big {
    const r = create();
    r.add(a, b) catch @panic("big: out of memory");
    return r;
}

pub fn sub(a: *const Big, b: *const Big) *Big {
    const r = create();
    r.sub(a, b) catch @panic("big: out of memory");
    return r;
}

pub fn mul(a: *const Big, b: *const Big) *Big {
    const r = create();
    r.mul(a, b) catch @panic("big: out of memory");
    return r;
}

pub fn neg(a: *const Big) *Big {
    const r = copy(a);
    r.negate();
    return r;
}

pub fn abs(a: *const Big) *Big {
    const r = copy(a);
    if (!r.isPositive()) r.abs();
    return r;
}

pub fn isZero(a: *const Big) bool {
    return a.eqlZero();
}

pub fn isNeg(a: *const Big) bool {
    return !a.isPositive();
}

pub fn cmp(a: *const Big, b: *const Big) Order {
    return a.order(b.*);
}

pub fn toU64(a: *const Big) ?u64 {
    return a.toInt(u64) catch null;
}

/// q = a / b, r = a % b with truncation toward zero.
pub fn divTrunc(a: *const Big, b: *const Big) struct { q: *Big, r: *Big } {
    const q = create();
    const r = create();
    Big.divTrunc(q, r, a, b) catch @panic("big: out of memory");
    return .{ .q = q, .r = r };
}

pub fn mod(a: *const Big, b: *const Big) *Big {
    return divTrunc(a, b).r;
}

pub fn pow(base: *const Big, exp: u32) *Big {
    const r = create();
    r.pow(base, exp) catch @panic("big: out of memory");
    return r;
}

pub fn pow10(n: u32) *Big {
    return pow(fromU64(10), n);
}

pub fn toString(a: *const Big, base: u8) []u8 {
    return a.toString(std.heap.page_allocator, base, .lower) catch @panic("big: out of memory");
}

/// Integer square root (floor), via Newton iteration on bignums.
pub fn sqrt(a: *const Big) *Big {
    if (isNeg(a) or isZero(a)) return fromU64(0);
    var x: *Big = copy(a);
    while (true) {
        const d = divTrunc(x, a);
        const y = divTrunc(add(d.q, x), fromU64(2)).q;
        if (cmp(y, x) != .lt) return x;
        x = y;
    }
}

/// Base-2 exponent of a small bignum, capped to avoid runaway computations.
pub fn smallExponent(a: *const Big, cap: u64) ?u32 {
    const v = toU64(a) orelse return null;
    if (v > cap) return null;
    return @intCast(v);
}
