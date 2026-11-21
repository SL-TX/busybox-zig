//! Backtracking bytecode interpreter for the regex compiler in parse.zig.
//! A step budget turns catastrophic backtracking into a clean error.

const std = @import("std");
const parse = @import("parse.zig");
const Program = parse.Program;
const Inst = parse.Inst;

pub const Match = struct { start: usize, end: usize };

pub const ExecError = error{StepLimitExceeded};

const Context = struct {
    prog: *const Program,
    text: []const u8,
    captures: [32]?usize = undefined,
    loop_pos: [32]usize = undefined,
    steps: usize = 0,
    max_steps: usize,
};

fn eq(a: u8, b: u8, ci: bool) bool {
    if (a == b) return true;
    if (!ci) return false;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn classMatches(class: parse.CharClass, c: u8, ci: bool) bool {
    var hit = false;
    for (class.ranges) |r| {
        if (c >= r.lo and c <= r.hi) {
            hit = true;
            break;
        }
        if (ci) {
            const swapped: u8 = if (std.ascii.isUpper(c)) std.ascii.toLower(c) else std.ascii.toUpper(c);
            if (swapped >= r.lo and swapped <= r.hi) {
                hit = true;
                break;
            }
        }
    }
    return hit != class.negated;
}

fn runPc(ctx: *Context, pc: u32, pos: usize) ExecError!bool {
    ctx.steps += 1;
    if (ctx.steps > ctx.max_steps) return error.StepLimitExceeded;
    const inst = ctx.prog.insts[pc];
    switch (inst) {
        .match => return true,
        .char => |c| {
            if (pos >= ctx.text.len) return false;
            if (eq(ctx.text[pos], c, ctx.prog.flags.ignore_case)) return runPc(ctx, pc + 1, pos + 1);
            return false;
        },
        .any => {
            if (pos >= ctx.text.len) return false;
            return runPc(ctx, pc + 1, pos + 1);
        },
        .class => |ci| {
            if (pos >= ctx.text.len) return false;
            if (classMatches(ctx.prog.classes[ci], ctx.text[pos], ctx.prog.flags.ignore_case)) return runPc(ctx, pc + 1, pos + 1);
            return false;
        },
        .bol => {
            if (pos == 0 or (ctx.prog.flags.newline and pos > 0 and ctx.text[pos - 1] == '\n')) return runPc(ctx, pc + 1, pos);
            return false;
        },
        .eol => {
            if (pos == ctx.text.len or (ctx.prog.flags.newline and pos < ctx.text.len and ctx.text[pos] == '\n')) return runPc(ctx, pc + 1, pos);
            return false;
        },
        .save => |slot| {
            const old = ctx.captures[slot];
            ctx.captures[slot] = pos;
            if (try runPc(ctx, pc + 1, pos)) return true;
            ctx.captures[slot] = old;
            return false;
        },
        .backref => |n| {
            const s = ctx.captures[2 * n];
            const e = ctx.captures[2 * n + 1];
            if (s == null or e == null or e.? < s.?) return runPc(ctx, pc + 1, pos);
            const sub = ctx.text[s.?..e.?];
            if (pos + sub.len > ctx.text.len) return false;
            const want = ctx.text[pos .. pos + sub.len];
            for (sub, want) |x, y| {
                if (!eq(x, y, ctx.prog.flags.ignore_case)) return false;
            }
            return runPc(ctx, pc + 1, pos + sub.len);
        },
        .split => |sp| {
            if (try runPc(ctx, sp.x, pos)) return true;
            return runPc(ctx, sp.y, pos);
        },
        .jmp => |target| return runPc(ctx, target, pos),
        .loop_enter => |slot| {
            ctx.loop_pos[slot] = pos;
            return runPc(ctx, pc + 1, pos);
        },
        .loop_check => |lc| {
            if (pos == ctx.loop_pos[lc.marker]) return runPc(ctx, lc.no_progress, pos);
            return runPc(ctx, pc + 1, pos);
        },
    }
}

/// Try to match starting exactly at `start`. Returns the number of match
/// slots written (1 + number of groups), or null when there is no match.
pub fn execAt(prog: *const Program, text: []const u8, start: usize, matches: []Match, max_steps: usize) ExecError!?usize {
    var ctx = Context{ .prog = prog, .text = text, .max_steps = max_steps };
    @memset(&ctx.captures, null);
    @memset(&ctx.loop_pos, 0);
    if (!(try runPc(&ctx, 0, start))) return null;

    var count: usize = 0;
    if (matches.len > 0) {
        matches[0] = .{ .start = start, .end = ctx.captures[1] orelse start };
        count = 1;
    }
    var g: usize = 1;
    while (g <= prog.group_count and g < matches.len) : (g += 1) {
        const s = ctx.captures[2 * g] orelse start;
        const e = ctx.captures[2 * g + 1] orelse s;
        matches[g] = .{ .start = s, .end = e };
        count += 1;
    }
    return count;
}
