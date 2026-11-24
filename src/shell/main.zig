//! Shell module root. Re-exports the real interpreter and the five applet
//! entry points. The lexer, parser, expander, executor, builtins and job
//! helpers live in their own files; this module only wires them together.

const std = @import("std");

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const expand = @import("expand.zig");
pub const state = @import("state.zig");
pub const builtins = @import("builtins.zig");
pub const exec = @import("exec.zig");
pub const job = @import("job.zig");

pub const ash_main = @import("ash.zig").main;
pub const hush_main = @import("hush.zig").main;
pub const cttyhack_main = @import("cttyhack.zig").main;

pub const init = struct {
    pub fn init() void {}
};

/// Convenience entry point used by tests and by the `sh` / `bash` aliases.
pub fn runScript(a: std.mem.Allocator, source: []const u8) u8 {
    var sh = state.Shell.init(a);
    sh.set("IFS", " \t\n") catch {};
    sh.set("PATH", "/bin:/usr/bin") catch {};
    var e = exec.Exec.init(&sh);
    e.install();
    const code = e.runSource(source);
    return e.finish(code);
}

test {
    _ = lexer;
    _ = parser;
    _ = expand;
    _ = state;
    _ = builtins;
    _ = exec;
    _ = job;
}

// ---------------------------------------------------------------------------
// Legacy helpers retained for the pre-existing unit tests. The real applets
// never use these; they are thin compatibility wrappers over the new engine.
// ---------------------------------------------------------------------------

pub const Var = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = false,
    readonly: bool = false,
    local: bool = false,
};

pub fn cwdSlice(buf: []const u8, n: usize) []const u8 {
    const slice = buf[0..@min(n, buf.len)];
    const end = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
    return slice[0..end];
}

pub fn tokenize(a: std.mem.Allocator, line: []const u8) ![][]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var lxr = lexer.Lexer.init(aa, line);
    const toks = try lxr.lex();
    var words: std.ArrayList([]u8) = .empty;
    for (toks) |t| {
        if (t.kind != .word or t.word == null) continue;
        var buf: std.ArrayList(u8) = .empty;
        for (t.word.?.segs) |sg| try buf.appendSlice(aa, sg.text);
        try words.append(a, try a.dupe(u8, buf.items));
    }
    return words.toOwnedSlice(a);
}

pub fn expandVars(a: std.mem.Allocator, word: []const u8, vars: []const Var) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < word.len) {
        if (word[i] == '$' and i + 1 < word.len) {
            var name: []const u8 = undefined;
            var next: usize = undefined;
            if (word[i + 1] == '{') {
                const close = std.mem.indexOfScalar(u8, word[i + 2 ..], '}') orelse {
                    try result.append(a, '$');
                    i += 1;
                    continue;
                };
                name = word[i + 2 .. i + 2 + close];
                next = i + 3 + close;
            } else {
                var end = i + 1;
                while (end < word.len and (std.ascii.isAlphanumeric(word[end]) or word[end] == '_')) end += 1;
                if (end == i + 1) {
                    try result.append(a, '$');
                    i += 1;
                    continue;
                }
                name = word[i + 1 .. end];
                next = end;
            }
            for (vars) |v| if (std.mem.eql(u8, v.name, name)) {
                try result.appendSlice(a, v.value);
                break;
            };
            i = next;
            continue;
        }
        try result.append(a, word[i]);
        i += 1;
    }
    return result.toOwnedSlice(a);
}

pub fn findInPath(a: std.mem.Allocator, name: []const u8, path: []const u8) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var sh = state.Shell.init(arena.allocator());
    sh.set("PATH", path) catch {};
    if (builtins.findProgram(&sh, name)) |p| return try a.dupe(u8, p);
    return null;
}

pub const AshInvocation = struct { command: ?[]const u8 = null, script_path: ?[]const u8 = null };

pub fn parseAshArgs(args: []const []const u8) !AshInvocation {
    var inv = AshInvocation{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
            i += 1;
            inv.command = args[i];
        } else if (args[i].len > 0 and args[i][0] == '-') {
            // options are handled by the real runner
        } else {
            inv.script_path = args[i];
            break;
        }
    }
    return inv;
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    vars: std.ArrayList(Var) = .empty,
    should_exit: bool = false,
    exit_code: u8 = 0,

    pub fn deinit(self: *Context) void {
        for (self.vars.items) |v| {
            self.allocator.free(v.name);
            self.allocator.free(v.value);
        }
        self.vars.deinit(self.allocator);
    }

    pub fn get(self: *const Context, name: []const u8) ?[]const u8 {
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) return self.vars.items[i].value;
        }
        return null;
    }

    pub fn set(self: *Context, name: []const u8, value: []const u8) !void {
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) {
                self.vars.items[i].value = try self.allocator.dupe(u8, value);
                return;
            }
        }
        try self.vars.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        });
    }
};

pub fn runLine(ctx: *Context, line: []const u8) !u8 {
    return runInput(ctx, line);
}

pub fn runInput(ctx: *Context, input: []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var sh = state.Shell.init(aa);
    sh.legacy_persist_assigns = true;
    for (ctx.vars.items) |v| {
        sh.vars.append(aa, .{
            .name = v.name,
            .value = v.value,
            .exported = v.exported,
            .readonly = v.readonly,
        }) catch {};
    }
    var e = exec.Exec.init(&sh);
    e.install();
    const code = e.runSource(input);
    _ = e.finish(code);
    for (ctx.vars.items) |v| {
        ctx.allocator.free(v.name);
        ctx.allocator.free(v.value);
    }
    ctx.vars.clearRetainingCapacity();
    for (sh.vars.items) |v| {
        ctx.vars.append(ctx.allocator, .{
            .name = ctx.allocator.dupe(u8, v.name) catch continue,
            .value = ctx.allocator.dupe(u8, v.value) catch continue,
            .exported = v.exported,
            .readonly = v.readonly,
        }) catch {};
    }
    if (sh.exiting) {
        ctx.should_exit = true;
        ctx.exit_code = sh.exit_code;
    }
    return sh.last_status;
}
