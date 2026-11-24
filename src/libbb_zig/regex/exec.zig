//! Backtracking bytecode interpreter for the regex compiler in parse.zig.
//!
//! The interpreter is iterative: an explicit backtrack stack and an undo trail
//! replace the old recursive `runPc`, so a long input (or a deeply nested
//! pattern) can never exhaust the machine stack. A step budget turns
//! catastrophic backtracking into a clean `error.StepLimitExceeded`, which also
//! bounds the memory used by the two work lists.
//!
//! Two matching modes share the VM:
//!   * `execAt`       - POSIX "leftmost-first" (the historical engine API,
//!                      kept unchanged for existing callers);
//!   * `execLongestAt`- POSIX "leftmost-longest" for BRE/ERE shell & editors.

const std = @import("std");
const parse = @import("parse.zig");
const Program = parse.Program;
const Inst = parse.Inst;

pub const Match = struct { start: usize, end: usize };

pub const ExecError = error{StepLimitExceeded};

/// Slot count must cover the two save slots of every group (group_count is
/// capped at 16 by the parser), plus the whole-match pair at slots 0 and 1.
const SLOT_COUNT = 36;

const TrailEntry = struct {
    is_loop: bool,
    slot: u8,
    old: ?usize,
};

const Frame = struct {
    pc: u32,
    pos: usize,
    trail_len: usize,
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

const Vm = struct {
    prog: *const Program,
    text: []const u8,
    alloc: std.mem.Allocator,
    max_steps: usize,
    longest: bool,

    captures: [SLOT_COUNT]?usize = undefined,
    loop_pos: [SLOT_COUNT]usize = undefined,
    stack: std.ArrayList(Frame) = .empty,
    trail: std.ArrayList(TrailEntry) = .empty,
    steps: usize = 0,
    best_end: ?usize = null,
    best_caps: [SLOT_COUNT]?usize = undefined,

    fn deinit(self: *Vm) void {
        self.stack.deinit(self.alloc);
        self.trail.deinit(self.alloc);
    }

    /// Every push follows a charged step, so `max_steps` also bounds the work
    /// lists; the cast is safe because pc indices are u32 in the program.
    fn pushFrame(self: *Vm, pc: u32, pos: usize) ExecError!void {
        self.stack.append(self.alloc, .{ .pc = pc, .pos = pos, .trail_len = self.trail.items.len }) catch return error.StepLimitExceeded;
    }

    fn pushTrail(self: *Vm, is_loop: bool, slot: u8, old: ?usize) ExecError!void {
        self.trail.append(self.alloc, .{ .is_loop = is_loop, .slot = slot, .old = old }) catch return error.StepLimitExceeded;
    }

    /// Run from `start`. In first mode, returns on the first accepting state.
    /// In longest mode, all surviving paths are explored and the furthest
    /// accepting state (and its captures) is retained.
    fn run(self: *Vm, start: usize) ExecError!bool {
        var pc: u32 = 0;
        var pos: usize = start;

        while (true) {
            self.steps += 1;
            if (self.steps > self.max_steps) return error.StepLimitExceeded;

            const inst = self.prog.insts[pc];
            var abandon_path = false;
            switch (inst) {
                .match => {
                    if (!self.longest) return true;
                    // Strictly greater keeps the first path on ties, matching
                    // the historical grep VM's tie-breaking behaviour.
                    if (self.best_end == null or pos > self.best_end.?) {
                        self.best_end = pos;
                        self.best_caps = self.captures;
                    }
                    abandon_path = true;
                },
                .char => |ch| {
                    if (pos < self.text.len and eq(self.text[pos], ch, self.prog.flags.ignore_case)) {
                        pc += 1;
                        pos += 1;
                    } else abandon_path = true;
                },
                .any => {
                    if (pos < self.text.len) {
                        pc += 1;
                        pos += 1;
                    } else abandon_path = true;
                },
                .class => |ci| {
                    if (pos < self.text.len and classMatches(self.prog.classes[ci], self.text[pos], self.prog.flags.ignore_case)) {
                        pc += 1;
                        pos += 1;
                    } else abandon_path = true;
                },
                .bol => {
                    if (pos == 0 or (self.prog.flags.newline and pos > 0 and self.text[pos - 1] == '\n')) {
                        pc += 1;
                    } else abandon_path = true;
                },
                .eol => {
                    if (pos == self.text.len or (self.prog.flags.newline and pos < self.text.len and self.text[pos] == '\n')) {
                        pc += 1;
                    } else abandon_path = true;
                },
                .save => |slot| {
                    try self.pushTrail(false, slot, self.captures[slot]);
                    self.captures[slot] = pos;
                    pc += 1;
                },
                .backref => |n| {
                    const s = self.captures[2 * n];
                    const e = self.captures[2 * n + 1];
                    if (s == null or e == null or e.? < s.?) {
                        // A group that did not participate matches empty.
                        pc += 1;
                    } else {
                        const sub = self.text[s.?..e.?];
                        if (pos + sub.len > self.text.len) {
                            abandon_path = true;
                        } else {
                            var ok = true;
                            for (sub, 0..) |x, k| {
                                if (!eq(x, self.text[pos + k], self.prog.flags.ignore_case)) {
                                    ok = false;
                                    break;
                                }
                            }
                            if (ok) {
                                pc += 1;
                                pos += sub.len;
                            } else abandon_path = true;
                        }
                    }
                },
                .split => |sp| {
                    try self.pushFrame(sp.y, pos);
                    pc = sp.x;
                },
                .jmp => |target| pc = target,
                .loop_enter => |slot| {
                    try self.pushTrail(true, slot, @as(?usize, self.loop_pos[slot]));
                    self.loop_pos[slot] = pos;
                    pc += 1;
                },
                .loop_check => |lc| {
                    if (pos == self.loop_pos[lc.marker]) {
                        pc = lc.no_progress;
                    } else pc += 1;
                },
            }
            if (!abandon_path) continue;

            // Backtrack to the most recent alternative, undoing its saves.
            if (self.stack.items.len == 0) break;
            const f = self.stack.pop().?;
            while (self.trail.items.len > f.trail_len) {
                const t = self.trail.pop().?;
                if (t.is_loop) {
                    self.loop_pos[t.slot] = t.old.?;
                } else {
                    self.captures[t.slot] = t.old;
                }
            }
            pc = f.pc;
            pos = f.pos;
        }
        return self.longest and self.best_end != null;
    }

    fn fill(self: *const Vm, start: usize, matches: []Match, caps: *const [SLOT_COUNT]?usize) usize {
        var count: usize = 0;
        if (matches.len > 0) {
            matches[0] = .{ .start = start, .end = caps[1] orelse start };
            count = 1;
        }
        var g: usize = 1;
        while (g <= self.prog.group_count and g < matches.len) : (g += 1) {
            const s = caps[2 * g] orelse start;
            const e = caps[2 * g + 1] orelse s;
            matches[g] = .{ .start = s, .end = e };
            count += 1;
        }
        return count;
    }
};

fn initVm(prog: *const Program, text: []const u8, max_steps: usize, longest: bool) Vm {
    var vm = Vm{
        .prog = prog,
        .text = text,
        .alloc = prog.allocator,
        .max_steps = max_steps,
        .longest = longest,
    };
    @memset(&vm.captures, null);
    @memset(&vm.loop_pos, 0);
    @memset(&vm.best_caps, null);
    return vm;
}

/// Try to match starting exactly at `start` (leftmost-first). Returns the
/// number of match slots written (1 + number of groups), or null on no match.
pub fn execAt(prog: *const Program, text: []const u8, start: usize, matches: []Match, max_steps: usize) ExecError!?usize {
    if (start > text.len) return null;
    var vm = initVm(prog, text, max_steps, false);
    defer vm.deinit();
    if (!(try vm.run(start))) return null;
    return vm.fill(start, matches, &vm.captures);
}

/// POSIX leftmost-longest variant. Explores all alternatives that reach the
/// same start position and reports the furthest match (with its captures).
pub fn execLongestAt(prog: *const Program, text: []const u8, start: usize, matches: []Match, max_steps: usize) ExecError!?usize {
    if (start > text.len) return null;
    var vm = initVm(prog, text, max_steps, true);
    defer vm.deinit();
    if (!(try vm.run(start))) return null;
    return vm.fill(start, matches, &vm.best_caps);
}
