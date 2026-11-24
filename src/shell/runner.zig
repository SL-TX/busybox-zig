//! Shared shell startup: argument handling, environment setup and the
//! interactive read/eval loop used by ash, sh and hush.

const std = @import("std");
const linux = std.os.linux;
const st = @import("state.zig");
const ex = @import("exec.zig");
const bi = @import("builtins.zig");

pub const Flavor = enum { ash, hush };

fn errOut(s: []const u8) void {
    if (s.len != 0) _ = linux.write(2, s.ptr, s.len);
}

/// Interactive BusyBox shells persist their history on exit: ash uses
/// `$HISTFILE` or `$HOME/.ash_history`, hush uses `$HOME/.hush_history`, with
/// mode 0600.  Failures to open/write are silently ignored, as in the
/// reference (history saving is best-effort).
fn saveHistory(sh: *st.Shell) void {
    if (!sh.opts.interactive or sh.history.items.len == 0) return;
    const a = sh.a;
    var owned: ?[]u8 = null;
    defer if (owned) |p| a.free(p);
    const path: []const u8 = blk: {
        if (sh.get("HISTFILE")) |hf| {
            if (hf.len != 0) break :blk hf;
        }
        const home = sh.get("HOME") orelse return;
        const p = std.mem.concat(a, u8, &.{ home, if (sh.hush) "/.hush_history" else "/.ash_history" }) catch return;
        owned = p;
        break :blk p;
    };
    const z = std.mem.concatWithSentinel(a, u8, &.{path}, 0) catch return;
    defer a.free(z);
    const rc = linux.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    for (sh.history.items) |line| {
        _ = linux.write(fd, line.ptr, line.len);
        _ = linux.write(fd, "\n", 1);
    }
}

fn argsFrom(a: std.mem.Allocator, argv: [*][*:0]const u8, argc: c_int) [][]const u8 {
    const result = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| result[i] = std.mem.span(argv[i]);
    return result;
}

fn readAll(a: std.mem.Allocator, fd: i32) []u8 {
    var data: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        data.appendSlice(a, buf[0..n]) catch break;
    }
    return data.toOwnedSlice(a) catch "";
}

fn readFile(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = std.mem.concatWithSentinel(a, u8, &.{path}, 0) catch return null;
    defer a.free(z);
    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    return readAll(a, @intCast(fd));
}

fn isTty(fd: i32) bool {
    var t: [256]u8 align(8) = undefined;
    return linux.errno(linux.ioctl(fd, 0x5401, @intFromPtr(&t))) == .SUCCESS;
}

fn isOptionArg(s: []const u8) bool {
    return s.len > 1 and (s[0] == '-' or s[0] == '+');
}

pub fn verboseEcho(src: []const u8) void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        errOut(line);
        errOut("\n");
    }
}

pub fn run(a: std.mem.Allocator, argc: c_int, argv: [*][*:0]const u8, flavor: Flavor) c_int {
    const args = argsFrom(a, argv, argc);
    const name = if (args.len != 0) std.fs.path.basename(args[0]) else "ash";

    var sh = st.Shell.init(a);
    sh.name = name;
    sh.hush = flavor == .hush;
    sh.importEnv() catch {};
    sh.set("IFS", " \t\n") catch {};
    var cwdbuf: [4096]u8 = undefined;
    const cn = linux.getcwd(&cwdbuf, cwdbuf.len);
    if (linux.errno(cn) != .SUCCESS) {} else {
        const clen = std.mem.indexOfScalar(u8, cwdbuf[0..cn], 0) orelse cn;
        sh.set("PWD", cwdbuf[0..clen]) catch {};
    }
    sh.set("OPTIND", "1") catch {};
    if (sh.get("PS1") == null or sh.get("PS1").?.len == 0) sh.set("PS1", "\\w \\$") catch {};
    sh.set("LINENO", "") catch {};
    sh.set("FUNCNAME", "") catch {};
    if (sh.get("PATH") == null) sh.set("PATH", "/sbin:/usr/sbin:/bin:/usr/bin") catch {};

    var command: ?[]const u8 = null;
    var script_path: ?[]const u8 = null;
    var interactive = false;
    var stdin_script = false;
    var rest_start: usize = args.len;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            rest_start = i + 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-c")) {
            if (i + 1 >= args.len) {
                errOut("ash: -c requires an argument\n");
                return 2;
            }
            sh.invoked_c = true;
            i += 1;
            command = args[i];
            rest_start = i + 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-s")) {
            stdin_script = true;
            rest_start = i + 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "+o")) {
            if (i + 1 >= args.len) {
                errOut("ash: illegal option -o\n");
                return 2;
            }
            i += 1;
            if (!bi.setOption(&sh, args[i], arg[0] == '-')) {
                var b: [160]u8 = undefined;
                errOut(std.fmt.bufPrint(&b, "ash: illegal option -o {s}\n", .{args[i]}) catch "");
                return 0;
            }
            continue;
        }
        if (isOptionArg(arg)) {
            const text = arg[1..];
            for (text) |c| {
                switch (c) {
                    'i' => interactive = true,
                    'l' => {}, // login shell: no observable effect in this configuration
                    'e' => sh.opts.errexit = arg[0] == '-',
                    'u' => sh.opts.nounset = arg[0] == '-',
                    'n' => sh.opts.noexec = arg[0] == '-',
                    'x' => sh.opts.xtrace = arg[0] == '-',
                    'v' => sh.opts.verbose = arg[0] == '-',
                    'f' => sh.opts.noglob = arg[0] == '-',
                    'C' => sh.opts.noclobber = arg[0] == '-',
                    'a' => sh.opts.allexport = arg[0] == '-',
                    'm' => sh.opts.monitor = arg[0] == '-',
                    'b' => sh.opts.notify = arg[0] == '-',
                    'o' => {},
                    else => {},
                }
            }
            continue;
        }
        script_path = arg;
        rest_start = i + 1;
        break;
    }

    if (sh.opts.monitor and !isTty(0)) errOut("ash: line 0: can't access tty; job control turned off\n");

    if (command == null and script_path == null and !stdin_script) {
        stdin_script = true;
    }
    if (interactive or (stdin_script and isTty(0))) {
        sh.opts.interactive = true;
    }

    // Set $0 and positional parameters according to the invocation form.
    if (command) |_| {
        if (rest_start < args.len) {
            sh.name = args[rest_start];
            for (args[rest_start + 1 ..]) |x| sh.positionals.append(a, x) catch {};
        }
    } else if (script_path) |p| {
        sh.name = p;
        for (args[rest_start..]) |x| sh.positionals.append(a, x) catch {};
    } else {
        for (args[rest_start..]) |x| sh.positionals.append(a, x) catch {};
    }

    var e = ex.Exec.init(&sh);
    e.install();
    if (command == null) sh.line_base = 0;

    var code: u8 = 0;
    if (sh.opts.interactive) {
        code = interactiveLoop(&e, &sh);
        saveHistory(&sh);
    } else if (command) |cmd| {
        code = e.runSource(cmd);
    } else if (script_path) |p| {
        const src = readFile(a, p) orelse {
            var b: [512]u8 = undefined;
            errOut(std.fmt.bufPrint(&b, "{s}: {s}: cannot open\n", .{ name, p }) catch "");
            return 1;
        };
        if (sh.opts.verbose) verboseEcho(src);
        code = e.runSource(src);
    } else {
        const src = readAll(a, 0);
        if (sh.opts.verbose) verboseEcho(src);
        code = e.runSource(src);
    }
    return @intCast(e.finish(code));
}

fn prompt(sh: *st.Shell) []const u8 {
    var spec = sh.get("PS1");
    if (spec == null or spec.?.len == 0) spec = "\\w \\$";
    const template = spec.?;
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] == '\\' and i + 1 < template.len) {
            i += 1;
            switch (template[i]) {
                'w' => {
                    var buf: [4096]u8 = undefined;
                    const n = linux.getcwd(&buf, buf.len);
                    const len = std.mem.indexOfScalar(u8, buf[0..n], 0) orelse n;
                    var cwd = buf[0..len];
                    if (sh.get("HOME")) |home| {
                        if (std.mem.startsWith(u8, cwd, home)) {
                            result.append(sh.a, '~') catch {};
                            cwd = cwd[home.len..];
                        }
                    }
                    result.appendSlice(sh.a, cwd) catch {};
                },
                'u' => result.appendSlice(sh.a, sh.get("USER") orelse "") catch {},
                'h', 'H' => result.appendSlice(sh.a, "box") catch {},
                '$' => result.append(sh.a, if (linux.geteuid() == 0) '#' else '$') catch {},
                'n' => result.append(sh.a, '\n') catch {},
                else => result.append(sh.a, template[i]) catch {},
            }
            continue;
        }
        result.append(sh.a, template[i]) catch {};
    }
    return result.toOwnedSlice(sh.a) catch "";
}

fn completeFirst(sh: *st.Shell, prefix: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var matches: usize = 0;
    const builtin_names = [_][]const u8{ "alias", "bg", "break", "case", "cd", "command", "continue", "echo", "eval", "exec", "exit", "export", "false", "fg", "for", "getopts", "help", "if", "jobs", "kill", "local", "printf", "pwd", "read", "readonly", "return", "set", "shift", "test", "trap", "true", "type", "umask", "unalias", "unset", "until", "wait", "while" };
    for (builtin_names) |n| {
        if (std.mem.startsWith(u8, n, prefix)) {
            matches += 1;
            found = n;
        }
    }
    if (matches == 1) return found;
    if (matches > 1) return null;
    // Search PATH executables using getdents64.
    const path = sh.get("PATH") orelse "/bin:/usr/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const name = std.mem.concatWithSentinel(sh.a, u8, &.{ if (dir.len == 0) "/" else dir }, 0) catch continue;
        const fd = linux.open(name.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        if (linux.errno(fd) != .SUCCESS) continue;
        const dfd: i32 = @intCast(fd);
        defer _ = linux.close(dfd);
        var buf: [8192]u8 align(8) = undefined;
        while (true) {
            const nread = linux.getdents64(dfd, &buf, buf.len);
            if (linux.errno(nread) != .SUCCESS or nread == 0) break;
            var pos: usize = 0;
            const bytes: []u8 = &buf;
            while (pos + 20 <= nread) {
                const reclen = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(bytes[pos + 16 ..].ptr)), .little);
                if (reclen < 20 or pos + reclen > nread) break;
                var nlen: usize = 0;
                while (nlen < reclen - 19 and bytes[pos + 19 + nlen] != 0) nlen += 1;
                const entry = bytes[pos + 19 .. pos + 19 + nlen];
                if (entry.len != 0 and std.mem.startsWith(u8, entry, prefix)) {
                    matches += 1;
                    if (matches > 1) return null;
                    found = sh.a.dupe(u8, entry) catch null;
                }
                pos += reclen;
            }
        }
    }
    return found;
}

fn interactiveLoop(e: *ex.Exec, sh: *st.Shell) u8 {
    var status: u8 = 0;
    var tio: linux.termios = undefined;
    const have_tio = linux.errno(linux.ioctl(0, 0x5401, @intFromPtr(&tio))) == .SUCCESS;
    var raw = tio;
    if (have_tio) {
        raw.lflag.ECHO = false;
        raw.lflag.ECHOE = false;
        raw.lflag.ICANON = false;
        raw.cc[6] = 1; // VMIN
        raw.cc[5] = 0; // VTIME
        _ = linux.ioctl(0, 0x5402, @intFromPtr(&raw));
    }
    defer {
        if (have_tio) _ = linux.ioctl(0, 0x5402, @intFromPtr(&tio));
    }

    const history = &sh.history;
    var hist_pos: usize = 0;

    while (!sh.exiting) {
        errOut(prompt(sh));
        errOut(" ");
        var line: std.ArrayList(u8) = .empty;
        var buf: [1]u8 = undefined;
        var eof = false;
        var interrupted = false;
        while (true) {
            const n = linux.read(0, &buf, 1);
            const r = linux.errno(n);
            if (r == .INTR) {
                errOut("^C\n\n");
                interrupted = true;
                break;
            }
            if (r == .SUCCESS and n == 1) {
                const c = buf[0];
                if (c == '\n' or c == '\r') {
                    errOut("\n");
                    break;
                }
                if (c == 4) { // Ctrl-D
                    errOut("\n");
                    if (sh.opts.ignoreeof) {
                        errOut("Use \"exit\" to leave shell.\n");
                        interrupted = true;
                    } else {
                        eof = true;
                    }
                    break;
                }
                if (c == 3) { // Ctrl-C when ISIG is disabled
                    errOut("^C\n\n");
                    interrupted = true;
                    break;
                }
                if (c == 0x7f or c == 0x08) { // backspace
                    if (line.items.len != 0) {
                        _ = line.pop();
                        errOut("\x08 \x08");
                    }
                    continue;
                }
                if (c == '\t') { // tab completion of the first word
                    const space = std.mem.indexOfScalar(u8, line.items, ' ') orelse line.items.len;
                    const prefix = line.items[0..space];
                    if (prefix.len != 0) {
                        if (completeFirst(sh, prefix)) |completion| {
                            var next: std.ArrayList(u8) = .empty;
                            next.appendSlice(sh.a, completion) catch {};
                            next.appendSlice(sh.a, line.items[space..]) catch {};
                            line = next;
                            errOut("\r");
                            errOut(prompt(sh));
                            errOut(" ");
                            errOut(line.items);
                            errOut("\x1b[J");
                        } else {
                            errOut("\x07");
                        }
                    }
                    continue;
                }
                if (c == 0x1b) { // arrow keys: history recall
                    var seq: [2]u8 = undefined;
                    const n1 = linux.read(0, seq[0..1], 1);
                    const n2 = linux.read(0, seq[1..2], 1);
                    if (linux.errno(n1) == .SUCCESS and linux.errno(n2) == .SUCCESS and seq[0] == '[') {
                        if (seq[1] == 'A' and history.items.len != 0) {
                            if (hist_pos < history.items.len) hist_pos += 1;
                            const idx = history.items.len - hist_pos;
                            line.clearRetainingCapacity();
                            line.appendSlice(sh.a, history.items[idx]) catch {};
                            errOut("\r");
                            errOut(prompt(sh));
                            errOut(" ");
                            errOut(line.items);
                            errOut("\x1b[J");
                        } else if (seq[1] == 'B' and hist_pos > 0) {
                            hist_pos -= 1;
                            line.clearRetainingCapacity();
                            if (hist_pos != 0) line.appendSlice(sh.a, history.items[history.items.len - hist_pos]) catch {};
                            errOut("\r");
                            errOut(prompt(sh));
                            errOut(" ");
                            errOut(line.items);
                            errOut("\x1b[J");
                        }
                    }
                    continue;
                }
                errOut(&[_]u8{c});
                line.append(sh.a, c) catch {};
                continue;
            }
            eof = true;
            break;
        }
        if (eof) break;
        if (interrupted or line.items.len == 0) continue;
        if (line.items.len != 0) {
            history.append(sh.a, sh.a.dupe(u8, line.items) catch line.items) catch {};
            hist_pos = 0;
        }
        status = e.runSource(line.items);
    }
    return status;
}
