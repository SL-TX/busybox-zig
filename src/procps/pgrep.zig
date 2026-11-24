//! pgrep / pkill — port of procps/pgrep.c.
//! BusyBox uses one main for both applets; pkill.zig is the thin entry point.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");
const proc = bb.procps;
const regex = bb.regex;
const pid_t = c.pid_t;

pub const Options = struct {
    list: bool = false,
    listfull: bool = false,
    full: bool = false,
    anchor: bool = false,
    newest: bool = false,
    oldest: bool = false,
    invert: bool = false,
    echo: bool = false,
    sid: i64 = -1,
    ppid: i64 = -1,
    signo: c_int = 15,
    pattern: ?[]const u8 = null,
    extra: bool = false,
};

fn flagBit(opts: *Options, ch: u8, is_pkill: bool) bool {
    switch (ch) {
        'l' => {
            if (is_pkill) opts.list = true else opts.list = true;
        },
        'a' => opts.listfull = true,
        'f' => opts.full = true,
        'x' => opts.anchor = true,
        'o' => opts.oldest = true,
        'n' => opts.newest = true,
        'v' => opts.invert = true,
        'e' => opts.echo = true,
        else => return false,
    }
    return true;
}

fn parse(prog: []const u8, av: []const []const u8, is_pkill: bool) Options {
    var opts = Options{};
    var i: usize = 1;
    if (is_pkill and i < av.len and av[i].len > 1 and av[i][0] == '-') {
        if (c.getSignum(av[i][1..])) |sig| {
            opts.signo = sig;
            i += 1;
        }
    }
    var positional: ?[]const u8 = null;
    var extra = false;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (std.mem.eql(u8, tok, "--")) {
            i += 1;
            while (i < av.len) : (i += 1) {
                if (positional == null) positional = av[i] else extra = true;
            }
            break;
        }
        if (tok.len < 2 or tok[0] != '-') {
            if (positional == null) positional = tok else extra = true;
            continue;
        }
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            if (flagBit(&opts, ch, is_pkill)) continue;
            if (ch == 's' or ch == 'P') {
                var value = tok[j + 1 ..];
                if (value.len == 0) {
                    if (i + 1 >= av.len) {
                        c.plainMsg("option requires an argument -- '{c}'", .{ch});
                        c.usageDie(prog);
                    }
                    i += 1;
                    value = av[i];
                }
                const num = std.fmt.parseInt(i64, value, 10) catch {
                    c.plainMsg("invalid number '{s}'", .{value});
                    std.process.exit(1);
                };
                if (ch == 's') opts.sid = num else opts.ppid = num;
                break;
            }
            c.plainMsg("invalid option -- '{c}'", .{ch});
            c.usageDie(prog);
        }
    }
    opts.pattern = positional;
    opts.extra = extra;
    return opts;
}

fn act(pid: pid_t, cmd: []const u8, opts: Options, is_pkill: bool) void {
    if (!is_pkill) {
        if (opts.list or opts.listfull) c.printfOut("{d} {s}\n", .{ pid, cmd }) else c.printfOut("{d}\n", .{pid});
        return;
    }
    _ = linux.kill(pid, @enumFromInt(@as(u32, @bitCast(opts.signo))));
    if (opts.echo) c.printfOut("{s} killed (pid {d})\n", .{ cmd, pid });
}

fn matches(re: ?*const regex.Regex, text: []const u8, anchor: bool) bool {
    const r = re orelse return true;
    var m: [1]regex.Match = undefined;
    const n = r.exec(text, &m) catch return false;
    if (n == 0) return false;
    if (anchor) return m[0].start == 0 and m[0].end == text.len;
    return true;
}

pub fn pgrepMain(is_pkill: bool, argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const av = c.argsFrom(a, argv, argc) catch return 1;
    defer a.free(av);
    const prog = std.fs.path.basename(av[0]);
    c.setName(prog);

    const opts = parse(prog, av, is_pkill);
    if (is_pkill and opts.list) {
        c.printSignames();
        return 0;
    }
    if ((opts.sid < 0 and opts.ppid < 0) and (opts.pattern == null or opts.extra)) {
        c.usageDie(prog);
    }
    var sid = opts.sid;
    if (sid == 0) sid = @intCast(linux.getsid(0));

    var re: ?regex.Regex = null;
    if (opts.pattern) |pattern| {
        re = regex.compile(a, pattern, .{ .extended = !opts.anchor }) catch {
            c.plainMsg("Invalid regex '{s}'", .{pattern});
            return 1;
        };
    }
    defer if (re) |*r| r.deinit();

    const mypid = linux.getpid();
    const pids = c.listPids(a, "/proc") catch return 1;
    defer a.free(pids);

    var matched: pid_t = 0;
    var last_cmd: ?[]u8 = null;
    defer if (last_cmd) |s| a.free(s);

    for (pids) |pid| {
        if (pid == mypid) continue;
        const st = proc.parseProcStat(pid) catch continue;
        if (!opts.invert) {
            if (opts.ppid >= 0 and opts.ppid != st.ppid) continue;
            if (sid >= 0 and sid != st.session) continue;
        }
        var cmd: []const u8 = st.commSlice();
        const raw_cmd = c.cmdline(a, pid);
        defer if (raw_cmd) |s| a.free(s);
        if (raw_cmd) |rc| {
            if (rc.len > 0) cmd = rc;
        }
        var matched_pattern = matches(if (re) |*r| r else null, cmd, opts.anchor);
        if (!matched_pattern) {
            matched_pattern = matches(if (re) |*r| r else null, st.commSlice(), opts.anchor);
        }
        if (opts.invert) {
            if ((opts.ppid >= 0 and opts.ppid != st.ppid) or (sid >= 0 and sid != st.session)) {
                matched_pattern = true;
            } else {
                matched_pattern = !matched_pattern;
            }
        }
        if (!matched_pattern) continue;
        matched = pid;
        if (opts.newest) {
            if (last_cmd) |s| a.free(s);
            last_cmd = a.dupe(u8, cmd) catch null;
            continue;
        }
        act(pid, cmd, opts, is_pkill);
        if (opts.oldest) break;
    }
    if (last_cmd) |cmd| act(matched, cmd, opts, is_pkill);
    return if (matched == 0) 1 else 0;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return pgrepMain(false, argc, argv);
}
