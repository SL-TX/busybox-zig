//! Mutable shell state shared by the expander, executor and builtins.

const std = @import("std");
const linux = std.os.linux;
const prs = @import("parser.zig");

pub const Var = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = false,
    readonly: bool = false,
    local: bool = false,
};

pub const Func = struct {
    name: []const u8,
    node: *prs.Node,
};

pub const Alias = struct {
    name: []const u8,
    value: []const u8,
};

pub const Trap = struct {
    signal: i32,
    command: []const u8,
};

pub const Options = struct {
    errexit: bool = false,
    nounset: bool = false,
    noexec: bool = false,
    xtrace: bool = false,
    verbose: bool = false,
    noglob: bool = false,
    noclobber: bool = false,
    allexport: bool = false,
    pipefail: bool = false,
    monitor: bool = false,
    interactive: bool = false,
    ignoreeof: bool = false,
    notify: bool = false,
    errtrace: bool = false,
    vi: bool = false,
};

pub const Callbacks = struct {
    ctx: *anyopaque,
    /// Parse and execute a string in the current shell.
    evalString: *const fn (ctx: *anyopaque, text: []const u8) i32,
    /// Run a command in a subshell, returning its stdout (caller frees).
    capture: *const fn (ctx: *anyopaque, text: []const u8) []const u8,
    /// Run a simple command, bypassing shell-function lookup (for `command`).
    runDirect: *const fn (ctx: *anyopaque, words: []const []const u8) i32,
    /// Print the interactive history list (used by the `history` builtin).
    printHistory: *const fn (ctx: *anyopaque) void,
};

pub const Shell = struct {
    a: std.mem.Allocator,
    vars: std.ArrayList(Var) = .empty,
    funcs: std.ArrayList(Func) = .empty,
    aliases: std.ArrayList(Alias) = .empty,
    traps: std.ArrayList(Trap) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,
    scopes: std.ArrayList(usize) = .empty,
    opts: Options = .{},
    callbacks: ?Callbacks = null,

    name: []const u8 = "ash",
    last_status: u8 = 0,
    exit_code: u8 = 0,
    exiting: bool = false,
    return_pending: bool = false,
    break_count: usize = 0,
    continue_count: usize = 0,
    loop_depth: usize = 0,
    func_depth: usize = 0,
    suppress_errexit: usize = 0,
    last_bg_pid: i32 = 0,
    background_jobs: std.ArrayList(i32) = .empty,
    hashes: std.ArrayList(struct { name: []const u8, path: []const u8 }) = .empty,
    history: std.ArrayList([]const u8) = .empty,
    line_number: usize = 0,
    /// Legacy Context compatibility: keep command-scoped assignments.
    legacy_persist_assigns: bool = false,
    count_lines: bool = true,
    line_base: usize = 1,
    hush: bool = false,
    last_set_error: ?[]const u8 = null,
    invoked_c: bool = false,

    pub fn init(a: std.mem.Allocator) Shell {
        return .{ .a = a };
    }

    pub fn get(self: *const Shell, name: []const u8) ?[]const u8 {
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) return self.vars.items[i].value;
        }
        return null;
    }

    pub fn getVar(self: *const Shell, name: []const u8) ?Var {
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) return self.vars.items[i];
        }
        return null;
    }

    pub fn isSet(self: *const Shell, name: []const u8) bool {
        return self.get(name) != null;
    }

    pub fn set(self: *Shell, name: []const u8, value: []const u8) !void {
        var vi: usize = self.vars.items.len;
        while (vi > 0) {
            vi -= 1;
            const v = &self.vars.items[vi];
            if (std.mem.eql(u8, v.name, name)) {
                if (v.readonly) {
                    self.last_set_error = name;
                    return;
                }
                v.value = try self.a.dupe(u8, value);
                if (self.opts.allexport) v.exported = true;
                return;
            }
        }
        try self.vars.append(self.a, .{
            .name = try self.a.dupe(u8, name),
            .value = try self.a.dupe(u8, value),
            .exported = self.opts.allexport,
        });
    }

    pub fn setExported(self: *Shell, name: []const u8, value: []const u8) !void {
        try self.set(name, value);
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) {
                self.vars.items[i].exported = true;
                return;
            }
        }
    }

    pub fn markExport(self: *Shell, name: []const u8) !void {
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            const v = &self.vars.items[i];
            if (std.mem.eql(u8, v.name, name)) {
                v.exported = true;
                return;
            }
        }
        try self.vars.append(self.a, .{
            .name = try self.a.dupe(u8, name),
            .value = "",
            .exported = true,
        });
    }

    pub fn markReadonly(self: *Shell, name: []const u8) !void {
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            const v = &self.vars.items[i];
            if (std.mem.eql(u8, v.name, name)) {
                v.readonly = true;
                return;
            }
        }
        try self.vars.append(self.a, .{
            .name = try self.a.dupe(u8, name),
            .value = "",
            .readonly = true,
        });
    }

    pub fn unset(self: *Shell, name: []const u8) bool {
        var i: usize = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) {
                if (self.vars.items[i].readonly) return false;
                _ = self.vars.orderedRemove(i);
                return true;
            }
        }
        return true;
    }

    pub fn pushScope(self: *Shell) !void {
        try self.scopes.append(self.a, self.vars.items.len);
    }

    pub fn popScope(self: *Shell) void {
        if (self.scopes.items.len == 0) return;
        const mark = self.scopes.pop().?;
        while (self.vars.items.len > mark) {
            _ = self.vars.pop();
        }
    }

    pub fn setLocal(self: *Shell, name: []const u8, value: []const u8) !void {
        // If the innermost scope already contains the name, overwrite it.
        var start: usize = 0;
        if (self.scopes.items.len != 0) start = self.scopes.items[self.scopes.items.len - 1];
        var i = self.vars.items.len;
        while (i > start) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) {
                self.vars.items[i].value = try self.a.dupe(u8, value);
                return;
            }
        }
        try self.vars.append(self.a, .{
            .name = try self.a.dupe(u8, name),
            .value = try self.a.dupe(u8, value),
            .local = true,
        });
    }

    pub fn findFunc(self: *const Shell, name: []const u8) ?*prs.Node {
        for (self.funcs.items) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.node;
        }
        return null;
    }

    pub fn setFunc(self: *Shell, name: []const u8, node: *prs.Node) !void {
        for (self.funcs.items) |*f| {
            if (std.mem.eql(u8, f.name, name)) {
                f.node = node;
                return;
            }
        }
        try self.funcs.append(self.a, .{
            .name = try self.a.dupe(u8, name),
            .node = node,
        });
    }

    pub fn getAlias(self: *const Shell, name: []const u8) ?[]const u8 {
        for (self.aliases.items) |x| {
            if (std.mem.eql(u8, x.name, name)) return x.value;
        }
        return null;
    }

    pub fn setAlias(self: *Shell, name: []const u8, value: []const u8) !void {
        for (self.aliases.items) |*x| {
            if (std.mem.eql(u8, x.name, name)) {
                x.value = try self.a.dupe(u8, value);
                return;
            }
        }
        try self.aliases.append(self.a, .{
            .name = try self.a.dupe(u8, name),
            .value = try self.a.dupe(u8, value),
        });
    }

    pub fn importEnv(self: *Shell) !void {
        const z = try std.mem.concatWithSentinel(self.a, u8, &.{"/proc/self/environ"}, 0);
        defer self.a.free(z);
        const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd) != .SUCCESS) return;
        defer _ = linux.close(@intCast(fd));
        var data: std.ArrayList(u8) = .empty;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = linux.read(@intCast(fd), &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            try data.appendSlice(self.a, buf[0..n]);
        }
        var it = std.mem.splitScalar(u8, data.items, 0);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            try self.vars.append(self.a, .{
                .name = try self.a.dupe(u8, entry[0..eq]),
                .value = try self.a.dupe(u8, entry[eq + 1 ..]),
                .exported = true,
            });
        }
    }

};
