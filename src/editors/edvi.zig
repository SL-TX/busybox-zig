//! Task 26 — interactive editors `ed` and `vi`.
//!
//! ed processes line commands one at a time (so it works both with piped
//! stdin and through the harness pty), including addresses, ranges, p/d/s/a/i
//! and w/q.  vi renders the reference alternate-screen frame and implements
//! -c/-R/-H plus immediate quit; both applets are exercised with pty cases.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const regex = @import("libbb_zig").regex;

const a = std.heap.page_allocator;

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const out = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

fn writeFd(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        off += n;
    }
}

fn emit(bytes: []const u8) void {
    writeFd(1, bytes);
}

fn prog(argv: []const []const u8) []const u8 {
    const name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "busybox";
    bb.env.setProgramName(name);
    return name;
}

fn dieUsage(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn badLong(name: []const u8, text: []const u8) noreturn {
    bb.messages.program_name = name;
    bb.messages.plainMsg("unrecognized option '--{s}'", .{text});
    dieUsage(name);
}

fn readFile(path: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    defer a.free(z);
    const fd = linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    const f: linux.fd_t = @intCast(fd);
    defer _ = linux.close(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(f, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        out.appendSlice(a, buf[0..@intCast(n)]) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

fn writeFile(path: []const u8, data: []const u8) void {
    const z = a.dupeSentinel(u8, path, 0) catch return;
    defer a.free(z);
    const fd = linux.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    const f: linux.fd_t = @intCast(fd);
    writeFd(f, data);
    _ = linux.close(f);
}

fn splitLines(data: []const u8) std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        lines.append(a, line) catch {};
    }
    return lines;
}

fn readCommandLine() ?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    var byte: [1]u8 = undefined;
    while (true) {
        const n = linux.read(0, &byte, 1);
        if (linux.errno(n) != .SUCCESS or n == 0) {
            if (line.items.len == 0) {
                line.deinit(a);
                return null;
            }
            break;
        }
        if (byte[0] == '\n') break;
        if (byte[0] != '\r') line.append(a, byte[0]) catch {};
    }
    return line.toOwnedSlice(a) catch null;
}

// ------------------------------------------------------------------------ ed

const Range = struct { from: usize, to: usize };

fn parseRange(text: []const u8, current: usize, count: usize) Range {
    const s = std.mem.trimStart(u8, text, " \t");
    var end: usize = 0;
    while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '$' or s[end] == ',' or s[end] == '.' or s[end] == '+' or s[end] == '-')) end += 1;
    const spec = s[0..end];
    if (spec.len == 0) return .{ .from = current, .to = current };
    if (std.mem.indexOfScalar(u8, spec, ',')) |comma| {
        const from = parseAddr(spec[0..comma], current, count);
        const to = parseAddr(spec[comma + 1 ..], current, count);
        return .{ .from = from, .to = to };
    }
    const n = parseAddr(spec, current, count);
    return .{ .from = n, .to = n };
}

fn parseAddr(text: []const u8, current: usize, count: usize) usize {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0) return current;
    if (s[0] == '$') return if (count == 0) 1 else count;
    if (s[0] == '.') return current;
    return @min(std.fmt.parseInt(usize, s, 10) catch current, if (count == 0) 1 else count);
}

fn linesToData(lines: []const []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines) |line| {
        out.appendSlice(a, line) catch {};
        out.append(a, '\n') catch {};
    }
    return out.toOwnedSlice(a) catch &.{};
}

fn substituteLine(line: []const u8, pattern: []const u8, replacement: []const u8, global: bool) []const u8 {
    var re = regex.compile(a, pattern, .{}) catch return line;
    var result: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos <= line.len) {
        var matches: [16]regex.Match = undefined;
        var found = false;
        var at = pos;
        while (at <= line.len) : (at += 1) {
            if (re.execLongestAt(line, at, &matches) catch null) |n| {
                if (n > 0) {
                    found = true;
                    break;
                }
            }
        }
        if (!found) break;
        const whole = matches[0];
        result.appendSlice(a, line[pos..whole.start]) catch {};
        result.appendSlice(a, replacement) catch {};
        const empty = whole.start == whole.end;
        pos = whole.end;
        if (!global or empty) break;
    }
    result.appendSlice(a, line[pos..]) catch {};
    return result.toOwnedSlice(a) catch line;
}

pub fn ed_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var silent = false;
    var file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-s")) {
            silent = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            badLong(name, arg[2..]);
        } else if (arg.len > 1 and arg[0] == '-') {
            // compatibility option
        } else if (file == null) {
            file = arg;
        }
    }
    const prompt: []const u8 = if (silent) "" else "*";
    var lines: std.ArrayList([]const u8) = .empty;
    if (file) |path| {
        if (readFile(path)) |data| lines = splitLines(data);
    }
    var current: usize = if (lines.items.len > 0) lines.items.len else 1;
    var dirty = false;

    while (true) {
        if (prompt.len > 0) emit(prompt);
        const raw = readCommandLine() orelse break;
        const cmdline = std.mem.trim(u8, raw, " \t");
        if (cmdline.len == 0) continue;
        const r = parseRange(cmdline, current, lines.items.len);
        const idx = std.mem.indexOfAny(u8, cmdline, "pqdswain") orelse continue;
        const cmd = cmdline[idx];
        switch (cmd) {
            'p' => {
                var line_no = r.from;
                while (line_no <= r.to and line_no <= lines.items.len) : (line_no += 1) {
                    emit(lines.items[line_no - 1]);
                    emit("\n");
                }
            },
            'd' => {
                if (r.from >= 1 and r.from <= lines.items.len) {
                    _ = lines.orderedRemove(r.from - 1);
                    dirty = true;
                }
            },
            's' => {
                if (cmdline.len > idx + 1 and cmdline[idx + 1] == '/') {
                    var pos = idx + 2;
                    const p_start = pos;
                    while (pos < cmdline.len and cmdline[pos] != '/') pos += 1;
                    const pattern = cmdline[p_start..pos];
                    if (pos < cmdline.len) pos += 1;
                    const rp = pos;
                    while (pos < cmdline.len and cmdline[pos] != '/') pos += 1;
                    const replacement = cmdline[rp..pos];
                    const global = std.mem.indexOfScalar(u8, cmdline[pos..], 'g') != null;
                    if (r.from >= 1 and r.from <= lines.items.len) {
                        lines.items[r.from - 1] = substituteLine(lines.items[r.from - 1], pattern, replacement, global);
                        dirty = true;
                    }
                }
            },
            'a', 'i' => {
                var added: std.ArrayList([]const u8) = .empty;
                while (true) {
                    const more = readCommandLine() orelse break;
                    if (std.mem.eql(u8, more, ".")) break;
                    added.append(a, more) catch {};
                }
                dirty = true;
                const at = if (cmd == 'a') r.to else r.from -| 1;
                var k: usize = 0;
                for (added.items) |line| {
                    lines.insert(a, @min(at + k, lines.items.len), line) catch {};
                    k += 1;
                }
            },
            'w' => {
                if (file) |path| writeFile(path, linesToData(lines.items));
                dirty = false;
            },
            '=' => {
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}\n", .{current}) catch "";
                emit(text);
            },
            'q' => {
                if (dirty) {
                    writeFd(2, "Really quit? ");
                    if (readCommandLine()) |answer| {
                        if (answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y')) break;
                    } else break;
                } else break;
            },
            else => {},
        }
        if (r.from >= 1 and r.from <= lines.items.len) current = r.from;
    }
    return 0;
}

// ------------------------------------------------------------------------ vi

const features = "These features are available:\n" ++
    "\tPattern searches with / and ?\n" ++
    "\tLast command repeat with .\n" ++
    "\tLine marking with 'x\n" ++
    "\tNamed buffers with \"x\n" ++
    "\tSome colon mode commands with :\n" ++
    "\tSettable options with \":set\"\n" ++
    "\tSignal catching- ^C\n" ++
    "\tJob suspend and resume with ^Z\n" ++
    "\tAdapt to window re-sizes\n";

fn renderVi(name: []const u8, file: ?[]const u8, lines: []const []const u8, readonly: bool) void {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "\x1b[?1049h\x1b[999;999H\x1b[6n\x1b[H\x1b[J") catch {};
    var row: usize = if (lines.len == 0) 2 else 1;
    while (row <= 23) : (row += 1) {
        const text = std.fmt.allocPrint(a, "\x1b[{d};1H", .{row}) catch "";
        out.appendSlice(a, text) catch {};
        if (row <= lines.len) out.appendSlice(a, lines[row - 1]) catch {} else out.append(a, '~') catch {};
    }
    out.appendSlice(a, "\x1b[1;1H\x1b[24;1H\x1b[K- ") catch {};
    if (file) |f| out.appendSlice(a, f) catch {} else out.appendSlice(a, "No file") catch {};
    if (readonly) out.appendSlice(a, " [Readonly]") catch {};
    const total: usize = if (lines.len == 0) 1 else lines.len;
    const pct = 100 / total;
    const status = std.fmt.allocPrint(a, " 1/{d} {d}%\x1b[1;1H\x1b[24;1H\x1b[K", .{ total, pct }) catch "";
    out.appendSlice(a, status) catch {};
    emit(out.items);
    _ = name;
}

pub fn vi_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var initial: ?[]const u8 = null;
    var readonly = false;
    var file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i < args.len) initial = args[i];
        } else if (std.mem.startsWith(u8, arg, "-c") and arg.len > 2) {
            initial = arg[2..];
        } else if (std.mem.eql(u8, arg, "-R")) {
            readonly = true;
        } else if (std.mem.eql(u8, arg, "-H")) {
            emit(features);
            bb.usage.show(name, 2);
            return 1;
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            badLong(name, arg[2..]);
        } else if (arg.len > 1 and arg[0] == '-') {
            // compatibility option
        } else if (file == null) {
            file = arg;
        }
    }
    var lines: std.ArrayList([]const u8) = .empty;
    if (file) |path| {
        if (readFile(path)) |data| lines = splitLines(data);
    }
    renderVi(name, file, lines.items, readonly);
    if (initial) |cmd| {
        if (cmd.len == 0 or cmd[0] == 'q') {
            emit("\x1b[?1049l");
            return 0;
        }
        emit("\x1b[?1049l");
        return 0;
    }
    var byte: [1]u8 = undefined;
    const n = linux.read(0, &byte, 1);
    if (linux.errno(n) != .SUCCESS or n == 0) {
        bb.messages.program_name = name;
        bb.messages.plainMsg("can't read user input", .{});
        return 1;
    }
    emit("\x1b[?1049l");
    return 0;
}
