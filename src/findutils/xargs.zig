//! findutils xargs — build and execute command lines from stdin.

const std = @import("std");
const c = @import("common.zig");
const bb = c.bb;

const Opt = struct {
    zero: bool = false,
    no_empty: bool = false,
    trace: bool = false,
    confirm: bool = false,
    xflag: bool = false,
    n: ?usize = null,
    s: ?usize = null,
    repl: ?[]const u8 = null,
    eof_str: ?[]const u8 = null,
    args_file: ?[]const u8 = null,
};

fn parseOpts(args: []const []const u8, prog: []const u8) Opt {
    var o = Opt{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tok.len < 2 or tok[0] != '-') break;
        if (std.mem.eql(u8, tok, "--")) {
            i += 1;
            break;
        }
        if (tok[1] == '-') {
            const name = tok[2..];
            if (std.mem.eql(u8, name, "no-run-if-empty")) {
                o.no_empty = true;
            } else {
                bb.messages.plainMsg("unrecognized option '--{s}'", .{name});
                bb.usage.die(prog);
            }
            continue;
        }
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            switch (ch) {
                '0' => o.zero = true,
                'r' => o.no_empty = true,
                't' => o.trace = true,
                'p' => o.confirm = true,
                'x' => o.xflag = true,
                'n', 's', 'E', 'I', 'i', 'P', 'a' => {
                    var val: []const u8 = undefined;
                    if (j + 1 < tok.len) {
                        val = tok[j + 1 ..];
                    } else if (i + 1 < args.len) {
                        i += 1;
                        val = args[i];
                    } else {
                        bb.messages.plainMsg("option requires an argument -- '{c}'", .{ch});
                        bb.usage.die(prog);
                    }
                    switch (ch) {
                        'n' => o.n = std.fmt.parseInt(usize, val, 10) catch 1,
                        's' => o.s = std.fmt.parseInt(usize, val, 10) catch 0,
                        'E' => o.eof_str = if (val.len == 0) null else val,
                        'I' => o.repl = val,
                        'i' => o.repl = if (val.len == 0) "{}" else val,
                        'a' => o.args_file = val,
                        'P' => {},
                        else => {},
                    }
                    break;
                },
                'e' => {
                    // -e[STR]: optional attached argument
                    if (j + 1 < tok.len) o.eof_str = tok[j + 1 ..];
                    break;
                },
                else => {
                    bb.messages.plainMsg("invalid option -- '{c}'", .{ch});
                    bb.usage.die(prog);
                },
            }
        }
    }
    return o;
}

fn readInput(allocator: std.mem.Allocator, o: Opt) []u8 {
    if (o.args_file) |path| return c.readFile(allocator, path) catch return allocator.alloc(u8, 0) catch unreachable;
    return c.readAllFd(allocator, 0) catch allocator.alloc(u8, 0) catch unreachable;
}

fn tokenize(allocator: std.mem.Allocator, data: []const u8, zero: bool, eof: ?[]const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    if (zero) {
        var it = std.mem.splitScalar(u8, data, 0);
        while (it.next()) |tok| {
            if (tok.len == 0) continue;
            if (eof) |e| if (std.mem.eql(u8, tok, e)) break;
            try out.append(allocator, try allocator.dupe(u8, tok));
        }
        return out.toOwnedSlice(allocator);
    }
    var i: usize = 0;
    while (i < data.len) {
        while (i < data.len and std.ascii.isWhitespace(data[i])) i += 1;
        if (i >= data.len) break;
        var tok: std.ArrayList(u8) = .empty;
        defer tok.deinit(allocator);
        var quote: u8 = 0;
        while (i < data.len) {
            const ch = data[i];
            if (quote == 0) {
                if (std.ascii.isWhitespace(ch)) break;
                if (ch == '\'' or ch == '"') {
                    quote = ch;
                    i += 1;
                    continue;
                }
                if (ch == '\\' and i + 1 < data.len) {
                    i += 1;
                    try tok.append(allocator, data[i]);
                    i += 1;
                    continue;
                }
                try tok.append(allocator, ch);
            } else {
                if (ch == quote) {
                    quote = 0;
                    i += 1;
                    continue;
                }
                if (ch == '\\' and i + 1 < data.len and quote == '"') {
                    i += 1;
                    try tok.append(allocator, data[i]);
                    i += 1;
                    continue;
                }
                try tok.append(allocator, ch);
            }
            i += 1;
        }
        const value = try allocator.dupe(u8, tok.items);
        if (eof) |e| if (std.mem.eql(u8, value, e)) break;
        try out.append(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

fn commandExists(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return c.statPath(name, true) != null;
    }
    const path = bb.env.get("PATH") orelse "/bin:/usr/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
        if (c.statPath(full, true) != null) return true;
    }
    return false;
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, trace: bool) u8 {
    if (argv.len > 0 and !commandExists(allocator, argv[0])) {
        bb.messages.errorMsg(2, "{s}", .{argv[0]});
        return 127;
    }
    if (trace) {
        for (argv, 0..) |a, i| {
            if (i != 0) c.writeAll(2, " ");
            c.writeAll(2, a);
        }
        c.writeAll(2, "\n");
    }
    const code = c.runChild(allocator, argv);
    return if (code == 255) 255 else if (code != 0) 123 else 0;
}

pub fn xargsMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const allocator = std.heap.page_allocator;
    const args = c.argsFrom(allocator, argv, argc) catch return 1;
    defer allocator.free(args);
    const prog = c.basename(args[0]);
    bb.env.setProgramName(prog);

    const o = parseOpts(args, prog);
    var cmd: []const []const u8 = args[1..];
    // Find first positional (command) token.
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const tok = args[idx];
        if (tok.len > 0 and tok[0] == '-') {
            // options with args consume the next token
            if (std.mem.eql(u8, tok, "-n") or std.mem.eql(u8, tok, "-s") or std.mem.eql(u8, tok, "-E") or
                std.mem.eql(u8, tok, "-I") or std.mem.eql(u8, tok, "-i") or std.mem.eql(u8, tok, "-P") or
                std.mem.eql(u8, tok, "-a") or std.mem.eql(u8, tok, "--"))
            {
                idx += 1;
                continue;
            }
            continue;
        }
        break;
    }
    if (idx < args.len) cmd = args[idx..] else cmd = &.{"echo"};

    const data = readInput(allocator, o);
    defer allocator.free(data);

    var status: u8 = 0;
    if (o.repl) |repl| {
        // One invocation per input line.
        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(allocator);
        var it = if (o.zero)
            std.mem.splitScalar(u8, data, 0)
        else
            std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, if (o.zero) "" else " \t\r");
            if (line.len == 0) continue;
            if (o.eof_str) |e| if (std.mem.eql(u8, line, e)) break;
            var built: std.ArrayList([]const u8) = .empty;
            for (cmd) |part| {
                const replaced = std.mem.replaceOwned(u8, allocator, part, repl, line) catch part;
                built.append(allocator, replaced) catch {};
            }
            const rc = runCommand(allocator, built.items, o.trace);
            if (rc == 255) return 255;
            if (rc != 0) status = rc;
        }
        return status;
    }

    const toks = tokenize(allocator, data, o.zero, o.eof_str) catch return 1;
    defer allocator.free(toks);
    if (toks.len == 0) {
        if (o.no_empty) return 0;
        const rc = runCommand(allocator, cmd, o.trace);
        return rc;
    }

    // -s limits the total bytes of the argument vector (each argument costs
    // strlen+1). Fixed command arguments are charged first, exactly as in
    // BusyBox's xargs.c, leaving the remaining budget for input tokens.
    var budget: usize = std.math.maxInt(usize);
    if (o.s) |sval| {
        budget = sval;
        for (cmd) |part| {
            const cost = part.len + 1;
            if (cost >= budget) {
                bb.messages.plainMsg("can't fit single argument within argument list size limit", .{});
                return 1;
            }
            budget -= cost;
        }
    }
    const per = o.n orelse toks.len;
    var pos: usize = 0;
    while (pos < toks.len) {
        var end = @min(pos + per, toks.len);
        if (o.s != null) {
            var used: usize = 0;
            var k = pos;
            while (k < @min(pos + per, toks.len)) : (k += 1) {
                const cost = toks[k].len + 1;
                if (cost > budget) {
                    bb.messages.plainMsg("argument line too long", .{});
                    return 1;
                }
                if (used + cost > budget) break;
                used += cost;
                end = k + 1;
            }
        }
        var built: std.ArrayList([]const u8) = .empty;
        defer built.deinit(allocator);
        for (cmd) |part| built.append(allocator, part) catch {};
        for (toks[pos..end]) |t| built.append(allocator, t) catch {};
        const rc = runCommand(allocator, built.items, o.trace);
        if (rc == 255) return 255;
        if (rc != 0) status = rc;
        pos = end;
    }
    return status;
}
