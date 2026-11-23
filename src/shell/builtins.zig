//! Built-in commands for the shell. Every function receives the live shell
//! state; returning null means "not a builtin, look it up in PATH".

const std = @import("std");
const linux = std.os.linux;
const st = @import("state.zig");
const ex = @import("expand.zig");
const Shell = st.Shell;

fn out(s: []const u8) void {
    if (s.len != 0) _ = linux.write(1, s.ptr, s.len);
}

fn errout(s: []const u8) void {
    if (s.len != 0) _ = linux.write(2, s.ptr, s.len);
}

fn zstr(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

fn err(sh: *Shell, cmd: []const u8, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}: {s}: line {d}: {s}\n", .{ sh.name, cmd, sh.line_number, msg }) catch "";
    errout(line);
}

fn num(s: []const u8) ?u8 {
    return std.fmt.parseInt(u8, s, 10) catch null;
}

/// Return the builtin's exit status, or null if `name` is not a builtin.
pub fn run(sh: *Shell, name: []const u8, args: []const []const u8) !?u8 {
    if (std.mem.eql(u8, name, ":") or std.mem.eql(u8, name, "true")) return 0;
    if (std.mem.eql(u8, name, "false")) return 1;
    if (std.mem.eql(u8, name, "echo")) return doEcho(sh, args);
    if (std.mem.eql(u8, name, "printf")) return doPrintf(sh, args);
    if (std.mem.eql(u8, name, "pwd")) return doPwd(sh, args);
    if (std.mem.eql(u8, name, "cd")) return doCd(sh, args);
    if (std.mem.eql(u8, name, "export")) return doExport(sh, args);
    if (std.mem.eql(u8, name, "readonly")) return doReadonly(sh, args);
    if (std.mem.eql(u8, name, "unset")) return doUnset(sh, args);
    if (std.mem.eql(u8, name, "set")) return doSet(sh, args);
    if (std.mem.eql(u8, name, "shift")) return doShift(sh, args);
    if (std.mem.eql(u8, name, "exit")) return doExit(sh, args);
    if (std.mem.eql(u8, name, "return")) return doReturn(sh, args);
    if (std.mem.eql(u8, name, "break")) return doBreak(sh, args, false);
    if (std.mem.eql(u8, name, "continue")) return doBreak(sh, args, true);
    if (std.mem.eql(u8, name, "eval")) return doEval(sh, args);
    if (std.mem.eql(u8, name, "exec")) return doExec(sh, args);
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "source")) return doSource(sh, args);
    if (std.mem.eql(u8, name, "command")) return doCommand(sh, args);
    if (std.mem.eql(u8, name, "type")) return doType(sh, args);
    if (std.mem.eql(u8, name, "alias")) return doAlias(sh, args);
    if (std.mem.eql(u8, name, "unalias")) return doUnalias(sh, args);
    if (std.mem.eql(u8, name, "let")) return doLet(sh, args);
    if (std.mem.eql(u8, name, "local")) return doLocal(sh, args);
    if (std.mem.eql(u8, name, "read")) return doRead(sh, args);
    if (std.mem.eql(u8, name, "getopts")) return doGetopts(sh, args);
    if (std.mem.eql(u8, name, "trap")) return doTrap(sh, args);
    if (std.mem.eql(u8, name, "umask")) return doUmask(sh, args);
    if (std.mem.eql(u8, name, "ulimit")) return doUlimit(sh, args);
    if (std.mem.eql(u8, name, "test") or std.mem.eql(u8, name, "[")) return doTest(sh, name, args);
    if (std.mem.eql(u8, name, "wait")) return doWait(sh, args);
    if (std.mem.eql(u8, name, "jobs")) return doJobs(sh, args);
    if (std.mem.eql(u8, name, "kill")) return doKill(sh, args);
    if (std.mem.eql(u8, name, "hash")) return doHash(sh, args);
    if (std.mem.eql(u8, name, "times")) return doTimes(sh, args);
    if (std.mem.eql(u8, name, "history")) return doHistory(sh, args);
    if (std.mem.eql(u8, name, "bg")) return doBgFg(sh, "bg", args);
    if (std.mem.eql(u8, name, "fg")) return doBgFg(sh, "fg", args);
    if (std.mem.eql(u8, name, "help")) {
        out("Built-in commands:\n");
        return 0;
    }
    return null;
}

fn doEcho(sh: *Shell, args: []const []const u8) u8 {
    var newline = true;
    var escapes = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 1 and a[0] == '-') {
            var all_flags = true;
            for (a[1..]) |c| switch (c) {
                'n' => newline = false,
                'e' => escapes = true,
                'E' => escapes = false,
                else => all_flags = false,
            };
            if (all_flags) continue;
        }
        for (args[i..], i..) |word, k| {
            if (k != i) out(" ");
            if (escapes) {
                var p: usize = 0;
                while (p < word.len) {
                    if (word[p] == '\\' and p + 1 < word.len) {
                        p += 1;
                        const c = word[p];
                        switch (c) {
                            'n' => out("\n"),
                            't' => out("\t"),
                            'r' => out("\r"),
                            'a' => out("\x07"),
                            'b' => out("\x08"),
                            'f' => out("\x0c"),
                            'v' => out("\x0b"),
                            '\\' => out("\\"),
                            '0' => {
                                var v: u16 = 0;
                                var count: usize = 0;
                                while (p + 1 < word.len and count < 3 and word[p + 1] >= '0' and word[p + 1] <= '7') {
                                    p += 1;
                                    v = v * 8 + (word[p] - '0');
                                    count += 1;
                                }
                                out(&[_]u8{@truncate(v)});
                            },
                            'c' => return 0,
                            else => {
                                out("\\");
                                out(&[_]u8{c});
                            },
                        }
                        p += 1;
                    } else {
                        out(word[p .. p + 1]);
                        p += 1;
                    }
                }
            } else {
                out(word);
            }
        }
        break;
    }
    if (newline) out("\n");
    _ = sh;
    return 0;
}

fn printEscaped(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '\n' => out("\\n"),
            '\t' => out("\\t"),
            '\r' => out("\\r"),
            '\\' => out("\\\\"),
            '\'' => out("\\'"),
            else => out(s[i .. i + 1]),
        }
    }
}

fn printFmtChar(fmt: []const u8, i: *usize) void {
    if (fmt[i.*] != '\\' or i.* + 1 >= fmt.len) {
        out(fmt[i.* .. i.* + 1]);
        i.* += 1;
        return;
    }
    i.* += 1;
    const c = fmt[i.*];
    switch (c) {
        'n' => out("\n"),
        't' => out("\t"),
        'r' => out("\r"),
        'a' => out("\x07"),
        'b' => out("\x08"),
        'f' => out("\x0c"),
        'v' => out("\x0b"),
        '\\' => out("\\"),
        'x' => {
            var value: u32 = 0;
            var k: usize = 0;
            while (k < 2 and i.* + 1 < fmt.len and std.ascii.isHex(fmt[i.* + 1])) : (k += 1) {
                i.* += 1;
                const d = std.ascii.toLower(fmt[i.*]);
                value = value * 16 + (if (d >= 'a') d - 'a' + 10 else d - '0');
            }
            out(&[_]u8{@truncate(value)});
        },
        '0'...'7' => {
            var value: u32 = c - '0';
            var k: usize = 1;
            while (k < 3 and i.* + 1 < fmt.len and fmt[i.* + 1] >= '0' and fmt[i.* + 1] <= '7') : (k += 1) {
                i.* += 1;
                value = value * 8 + (fmt[i.*] - '0');
            }
            out(&[_]u8{@truncate(value)});
        },
        else => {
            out("\\");
            out(fmt[i.* .. i.* + 1]);
        },
    }
    i.* += 1;
}

const FmtSpec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    precision: ?usize = null,
};

fn pad(out_count: *usize, n: usize, c: u8) void {
    var b: [1]u8 = .{c};
    var k: usize = 0;
    while (k < n) : (k += 1) out(&b);
    out_count.* += n;
}

fn emitPadded(text: []const u8, spec: FmtSpec) void {
    const len = text.len;
    if (!spec.left and spec.width > len) pad(&g_pad_count, spec.width - len, ' ');
    out(text);
    if (spec.left and spec.width > len) pad(&g_pad_count, spec.width - len, ' ');
}

var g_pad_count: usize = 0;

fn digitsFor(value: u64, base: u8, upper: bool, buf: []u8) []const u8 {
    const alphabet = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v != 0) {
        i -= 1;
        buf[i] = alphabet[@intCast(v % base)];
        v /= base;
    }
    return buf[i..];
}

fn formatNumber(val: []const u8, spec: FmtSpec, conv: u8) void {
    const signed = conv == 'd' or conv == 'i';
    var negative = false;
    var magnitude: u64 = 0;
    if (signed) {
        const n = std.fmt.parseInt(i64, val, 0) catch 0;
        negative = n < 0;
        magnitude = if (negative) @as(u64, @bitCast(-n)) else @as(u64, @bitCast(n));
    } else {
        magnitude = std.fmt.parseInt(u64, val, 0) catch 0;
    }
    const base: u8 = switch (conv) {
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    var dbuf: [80]u8 = undefined;
    var digits = digitsFor(magnitude, base, conv == 'X', &dbuf);
    if (spec.precision) |prec| {
        if (prec == 0 and magnitude == 0) {
            digits = digits[digits.len..];
        } else if (prec > digits.len) {
            // build zero-padded digits in a second buffer
            var zbuf: [96]u8 = undefined;
            const padn = prec - digits.len;
            @memset(zbuf[0..padn], '0');
            @memcpy(zbuf[padn .. padn + digits.len], digits);
            // copy back
            @memcpy(dbuf[0 .. padn + digits.len], zbuf[0 .. padn + digits.len]);
            digits = dbuf[0 .. padn + digits.len];
        }
    }
    var pbuf: [8]u8 = undefined;
    var prefix: []const u8 = "";
    if (signed) {
        if (negative) {
            pbuf[0] = '-';
            prefix = pbuf[0..1];
        } else if (spec.plus) {
            pbuf[0] = '+';
            prefix = pbuf[0..1];
        } else if (spec.space) {
            pbuf[0] = ' ';
            prefix = pbuf[0..1];
        }
    } else if (spec.alt and magnitude != 0) {
        if (conv == 'x' or conv == 'X') {
            pbuf[0] = '0';
            pbuf[1] = conv;
            prefix = pbuf[0..2];
        } else if (conv == 'o') {
            pbuf[0] = '0';
            prefix = pbuf[0..1];
        }
    } else if (spec.alt and conv == 'o' and digits.len == 0) {
        pbuf[0] = '0';
        prefix = pbuf[0..1];
    }
    const total = prefix.len + digits.len;
    if (!spec.left and spec.zero and spec.precision == null and spec.width > total) {
        out(prefix);
        pad(&g_pad_count, spec.width - total, '0');
        out(digits);
        return;
    }
    if (!spec.left and spec.width > total) pad(&g_pad_count, spec.width - total, ' ');
    out(prefix);
    out(digits);
    if (spec.left and spec.width > total) pad(&g_pad_count, spec.width - total, ' ');
}

fn printBackslashEscaped(text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            out(text[i .. i + 1]);
            continue;
        }
        i += 1;
        switch (text[i]) {
            'n' => out("\n"),
            't' => out("\t"),
            'r' => out("\r"),
            'a' => out("\x07"),
            'b' => out("\x08"),
            'f' => out("\x0c"),
            'v' => out("\x0b"),
            '\\' => out("\\"),
            else => {
                out("\\");
                out(text[i .. i + 1]);
            },
        }
    }
}

fn doPrintf(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        err(sh, "printf", "missing format");
        return 2;
    }
    const fmt = args[0];
    var argi: usize = 1;
    while (true) {
        var i: usize = 0;
        var used_arg = false;
        while (i < fmt.len) {
            if (fmt[i] != '%') {
                printFmtChar(fmt, &i);
                continue;
            }
            i += 1;
            if (i >= fmt.len) break;
            if (fmt[i] == '%') {
                out("%");
                i += 1;
                continue;
            }
            var spec = FmtSpec{};
            var had_mod = false;
            parse_flags: while (i < fmt.len) : (i += 1) {
                switch (fmt[i]) {
                    '-' => spec.left = true,
                    '+' => spec.plus = true,
                    ' ' => spec.space = true,
                    '#' => spec.alt = true,
                    '0' => spec.zero = true,
                    else => break :parse_flags,
                }
                had_mod = true;
            }
            if (i < fmt.len and fmt[i] == '*') {
                had_mod = true;
                i += 1;
                if (argi < args.len) {
                    spec.width = std.fmt.parseInt(usize, args[argi], 10) catch 0;
                    argi += 1;
                    used_arg = true;
                }
            } else {
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
                    had_mod = true;
                    spec.width = spec.width * 10 + (fmt[i] - '0');
                }
            }
            if (i < fmt.len and fmt[i] == '.') {
                had_mod = true;
                i += 1;
                if (i < fmt.len and fmt[i] == '*') {
                    i += 1;
                    if (argi < args.len) {
                        spec.precision = std.fmt.parseInt(usize, args[argi], 10) catch 0;
                        argi += 1;
                        used_arg = true;
                    }
                } else {
                    var p: usize = 0;
                    while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p * 10 + (fmt[i] - '0');
                    spec.precision = p;
                }
            }
            while (i < fmt.len and (fmt[i] == 'l' or fmt[i] == 'h' or fmt[i] == 'j' or fmt[i] == 'z' or fmt[i] == 't' or fmt[i] == 'L' or fmt[i] == 'q')) i += 1;
            if (i >= fmt.len) break;
            const conv = fmt[i];
            i += 1;
            if (conv == 'b' and had_mod) {
                var eb: [1024]u8 = undefined;
                const em = std.fmt.bufPrint(&eb, "{s}: {s}: invalid format\n", .{ sh.name, fmt }) catch "";
                errout(em);
                return 1;
            }
            const val: []const u8 = if (argi < args.len) blk: {
                used_arg = true;
                const v = args[argi];
                argi += 1;
                break :blk v;
            } else "";
            switch (conv) {
                's' => {
                    const text = val;
                    emitPadded(if (spec.precision) |p| text[0..@min(p, text.len)] else text, spec);
                },
                'b' => {
                    if (spec.precision) |p| {
                        emitPadded(val[0..@min(p, val.len)], spec);
                    } else {
                        if (!spec.left and spec.width > val.len) pad(&g_pad_count, spec.width - val.len, ' ');
                        printBackslashEscaped(val);
                        if (spec.left and spec.width > val.len) pad(&g_pad_count, spec.width - val.len, ' ');
                    }
                },
                'c' => emitPadded(if (val.len != 0) val[0..1] else "", spec),
                'd', 'i', 'u', 'o', 'x', 'X' => formatNumber(val, spec, conv),
                else => emitPadded(val, spec),
            }
        }
        if (!used_arg or argi >= args.len) break;
    }
    return 0;
}

fn doPwd(sh: *Shell, args: []const []const u8) u8 {
    var buf: [4096]u8 = undefined;
    const n = linux.getcwd(&buf, buf.len);
    if (linux.errno(n) != .SUCCESS) {
        err(sh, "pwd", "getcwd failed");
        return 1;
    }
    const end = std.mem.indexOfScalar(u8, buf[0..n], 0) orelse n;
    out(buf[0..end]);
    out("\n");
    _ = args;
    return 0;
}

fn doCd(sh: *Shell, args: []const []const u8) u8 {
    var target: ?[]const u8 = null;
    for (args) |a| {
        if (a.len > 1 and a[0] == '-') continue;
        target = a;
        break;
    }
    var dest: []const u8 = undefined;
    if (target == null) {
        dest = sh.get("HOME") orelse "/";
    } else if (std.mem.eql(u8, target.?, "-")) {
        dest = sh.get("OLDPWD") orelse {
            err(sh, "cd", "OLDPWD not set");
            return 1;
        };
    } else {
        dest = target.?;
    }
    const z = zstr(sh.a, dest) catch return 1;
    defer sh.a.free(z);
    if (linux.errno(linux.chdir(z.ptr)) != .SUCCESS) {
        var b: [256]u8 = undefined;
        const m = std.fmt.bufPrint(&b, "can't cd to {s}", .{dest}) catch "can't cd";
        err(sh, "cd", m);
        return 1;
    }
    var buf: [4096]u8 = undefined;
    const n = linux.getcwd(&buf, buf.len);
    const physical = buf[0..@min(n, buf.len)];
    const end = std.mem.indexOfScalar(u8, physical, 0) orelse physical.len;
    sh.set("OLDPWD", sh.get("PWD") orelse physical[0..end]) catch {};
    sh.set("PWD", physical[0..end]) catch {};
    if (std.mem.eql(u8, target orelse "", "-")) {
        out(physical[0..end]);
        out("\n");
    }
    return 0;
}

const ExportPair = struct { name: []const u8, value: []const u8, exported: bool };

fn listVars(sh: *Shell, only_exported: bool, prefix: []const u8) u8 {
    var items: std.ArrayList(ExportPair) = .empty;
    for (sh.vars.items) |v| {
        if (only_exported and !v.exported) continue;
        if (v.name.len == 0) continue;
        items.append(sh.a, .{ .name = v.name, .value = v.value, .exported = v.exported }) catch {};
    }
    std.mem.sort(ExportPair, items.items, {}, struct {
        fn less(_: void, a: ExportPair, b: ExportPair) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    for (items.items) |v| {
        out(prefix);
        out(v.name);
        out("='");
        printEscaped(v.value);
        out("'\n");
    }
    return 0;
}

fn doExport(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) return listVars(sh, true, "export ");
    var code: u8 = 0;
    for (args) |a| {
        if (std.mem.indexOfScalar(u8, a, '=')) |eqpos| {
            sh.setExported(a[0..eqpos], a[eqpos + 1 ..]) catch {
                code = 1;
                continue;
            };
        } else {
            sh.markExport(a) catch {
                code = 1;
                continue;
            };
        }
    }
    return code;
}

fn doReadonly(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) return listVars(sh, false, "readonly ");
    var code: u8 = 0;
    for (args) |a| {
        if (std.mem.indexOfScalar(u8, a, '=')) |eqpos| {
            sh.set(a[0..eqpos], a[eqpos + 1 ..]) catch {
                code = 1;
                continue;
            };
        }
        sh.markReadonly(if (std.mem.indexOfScalar(u8, a, '=')) |p| a[0..p] else a) catch {
            code = 1;
        };
    }
    return code;
}

fn doUnset(sh: *Shell, args: []const []const u8) u8 {
    var code: u8 = 0;
    for (args) |a| {
        if (!sh.unset(a)) {
            var b: [256]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "{s}: readonly variable", .{a}) catch "";
            err(sh, "unset", m);
            code = 1;
        }
        var i: usize = sh.funcs.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, sh.funcs.items[i].name, a)) _ = sh.funcs.orderedRemove(i);
        }
    }
    return code;
}

const OptSpec = struct { short: u8, field: *bool };

pub fn setOption(sh: *Shell, name: []const u8, on: bool) bool {
    const longs = [_]struct { n: []const u8, f: *bool }{
        .{ .n = "errexit", .f = &sh.opts.errexit },
        .{ .n = "e", .f = &sh.opts.errexit },
        .{ .n = "nounset", .f = &sh.opts.nounset },
        .{ .n = "u", .f = &sh.opts.nounset },
        .{ .n = "noexec", .f = &sh.opts.noexec },
        .{ .n = "n", .f = &sh.opts.noexec },
        .{ .n = "xtrace", .f = &sh.opts.xtrace },
        .{ .n = "x", .f = &sh.opts.xtrace },
        .{ .n = "verbose", .f = &sh.opts.verbose },
        .{ .n = "v", .f = &sh.opts.verbose },
        .{ .n = "noglob", .f = &sh.opts.noglob },
        .{ .n = "f", .f = &sh.opts.noglob },
        .{ .n = "noclobber", .f = &sh.opts.noclobber },
        .{ .n = "C", .f = &sh.opts.noclobber },
        .{ .n = "allexport", .f = &sh.opts.allexport },
        .{ .n = "a", .f = &sh.opts.allexport },
        .{ .n = "pipefail", .f = &sh.opts.pipefail },
        .{ .n = "monitor", .f = &sh.opts.monitor },
        .{ .n = "m", .f = &sh.opts.monitor },
        .{ .n = "interactive", .f = &sh.opts.interactive },
        .{ .n = "i", .f = &sh.opts.interactive },
        .{ .n = "ignoreeof", .f = &sh.opts.ignoreeof },
        .{ .n = "notify", .f = &sh.opts.notify },
        .{ .n = "b", .f = &sh.opts.notify },
        .{ .n = "errtrace", .f = &sh.opts.errtrace },
        .{ .n = "E", .f = &sh.opts.errtrace },
        .{ .n = "vi", .f = &sh.opts.vi },
    };
    for (longs) |o| {
        if (std.mem.eql(u8, o.n, name)) {
            o.f.* = on;
            return true;
        }
    }
    return false;
}

fn setFlagsText(sh: *Shell, on: bool, text: []const u8) u8 {
    if (text.len == 0) return 0;
    if (text[0] == 'o') {
        const rest = std.mem.trim(u8, text[1..], " ");
        if (!setOption(sh, rest, on)) {
            var b: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "illegal option -o {s}", .{rest}) catch "illegal option";
            err(sh, "set", m);
            return 2;
        }
        return 0;
    }
    for (text) |c| {
        var nm: [1]u8 = .{c};
        if (!setOption(sh, &nm, on)) {
            var b: [64]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "illegal option -{c}", .{c}) catch "illegal option";
            err(sh, "set", m);
            return 2;
        }
    }
    return 0;
}

fn listOptions(sh: *Shell) u8 {
    if (sh.hush) {
        const hs = [_]struct { n: []const u8, v: bool }{
            .{ .n = "pipefail", .v = sh.opts.pipefail },
            .{ .n = "noexec", .v = sh.opts.noexec },
            .{ .n = "errexit", .v = sh.opts.errexit },
            .{ .n = "xtrace", .v = sh.opts.xtrace },
        };
        for (hs) |o| {
            var b: [80]u8 = undefined;
            out(std.fmt.bufPrint(&b, "set {s}o {s}\n", .{ if (o.v) "-" else "+", o.n }) catch "");
        }
        return 0;
    }
    const all = [_]struct { n: []const u8, v: bool }{
        .{ .n = "errexit", .v = sh.opts.errexit },
        .{ .n = "noglob", .v = sh.opts.noglob },
        .{ .n = "ignoreeof", .v = sh.opts.ignoreeof },
        .{ .n = "monitor", .v = sh.opts.monitor },
        .{ .n = "noexec", .v = sh.opts.noexec },
        .{ .n = "xtrace", .v = sh.opts.xtrace },
        .{ .n = "verbose", .v = sh.opts.verbose },
        .{ .n = "noclobber", .v = sh.opts.noclobber },
        .{ .n = "allexport", .v = sh.opts.allexport },
        .{ .n = "notify", .v = sh.opts.notify },
        .{ .n = "nounset", .v = sh.opts.nounset },
        .{ .n = "errtrace", .v = sh.opts.errtrace },
        .{ .n = "vi", .v = sh.opts.vi },
        .{ .n = "pipefail", .v = sh.opts.pipefail },
    };
    for (all) |o| {
        var b: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&b, "{s:<15} {s}\n", .{ o.n, if (o.v) "on" else "off" }) catch "";
        out(m);
    }
    return 0;
}

fn noTtyWarning(sh: *Shell) void {
    var t: [256]u8 align(8) = undefined;
    if (linux.errno(linux.ioctl(0, 0x5401, @intFromPtr(&t))) == .SUCCESS) return;
    err(sh, "set", "can't access tty; job control turned off");
}

fn doSet(sh: *Shell, args: []const []const u8) u8 {
    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and (args[i][0] == '-' or args[i][0] == '+')) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-")) break;
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "+o")) {
            const on = args[i][0] == '-';
            if (i + 1 >= args.len) return listOptions(sh);
            i += 1;
            const changed = setOption(sh, args[i], on);
            if (changed and on and (std.mem.eql(u8, args[i], "monitor") or std.mem.eql(u8, args[i], "m"))) noTtyWarning(sh);
            if (!changed) {
                var b: [128]u8 = undefined;
                const m = std.fmt.bufPrint(&b, "illegal option -o {s}", .{args[i]}) catch "illegal option";
                err(sh, "set", m);
                return 2;
            }
            continue;
        }
        const code = setFlagsText(sh, args[i][0] == '-', args[i][1..]);
        if (code == 0 and args[i][0] == '-' and std.mem.indexOfScalar(u8, args[i][1..], 'm') != null) noTtyWarning(sh);
        if (code != 0) return code;
    }
    if (i == 0 and args.len == 0) return listVars(sh, false, "");
    // `set -o` with no option lists all options.
    if (i > 0 and std.mem.eql(u8, args[i - 1], "-o") and i >= args.len) return listOptions(sh);
    if (i < args.len) {
        sh.positionals.clearRetainingCapacity();
        for (args[i..]) |a| sh.positionals.append(sh.a, a) catch {};
    }
    return 0;
}

fn doShift(sh: *Shell, args: []const []const u8) u8 {
    var n: usize = 1;
    if (args.len != 0) n = std.fmt.parseInt(usize, args[0], 10) catch {
        err(sh, "shift", "numeric argument required");
        return 2;
    };
    if (n > sh.positionals.items.len) {
        err(sh, "shift", "shift count > number of positional parameters");
        return 1;
    }
    var k: usize = 0;
    while (k < n) : (k += 1) _ = sh.positionals.orderedRemove(0);
    return 0;
}

extern fn execSetExitOverride(code: u8) void;

fn doExit(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        sh.exiting = true;
        return sh.exit_code;
    }
    sh.exit_code = num(args[0]) orelse 2;
    execSetExitOverride(sh.exit_code);
    sh.exiting = true;
    return sh.exit_code;
}

fn doReturn(sh: *Shell, args: []const []const u8) u8 {
    if (sh.func_depth == 0) {
        sh.exiting = true;
        if (args.len != 0) sh.exit_code = num(args[0]) orelse 2;
        return sh.exit_code;
    }
    sh.return_pending = true;
    if (args.len != 0) sh.last_status = num(args[0]) orelse 2;
    return sh.last_status;
}

fn doBreak(sh: *Shell, args: []const []const u8, is_continue: bool) u8 {
    if (sh.loop_depth == 0) return 0;
    var n: usize = 1;
    if (args.len != 0) n = std.fmt.parseInt(usize, args[0], 10) catch 1;
    if (n > sh.loop_depth) n = sh.loop_depth;
    if (is_continue) sh.continue_count = n else sh.break_count = n;
    return 0;
}

fn doEval(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) return 0;
    var text: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, i| {
        if (i != 0) text.append(sh.a, ' ') catch {};
        text.appendSlice(sh.a, a) catch {};
    }
    if (sh.callbacks) |cb| return @intCast(cb.evalString(cb.ctx, text.items) & 0xff);
    return 0;
}

fn doExec(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) return 0;
    if (sh.callbacks == null) return 0;
    execReplace(sh, args);
    return 126;
}

fn execReplace(sh: *Shell, args: []const []const u8) void {
    const path = findProgram(sh, args[0]) orelse return;
    const argc: usize = args.len;
    const argv = sh.a.allocSentinel(?[*:0]const u8, argc, null) catch return;
    for (args, 0..) |a, i| {
        const z = zstr(sh.a, a) catch return;
        argv[i] = z.ptr;
    }
    var count: usize = 0;
    for (sh.vars.items) |v| {
        if (v.exported) count += 1;
    }
    const envp = sh.a.allocSentinel(?[*:0]const u8, count, null) catch return;
    var k: usize = 0;
    for (sh.vars.items) |v| {
        if (!v.exported) continue;
        envp[k] = (std.fmt.allocPrintSentinel(sh.a, "{s}={s}", .{ v.name, v.value }, 0) catch return).ptr;
        k += 1;
    }
    const p = zstr(sh.a, path) catch return;
    _ = linux.execve(p.ptr, argv.ptr, envp.ptr);
}

pub fn findProgram(sh: *Shell, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const z = zstr(sh.a, name) catch return null;
        defer sh.a.free(z);
        if (linux.errno(linux.access(z.ptr, linux.X_OK)) == .SUCCESS) return name;
        return null;
    }
    const path = sh.get("PATH") orelse "/bin:/usr/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const cand = if (dir.len == 0)
            sh.a.dupe(u8, name) catch return null
        else
            std.fmt.allocPrint(sh.a, "{s}/{s}", .{ dir, name }) catch return null;
        const z = zstr(sh.a, cand) catch return null;
        const ok = linux.errno(linux.access(z.ptr, linux.X_OK)) == .SUCCESS;
        sh.a.free(z);
        if (ok) return cand;
    }
    return null;
}

fn findReadable(sh: *Shell, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    const path = sh.get("PATH") orelse "/bin:/usr/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const cand = std.fmt.allocPrint(sh.a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch return null;
        const z = zstr(sh.a, cand) catch return null;
        const ok = linux.errno(linux.access(z.ptr, linux.R_OK)) == .SUCCESS;
        if (ok) return cand;
    }
    return null;
}

fn doSource(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        err(sh, ".", "filename argument required");
        return 2;
    }
    var pathbuf: []const u8 = args[0];
    if (std.mem.indexOfScalar(u8, args[0], '/') == null) {
        if (findReadable(sh, args[0])) |p| pathbuf = p;
    }
    const z = zstr(sh.a, pathbuf) catch return 1;
    defer sh.a.free(z);
    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) {
        var b: [256]u8 = undefined;
        const m = std.fmt.bufPrint(&b, "{s}: {s}", .{ args[0], @tagName(linux.errno(fd)) }) catch "";
        err(sh, ".", m);
        return 1;
    }
    var data: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(@intCast(fd), &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        data.appendSlice(sh.a, buf[0..n]) catch {};
    }
    _ = linux.close(@intCast(fd));
    // Positional arguments are temporarily replaced for a sourced script.
    var saved: std.ArrayList([]const u8) = .empty;
    saved.appendSlice(sh.a, sh.positionals.items) catch {};
    sh.positionals.clearRetainingCapacity();
    for (args[1..]) |a| sh.positionals.append(sh.a, a) catch {};
    sh.pushScope() catch {};
    const code: u8 = if (sh.callbacks) |cb| @intCast(cb.evalString(cb.ctx, data.items) & 0xff) else 0;
    sh.popScope();
    sh.positionals = saved;
    return code;
}

fn isBuiltinName(name: []const u8) bool {
    const names = [_][]const u8{ ":", "true", "false", "echo", "printf", "pwd", "cd", "export", "readonly", "unset", "set", "shift", "exit", "return", "break", "continue", "eval", "exec", ".", "source", "command", "type", "alias", "unalias", "let", "local", "read", "getopts", "trap", "umask", "ulimit", "test", "[", "wait", "jobs", "kill", "hash", "times", "history", "bg", "fg", "nolog", "help" };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn doCommand(sh: *Shell, args: []const []const u8) u8 {
    var i: usize = 0;
    var lookup_only = false;
    var verbose = false;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        for (args[i][1..]) |c| {
            if (c == 'v') lookup_only = true;
            if (c == 'V') verbose = true;
        }
    }
    if (i >= args.len) return 0;
    const name = args[i];
    if (verbose) {
        if (findProgram(sh, name) != null or isBuiltinName(name)) {
            var b: [256]u8 = undefined;
            out(std.fmt.bufPrint(&b, "{s} is a shell builtin\n", .{name}) catch "");
        } else {
            var b: [256]u8 = undefined;
            out(std.fmt.bufPrint(&b, "{s}: not found\n", .{name}) catch "");
            return 127;
        }
        return 0;
    }
    if (lookup_only) {
        if (sh.findFunc(name) != null) {
            out(name);
            out("\n");
            return 0;
        }
        if (isBuiltinName(name)) {
            out(name);
            out("\n");
            return 0;
        }
        if (findProgram(sh, name)) |p| {
            out(p);
            out("\n");
            return 0;
        }
        return 127;
    }
    // 'command' suppresses shell functions but keeps builtins.
    if (sh.callbacks) |cb| return @intCast(cb.runDirect(cb.ctx, args[i..]) & 0xff);
    return 0;
}

fn doType(sh: *Shell, args: []const []const u8) u8 {
    var code: u8 = 0;
    for (args) |name| {
        if (sh.findFunc(name) != null) {
            var b: [256]u8 = undefined;
            out(std.fmt.bufPrint(&b, "{s} is a function\n", .{name}) catch "");
        } else if (isBuiltinName(name)) {
            var b: [256]u8 = undefined;
            out(std.fmt.bufPrint(&b, "{s} is a shell builtin\n", .{name}) catch "");
        } else if (findProgram(sh, name)) |p| {
            var b: [256]u8 = undefined;
            out(std.fmt.bufPrint(&b, "{s} is {s}\n", .{ name, p }) catch "");
        } else {
            var b: [256]u8 = undefined;
            out(std.fmt.bufPrint(&b, "{s}: not found\n", .{name}) catch "");
            code = 127;
        }
    }
    return code;
}

fn doAlias(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        for (sh.aliases.items) |x| {
            var b: [512]u8 = undefined;
            out(std.fmt.bufPrint(&b, "alias {s}='{s}'\n", .{ x.name, x.value }) catch "");
        }
        return 0;
    }
    var code: u8 = 0;
    for (args) |a| {
        if (std.mem.indexOfScalar(u8, a, '=')) |p| {
            sh.setAlias(a[0..p], a[p + 1 ..]) catch {
                code = 1;
            };
        } else if (sh.getAlias(a)) |v| {
            var b: [512]u8 = undefined;
            out(std.fmt.bufPrint(&b, "alias {s}='{s}'\n", .{ a, v }) catch "");
        } else code = 1;
    }
    return code;
}

fn doUnalias(sh: *Shell, args: []const []const u8) u8 {
    var code: u8 = 0;
    for (args) |a| {
        var i: usize = sh.aliases.items.len;
        var found = false;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, sh.aliases.items[i].name, a)) {
                _ = sh.aliases.orderedRemove(i);
                found = true;
            }
        }
        if (!found) code = 1;
    }
    return code;
}

fn doLet(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) return 1;
    var last: i64 = 0;
    for (args) |a| {
        last = evalArith(sh, a) catch return 1;
    }
    return if (last != 0) 0 else 1;
}

pub fn arithGet(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const sh: *Shell = @ptrCast(@alignCast(ctx));
    var nm = name;
    if (nm.len > 1 and nm[0] == '$') nm = nm[1..];
    if (nm.len == 1 and nm[0] >= '0' and nm[0] <= '9') {
        const idx = nm[0] - '0';
        if (idx == 0) return sh.name;
        if (idx <= sh.positionals.items.len) return sh.positionals.items[idx - 1];
        return "";
    }
    if (std.mem.eql(u8, nm, "#")) {
        const text = std.fmt.allocPrint(sh.a, "{d}", .{sh.positionals.items.len}) catch return "";
        return text;
    }
    if (std.mem.eql(u8, nm, "?")) {
        return std.fmt.allocPrint(sh.a, "{d}", .{sh.last_status}) catch "";
    }
    return sh.get(nm);
}

pub fn arithSet(ctx: *anyopaque, name: []const u8, value: i64) void {
    const sh: *Shell = @ptrCast(@alignCast(ctx));
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    sh.set(name, text) catch {};
}

pub fn evalArith(sh: *Shell, text: []const u8) !i64 {
    var expr = text;
    if (std.mem.startsWith(u8, expr, "${") and std.mem.endsWith(u8, expr, "}")) {
        expr = expr[2 .. expr.len - 1];
    }
    const env = ex.ArithEnv{ .ctx = sh, .get = arithGet, .set = arithSet };
    return ex.eval(expr, env);
}

fn doLocal(sh: *Shell, args: []const []const u8) u8 {
    if (sh.func_depth == 0) {
        err(sh, "local", "not in a function");
        return 2;
    }
    var code: u8 = 0;
    for (args) |a| {
        if (std.mem.indexOfScalar(u8, a, '=')) |p| {
            sh.setLocal(a[0..p], a[p + 1 ..]) catch { code = 1; };
        } else {
            sh.setLocal(a, "") catch { code = 1; };
        }
    }
    return code;
}

fn doRead(sh: *Shell, args: []const []const u8) u8 {
    var raw = false;
    var prompt: ?[]const u8 = null;
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 1 and a[0] == '-') {
            for (a[1..]) |c| switch (c) {
                'r' => raw = true,
                else => {},
            };
            if (a.len >= 2 and a[1] == 'p' and i + 1 < args.len) {
                i += 1;
                prompt = args[i];
            }
            continue;
        }
        names.append(sh.a, a) catch {};
    }
    if (prompt) |p| out(p);
    var line: std.ArrayList(u8) = .empty;
    var protected: std.ArrayList(bool) = .empty;
    var buf: [1]u8 = undefined;
    var got_eof = false;
    while (true) {
        const n = linux.read(0, &buf, 1);
        if (linux.errno(n) != .SUCCESS) {
            got_eof = true;
            break;
        }
        if (n == 0) {
            got_eof = true;
            break;
        }
        if (buf[0] == '\n') break;
        if (buf[0] == '\\' and !raw) {
            const n2 = linux.read(0, &buf, 1);
            if (linux.errno(n2) != .SUCCESS or n2 == 0) {
                line.append(sh.a, '\\') catch {};
                protected.append(sh.a, false) catch {};
                break;
            }
            if (buf[0] == '\n') continue; // backslash-newline: continue on next line
            line.append(sh.a, buf[0]) catch {}; // backslash removes itself
            protected.append(sh.a, true) catch {}; // but the char is IFS-protected
            continue;
        }
        line.append(sh.a, buf[0]) catch {};
        protected.append(sh.a, false) catch {};
    }
    const text = line.items;
    const prot = protected.items;
    if (!got_eof or text.len != 0) {
        if (names.items.len == 0) {
            sh.set("REPLY", text) catch {};
            return 0;
        }
        const ifs = sh.get("IFS") orelse " \t\n";
        var fields: std.ArrayList([]const u8) = .empty;
        var cur: usize = 0;
        while (cur < line.items.len and std.mem.indexOfScalar(u8, ifs, line.items[cur]) != null and !prot[cur]) cur += 1;
        while (cur < line.items.len and names.items.len > fields.items.len + 1) {
            const begin = cur;
            while (cur < line.items.len and
                !(std.mem.indexOfScalar(u8, ifs, line.items[cur]) != null and !prot[cur])) cur += 1;
            fields.append(sh.a, line.items[begin..cur]) catch {};
            while (cur < line.items.len and std.mem.indexOfScalar(u8, ifs, line.items[cur]) != null and !prot[cur]) cur += 1;
        }
        fields.append(sh.a, line.items[cur..]) catch {};
        for (names.items, 0..) |name, k| {
            sh.set(name, if (k < fields.items.len) fields.items[k] else "") catch {};
        }
        return 0;
    }
    return 1;
}

fn doGetopts(sh: *Shell, args: []const []const u8) u8 {
    if (args.len < 2) return 2;
    const spec = args[0];
    const varname = args[1];
    const idx_s = sh.get("OPTIND") orelse "1";
    var idx = std.fmt.parseInt(usize, idx_s, 10) catch 1;
    if (idx == 0) idx = 1;
    const argv = sh.positionals.items;
    if (idx > argv.len or argv[idx - 1].len < 2 or argv[idx - 1][0] != '-') {
        sh.set("OPTIND", std.fmt.allocPrint(sh.a, "{d}", .{idx}) catch "1") catch {};
        sh.set(varname, "?") catch {};
        return 1;
    }
    const arg = argv[idx - 1];
    const c = arg[1];
    const pos = std.mem.indexOfScalar(u8, spec, c);
    const needs_arg = pos != null and pos.? + 1 < spec.len and spec[pos.? + 1] == ':';
    sh.set(varname, std.fmt.allocPrint(sh.a, "{c}", .{c}) catch "") catch {};
    if (needs_arg) {
        if (arg.len > 2) {
            sh.set("OPTARG", arg[2..]) catch {};
            idx += 1;
        } else if (idx < argv.len) {
            sh.set("OPTARG", argv[idx]) catch {};
            idx += 2;
        } else {
            sh.set("OPTARG", "") catch {};
            sh.set("OPTIND", std.fmt.allocPrint(sh.a, "{d}", .{idx + 1}) catch "1") catch {};
            return 1;
        }
    } else {
        if (arg.len > 2) {
            // clustered short options: rewrite the current argument
            const newarg = std.fmt.allocPrint(sh.a, "-{s}", .{arg[2..]}) catch "";
            sh.positionals.items[idx - 1] = newarg;
        } else {
            idx += 1;
        }
    }
    sh.set("OPTIND", std.fmt.allocPrint(sh.a, "{d}", .{idx}) catch "1") catch {};
    return 0;
}

fn doTrap(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        for (sh.traps.items) |t| {
            var b: [256]u8 = undefined;
            out(std.fmt.bufPrint(&b, "trap -- '{s}' {d}\n", .{ t.command, t.signal }) catch "");
        }
        return 0;
    }
    var cmd = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, cmd, "-")) {
        cmd = "";
    }
    var code: u8 = 0;
    for (rest) |sig| {
        const signum: i32 = if (std.mem.eql(u8, sig, "EXIT") or std.mem.eql(u8, sig, "0")) 0 else std.fmt.parseInt(i32, sig, 10) catch 2;
        var i: usize = sh.traps.items.len;
        while (i > 0) {
            i -= 1;
            if (sh.traps.items[i].signal == signum) _ = sh.traps.orderedRemove(i);
        }
        if (cmd.len != 0) sh.traps.append(sh.a, .{ .signal = signum, .command = cmd }) catch {
            code = 1;
        };
    }
    return code;
}

fn doUmask(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        const old = linux.syscall1(.umask, 0);
        _ = linux.syscall1(.umask, old); // querying must not change the mask
        var b: [16]u8 = undefined;
        out(std.fmt.bufPrint(&b, "{o:0>4}\n", .{old & 0o7777}) catch "0000\n");
        return 0;
    }
    const mask = std.fmt.parseInt(u32, args[0], 8) catch {
        err(sh, "umask", "illegal number");
        return 1;
    };
    _ = linux.syscall1(.umask, mask & 0o7777);
    return 0;
}

fn doHash(sh: *Shell, args: []const []const u8) u8 {
    var reset = false;
    for (args) |a| {
        if (a.len > 1 and a[0] == '-') {
            for (a[1..]) |c| {
                if (c == 'r') {
                    reset = true;
                } else {
                    var b: [96]u8 = undefined;
                    err(sh, "hash", std.fmt.bufPrint(&b, "illegal option -{c}", .{c}) catch "");
                    return 2;
                }
            }
        }
    }
    if (reset) {
        sh.hashes.clearRetainingCapacity();
        return 0;
    }
    var code: u8 = 0;
    for (args) |a| {
        if (a.len > 0 and a[0] == '-') continue;
        if (findProgram(sh, a) == null) {
            var b: [256]u8 = undefined;
            err(sh, "hash", std.fmt.bufPrint(&b, "{s}: not found", .{a}) catch "");
            code = 1;
        }
    }
    if (args.len == 0) {
        for (sh.hashes.items) |h| {
            out(h.path);
            out("\n");
        }
    }
    return code;
}

const Tms = extern struct { utime: i64, stime: i64, cutime: i64, cstime: i64 };

fn printTime(ticks: i64) void {
    const t: u64 = @intCast(@max(ticks, 0));
    const sec = t / 100;
    const ms = (t % 100) * 10;
    var b: [64]u8 = undefined;
    out(std.fmt.bufPrint(&b, "{d}m{d}.{d:0>3}s", .{ sec, ms / 1000, ms % 1000 }) catch "");
}

fn doTimes(sh: *Shell, args: []const []const u8) u8 {
    _ = sh;
    _ = args;
    var t: Tms = undefined;
    _ = linux.syscall1(.times, @intFromPtr(&t));
    printTime(t.utime + t.cutime);
    out(" ");
    printTime(t.stime + t.cstime);
    out("\n");
    printTime(t.cutime);
    out(" ");
    printTime(t.cstime);
    out("\n");
    return 0;
}

fn doHistory(sh: *Shell, args: []const []const u8) u8 {
    _ = args;
    if (sh.callbacks) |cb| cb.printHistory(cb.ctx);
    return 0;
}

fn doBgFg(sh: *Shell, cmd: []const u8, args: []const []const u8) u8 {
    if (args.len == 0) {
        err(sh, cmd, "No current job");
        return 2;
    }
    var b: [256]u8 = undefined;
    err(sh, cmd, std.fmt.bufPrint(&b, "{s}: no such job", .{args[0]}) catch "");
    return 2;
}

fn doUlimit(sh: *Shell, args: []const []const u8) u8 {
    _ = sh;
    const resources = [_]struct { n: []const u8, v: linux.rlimit_resource }{
        .{ .n = "-n", .v = .NOFILE }, .{ .n = "-v", .v = .AS },
        .{ .n = "-m", .v = .RSS }, .{ .n = "-s", .v = .STACK },
        .{ .n = "-c", .v = .CORE }, .{ .n = "-u", .v = .NPROC },
        .{ .n = "-f", .v = .FSIZE },
    };
    var chosen: ?linux.rlimit_resource = null;
    var set_value: ?u64 = null;
    for (args) |a| {
        if (a.len > 1 and a[0] == '-') {
            for (resources) |r| {
                if (std.mem.eql(u8, a, r.n)) chosen = r.v;
            }
        } else {
            set_value = if (std.mem.eql(u8, a, "unlimited")) std.math.maxInt(u64) else std.fmt.parseInt(u64, a, 10) catch return 1;
        }
    }
    if (chosen == null) {
        for (resources) |r| {
            var lim: linux.rlimit = undefined;
            if (linux.errno(linux.getrlimit(r.v, &lim)) != .SUCCESS) continue;
            var b: [128]u8 = undefined;
            const name = r.n[1..];
            const cur = if (lim.cur == std.math.maxInt(u64)) "unlimited" else std.fmt.bufPrint(&b, "{d}", .{lim.cur}) catch "";
            out(std.fmt.bufPrint(&b, "-{s} {s}\n", .{ name, cur }) catch "");
        }
        return 0;
    }
    var lim: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(chosen.?, &lim)) != .SUCCESS) return 1;
    if (set_value) |v| {
        lim.cur = v;
        if (linux.errno(linux.setrlimit(chosen.?, &lim)) != .SUCCESS) return 1;
    }
    if (lim.cur == std.math.maxInt(u64)) {
        out("unlimited\n");
    } else {
        var b: [64]u8 = undefined;
        out(std.fmt.bufPrint(&b, "{d}\n", .{lim.cur}) catch "");
    }
    return 0;
}

fn doWait(sh: *Shell, args: []const []const u8) u8 {
    var next_only = false;
    var pids: std.ArrayList(i32) = .empty;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-n")) {
            next_only = true;
            continue;
        }
        const pid = std.fmt.parseInt(i32, a, 10) catch return 1;
        pids.append(sh.a, pid) catch {};
    }
    if (next_only) {
        if (pids.items.len == 0) {
            if (sh.background_jobs.items.len == 0) return 127;
            pids.appendSlice(sh.a, sh.background_jobs.items) catch {};
        }
        for (pids.items) |pid| {
            const rc = biWaitPid(sh, pid);
            removeBackground(sh, pid);
            return rc;
        }
        return 127;
    }
    if (pids.items.len != 0) {
        var last: u8 = 0;
        for (pids.items) |pid| {
            last = biWaitPid(sh, pid);
            removeBackground(sh, pid);
        }
        return last;
    }
    var last: u8 = 0;
    const copy = sh.a.dupe(i32, sh.background_jobs.items) catch return 0;
    for (copy) |pid| {
        last = biWaitPid(sh, pid);
        removeBackground(sh, pid);
    }
    return last;
}

fn biWaitPid(sh: *Shell, pid: i32) u8 {
    _ = sh;
    var status: i32 = 0;
    const got = linux.waitpid(pid, &status, 0);
    if (linux.errno(got) != .SUCCESS) return 127;
    if ((status & 0x7f) != 0 and (status & 0x7f) != 0x7f) return @intCast(128 + (status & 0x7f));
    return @intCast((status >> 8) & 0xff);
}

fn removeBackground(sh: *Shell, pid: i32) void {
    var i: usize = sh.background_jobs.items.len;
    while (i > 0) {
        i -= 1;
        if (sh.background_jobs.items[i] == pid) {
            _ = sh.background_jobs.orderedRemove(i);
            return;
        }
    }
}

fn doJobs(sh: *Shell, args: []const []const u8) u8 {
    _ = args;
    for (sh.background_jobs.items, 1..) |_, i| {
        var b: [80]u8 = undefined;
        out(std.fmt.bufPrint(&b, "[{d}]+ Running\n", .{i}) catch "");
    }
    return 0;
}

fn doKill(sh: *Shell, args: []const []const u8) u8 {
    _ = sh;
    var sig: i32 = 15;
    var start: usize = 0;
    if (args.len != 0 and args[0].len > 0 and args[0][0] == '-') {
        sig = std.fmt.parseInt(i32, args[0][1..], 10) catch 15;
        start = 1;
    }
    var code: u8 = 0;
    for (args[start..]) |a| {
        const pid = std.fmt.parseInt(i32, a, 10) catch {
            code = 1;
            continue;
        };
        const lsig: linux.SIG = @enumFromInt(@as(u32, @intCast(sig)));
        if (linux.errno(linux.kill(pid, lsig)) != .SUCCESS) code = 1;
    }
    return code;
}

// --------------------------------------------------------------------- test

const TestCtx = struct {
    sh: *Shell,

    fn unary(sh: *Shell, op: []const u8, s: []const u8) bool {
        if (std.mem.eql(u8, op, "-n")) return s.len != 0;
        if (std.mem.eql(u8, op, "-z")) return s.len == 0;
        if (std.mem.eql(u8, op, "-e") or std.mem.eql(u8, op, "-a")) {
            const z = zstr(sh.a, s) catch return false;
            defer sh.a.free(z);
            return linux.errno(linux.access(z.ptr, linux.F_OK)) == .SUCCESS;
        }
        const modes = [_]struct { n: []const u8, m: i32 }{
            .{ .n = "-r", .m = linux.R_OK }, .{ .n = "-w", .m = linux.W_OK },
            .{ .n = "-x", .m = linux.X_OK },
        };
        for (modes) |m| {
            if (std.mem.eql(u8, op, m.n)) {
                const z = zstr(sh.a, s) catch return false;
                defer sh.a.free(z);
                return linux.errno(linux.access(z.ptr, @intCast(m.m))) == .SUCCESS;
            }
        }
        if (std.mem.eql(u8, op, "-t")) {
            const fd = std.fmt.parseInt(i32, s, 10) catch return false;
            var t: [256]u8 align(8) = undefined;
            return linux.errno(linux.ioctl(fd, 0x5401, @intFromPtr(&t))) == .SUCCESS;
        }
        const z = zstr(sh.a, s) catch return false;
        defer sh.a.free(z);
        var stx: linux.Statx = undefined;
        const follow: u32 = if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) linux.AT.SYMLINK_NOFOLLOW else 0;
        if (linux.errno(linux.statx(@intCast(linux.AT.FDCWD), z.ptr, follow, .BASIC_STATS, &stx)) != .SUCCESS) return false;
        if (std.mem.eql(u8, op, "-f")) return (stx.mode & linux.S.IFMT) == linux.S.IFREG;
        if (std.mem.eql(u8, op, "-d")) return (stx.mode & linux.S.IFMT) == linux.S.IFDIR;
        if (std.mem.eql(u8, op, "-s")) return stx.size > 0;
        if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) return (stx.mode & linux.S.IFMT) == linux.S.IFLNK;
        if (std.mem.eql(u8, op, "-b")) return (stx.mode & linux.S.IFMT) == linux.S.IFBLK;
        if (std.mem.eql(u8, op, "-c")) return (stx.mode & linux.S.IFMT) == linux.S.IFCHR;
        if (std.mem.eql(u8, op, "-p")) return (stx.mode & linux.S.IFMT) == linux.S.IFIFO;
        if (std.mem.eql(u8, op, "-S")) return (stx.mode & linux.S.IFMT) == linux.S.IFSOCK;
        return false;
    }
};

const TestParser = struct {
    args: []const []const u8,
    i: usize = 0,
    sh: *Shell,

    fn eval(self: *TestParser) bool {
        return self.orExpr();
    }

    fn orExpr(self: *TestParser) bool {
        var v = self.andExpr();
        while (self.peek("-o")) {
            self.i += 1;
            const r = self.andExpr();
            v = v or r;
        }
        return v;
    }

    fn andExpr(self: *TestParser) bool {
        var v = self.atom();
        while (self.peek("-a")) {
            self.i += 1;
            const r = self.atom();
            v = v and r;
        }
        return v;
    }

    fn peek(self: *const TestParser, s: []const u8) bool {
        return self.i < self.args.len and std.mem.eql(u8, self.args[self.i], s);
    }

    fn atom(self: *TestParser) bool {
        if (self.i >= self.args.len) return false;
        if (self.peek("!")) {
            self.i += 1;
            return !self.atom();
        }
        if (self.peek("(")) {
            self.i += 1;
            const v = self.orExpr();
            if (self.peek(")")) self.i += 1;
            return v;
        }
        const a = self.args[self.i];
        self.i += 1;
        if (self.i < self.args.len) {
            const op = self.args[self.i];
            if (isBinaryOp(op) and self.i + 1 < self.args.len) {
                self.i += 1;
                const b = self.args[self.i];
                self.i += 1;
                return compareOp(a, op, b, self.sh);
            }
        }
        if (isUnaryOp(a)) {
            if (self.i >= self.args.len) return false;
            const operand = self.args[self.i];
            self.i += 1;
            return TestCtx.unary(self.sh, a, operand);
        }
        return a.len != 0;
    }
};

fn isUnaryOp(s: []const u8) bool {
    const ops = [_][]const u8{ "-n", "-z", "-e", "-a", "-f", "-d", "-s", "-L", "-h", "-r", "-w", "-x", "-t", "-b", "-c", "-p", "-S" };
    for (ops) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn isBinaryOp(s: []const u8) bool {
    const ops = [_][]const u8{ "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef", "-a", "-o" };
    for (ops) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

const FileInfo = struct { dev: u64, ino: u64, sec: i64, nsec: u64 };

fn statInfo(sh: *Shell, path: []const u8) ?FileInfo {
    const z = zstr(sh.a, path) catch return null;
    defer sh.a.free(z);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(@intCast(linux.AT.FDCWD), z.ptr, 0, .BASIC_STATS, &stx)) != .SUCCESS) return null;
    return .{
        .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
        .ino = stx.ino,
        .sec = stx.mtime.sec,
        .nsec = stx.mtime.nsec,
    };
}

fn compareOp(a: []const u8, op: []const u8, b: []const u8, sh: *Shell) bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, a, b);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, a, b);
    if (std.mem.eql(u8, op, "<")) return std.mem.order(u8, a, b) == .lt;
    if (std.mem.eql(u8, op, ">")) return std.mem.order(u8, a, b) == .gt;
    if (std.mem.eql(u8, op, "-a")) return a.len != 0 and b.len != 0;
    if (std.mem.eql(u8, op, "-o")) return a.len != 0 or b.len != 0;
    if (std.mem.eql(u8, op, "-ef") or std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot")) {
        const fa = statInfo(sh, a) orelse return false;
        const fb = statInfo(sh, b) orelse return false;
        if (std.mem.eql(u8, op, "-ef")) {
            return fa.dev == fb.dev and fa.ino == fb.ino;
        }
        const newer = fa.sec > fb.sec or (fa.sec == fb.sec and fa.nsec > fb.nsec);
        const older = fa.sec < fb.sec or (fa.sec == fb.sec and fa.nsec < fb.nsec);
        return if (std.mem.eql(u8, op, "-nt")) newer else older;
    }
    const an = std.fmt.parseInt(i64, a, 10) catch return false;
    const bn = std.fmt.parseInt(i64, b, 10) catch return false;
    if (std.mem.eql(u8, op, "-eq")) return an == bn;
    if (std.mem.eql(u8, op, "-ne")) return an != bn;
    if (std.mem.eql(u8, op, "-lt")) return an < bn;
    if (std.mem.eql(u8, op, "-le")) return an <= bn;
    if (std.mem.eql(u8, op, "-gt")) return an > bn;
    if (std.mem.eql(u8, op, "-ge")) return an >= bn;
    return false;
}

fn doTest(sh: *Shell, name: []const u8, args: []const []const u8) u8 {
    var actual = args;
    if (std.mem.eql(u8, name, "[") and args.len > 0 and std.mem.eql(u8, args[args.len - 1], "]")) {
        actual = args[0 .. args.len - 1];
    }
    if (actual.len == 0) return 1;
    var p = TestParser{ .args = actual, .sh = sh };
    return if (p.eval()) 0 else 1;
}
