//! shell module — a small POSIX-like interpreter (ash/hush subset).
//! Supports quoted words, $VAR expansion, builtins, PATH lookup and external
//! commands. Pipelines, redirections, control flow and job control are out of
//! scope for this subset.

const std = @import("std");
const linux = std.os.linux;

pub const init = struct {
    pub fn init() void {}
};

fn out(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}

fn zstr(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ------------------------------------------------------------------ parsing

/// Split a command line into words, honoring single/double quotes and
/// backslash escapes. Quotes themselves are removed from the result.
pub fn tokenize(a: std.mem.Allocator, line: []const u8) ![][]u8 {
    var words: std.ArrayList([]u8) = .empty;
    errdefer {
        for (words.items) |w| a.free(w);
        words.deinit(a);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(a);
    var quote: u8 = 0;
    var started = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote == 0 and (c == ' ' or c == '\t' or c == '\r' or c == '\n')) {
            if (started) {
                try words.append(a, try current.toOwnedSlice(a));
                current = .empty;
                started = false;
            }
            continue;
        }
        if (c == '\\' and quote != '\'' and i + 1 < line.len) {
            i += 1;
            try current.append(a, line[i]);
            started = true;
            continue;
        }
        if (quote == 0 and (c == '\'' or c == '"')) {
            quote = c;
            started = true;
            continue;
        }
        if (quote != 0 and c == quote) {
            quote = 0;
            continue;
        }
        try current.append(a, c);
        started = true;
    }
    if (started) try words.append(a, try current.toOwnedSlice(a));
    return words.toOwnedSlice(a);
}

pub const Var = struct { name: []const u8, value: []const u8 };

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Expand $NAME and ${NAME}; unknown variables expand to the empty string.
pub fn expandVars(a: std.mem.Allocator, word: []const u8, vars: []const Var) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
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
                next = i + 2 + close + 1;
            } else {
                var end = i + 1;
                while (end < word.len and isNameChar(word[end])) end += 1;
                if (end == i + 1) {
                    try result.append(a, '$');
                    i += 1;
                    continue;
                }
                name = word[i + 1 .. end];
                next = end;
            }
            for (vars) |v| {
                if (eq(v.name, name)) {
                    try result.appendSlice(a, v.value);
                    break;
                }
            }
            i = next;
            continue;
        }
        try result.append(a, word[i]);
        i += 1;
    }
    return result.toOwnedSlice(a);
}

/// Find a command in a colon-separated PATH. A name containing '/' is used
/// directly.
pub fn findInPath(a: std.mem.Allocator, name: []const u8, path: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const z = try zstr(a, name);
        defer a.free(z);
        if (linux.errno(linux.access(z.ptr, linux.X_OK)) == .SUCCESS) return try a.dupe(u8, name);
        return null;
    }
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const candidate = if (dir.len == 0)
            try a.dupe(u8, name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
        const z = try zstr(a, candidate);
        const executable = linux.errno(linux.access(z.ptr, linux.X_OK)) == .SUCCESS;
        a.free(z);
        if (executable) return candidate;
        a.free(candidate);
    }
    return null;
}

// ------------------------------------------------------------------ execution

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
        for (self.vars.items) |v| if (eq(v.name, name)) return v.value;
        return null;
    }

    pub fn set(self: *Context, name: []const u8, value: []const u8) !void {
        for (self.vars.items) |*v| {
            if (eq(v.name, name)) {
                v.value = try self.allocator.dupe(u8, value);
                return;
            }
        }
        try self.vars.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        });
    }
};

/// The kernel's getcwd result may include the NUL terminator in its length.
pub fn cwdSlice(buf: []const u8, n: usize) []const u8 {
    const slice = buf[0..@min(n, buf.len)];
    const end = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
    return slice[0..end];
}

fn runBuiltin(ctx: *Context, words: []const []u8) !?u8 {
    const a = ctx.allocator;
    const name = words[0];
    if (eq(name, "true")) return 0;
    if (eq(name, "false")) return 1;
    if (eq(name, "echo")) {
        for (words[1..], 0..) |word, i| {
            if (i > 0) out(" ");
            out(word);
        }
        out("\n");
        return 0;
    }
    if (eq(name, "pwd")) {
        var buf: [4096]u8 = undefined;
        const n = linux.getcwd(&buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return 1;
        out(cwdSlice(&buf, n));
        out("\n");
        return 0;
    }
    if (eq(name, "cd")) {
        const target = if (words.len > 1) words[1] else (ctx.get("HOME") orelse "/");
        const z = try zstr(a, target);
        defer a.free(z);
        if (linux.errno(linux.chdir(z.ptr)) != .SUCCESS) return 1;
        try ctx.set("PWD", target);
        return 0;
    }
    if (eq(name, "export")) return 0;
    if (eq(name, "exit")) {
        ctx.should_exit = true;
        ctx.exit_code = if (words.len > 1)
            std.fmt.parseInt(u8, words[1], 10) catch 1
        else
            0;
        return ctx.exit_code;
    }
    return null;
}

fn runExternal(ctx: *Context, words: []const []u8) !u8 {
    const a = ctx.allocator;
    const path_var = ctx.get("PATH") orelse "/bin:/usr/bin";
    const resolved = (try findInPath(a, words[0], path_var)) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: not found\n", .{words[0]}) catch "";
        errOut(msg);
        return 127;
    };
    defer a.free(resolved);

    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return 1;
    if (child == 0) {
        const path_z = zstr(a, resolved) catch std.process.exit(127);
        const argv_z = a.allocSentinel(?[*:0]const u8, words.len, null) catch std.process.exit(127);
        for (words, 0..) |word, i| {
            argv_z[i] = (zstr(a, word) catch std.process.exit(127)).ptr;
        }
        const envp_z = a.allocSentinel(?[*:0]const u8, 0, null) catch std.process.exit(127);
        _ = linux.execve(path_z.ptr, argv_z.ptr, envp_z.ptr);
        std.process.exit(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(child), &status, 0);
    return @intCast((status >> 8) & 0xff);
}

fn errOut(bytes: []const u8) void {
    _ = linux.write(2, bytes.ptr, bytes.len);
}

pub fn runLine(ctx: *Context, line: []const u8) !u8 {
    const a = ctx.allocator;
    const words = try tokenize(a, line);
    defer {
        for (words) |w| a.free(w);
        a.free(words);
    }
    if (words.len == 0) return 0;

    // VAR=value assignment
    if (std.mem.indexOfScalar(u8, words[0], '=')) |pos| {
        if (pos > 0) {
            const name = words[0][0..pos];
            const value = words[0][pos + 1 ..];
            const expanded = try expandVars(a, value, ctx.vars.items);
            defer a.free(expanded);
            try ctx.set(name, expanded);
            return 0;
        }
    }

    var expanded: std.ArrayList([]u8) = .empty;
    defer {
        for (expanded.items) |w| a.free(w);
        expanded.deinit(a);
    }
    for (words) |word| try expanded.append(a, try expandVars(a, word, ctx.vars.items));

    if (try runBuiltin(ctx, expanded.items)) |code| return code;
    return runExternal(ctx, expanded.items);
}

pub fn runInput(ctx: *Context, input: []const u8) u8 {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var commands = std.mem.splitScalar(u8, line, ';');
        while (commands.next()) |command| {
            const code = runLine(ctx, command) catch 1;
            if (ctx.should_exit) return ctx.exit_code;
            _ = code;
        }
    }
    return 0;
}

fn readAll(a: std.mem.Allocator, fd: linux.fd_t) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try result.appendSlice(a, buf[0..n]);
    }
    return result.toOwnedSlice(a);
}

pub fn ash_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    var ctx = Context{ .allocator = a };
    defer {
        for (ctx.vars.items) |v| {
            a.free(v.name);
            a.free(v.value);
        }
        ctx.vars.deinit(a);
    }
    ctx.set("PATH", "/bin:/usr/bin") catch return 1;

    var command: ?[]const u8 = null;
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (eq(arg, "-c") and i + 1 < @as(usize, @intCast(argc))) {
            i += 1;
            command = std.mem.span(argv[i]);
        }
    }
    if (command) |cmd| return runInput(&ctx, cmd);

    const input = readAll(a, 0) catch return 1;
    defer a.free(input);
    return runInput(&ctx, input);
}

pub fn hush_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ash_main(argc, argv);
}
