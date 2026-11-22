//! Shell executor: expansion, redirections, control flow, pipelines and
//! process management. Works together with state.zig and builtins.zig.

const std = @import("std");
const linux = std.os.linux;
const lx = @import("lexer.zig");
const prs = @import("parser.zig");
const st = @import("state.zig");
const bi = @import("builtins.zig");
const ex = @import("expand.zig");
const job = @import("job.zig");

const Shell = st.Shell;
const Node = prs.Node;

var pending_signal: i32 = 0;
var sh_exit_override: ?u8 = null;

pub export fn execSetExitOverride(code: u8) void {
    sh_exit_override = code;
}

fn signalHandler(sig: linux.SIG) callconv(.c) void {
    pending_signal = @as(i32, @intCast(@intFromEnum(sig)));
}

fn out(s: []const u8) void {
    if (s.len != 0) _ = linux.write(1, s.ptr, s.len);
}

fn errOut(s: []const u8) void {
    if (s.len != 0) _ = linux.write(2, s.ptr, s.len);
}

fn appendTraceWord(a: std.mem.Allocator, list: *std.ArrayList(u8), word: []const u8) !void {
    if (word.len == 0) {
        if (g_trace_hush) {
            try list.appendSlice(a, "''");
        }
        return;
    }
    var safe = true;
    for (word) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '@' or c == ':' or c == '.' or c == '/' or c == '+' or c == '-' or (g_trace_hush and c == '='))) {
            safe = false;
            break;
        }
    }
    if (safe) {
        try list.appendSlice(a, word);
        return;
    }
    try list.append(a, '\'');
    for (word) |c| {
        if (c == '\'') {
            if (g_trace_hush) {
                try list.appendSlice(a, "'\\''");
            } else {
                try list.appendSlice(a, "'\"'\"'");
            }
        } else {
            try list.append(a, c);
        }
    }
    try list.append(a, '\'');
}

const ReplParts = struct { pattern: []const u8, replacement: []const u8 };

fn splitReplacement(a: std.mem.Allocator, raw: []const u8) ReplParts {
    var i: usize = 0;
    var quote: u8 = 0;
    var sep: ?usize = null;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\\' and quote != '\'') {
            i += 1;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '/') {
            sep = i;
            break;
        }
    }
    const pat_raw = if (sep) |p| raw[0..p] else raw;
    const repl_raw = if (sep) |p| raw[p + 1 ..] else "";
    return .{ .pattern = unquoteWord(a, pat_raw), .replacement = repl_raw };
}

fn unquoteWord(a: std.mem.Allocator, raw: []const u8) []const u8 {
    var outl: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            outl.append(a, raw[i]) catch {};
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0 else outl.append(a, c) catch {};
            continue;
        }
        if (c == '\'' or c == '"') quote = c else outl.append(a, c) catch {};
    }
    return outl.toOwnedSlice(a) catch raw;
}

var g_trace_hush: bool = false;

pub const ExpandError = std.mem.Allocator.Error;

pub const Exec = struct {
    sh: *Shell,
    no_glob_depth: usize = 0,
    suppress_nounset: usize = 0,
    expansion_quote: lx.Quote = .none,

    pub fn init(sh: *Shell) Exec {
        return .{ .sh = sh };
    }

    pub fn install(self: *Exec) void {
        self.sh.callbacks = .{
            .ctx = self.sh,
            .evalString = evalCallback,
            .capture = captureCallback,
            .runDirect = runDirectCallback,
            .printHistory = printHistoryCallback,
        };
        const sigs = [_]linux.SIG{ .INT, .TERM, .HUP, .QUIT, .USR1, .USR2 };
        for (sigs) |s| {
            var act: linux.Sigaction = undefined;
            act.handler = .{ .handler = signalHandler };
            act.mask = std.mem.zeroes(linux.sigset_t);
            act.flags = 0;
            _ = linux.sigaction(s, &act, null);
        }
    }

    fn evalCallback(ctx: *anyopaque, text: []const u8) i32 {
        const sh: *Shell = @ptrCast(@alignCast(ctx));
        var e = Exec.init(sh);
        return @intCast(e.runSource(text));
    }

    fn printHistoryCallback(ctx: *anyopaque) void {
        const sh: *Shell = @ptrCast(@alignCast(ctx));
        for (sh.history.items, 1..) |line, i| {
            var b: [4096]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "{d: >6} {s}\n", .{ i, line }) catch "";
            out(m);
        }
    }

    fn runDirectCallback(ctx: *anyopaque, words: []const []const u8) i32 {
        const sh: *Shell = @ptrCast(@alignCast(ctx));
        var e = Exec.init(sh);
        return @intCast(e.runCommandDirect(words));
    }

    fn captureCallback(ctx: *anyopaque, text: []const u8) []const u8 {
        const sh: *Shell = @ptrCast(@alignCast(ctx));
        var e = Exec.init(sh);
        return e.captureOutput(text);
    }

    // ---------------------------------------------------------------- public

    pub fn runSource(self: *Exec, source: []const u8) u8 {
        var lxr = lx.Lexer.init(self.sh.a, source);
        const toks = lxr.lex() catch {
            errOut("Syntax error: unterminated quote\n");
            return 2;
        };
        var p = prs.Parser.init(self.sh.a, source, toks);
        const nodes = p.parseAll() catch {
            var b: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&b, "{s}: line {d}: syntax error: {s}\n", .{
                self.sh.name, self.sh.line_number, p.error_detail orelse "unexpected token",
            }) catch "";
            errOut(msg);
            return 2;
        };
        return self.execList(nodes, false);
    }

    fn execList(self: *Exec, nodes: []*Node, in_condition: bool) u8 {
        var status: u8 = 0;
        for (nodes) |n| {
            status = self.execNode(n, in_condition);
            if (self.sh.exiting or self.sh.return_pending) break;
            if (self.sh.break_count != 0 or self.sh.continue_count != 0) break;
            self.checkSignals();
        }
        return status;
    }

    fn checkSignals(self: *Exec) void {
        const sig = pending_signal;
        if (sig == 0) return;
        pending_signal = 0;
        for (self.sh.traps.items) |t| {
            if (t.signal == sig and t.command.len != 0) {
                _ = self.runSource(t.command);
            }
        }
    }

    fn runExitTraps(self: *Exec) void {
        for (self.sh.traps.items) |t| {
            if (t.signal == 0 and t.command.len != 0) {
                _ = self.runSource(t.command);
            }
        }
    }

    pub fn finish(self: *Exec, code: u8) u8 {
        self.runExitTraps();
        return if (self.sh.exiting) self.sh.exit_code else code;
    }

    fn execNode(self: *Exec, node: *Node, in_condition: bool) u8 {
        if (self.sh.count_lines) self.sh.line_number = node.line -| self.sh.line_base;
        // Compound-command redirections are applied around the whole command.
        var guard: RedirGuard = .{};
        const is_simple = std.meta.activeTag(node.body) == .simple;
        if (node.redirects.len != 0 and !is_simple) {
            guard = self.applyRedirects(node.redirects);
            if (guard.failed) {
                guard.restore();
                self.sh.last_status = 1;
                return 1;
            }
        }
        const status = self.execBody(node, in_condition);
        guard.restore();
        self.sh.last_status = status;
        return status;
    }

    fn execBody(self: *Exec, node: *Node, in_condition: bool) u8 {
        switch (node.body) {
            .sequence => |items| return self.execList(items, in_condition),
            .empty => return 0,
            .simple => |s| return self.execSimple(node, s, in_condition),
            .and_or => |b| {
                const l = self.execNode(b.left, true);
                if (b.op == .andand) {
                    if (l != 0) return l;
                } else {
                    if (l == 0) return l;
                }
                return self.execNode(b.right, in_condition);
            },
            .pipeline => |p| return self.execPipeline(p, in_condition),
            .background => |child| {
                const pid = linux.fork();
                if (linux.errno(pid) != .SUCCESS) return 1;
                if (pid == 0) {
                    const code = self.execNode(child, in_condition);
                    self.runExitTraps();
                    std.process.exit(if (sh_exit_override != null) sh_exit_override.? else code);
                }
                self.sh.last_bg_pid = @intCast(pid);
                self.sh.background_jobs.append(self.sh.a, @intCast(pid)) catch {};
                return 0;
            },
            .subshell => |child| {
                const pid = linux.fork();
                if (linux.errno(pid) != .SUCCESS) return 1;
                if (pid == 0) {
                    const code = self.execNode(child, in_condition);
                    self.runExitTraps();
                    std.process.exit(if (sh_exit_override != null) sh_exit_override.? else code);
                }
                var status: i32 = 0;
                _ = linux.waitpid(@intCast(pid), &status, 0);
                return @intCast((status >> 8) & 0xff);
            },
            .group => |child| return self.execNode(child, in_condition),
            .if_stmt => |s| {
                for (s.arms) |arm| {
                    const c = self.execNode(arm.cond, true);
                    if (c == 0) return self.execNode(arm.body, in_condition);
                }
                if (s.else_body) |e| return self.execNode(e, in_condition);
                return 0;
            },
            .while_stmt => |lp| return self.execLoop(lp, false, in_condition),
            .until_stmt => |lp| return self.execLoop(lp, true, in_condition),
            .for_stmt => |fp| return self.execFor(fp, in_condition),
            .case_stmt => |cs| return self.execCase(cs, in_condition),
            .func_def => |fd| {
                self.sh.setFunc(fd.name, fd.body) catch {};
                return 0;
            },
            .arith_cmd => |text| {
                const v = bi.evalArith(self.sh, text) catch return 1;
                return if (v != 0) 0 else 1;
            },
        }
    }

    fn execLoop(self: *Exec, lp: prs.Loop, until: bool, in_condition: bool) u8 {
        self.sh.loop_depth += 1;
        defer self.sh.loop_depth -= 1;
        var status: u8 = 0;
        while (true) {
            var cond = self.execNode(lp.cond, true);
            if (until) cond = if (cond == 0) 1 else 0;
            if (cond != 0) break;
            status = self.execNode(lp.body, in_condition);
            if (self.sh.exiting or self.sh.return_pending) break;
            if (self.sh.break_count != 0) {
                self.sh.break_count -= 1;
                break;
            }
            if (self.sh.continue_count != 0) {
                self.sh.continue_count -= 1;
                continue;
            }
        }
        return status;
    }

    fn execFor(self: *Exec, fp: prs.ForStmt, in_condition: bool) u8 {
        self.sh.loop_depth += 1;
        defer self.sh.loop_depth -= 1;
        var values: std.ArrayList([]const u8) = .empty;
        for (fp.words) |w| {
            const fields = self.expandWord(w, true) catch continue;
            for (fields) |f| values.append(self.sh.a, f) catch {};
        }
        if (fp.words.len == 0) {
            for (self.sh.positionals.items) |p| values.append(self.sh.a, p) catch {};
        }
        var status: u8 = 0;
        for (values.items) |v| {
            self.sh.set(fp.name, v) catch {};
            status = self.execNode(fp.body, in_condition);
            if (self.sh.exiting or self.sh.return_pending) break;
            if (self.sh.break_count != 0) {
                self.sh.break_count -= 1;
                break;
            }
            if (self.sh.continue_count != 0) {
                self.sh.continue_count -= 1;
                continue;
            }
        }
        return status;
    }

    fn execCase(self: *Exec, cs: prs.CaseStmt, in_condition: bool) u8 {
        const fields = self.expandWord(cs.word, false) catch return 1;
        const value = if (fields.len != 0) fields[0] else "";
        for (cs.arms) |arm| {
            for (arm.patterns) |patw| {
                self.no_glob_depth += 1;
                const pf = self.expandWord(patw, false) catch {
                    self.no_glob_depth -= 1;
                    continue;
                };
                const pat_chars = self.wordToChars(patw) catch {
                    self.no_glob_depth -= 1;
                    continue;
                };
                self.no_glob_depth -= 1;
                _ = pf;
                var effective_buf: std.ArrayList(u8) = .empty;
                for (pat_chars) |ch| {
                    if (ch.c == 0x1f) continue;
                    if (!ch.glob and (ch.c == '*' or ch.c == '?' or ch.c == '[')) {
                        effective_buf.append(self.sh.a, '\\') catch {};
                    }
                    effective_buf.append(self.sh.a, ch.c) catch {};
                }
                const effective = effective_buf.items;
                if (ex.patternMatch(effective, value)) {
                    return self.execNode(arm.body, in_condition);
                }
            }
        }
        return 0;
    }

    // ---------------------------------------------------------- simple cmds

    fn execSimple(self: *Exec, node: *Node, s: prs.Simple, in_condition: bool) u8 {
        // Assignment prefixes are applied to a temporary snapshot; for a
        // command without a word they become permanent shell assignments.
        if (s.words.len == 0) {
            if (node.redirects.len != 0) {
                var aguard = self.applyRedirects(node.redirects);
                const astatus: u8 = if (aguard.failed) 1 else 0;
                for (s.assigns) |asg| self.applyAssign(asg, false);
                aguard.restore();
                self.sh.last_status = astatus;
                return astatus;
            }
            for (s.assigns) |asg| self.applyAssign(asg, false);
            return 0;
        }
        const saved = self.snapshotAssigns(s.assigns);
        for (s.assigns) |asg| self.applyAssign(asg, true);

        var words: std.ArrayList([]const u8) = .empty;
        for (s.words) |w| {
            const fields = self.expandWord(w, true) catch {
                words.append(self.sh.a, "") catch {};
                continue;
            };
            for (fields) |f| words.append(self.sh.a, f) catch {};
        }
        if (self.sh.exiting) {
            self.restoreAssigns(saved);
            return self.sh.exit_code;
        }
        if (self.sh.opts.noexec) {
            self.restoreAssigns(saved);
            return 0;
        }
        var status: u8 = 0;
        if (words.items.len == 0) {
            status = 0;
        } else {
            // alias expansion on the first word
            if (self.sh.opts.interactive and self.sh.getAlias(words.items[0]) != null) {
                const expansion = self.sh.getAlias(words.items[0]).?;
                var joined: std.ArrayList(u8) = .empty;
                joined.appendSlice(self.sh.a, expansion) catch {};
                for (words.items[1..]) |w| {
                    joined.append(self.sh.a, ' ') catch {};
                    joined.appendSlice(self.sh.a, w) catch {};
                }
                status = self.runSource(joined.items);
            } else {
        if (self.sh.opts.xtrace) {
            g_trace_hush = self.sh.hush;
            var line: std.ArrayList(u8) = .empty;
            line.append(self.sh.a, '+') catch {};
            for (words.items) |w| {
                line.append(self.sh.a, ' ') catch {};
                appendTraceWord(self.sh.a, &line, w) catch {};
            }
            line.append(self.sh.a, '\n') catch {};
            errOut(line.items);
        }
                var rguard: RedirGuard = .{};
                if (node.redirects.len != 0) {
                    rguard = self.applyRedirects(node.redirects);
                    if (rguard.failed) status = 1 else status = self.runCommand(words.items, s.assigns, in_condition);
                    if (words.items[0].len == 0 or !std.mem.eql(u8, words.items[0], "exec")) rguard.restore();
                } else {
                    status = self.runCommand(words.items, s.assigns, in_condition);
                }
            }
        }
        if (!self.sh.legacy_persist_assigns) self.restoreAssigns(saved);
        if (self.sh.opts.errexit and !in_condition and self.sh.suppress_errexit == 0 and status != 0) {
            self.sh.exiting = true;
            self.sh.exit_code = status;
        }
        self.sh.last_status = status;
        return status;
    }

    const SavedAssign = struct { name: []const u8, had: bool, value: []const u8, exported: bool };

    fn snapshotAssigns(self: *Exec, assigns: []const prs.Assignment) []SavedAssign {
        const list = self.sh.a.alloc(SavedAssign, assigns.len) catch return &.{};
        for (assigns, 0..) |asg, i| {
            if (self.sh.getVar(asg.name)) |v| {
                list[i] = .{ .name = asg.name, .had = true, .value = v.value, .exported = v.exported };
            } else {
                list[i] = .{ .name = asg.name, .had = false, .value = "", .exported = false };
            }
        }
        return list;
    }

    fn restoreAssigns(self: *Exec, saved: []const SavedAssign) void {
        for (saved) |s| {
            if (s.had) {
                self.sh.set(s.name, s.value) catch {};
            } else {
                _ = self.sh.unset(s.name);
            }
        }
    }

    fn applyAssign(self: *Exec, asg: prs.Assignment, temporary: bool) void {
        self.no_glob_depth += 1;
        defer self.no_glob_depth -= 1;
        const fields = self.expandWord(asg.value, false) catch return;
        var val: []const u8 = if (fields.len != 0) fields[0] else "";
        _ = temporary;
        if (asg.append) {
            const old = self.sh.get(asg.name) orelse "";
            val = std.fmt.allocPrint(self.sh.a, "{s}{s}", .{ old, val }) catch val;
        }
        self.sh.last_set_error = null;
        self.sh.set(asg.name, val) catch {};
        if (self.sh.last_set_error) |_| {
            var b: [256]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "{s}: line {d}: {s}: is read only\n", .{ self.sh.name, self.sh.line_number, asg.name }) catch "";
            errOut(m);
            self.sh.last_set_error = null;
            self.sh.exiting = true;
            self.sh.exit_code = 2;
        }
    }

    fn runCommand(self: *Exec, words: []const []const u8, assigns: []const prs.Assignment, in_condition: bool) u8 {
        const name = words[0];
        // functions take precedence over builtins
        if (self.sh.findFunc(name)) |body| {
            return self.callFunction(body, words[1..], assigns);
        }
        if (bi.run(self.sh, name, words[1..]) catch null) |code| {
            return code;
        }
        _ = in_condition;
        return self.runExternal(words, assigns);
    }

    fn runCommandDirect(self: *Exec, words: []const []const u8) u8 {
        if (words.len == 0) return 0;
        if (bi.run(self.sh, words[0], words[1..]) catch null) |code| return code;
        return self.runExternal(words, &.{});
    }

    fn callFunction(self: *Exec, body: *Node, args: []const []const u8, assigns: []const prs.Assignment) u8 {
        var saved: std.ArrayList([]const u8) = .empty;
        saved.appendSlice(self.sh.a, self.sh.positionals.items) catch {};
        self.sh.positionals.clearRetainingCapacity();
        for (args) |a| self.sh.positionals.append(self.sh.a, a) catch {};
        self.sh.pushScope() catch {};
        self.sh.func_depth += 1;
        defer {
            self.sh.func_depth -= 1;
            self.sh.popScope();
            self.sh.positionals = saved;
            self.sh.return_pending = false;
        }
        // command-scoped assignments are visible in the function
        for (assigns) |asg| self.applyAssign(asg, false);
        const code = self.execNode(body, false);
        if (self.sh.return_pending) {
            const rc = self.sh.last_status;
            self.sh.return_pending = false;
            return rc;
        }
        return code;
    }

    fn runExternal(self: *Exec, words: []const []const u8, assigns: []const prs.Assignment) u8 {
        const path = bi.findProgram(self.sh, words[0]) orelse {
            var b: [512]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "{s}: line {d}: {s}: not found\n", .{ self.sh.name, self.sh.line_number, words[0] }) catch "";
            errOut(m);
            return 127;
        };
        var hashed = false;
        for (self.sh.hashes.items) |h| {
            if (std.mem.eql(u8, h.name, words[0])) hashed = true;
        }
        if (!hashed) {
            self.sh.hashes.append(self.sh.a, .{
                .name = self.sh.a.dupe(u8, words[0]) catch words[0],
                .path = self.sh.a.dupe(u8, path) catch path,
            }) catch {};
        }
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return 1;
        if (pid == 0) {
            const argv = self.sh.a.allocSentinel(?[*:0]const u8, words.len, null) catch std.process.exit(1);
            for (words, 0..) |w, i| {
                argv[i] = (std.mem.concatWithSentinel(self.sh.a, u8, &.{w}, 0) catch std.process.exit(1)).ptr;
            }
            var count: usize = 0;
            for (self.sh.vars.items) |v| if (v.exported) {
                count += 1;
            };
            count += assigns.len;
            const envp = self.sh.a.allocSentinel(?[*:0]const u8, count, null) catch std.process.exit(1);
            var k: usize = 0;
            for (self.sh.vars.items) |v| {
                if (!v.exported) continue;
                envp[k] = (std.fmt.allocPrintSentinel(self.sh.a, "{s}={s}", .{ v.name, v.value }, 0) catch std.process.exit(1)).ptr;
                k += 1;
            }
            for (assigns) |asg| {
                self.no_glob_depth += 1;
                const fields = self.expandWord(asg.value, false) catch {
                    self.no_glob_depth -= 1;
                    continue;
                };
                self.no_glob_depth -= 1;
                envp[k] = (std.fmt.allocPrintSentinel(self.sh.a, "{s}={s}", .{ asg.name, if (fields.len != 0) fields[0] else "" }, 0) catch std.process.exit(1)).ptr;
                k += 1;
            }
            const p = std.mem.concatWithSentinel(self.sh.a, u8, &.{path}, 0) catch std.process.exit(1);
            _ = linux.execve(p.ptr, argv.ptr, envp.ptr);
            std.process.exit(127);
        }
        return job.wait(@intCast(pid));
    }

    // -------------------------------------------------------------- pipeline

    fn execPipeline(self: *Exec, pl: prs.Pipeline, in_condition: bool) u8 {
        const n = pl.stages.len;
        if (n == 0) return 0;
        if (n == 1 and !pl.negate) return self.execNode(pl.stages[0], in_condition);
        var pipes: [64][2]i32 = undefined;
        const count = @min(n - 1, pipes.len);
        for (0..count) |i| {
            if (linux.errno(linux.pipe2(&pipes[i], .{})) != .SUCCESS) return 1;
        }
        var pids: [64]i32 = undefined;
        var launched: usize = 0;
        for (0..n) |i| {
            const pid = linux.fork();
            if (linux.errno(pid) != .SUCCESS) break;
            if (pid == 0) {
                if (i > 0 and i - 1 < count) {
                    _ = linux.dup2(pipes[i - 1][0], 0);
                }
                if (i < count) {
                    _ = linux.dup2(pipes[i][1], 1);
                }
                for (0..count) |k| {
                    _ = linux.close(pipes[k][0]);
                    _ = linux.close(pipes[k][1]);
                }
                const code = self.execNode(pl.stages[i], in_condition);
                std.process.exit(code);
            }
            pids[launched] = @intCast(pid);
            launched += 1;
        }
        for (0..count) |k| {
            _ = linux.close(pipes[k][0]);
            _ = linux.close(pipes[k][1]);
        }
        var statuses: [64]u8 = std.mem.zeroes([64]u8);
        var j: usize = 0;
        while (j < launched) : (j += 1) {
            statuses[j] = job.wait(pids[j]);
        }
        var result: u8 = if (launched != 0) statuses[launched - 1] else 1;
        if (self.sh.opts.pipefail) {
            for (statuses[0..launched]) |s| if (s != 0) {
                result = s;
            };
        }
        if (pl.negate) result = if (result == 0) 1 else 0;
        return result;
    }

    // ---------------------------------------------------------- redirections

    const SavedFd = struct { target: u8, saved: i32 };
    const RedirGuard = struct {
        saved: [32]SavedFd = undefined,
        n: usize = 0,
        failed: bool = false,

        fn restore(self: *RedirGuard) void {
            var i = self.n;
            while (i > 0) {
                i -= 1;
                const s = self.saved[i];
                if (s.saved >= 0) {
                    _ = linux.dup2(s.saved, s.target);
                    _ = linux.close(s.saved);
                } else {
                    _ = linux.close(s.target);
                }
            }
        }
    };

    fn applyRedirects(self: *Exec, redirs: []const prs.Redir) RedirGuard {
        var g: RedirGuard = .{};
        for (redirs) |r| {
            self.no_glob_depth += 1;
            const target_fields = self.expandWord(r.target, false) catch {
                self.no_glob_depth -= 1;
                g.failed = true;
                return g;
            };
            self.no_glob_depth -= 1;
            const target = if (target_fields.len != 0) target_fields[0] else "";
            if (g.n < g.saved.len) {
                const sv = linux.fcntl(r.io, linux.F.DUPFD_CLOEXEC, 10);
                const saved_fd: i32 = if (linux.errno(sv) == .SUCCESS) @intCast(sv) else -1;
                g.saved[g.n] = .{ .target = r.io, .saved = saved_fd };
                g.n += 1;
            }
            switch (r.op) {
                .lt => {
                    const z = std.mem.concatWithSentinel(self.sh.a, u8, &.{target}, 0) catch {
                        g.failed = true;
                        return g;
                    };
                    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
                    if (linux.errno(fd) != .SUCCESS) {
                        self.reportRedirError(r.op, target, linux.errno(fd));
                        g.failed = true;
                        return g;
                    }
                    _ = linux.dup2(@intCast(fd), r.io);
                    _ = linux.close(@intCast(fd));
                },
                .gt, .gtbar => {
                    var flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
                    if (self.sh.opts.noclobber and r.op == .gt) flags.EXCL = true;
                    const z = std.mem.concatWithSentinel(self.sh.a, u8, &.{target}, 0) catch {
                        g.failed = true;
                        return g;
                    };
                    const fd = linux.open(z.ptr, flags, 0o666);
                    if (linux.errno(fd) != .SUCCESS) {
                        self.reportRedirError(r.op, target, linux.errno(fd));
                        g.failed = true;
                        return g;
                    }
                    _ = linux.dup2(@intCast(fd), r.io);
                    _ = linux.close(@intCast(fd));
                },
                .dgt => {
                    const z = std.mem.concatWithSentinel(self.sh.a, u8, &.{target}, 0) catch {
                        g.failed = true;
                        return g;
                    };
                    const fd = linux.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o666);
                    if (linux.errno(fd) != .SUCCESS) {
                        self.reportRedirError(r.op, target, linux.errno(fd));
                        g.failed = true;
                        return g;
                    }
                    _ = linux.dup2(@intCast(fd), r.io);
                    _ = linux.close(@intCast(fd));
                },
                .ltgt => {
                    const z = std.mem.concatWithSentinel(self.sh.a, u8, &.{target}, 0) catch {
                        g.failed = true;
                        return g;
                    };
                    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o666);
                    if (linux.errno(fd) != .SUCCESS) {
                        self.reportRedirError(r.op, target, linux.errno(fd));
                        g.failed = true;
                        return g;
                    }
                    _ = linux.dup2(@intCast(fd), r.io);
                    _ = linux.close(@intCast(fd));
                },
                .lt_and, .gt_and => {
                    if (std.mem.eql(u8, target, "-")) {
                        _ = linux.close(r.io);
                    } else {
                        const fd = std.fmt.parseInt(i32, target, 10) catch 0;
                        if (fd >= 0) _ = linux.dup2(fd, r.io);
                    }
                },
                .dlt, .dltdash, .tlt => {
                    var body = if (r.op == .tlt) (if (target_fields.len != 0) target_fields[0] else "") else (r.body orelse "");
                    if (!r.quoted) body = self.expandHereDoc(body);
                    if (r.op == .tlt) {
                        body = std.fmt.allocPrint(self.sh.a, "{s}\n", .{body}) catch body;
                    }
                    const mname = std.mem.concatWithSentinel(self.sh.a, u8, &.{"heredoc"}, 0) catch {
                        g.failed = true;
                        return g;
                    };
                    const mfd = linux.memfd_create(mname.ptr, 0);
                    if (linux.errno(mfd) != .SUCCESS) {
                        g.failed = true;
                        return g;
                    }
                    const fd: i32 = @intCast(mfd);
                    var written: usize = 0;
                    while (written < body.len) {
                        const nw = linux.write(fd, body[written..].ptr, body.len - written);
                        if (linux.errno(nw) != .SUCCESS or nw == 0) break;
                        written += nw;
                    }
                    _ = linux.lseek(fd, 0, 0);
                    _ = linux.dup2(fd, r.io);
                    _ = linux.close(fd);
                },
                .amp_gt, .amp_dgt => {
                    if (g.n < g.saved.len) {
                        const sv1 = linux.fcntl(1, linux.F.DUPFD_CLOEXEC, 10);
                        const sf1: i32 = if (linux.errno(sv1) == .SUCCESS) @intCast(sv1) else -1;
                        g.saved[g.n] = .{ .target = 1, .saved = sf1 };
                        g.n += 1;
                    }
                    if (g.n < g.saved.len) {
                        const sv2 = linux.fcntl(2, linux.F.DUPFD_CLOEXEC, 10);
                        const sf2: i32 = if (linux.errno(sv2) == .SUCCESS) @intCast(sv2) else -1;
                        g.saved[g.n] = .{ .target = 2, .saved = sf2 };
                        g.n += 1;
                    }
                    const z = std.mem.concatWithSentinel(self.sh.a, u8, &.{target}, 0) catch {
                        g.failed = true;
                        return g;
                    };
                    var flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
                    if (r.op == .amp_dgt) {
                        flags.TRUNC = false;
                        flags.APPEND = true;
                    }
                    const fd = linux.open(z.ptr, flags, 0o666);
                    if (linux.errno(fd) != .SUCCESS) {
                        self.reportRedirError(r.op, target, linux.errno(fd));
                        g.failed = true;
                        return g;
                    }
                    _ = linux.dup2(@intCast(fd), 1);
                    _ = linux.dup2(@intCast(fd), 2);
                    _ = linux.close(@intCast(fd));
                },
            }
        }
        return g;
    }

    fn reportRedirError(self: *Exec, op: lx.RedirOp, target: []const u8, e: linux.E) void {
        var b: [512]u8 = undefined;
        const detail: []const u8 = switch (e) {
            .NOENT => "no such file",
            .ACCES => "Permission denied",
            .ISDIR => "Is a directory",
            else => "Input/output error",
        };
        const verb: []const u8 = if (e == .NOENT and (op == .gt or op == .dgt or op == .gtbar or op == .amp_gt or op == .amp_dgt or op == .ltgt)) "nonexistent directory" else detail;
        const action: []const u8 = if (op == .lt) "can't open" else "can't create";
        const m = std.fmt.bufPrint(&b, "{s}: line {d}: {s} {s}: {s}\n", .{ self.sh.name, self.sh.line_number, action, target, verb }) catch "";
        errOut(m);
    }

    // -------------------------------------------------------------- expansion

    const EChar = struct { c: u8, splittable: bool, glob: bool };

    fn expandWord(self: *Exec, w: lx.Word, allow_split: bool) ExpandError![][]const u8 {
        const chars = try self.wordToChars(w);
        // $@ inserts field separators before quote removal.
        var raw_fields: std.ArrayList([]EChar) = .empty;
        var cur_chars: std.ArrayList(EChar) = .empty;
        for (chars) |ch| {
            if (ch.c == 0x1f and !ch.glob) {
                try raw_fields.append(self.sh.a, try cur_chars.toOwnedSlice(self.sh.a));
                cur_chars = .empty;
                continue;
            }
            try cur_chars.append(self.sh.a, ch);
        }
        try raw_fields.append(self.sh.a, try cur_chars.toOwnedSlice(self.sh.a));

        var fields: std.ArrayList([]const u8) = .empty;
        var active: std.ArrayList([]bool) = .empty;
        const ifs = self.sh.get("IFS") orelse " \t\n";
        for (raw_fields.items) |rf| {
            var seg: std.ArrayList(EChar) = .empty;
            var last_nonspace = false;
            const flushSeg = struct {
                fn f(slf: *Exec, ac: *std.ArrayList(EChar), fl: *std.ArrayList([]const u8), act: *std.ArrayList([]bool)) !void {
                    var text: std.ArrayList(u8) = .empty;
                    var flags: std.ArrayList(bool) = .empty;
                    for (ac.items) |ch| {
                        try text.append(slf.sh.a, ch.c);
                        try flags.append(slf.sh.a, ch.glob);
                    }
                    try fl.append(slf.sh.a, try text.toOwnedSlice(slf.sh.a));
                    try act.append(slf.sh.a, try flags.toOwnedSlice(slf.sh.a));
                    ac.clearRetainingCapacity();
                }
            }.f;
            if (allow_split) {
                var had_delim = false;
                for (rf) |ch| {
                    const is_delim = ch.splittable and std.mem.indexOfScalar(u8, ifs, ch.c) != null;
                    if (is_delim) {
                        const ws = ch.c == ' ' or ch.c == '\t' or ch.c == '\n';
                        if (seg.items.len != 0 or !ws) try flushSeg(self, &seg, &fields, &active);
                        last_nonspace = !ws;
                        had_delim = true;
                    } else {
                        try seg.append(self.sh.a, ch);
                        last_nonspace = false;
                    }
                }
                if (seg.items.len != 0 or last_nonspace or !had_delim) try flushSeg(self, &seg, &fields, &active);
            } else {
                try seg.appendSlice(self.sh.a, rf);
                try flushSeg(self, &seg, &fields, &active);
            }
        }

        if (!self.sh.opts.noglob and self.no_glob_depth == 0) {
            var globbed: std.ArrayList([]const u8) = .empty;
            for (fields.items, 0..) |f, fi| {
                var has_glob = false;
                for (active.items[fi]) |a| {
                    if (a) has_glob = true;
                }
                if (!has_glob) {
                    try globbed.append(self.sh.a, f);
                    continue;
                }
                const expanded = self.globField(f, active.items[fi]) catch {
                    try globbed.append(self.sh.a, f);
                    continue;
                };
                if (expanded.len != 0) {
                    for (expanded) |e| try globbed.append(self.sh.a, e);
                } else {
                    try globbed.append(self.sh.a, f);
                }
            }
            fields = globbed;
        }
        return fields.toOwnedSlice(self.sh.a);
    }

    fn expandToString(self: *Exec, w: lx.Word) ExpandError![]u8 {
        const fields = try self.expandWord(w, false);
        if (fields.len == 0) return "";
        var result: std.ArrayList(u8) = .empty;
        for (fields, 0..) |f, i| {
            if (i != 0) try result.append(self.sh.a, ' ');
            try result.appendSlice(self.sh.a, f);
        }
        return result.toOwnedSlice(self.sh.a);
    }

    fn charsFromString(text: []const u8, split: bool, glob: bool) ExpandError![]EChar {
        var chars: std.ArrayList(EChar) = .empty;
        for (text) |c| try chars.append(std.heap.page_allocator, .{ .c = c, .splittable = split, .glob = glob });
        return chars.toOwnedSlice(std.heap.page_allocator);
    }

    fn appendSegment(self: *Exec, chars: *std.ArrayList(EChar), seg: lx.Segment) ExpandError!void {
        switch (seg.kind) {
            .literal => {
                for (seg.text) |c| try chars.append(self.sh.a, .{ .c = c, .splittable = false, .glob = seg.quote == .none });
            },
            .variable => {
                const saved_quote = self.expansion_quote;
                self.expansion_quote = seg.quote;
                defer self.expansion_quote = saved_quote;
                const sub = try self.expandParameter(seg.text);
                const quoted = seg.quote != .none;
                for (sub) |ch| {
                    try chars.append(self.sh.a, .{
                        .c = ch.c,
                        .splittable = ch.splittable and !quoted,
                        .glob = ch.glob and !quoted,
                    });
                }
            },
            .command_sub => {
                const text = self.captureOutput(seg.text);
                defer self.sh.a.free(text);
                for (text) |c| try chars.append(self.sh.a, .{ .c = c, .splittable = seg.quote == .none, .glob = seg.quote == .none });
            },
            .arith => {
                const v = bi.evalArith(self.sh, seg.text) catch 0;
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0";
                for (text) |c| try chars.append(self.sh.a, .{ .c = c, .splittable = seg.quote == .none, .glob = seg.quote == .none });
            },
        }
    }

    /// Expand a word into flagged characters, preserving each nested word's
    /// quote context so field splitting can honour quotes inside ${...}.
    fn wordToChars(self: *Exec, w: lx.Word) ExpandError![]EChar {
        var chars: std.ArrayList(EChar) = .empty;
        var first = true;
        for (w.segs) |seg| {
            if (seg.kind == .literal and seg.quote == .none and first and seg.text.len != 0 and seg.text[0] == '~') {
                const home = self.sh.get("HOME") orelse "";
                for (home) |c| try chars.append(self.sh.a, .{ .c = c, .splittable = false, .glob = false });
                for (seg.text[1..]) |c| try chars.append(self.sh.a, .{ .c = c, .splittable = false, .glob = false });
                first = false;
                continue;
            }
            if (seg.text.len != 0 or seg.kind != .literal) first = false;
            try self.appendSegment(&chars, seg);
        }
        return chars.toOwnedSlice(self.sh.a);
    }

    fn expandParameter(self: *Exec, spec: []const u8) ExpandError![]EChar {
        if (spec.len == 0) return &.{};
        return self.expandBraced(spec);
    }

    fn paramValue(self: *Exec, name: []const u8) []const u8 {
        const a = self.sh.a;
        if (std.mem.eql(u8, name, "@")) {
            var r: std.ArrayList(u8) = .empty;
            for (self.sh.positionals.items, 0..) |p, i| {
                if (i != 0) r.append(a, 0x1f) catch {};
                r.appendSlice(a, p) catch {};
            }
            return r.toOwnedSlice(a) catch "";
        }
        if (std.mem.eql(u8, name, "*")) {
            var r: std.ArrayList(u8) = .empty;
            const sep = if (self.sh.get("IFS")) |ifs| (if (ifs.len != 0) ifs[0..1] else "") else " ";
            for (self.sh.positionals.items, 0..) |p, i| {
                if (i != 0) r.appendSlice(a, sep) catch {};
                r.appendSlice(a, p) catch {};
            }
            return r.toOwnedSlice(a) catch "";
        }
        if (std.mem.eql(u8, name, "#")) return std.fmt.allocPrint(a, "{d}", .{self.sh.positionals.items.len}) catch "";
        if (std.mem.eql(u8, name, "?")) return std.fmt.allocPrint(a, "{d}", .{self.sh.last_status}) catch "";
        if (std.mem.eql(u8, name, "$")) return std.fmt.allocPrint(a, "{d}", .{linux.getpid()}) catch "";
        if (std.mem.eql(u8, name, "!")) return std.fmt.allocPrint(a, "{d}", .{self.sh.last_bg_pid}) catch "";
        if (std.mem.eql(u8, name, "-")) {
            var r: std.ArrayList(u8) = .empty;
            if (self.sh.opts.errexit) r.append(a, 'e') catch {};
            if (self.sh.opts.nounset) r.append(a, 'u') catch {};
            if (self.sh.opts.xtrace) r.append(a, 'x') catch {};
            if (self.sh.opts.noglob) r.append(a, 'f') catch {};
            if (self.sh.opts.interactive) r.append(a, 'i') catch {};
            return r.toOwnedSlice(a) catch "";
        }
        if (name.len == 1 and name[0] >= '0' and name[0] <= '9') {
            const idx = name[0] - '0';
            if (idx == 0) return a.dupe(u8, self.sh.name) catch "";
            if (idx <= self.sh.positionals.items.len) return a.dupe(u8, self.sh.positionals.items[idx - 1]) catch "";
            return "";
        }
        if (std.mem.eql(u8, name, "LINENO")) return std.fmt.allocPrint(a, "{d}", .{self.sh.line_number}) catch "";
        if (self.sh.get(name)) |v| return a.dupe(u8, v) catch "";
        if (self.sh.opts.nounset and !self.sh.opts.interactive and self.suppress_nounset == 0) {
            var b: [256]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "{s}: {s}: parameter not set\n", .{ self.sh.name, name }) catch "";
            errOut(m);
            self.sh.exiting = true;
            self.sh.exit_code = 1;
        }
        return "";
    }

    fn expandBraced(self: *Exec, spec: []const u8) ExpandError![]EChar {
        if (spec.len == 0) return &.{};
        if (spec[0] == '#' and spec.len > 1) {
            const val = self.paramValue(spec[1..]);
            const text = std.fmt.allocPrint(self.sh.a, "{d}", .{val.len}) catch "0";
            return charsFromString(text, true, true);
        }
        var nend: usize = 0;
        if ((spec[0] >= '0' and spec[0] <= '9') or spec[0] == '?' or spec[0] == '$' or
            spec[0] == '#' or spec[0] == '!' or spec[0] == '@' or spec[0] == '*' or spec[0] == '-')
        {
            nend = 1;
        } else {
            while (nend < spec.len and (std.ascii.isAlphanumeric(spec[nend]) or spec[nend] == '_')) nend += 1;
        }
        const name = spec[0..nend];
        const rest = spec[nend..];
        const is_special = name.len == 1 and std.mem.indexOfScalar(u8, "$#?!@*-", name[0]) != null;
        const name_set = if (name.len == 1 and std.ascii.isDigit(name[0]))
            (name[0] == '0' or @as(usize, name[0] - '1') < self.sh.positionals.items.len)
        else
            (is_special or self.sh.isSet(name));
        const has_default = rest.len != 0 and (rest[0] == '-' or rest[0] == '+' or rest[0] == '=' or rest[0] == '?' or (rest[0] == ':' and rest.len > 1));
        if (has_default) self.suppress_nounset += 1;
        const value = self.paramValue(name);
        if (has_default) self.suppress_nounset -= 1;

        const ops2 = [_][]const u8{ ":=", ":-", ":?", ":+", "##", "%%", "//" };
        if (rest.len >= 2) {
            for (ops2) |op| {
                if (std.mem.startsWith(u8, rest, op)) {
                    return self.braceOp(name, value, name_set, op, rest[2..]);
                }
            }
        }
        if (rest.len >= 1) {
            switch (rest[0]) {
                '=', '-', '?', '+', '#', '%', '/' => return self.braceOp(name, value, name_set, rest[0..1], rest[1..]),
                ':' => {
                    const text = self.substring(value, rest[1..]) catch "";
                    return charsFromString(text, true, true);
                },
                else => {},
            }
        }
        return charsFromString(value, true, true);
    }

    fn flattenChars(self: *Exec, chars: []const EChar) ExpandError![]u8 {
        var result: std.ArrayList(u8) = .empty;
        for (chars) |ch| try result.append(self.sh.a, ch.c);
        return result.toOwnedSlice(self.sh.a);
    }

    fn braceOp(self: *Exec, name: []const u8, value: []const u8, is_set: bool, op: []const u8, word: []const u8) ExpandError![]EChar {
        const a = self.sh.a;
        const set = is_set;
        const colon = op.len == 2;
        const value_chars = try charsFromString(value, true, true);
        if (std.mem.eql(u8, op, ":-") or std.mem.eql(u8, op, "-")) {
            if ((!colon and set) or (colon and value.len != 0)) return value_chars;
            return self.expandWordToChars(word);
        }
        if (std.mem.eql(u8, op, ":=") or std.mem.eql(u8, op, "=")) {
            if ((!colon and set) or (colon and value.len != 0)) return value_chars;
            const chars = try self.expandWordToChars(word);
            self.sh.set(name, try self.flattenChars(chars)) catch {};
            return chars;
        }
        if (std.mem.eql(u8, op, ":?") or std.mem.eql(u8, op, "?")) {
            if ((!colon and set) or (colon and value.len != 0)) return value_chars;
            const chars = try self.expandWordToChars(word);
            const m = try self.flattenChars(chars);
            var b: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&b, "{s}: line {d}: {s}: {s}\n", .{ self.sh.name, self.sh.line_number, name, if (m.len != 0) m else "parameter null or not set" }) catch "";
            errOut(msg);
            self.sh.exiting = true;
            self.sh.exit_code = 2;
            return &.{};
        }
        if (std.mem.eql(u8, op, ":+") or std.mem.eql(u8, op, "+")) {
            if ((!colon and set) or (colon and value.len != 0)) return self.expandWordToChars(word);
            return &.{};
        }
        if (std.mem.eql(u8, op, "#") or std.mem.eql(u8, op, "##")) {
            const pattern = try self.expandWordText(word);
            const longest = op.len == 2;
            var best: usize = if (longest) 0 else value.len;
            var p: usize = 0;
            while (p <= value.len) : (p += 1) {
                if (ex.patternMatch(pattern, value[0..p])) {
                    if (longest) {
                        if (p >= best) best = p;
                    } else {
                        if (p <= best) best = p;
                    }
                }
            }
            return charsFromString(value[best..], true, true);
        }
        if (std.mem.eql(u8, op, "%") or std.mem.eql(u8, op, "%%")) {
            const pattern = try self.expandWordText(word);
            const longest = op.len == 2;
            var best: usize = if (longest) value.len else 0;
            var p: usize = 0;
            while (p <= value.len) : (p += 1) {
                if (ex.patternMatch(pattern, value[p..])) {
                    if (longest) {
                        if (p <= best) best = p;
                    } else {
                        if (p >= best) best = p;
                    }
                }
            }
            return charsFromString(value[0..best], true, true);
        }
        if (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "//")) {
            const parts = splitReplacement(self.sh.a, word);
            const patt = parts.pattern;
            const repl = parts.replacement;
            const pattern = try self.expandWordText(patt);
            const replacement_chars = try self.expandWordToChars(repl);
            const replacement = try self.flattenChars(replacement_chars);
            if (pattern.len == 0) return value_chars;
            var result: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            var replaced_once = false;
            while (i < value.len) {
                var found: usize = 0;
                var k: usize = i;
                while (k <= value.len) : (k += 1) {
                    if (ex.patternMatch(pattern, value[i..k])) found = k - i;
                }
                if (found != 0) {
                    result.appendSlice(a, replacement) catch {};
                    i += found;
                    replaced_once = true;
                    if (op.len == 1) {
                        result.appendSlice(a, value[i..]) catch {};
                        break;
                    }
                } else {
                    result.append(a, value[i]) catch {};
                    i += 1;
                }
            }
            if (!replaced_once) return value_chars;
            return charsFromString(result.items, true, true);
        }
        return value_chars;
    }

    fn substring(self: *Exec, value: []const u8, spec: []const u8) ExpandError![]const u8 {
        var it = std.mem.splitScalar(u8, spec, ':');
        const off_text = it.next() orelse "0";
        const len_text: ?[]const u8 = it.next();
        var off = bi.evalArith(self.sh, off_text) catch 0;
        if (off < 0) off += @intCast(value.len);
        if (off < 0) off = 0;
        if (off >= value.len) return "";
        const start: usize = @intCast(off);
        var end = value.len;
        if (len_text) |lt| {
            const len = bi.evalArith(self.sh, lt) catch 0;
            if (len < 0) {
                const e = @as(i64, @intCast(value.len)) + len;
                end = if (e < @as(i64, @intCast(start))) start else @intCast(e);
            } else {
                end = @min(value.len, start + @as(usize, @intCast(len)));
            }
        }
        return self.sh.a.dupe(u8, value[start..end]) catch "";
    }

    /// Expand the raw text of a parameter's replacement word into flagged
    /// characters (no pathname expansion) so nested quotes survive.
    fn expandWordToChars(self: *Exec, text: []const u8) ExpandError![]EChar {
        if (text.len == 0) return &.{};
        // Inside a double-quoted substitution, literal single quotes in a
        // replacement word are not syntactic quotes in BusyBox ash.
        if (self.expansion_quote == .double and std.mem.indexOfScalar(u8, text, '\'') != null) {
            var lit: std.ArrayList(u8) = .empty;
            for (text) |c| if (c != '"') lit.append(self.sh.a, c) catch {};
            return charsFromString(lit.items, false, false);
        }
        self.no_glob_depth += 1;
        defer self.no_glob_depth -= 1;
        var lxr = lx.Lexer.init(self.sh.a, text);
        const toks = lxr.lex() catch return charsFromString(text, true, false);
        var chars: std.ArrayList(EChar) = .empty;
        for (toks) |t| {
            if (t.kind == .newline or t.kind == .semi) {
                try chars.append(self.sh.a, .{ .c = ' ', .splittable = true, .glob = false });
                continue;
            }
            if (t.kind != .word or t.word == null) continue;
            const part = try self.wordToChars(t.word.?);
            if (chars.items.len != 0) try chars.append(self.sh.a, .{ .c = ' ', .splittable = true, .glob = false });
            try chars.appendSlice(self.sh.a, part);
        }
        return chars.toOwnedSlice(self.sh.a);
    }

    fn expandWordText(self: *Exec, text: []const u8) ExpandError![]u8 {
        if (text.len == 0) return "";
        const chars = try self.expandWordToChars(text);
        return self.flattenChars(chars);
    }

    fn expandHereDoc(self: *Exec, body: []const u8) []const u8 {
        var result: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) {
            const c = body[i];
            if (c == '\\' and i + 1 < body.len) {
                const n = body[i + 1];
                if (n == '\n') {
                    i += 2;
                    continue;
                }
                if (n == '$' or n == '`' or n == '\\') {
                    result.append(self.sh.a, n) catch {};
                    i += 2;
                    continue;
                }
                result.append(self.sh.a, '\\') catch {};
                i += 1;
                continue;
            }
            if (c == '`') {
                const end = std.mem.indexOfScalarPos(u8, body, i + 1, '`') orelse {
                    result.append(self.sh.a, c) catch {};
                    i += 1;
                    continue;
                };
                const text = self.captureOutput(body[i + 1 .. end]);
                result.appendSlice(self.sh.a, text) catch {};
                i = end + 1;
                continue;
            }
            if (c == '$') {
                const consumed = substitutionLength(body[i..]);
                if (consumed != 0) {
                    var lxr = lx.Lexer.init(self.sh.a, body[i .. i + consumed]);
                    if (lxr.lex()) |toks| {
                        if (toks.len != 0 and toks[0].kind == .word and toks[0].word != null) {
                            const segs = toks[0].word.?.segs;
                            if (segs.len != 0) {
                                var chars: std.ArrayList(EChar) = .empty;
                                for (segs) |sg| self.appendSegment(&chars, sg) catch {};
                                for (chars.items) |ch| result.append(self.sh.a, ch.c) catch {};
                                i += consumed;
                                continue;
                            }
                        }
                    } else |_| {}
                }
            }
            result.append(self.sh.a, c) catch {};
            i += 1;
        }
        return result.toOwnedSlice(self.sh.a) catch "";
    }

    fn listDirMatching(self: *Exec, dirpath: []const u8, pattern: []const u8, allow_dot: bool, prefix: []const u8, want_dirs: bool, out_list: *std.ArrayList([]const u8)) void {
        const zdir = std.mem.concatWithSentinel(self.sh.a, u8, &.{dirpath}, 0) catch return;
        const d = linux.open(zdir.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(d) != .SUCCESS) return;
        const dirfd: i32 = @intCast(d);
        defer _ = linux.close(dirfd);
        var buf: [8192]u8 align(8) = undefined;
        while (true) {
            const n = linux.getdents64(dirfd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var pos: usize = 0;
            const bytes: []u8 = &buf;
            while (pos + 19 <= n) {
                const reclen = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(bytes[pos + 16 ..].ptr)), .little);
                if (reclen < 20 or pos + reclen > n) break;
                var name_len: usize = 0;
                while (name_len < reclen - 19 and bytes[pos + 19 + name_len] != 0) name_len += 1;
                const name = bytes[pos + 19 .. pos + 19 + name_len];
                if (name.len == 0) {
                    pos += reclen;
                    continue;
                }
                if (name[0] == '.' and !allow_dot) {
                    pos += reclen;
                    continue;
                }
                if (!ex.pathMatch(pattern, name)) {
                    pos += reclen;
                    continue;
                }
                const candidate = if (prefix.len == 0)
                    self.sh.a.dupe(u8, name) catch name
                else if (std.mem.eql(u8, prefix, "/"))
                    std.fmt.allocPrint(self.sh.a, "/{s}", .{name}) catch name
                else
                    std.fmt.allocPrint(self.sh.a, "{s}/{s}", .{ prefix, name }) catch name;
                if (want_dirs) {
                    const zp = std.mem.concatWithSentinel(self.sh.a, u8, &.{candidate}, 0) catch {
                        pos += reclen;
                        continue;
                    };
                    var stx: linux.Statx = undefined;
                    if (linux.errno(linux.statx(@intCast(linux.AT.FDCWD), zp.ptr, 0, .BASIC_STATS, &stx)) != .SUCCESS or
                        (stx.mode & linux.S.IFMT) != linux.S.IFDIR)
                    {
                        pos += reclen;
                        continue;
                    }
                }
                out_list.append(self.sh.a, candidate) catch {};
                pos += reclen;
            }
        }
    }

    fn globField(self: *Exec, field: []const u8, active: []const bool) ![][]const u8 {
        // Split into path components so that every component containing an
        // active metacharacter is expanded independently.
        var components: std.ArrayList([]const u8) = .empty;
        var offsets: std.ArrayList(usize) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= field.len) : (i += 1) {
            if (i == field.len or field[i] == '/') {
                components.append(self.sh.a, field[start..i]) catch return &.{};
                offsets.append(self.sh.a, start) catch return &.{};
                start = i + 1;
            }
        }
        var current: std.ArrayList([]const u8) = .empty;
        current.append(self.sh.a, if (field.len != 0 and field[0] == '/') "/" else "") catch return &.{};
        for (components.items, 0..) |comp, ci| {
            const off = @min(offsets.items[ci], active.len);
            const act = active[off .. @min(off + comp.len, active.len)];
            var is_glob = false;
            for (act) |a| {
                if (a) is_glob = true;
            }
            const last = ci + 1 == components.items.len;
            var next: std.ArrayList([]const u8) = .empty;
            if (!is_glob) {
                for (current.items) |prefix| {
                    const joined = if (prefix.len == 0)
                        self.sh.a.dupe(u8, comp) catch comp
                    else if (std.mem.eql(u8, prefix, "/"))
                        std.fmt.allocPrint(self.sh.a, "/{s}", .{comp}) catch comp
                    else
                        std.fmt.allocPrint(self.sh.a, "{s}/{s}", .{ prefix, comp }) catch comp;
                    next.append(self.sh.a, joined) catch {};
                }
            } else {
                const pattern = buildPattern(self.sh.a, comp, act) catch return &.{};
                const allow_dot = comp.len != 0 and act.len != 0 and act[0] and comp[0] == '.';
                for (current.items) |prefix| {
                    const dirpath = if (prefix.len == 0) "." else prefix;
                    self.listDirMatching(dirpath, pattern, allow_dot, prefix, !last, &next);
                }
            }
            current = next;
            if (current.items.len == 0) return &.{};
        }
        std.mem.sort([]const u8, current.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        return current.toOwnedSlice(self.sh.a);
    }

    // ------------------------------------------------------- command capture

    fn captureOutput(self: *Exec, text: []const u8) []u8 {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return "";
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
            return "";
        }
        if (pid == 0) {
            _ = linux.close(fds[0]);
            _ = linux.dup2(fds[1], 1);
            _ = linux.close(fds[1]);
            const code = self.runSource(text);
            std.process.exit(code);
        }
        _ = linux.close(fds[1]);
        var result: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = linux.read(fds[0], &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            result.appendSlice(self.sh.a, buf[0..n]) catch {};
        }
        _ = linux.close(fds[0]);
        self.sh.last_status = job.wait(@intCast(pid));
        var slice = result.items;
        while (slice.len != 0 and slice[slice.len - 1] == '\n') slice = slice[0 .. slice.len - 1];
        return self.sh.a.dupe(u8, slice) catch "";
    }
};

fn substitutionLength(body: []const u8) usize {
    if (body.len < 2) return 0;
    if (body[1] == '{') {
        const e = lx.findClose(body, 2, '{', '}') orelse return body.len;
        return e + 1;
    }
    if (body[1] == '(') {
        if (body.len > 2 and body[2] == '(') {
            const e = lx.findArithClose(body, 3) orelse return body.len;
            return e + 2;
        }
        const e = lx.findClose(body, 2, '(', ')') orelse return body.len;
        return e + 1;
    }
    if (body[1] >= '0' and body[1] <= '9') return 2;
    var i: usize = 2;
    while (i < body.len and (std.ascii.isAlphanumeric(body[i]) or body[i] == '_')) i += 1;
    return i;
}

fn buildPattern(a: std.mem.Allocator, base: []const u8, active: []const bool) ![]u8 {
    var p: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_class = false;
    while (i < base.len) : (i += 1) {
        const c = base[i];
        const is_active = i < active.len and active[i];
        if (is_active and c == '[') {
            in_class = true;
            try p.append(a, c);
            continue;
        }
        if (in_class) {
            try p.append(a, c);
            if (c == ']') in_class = false;
            continue;
        }
        if (is_active and (c == '*' or c == '?')) {
            try p.append(a, c);
        } else {
            try p.append(a, '\\');
            try p.append(a, c);
        }
    }
    return p.toOwnedSlice(a);
}
