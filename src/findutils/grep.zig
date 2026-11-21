//! findutils grep / egrep / fgrep — search for patterns in files or stdin.
//!
//! The Task 6 regex engine is leftmost-first/greedy. POSIX grep requires
//! leftmost-LONGEST, so this applet uses a local backtracking VM over the same
//! compiled program which records the furthest accepting state instead of the
//! first one. The global engine is left untouched for sed/awk.

const std = @import("std");
const c = @import("common.zig");
const bb = c.bb;
const regex = bb.regex;
const A = std.heap.page_allocator;

// ---- POSIX leftmost-longest VM over the Task 6 bytecode ------------------

fn Longest(comptime Prog: type) type {
    return struct {
        prog: *const Prog,
        text: []const u8,
        step: usize = 0,
        max_steps: usize,
        best_end: ?usize = null,
        best_caps: [32]?usize = undefined,
        loop_pos: [32]usize = undefined,

        const Self = @This();

        fn eq(self: *const Self, a: u8, b: u8) bool {
            if (a == b) return true;
            if (!self.prog.flags.ignore_case) return false;
            return std.ascii.toLower(a) == std.ascii.toLower(b);
        }

        fn classHit(self: *const Self, ci: u32, ch: u8) bool {
            const cl = self.prog.classes[ci];
            var hit = false;
            for (cl.ranges) |r| {
                if (ch >= r.lo and ch <= r.hi) {
                    hit = true;
                    break;
                }
                if (self.prog.flags.ignore_case) {
                    const s = if (std.ascii.isUpper(ch)) std.ascii.toLower(ch) else std.ascii.toUpper(ch);
                    if (s >= r.lo and s <= r.hi) {
                        hit = true;
                        break;
                    }
                }
            }
            return hit != cl.negated;
        }

        fn run(self: *Self, pc: u32, pos: usize, caps: *[32]?usize) void {
            self.step += 1;
            if (self.step > self.max_steps) return;
            const inst = self.prog.insts[pc];
            switch (inst) {
                .match => {
                    if (self.best_end == null or pos > self.best_end.?) {
                        self.best_end = pos;
                        self.best_caps = caps.*;
                    }
                },
                .char => |ch| {
                    if (pos < self.text.len and self.eq(self.text[pos], ch))
                        self.run(pc + 1, pos + 1, caps);
                },
                .any => {
                    if (pos < self.text.len) self.run(pc + 1, pos + 1, caps);
                },
                .class => |ci| {
                    if (pos < self.text.len and self.classHit(ci, self.text[pos]))
                        self.run(pc + 1, pos + 1, caps);
                },
                .bol => {
                    if (pos == 0 or (self.prog.flags.newline and pos > 0 and self.text[pos - 1] == '\n'))
                        self.run(pc + 1, pos, caps);
                },
                .eol => {
                    if (pos == self.text.len or (self.prog.flags.newline and pos < self.text.len and self.text[pos] == '\n'))
                        self.run(pc + 1, pos, caps);
                },
                .save => |slot| {
                    const old = caps[slot];
                    caps[slot] = pos;
                    self.run(pc + 1, pos, caps);
                    caps[slot] = old;
                },
                .backref => |n| {
                    const s = caps[2 * n] orelse return self.run(pc + 1, pos, caps);
                    const e = caps[2 * n + 1] orelse return self.run(pc + 1, pos, caps);
                    if (e < s) return self.run(pc + 1, pos, caps);
                    const sub = self.text[s..e];
                    if (pos + sub.len > self.text.len) return;
                    for (sub, 0..) |ch, k| {
                        if (!self.eq(ch, self.text[pos + k])) return;
                    }
                    self.run(pc + 1, pos + sub.len, caps);
                },
                .split => |sp| {
                    self.run(sp.x, pos, caps);
                    self.run(sp.y, pos, caps);
                },
                .jmp => |target| self.run(target, pos, caps),
                .loop_enter => |slot| {
                    const old = self.loop_pos[slot];
                    self.loop_pos[slot] = pos;
                    self.run(pc + 1, pos, caps);
                    self.loop_pos[slot] = old;
                },
                .loop_check => |lc| {
                    if (pos == self.loop_pos[lc.marker])
                        self.run(lc.no_progress, pos, caps)
                    else
                        self.run(pc + 1, pos, caps);
                },
            }
        }
    };
}

const Span = struct { start: usize, end: usize };

fn regexAt(re: *const regex.Regex, text: []const u8, start: usize, spans: []Span) ?usize {
    var caps: [32]?usize = undefined;
    @memset(&caps, null);
    var vm = Longest(@TypeOf(re.prog)){
        .prog = &re.prog,
        .text = text,
        .max_steps = re.max_steps,
    };
    vm.run(0, start, &caps);
    const end = vm.best_end orelse return null;
    if (spans.len > 0) {
        spans[0] = .{ .start = start, .end = end };
        var g: usize = 1;
        while (g <= re.prog.group_count and g < spans.len) : (g += 1) {
            const s = vm.best_caps[2 * g] orelse start;
            const e = vm.best_caps[2 * g + 1] orelse s;
            spans[g] = .{ .start = s, .end = e };
        }
        return g;
    }
    return 1;
}

fn fixedAt(needle: []const u8, text: []const u8, start: usize, ci: bool) ?Span {
    if (needle.len == 0) return .{ .start = start, .end = start };
    if (start + needle.len > text.len) return null;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        const a = text[start + i];
        const b = needle[i];
        if (!(a == b or (ci and std.ascii.toLower(a) == std.ascii.toLower(b)))) return null;
    }
    return .{ .start = start, .end = start + needle.len };
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

const Matcher = struct {
    re: ?regex.Regex = null,
    fixed: ?[]const u8 = null,
    ci: bool = false,

    fn deinit(self: *Matcher) void {
        if (self.re) |*r| r.deinit();
    }

    fn at(self: *const Matcher, text: []const u8, start: usize, spans: []Span) ?usize {
        if (self.fixed) |f| {
            if (fixedAt(f, text, start, self.ci)) |s| {
                if (spans.len > 0) spans[0] = s;
                return 1;
            }
            return null;
        }
        return regexAt(&self.re.?, text, start, spans);
    }
};

// ---- grep driver ---------------------------------------------------------

const Options = struct {
    flags: u32 = 0,
    after: usize = 0,
    before: usize = 0,
    max_match: ?usize = null,
    patterns: std.ArrayList([]const u8) = .empty,
};

const F_H: u32 = 1 << 0;
const F_h: u32 = 1 << 1;
const F_n: u32 = 1 << 2;
const F_l: u32 = 1 << 3;
const F_L: u32 = 1 << 4;
const F_c: u32 = 1 << 5;
const F_o: u32 = 1 << 6;
const F_q: u32 = 1 << 7;
const F_s: u32 = 1 << 8;
const F_r: u32 = 1 << 9;
const F_R: u32 = 1 << 10;
const F_v: u32 = 1 << 11;
const F_i: u32 = 1 << 12;
const F_w: u32 = 1 << 13;
const F_x: u32 = 1 << 14;
const F_F: u32 = 1 << 15;
const F_E: u32 = 1 << 16;

fn firstMatch(m: *const Matcher, line: []const u8, opts: Options, from: usize) ?Span {
    var pos = from;
    while (pos <= line.len) : (pos += 1) {
        var spans: [4]Span = undefined;
        _ = m.at(line, pos, &spans) orelse continue;
        const sp = spans[0];
        if (opts.flags & F_w != 0) {
            if (sp.start > 0 and isWord(line[sp.start - 1])) continue;
            if (sp.end < line.len and isWord(line[sp.end])) continue;
        }
        if (opts.flags & F_x != 0 and !(sp.start == 0 and sp.end == line.len)) continue;
        if (sp.end == sp.start) {
            if (pos == line.len) return sp;
            continue;
        }
        return sp;
    }
    return null;
}

fn lineIsMatch(matchers: []const Matcher, line: []const u8, opts: Options) bool {
    for (matchers) |*m| {
        if (firstMatch(m, line, opts, 0) != null) return true;
    }
    return false;
}

fn emitSpan(sp: Span, line: []const u8, idx: usize, prefix: ?[]const u8, opts: Options, out: *const fn ([]const u8) void) void {
    if (prefix) |p| {
        out(p);
        out(":");
    }
    if (opts.flags & F_n != 0) {
        var b: [32]u8 = undefined;
        out(std.fmt.bufPrint(&b, "{d}:", .{idx + 1}) catch "0:");
    }
    out(line[sp.start..sp.end]);
    out("\n");
}

fn spanLess(_: void, a: Span, b: Span) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

fn emitMatches(matchers: []const Matcher, line: []const u8, idx: usize, prefix: ?[]const u8, opts: Options, out: *const fn ([]const u8) void) void {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(A);
    for (matchers) |*m| {
        var pos: usize = 0;
        while (pos <= line.len) {
            const sp = firstMatch(m, line, opts, pos) orelse break;
            if (sp.end == sp.start) {
                pos += 1;
                continue;
            }
            spans.append(A, sp) catch {};
            pos = sp.end;
        }
    }
    std.mem.sort(Span, spans.items, {}, spanLess);
    var prev: ?Span = null;
    for (spans.items) |sp| {
        if (prev) |p| if (p.start == sp.start and p.end == sp.end) continue;
        emitSpan(sp, line, idx, prefix, opts, out);
        prev = sp;
    }
}

fn emitLine(line: []const u8, idx: usize, prefix: ?[]const u8, opts: Options, out: *const fn ([]const u8) void) void {
    if (opts.flags & (F_o | F_l | F_L | F_c | F_q) != 0) return;
    if (prefix) |p| {
        out(p);
        out(":");
    }
    if (opts.flags & F_n != 0) {
        var b: [32]u8 = undefined;
        out(std.fmt.bufPrint(&b, "{d}:", .{idx + 1}) catch "0:");
    }
    out(line);
    out("\n");
}

const FileResult = struct { matched: bool = false, count: usize = 0 };

fn processLines(matchers: []const Matcher, data: []const u8, opts: Options, prefix: ?[]const u8, out: *const fn ([]const u8) void) FileResult {
    var result = FileResult{};
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(A);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        lines.append(A, line) catch {};
    }

    var after_left: usize = 0;
    var last_printed: ?usize = null;
    for (lines.items, 0..) |line, idx| {
        const hit = lineIsMatch(matchers, line, opts);
        const selected = if (opts.flags & F_v != 0) !hit else hit;
        if (selected) {
            result.matched = true;
            result.count += 1;
            if (opts.max_match) |mm| if (result.count > mm) break;
            if (opts.flags & (F_l | F_L | F_c | F_q) != 0) continue;

            if (opts.after > 0 or opts.before > 0) {
                if (last_printed) |lp| {
                    if (idx > lp + 1 + after_left) out("--");
                }
            }
            if (opts.before > 0) {
                const bstart = if (idx > opts.before) idx - opts.before else 0;
                var b = bstart;
                while (b < idx) : (b += 1) {
                    if (last_printed != null and b <= last_printed.?) continue;
                    emitLine(lines.items[b], b, prefix, opts, out);
                }
            }
            if (opts.flags & F_o != 0) {
                emitMatches(matchers, line, idx, prefix, opts, out);
            } else {
                emitLine(line, idx, prefix, opts, out);
            }
            last_printed = idx;
            after_left = opts.after;
        } else if (after_left > 0 and opts.flags & F_v == 0) {
            emitLine(line, idx, prefix, opts, out);
            after_left -= 1;
            last_printed = idx;
        }
    }
    return result;
}

fn collectFiles(allocator: std.mem.Allocator, path: []const u8, recurse: bool, files: *std.ArrayList([]const u8)) void {
    const st = c.fileInfo(path) orelse {
        files.append(allocator, path) catch {};
        return;
    };
    if ((st.mode & c.linux.S.IFMT) == c.linux.S.IFDIR) {
        if (!recurse) return;
        var dir = c.DirIter.open(path) orelse return;
        defer dir.close();
        while (dir.next()) |name| {
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const full = if (std.mem.endsWith(u8, path, "/"))
                std.fmt.allocPrint(allocator, "{s}{s}", .{ path, name })
            else
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
            const p = full catch continue;
            const st2 = c.statPath(p, false) orelse continue;
            if ((st2.mode & c.linux.S.IFMT) == c.linux.S.IFDIR) {
                collectFiles(allocator, p, recurse, files);
            } else {
                files.append(allocator, p) catch {};
            }
        }
        return;
    }
    files.append(allocator, path) catch {};
}

fn stdoutWrite(s: []const u8) void {
    c.writeAll(1, s);
}

fn dieUsage(prog: []const u8) noreturn {
    bb.usage.show(prog, 2);
    std.process.exit(2);
}

pub fn grepMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const name0 = c.basename(std.mem.span(argv[0]));
    bb.env.setProgramName(name0);
    var opts = Options{};
    const is_egrep = std.mem.eql(u8, name0, "egrep");
    const is_fgrep = std.mem.eql(u8, name0, "fgrep");
    if (is_egrep) opts.flags |= F_E;
    if (is_fgrep) opts.flags |= F_F;

    const args = c.argsFrom(A, argv, argc) catch return 2;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(A);
    var positional_pattern: ?[]const u8 = null;
    var i: usize = 1;
    var endopts = false;
    while (i < args.len) : (i += 1) {
        const t = args[i];
        if (!endopts and std.mem.eql(u8, t, "--")) {
            endopts = true;
            continue;
        }
        if (!endopts and t.len > 1 and t[0] == '-') {
            if (std.mem.eql(u8, t, "-H")) opts.flags |= F_H
            else if (std.mem.eql(u8, t, "-h")) opts.flags |= F_h
            else if (std.mem.eql(u8, t, "-n")) opts.flags |= F_n
            else if (std.mem.eql(u8, t, "-l")) opts.flags |= F_l
            else if (std.mem.eql(u8, t, "-L")) opts.flags |= F_L
            else if (std.mem.eql(u8, t, "-c")) opts.flags |= F_c
            else if (std.mem.eql(u8, t, "-o")) opts.flags |= F_o
            else if (std.mem.eql(u8, t, "-q")) opts.flags |= F_q
            else if (std.mem.eql(u8, t, "-s")) opts.flags |= F_s
            else if (std.mem.eql(u8, t, "-r")) opts.flags |= F_r
            else if (std.mem.eql(u8, t, "-R")) opts.flags |= F_R
            else if (std.mem.eql(u8, t, "-v")) opts.flags |= F_v
            else if (std.mem.eql(u8, t, "-i")) opts.flags |= F_i
            else if (std.mem.eql(u8, t, "-w")) opts.flags |= F_w
            else if (std.mem.eql(u8, t, "-x")) opts.flags |= F_x
            else if (std.mem.eql(u8, t, "-F")) opts.flags |= F_F
            else if (std.mem.eql(u8, t, "-E")) opts.flags |= F_E
            else if (std.mem.eql(u8, t, "-G")) opts.flags &= ~@as(u32, F_E)
            else if (std.mem.eql(u8, t, "-e") or std.mem.eql(u8, t, "-f") or std.mem.eql(u8, t, "-m") or std.mem.eql(u8, t, "-A") or std.mem.eql(u8, t, "-B") or std.mem.eql(u8, t, "-C")) {
                if (i + 1 >= args.len) {
                    bb.messages.plainMsg("option requires an argument -- '{c}'", .{t[1]});
                    dieUsage(name0);
                }
                i += 1;
                const v = args[i];
                if (t[1] == 'e') {
                    opts.patterns.append(A, v) catch {};
                } else if (t[1] == 'f') {
                    const data = c.readFile(A, v) catch {
                        if (opts.flags & F_s == 0) bb.messages.errorMsg(2, "{s}", .{v});
                        continue;
                    };
                    var lit = std.mem.splitScalar(u8, data, '\n');
                    while (lit.next()) |line| {
                        if (line.len == 0 and lit.peek() == null) break;
                        opts.patterns.append(A, A.dupe(u8, line) catch line) catch {};
                    }
                } else {
                    const n = std.fmt.parseInt(usize, v, 10) catch 0;
                    if (t[1] == 'm') opts.max_match = n;
                    if (t[1] == 'A') opts.after = n;
                    if (t[1] == 'B') opts.before = n;
                    if (t[1] == 'C') {
                        opts.after = n;
                        opts.before = n;
                    }
                }
            } else if (std.mem.startsWith(u8, t, "-e") and t.len > 2) {
                opts.patterns.append(A, t[2..]) catch {};
            } else if (std.mem.startsWith(u8, t, "-A") and t.len > 2) {
                opts.after = std.fmt.parseInt(usize, t[2..], 10) catch 0;
            } else if (std.mem.startsWith(u8, t, "-B") and t.len > 2) {
                opts.before = std.fmt.parseInt(usize, t[2..], 10) catch 0;
            } else if (std.mem.startsWith(u8, t, "-C") and t.len > 2) {
                const n = std.fmt.parseInt(usize, t[2..], 10) catch 0;
                opts.after = n;
                opts.before = n;
            } else if (std.mem.startsWith(u8, t, "-m") and t.len > 2) {
                opts.max_match = std.fmt.parseInt(usize, t[2..], 10) catch 0;
            } else {
                if (std.mem.startsWith(u8, t, "--")) {
                    bb.messages.plainMsg("unrecognized option '{s}'", .{t});
                } else {
                    bb.messages.plainMsg("invalid option -- '{c}'", .{t[1]});
                }
                dieUsage(name0);
            }
            continue;
        }
        if (opts.patterns.items.len == 0 and positional_pattern == null) {
            positional_pattern = t;
        } else {
            files.append(A, t) catch {};
        }
    }
    if (positional_pattern) |p| opts.patterns.insert(A, 0, p) catch {};
    if (opts.patterns.items.len == 0) dieUsage(name0);

    var matchers: std.ArrayList(Matcher) = .empty;
    defer {
        for (matchers.items) |*m| m.deinit();
        matchers.deinit(A);
    }
    for (opts.patterns.items) |pat| {
        var m = Matcher{ .ci = opts.flags & F_i != 0 };
        if (opts.flags & F_F != 0) {
            m.fixed = pat;
        } else {
            m.re = regex.compile(A, pat, .{
                .extended = opts.flags & F_E != 0,
                .ignore_case = opts.flags & F_i != 0,
            }) catch {
                bb.messages.plainMsg("invalid regex", .{});
                return 2;
            };
        }
        matchers.append(A, m) catch {};
    }

    if (files.items.len == 0) {
        files.append(A, "-") catch {};
    } else {
        var expanded: std.ArrayList([]const u8) = .empty;
        for (files.items) |f| collectFiles(A, f, opts.flags & (F_r | F_R) != 0, &expanded);
        files = expanded;
    }

    const prefix_mode = opts.flags & F_H != 0 or (opts.flags & F_h == 0 and (files.items.len > 1 or opts.flags & (F_r | F_R) != 0));
    var any_match = false;
    var status: c_int = 0;

    for (files.items) |f| {
        const data = if (std.mem.eql(u8, f, "-"))
            c.readAllFd(A, 0) catch &.{}
        else
            c.readFile(A, f) catch {
                if (opts.flags & F_s == 0) bb.messages.errorMsg(2, "{s}", .{f});
                status = 2;
                continue;
            };
        const prefix: ?[]const u8 = if (prefix_mode and !std.mem.eql(u8, f, "-")) f else null;
        const fres = processLines(matchers.items, data, opts, prefix, stdoutWrite);
        if ((opts.flags & F_L != 0 and !fres.matched) or (opts.flags & F_L == 0 and fres.matched)) any_match = true;
        if (opts.flags & F_l != 0 and fres.matched) {
            if (prefix) |p| c.writeAll(1, p) else c.writeAll(1, f);
            c.writeAll(1, "\n");
        }
        if (opts.flags & F_L != 0 and !fres.matched) {
            if (prefix) |p| c.writeAll(1, p) else c.writeAll(1, f);
            c.writeAll(1, "\n");
        }
        if (opts.flags & F_c != 0) {
            if (prefix) |p| {
                c.writeAll(1, p);
                c.writeAll(1, ":");
            }
            var nb: [32]u8 = undefined;
            c.writeAll(1, std.fmt.bufPrint(&nb, "{d}", .{fres.count}) catch "0");
            c.writeAll(1, "\n");
        }
        if (opts.flags & F_q != 0 and any_match) return 0;
    }
    if (status != 0) return 2;
    return if (any_match) 0 else 1;
}
