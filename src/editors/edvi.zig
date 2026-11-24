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
    var prompt: []const u8 = ""; // reference: no prompt unless -p is given
    var file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-s")) {
            silent = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) prompt = args[i];
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
    var current: usize = if (lines.items.len > 0) lines.items.len else 1;
    var dirty = false;

    while (true) {
        if (prompt.len > 0) writeFd(2, prompt);
        const raw = readCommandLine() orelse break;
        const cmdline = std.mem.trim(u8, raw, " \t");
        if (cmdline.len == 0) continue;
        const r = parseRange(cmdline, current, lines.items.len);
        const idx = std.mem.indexOfAny(u8, cmdline, "pqdswain=") orelse continue;
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
                var ln = r.to;
                while (ln >= r.from and ln >= 1 and ln <= lines.items.len) : (ln -= 1) {
                    _ = lines.orderedRemove(ln - 1);
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
                const text = std.fmt.bufPrint(&buf, "{d}\n", .{if (r.from >= 1) r.from else current}) catch "";
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

fn renderVi(name: []const u8, file: ?[]const u8, lines: []const []const u8, cursor_line: usize, readonly: bool, modified: bool, status_msg: ?[]const u8) void {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "\x1b[?1049h\x1b[999;999H\x1b[6n\x1b[H\x1b[J") catch {};
    var row: usize = if (lines.len == 0) 2 else 1;
    while (row <= 23) : (row += 1) {
        const text = std.fmt.allocPrint(a, "\x1b[{d};1H", .{row}) catch "";
        out.appendSlice(a, text) catch {};
        if (row <= lines.len) out.appendSlice(a, lines[row - 1]) catch {} else out.append(a, '~') catch {};
    }
    const cur: usize = if (cursor_line == 0) 1 else cursor_line;
    const home = std.fmt.allocPrint(a, "\x1b[{d};1H", .{cur}) catch "\x1b[1;1H";
    out.appendSlice(a, home) catch {};
    out.appendSlice(a, "\x1b[24;1H\x1b[K") catch {};
    if (status_msg) |msg| {
        out.appendSlice(a, msg) catch {};
    } else {
        out.appendSlice(a, "- ") catch {};
        if (file) |f| out.appendSlice(a, f) catch {} else out.appendSlice(a, "No file") catch {};
        if (readonly) out.appendSlice(a, " [Readonly]") catch {};
        if (modified) out.appendSlice(a, " [Modified]") catch {};
        const total: usize = if (lines.len == 0) 1 else lines.len;
        const pct = if (cur > total) 100 else (cur * 100) / total;
        const status = std.fmt.allocPrint(a, " {d}/{d} {d}%", .{ cur, total, pct }) catch "";
        out.appendSlice(a, status) catch {};
    }
    out.appendSlice(a, "\x1b[1;1H\x1b[24;1H\x1b[K") catch {};
    emit(out.items);
    _ = name;
}

fn writeMessage(file: ?[]const u8, lines: []const []const u8) []const u8 {
    var chars: usize = 0;
    for (lines) |line| chars += line.len + 1;
    const path = file orelse "No file";
    return std.fmt.allocPrint(a, "'{s}' {d}L, {d}C", .{ path, lines.len, chars }) catch "";
}

fn viSubstitute(lines: *std.ArrayList([]const u8), command: []const u8) void {
    if (command.len < 3 or command[0] != 's') return;
    const delim = command[1];
    var pos: usize = 2;
    const p0 = pos;
    while (pos < command.len and command[pos] != delim) pos += 1;
    const pattern = command[p0..pos];
    if (pos >= command.len) return;
    pos += 1;
    const r0 = pos;
    while (pos < command.len and command[pos] != delim) pos += 1;
    const replacement = command[r0..pos];
    const global = std.mem.indexOfScalar(u8, command[pos..], 'g') != null;
    for (lines.items) |*line| {
        line.* = substituteLine(line.*, pattern, replacement, global);
    }
}

fn readKey() ?u8 {
    var byte: [1]u8 = undefined;
    const n = linux.read(0, &byte, 1);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    return byte[0];
}

fn readUntil(stop: u8) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    while (true) {
        const ch = readKey() orelse {
            if (buf.items.len == 0) return null;
            break;
        };
        if (ch == stop) break;
        buf.append(a, ch) catch {};
    }
    return buf.toOwnedSlice(a) catch null;
}

pub fn vi_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var commands: std.ArrayList([]const u8) = .empty;
    var readonly = false;
    var file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i < args.len) commands.append(a, args[i]) catch {};
        } else if (std.mem.startsWith(u8, arg, "-c") and arg.len > 2) {
            commands.append(a, arg[2..]) catch {};
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
    var cursor: usize = 1;
    var modified = false;
    var quit = false;
    var status_override: ?[]const u8 = null;

    // -c commands are real ex commands, executed in order at startup.
    for (commands.items) |raw| {
        var cmd = std.mem.trim(u8, raw, " \t");
        if (cmd.len > 0 and cmd[0] == ':') cmd = std.mem.trimStart(u8, cmd[1..], " \t");
        if (cmd.len == 0) continue;
        if (std.mem.startsWith(u8, cmd, "s/")) viSubstitute(&lines, cmd);
        if (cmd[0] == 'w') {
            modified = false;
            if (file) |path| writeFile(path, linesToData(lines.items));
            status_override = writeMessage(file, lines.items);
        }
        if (cmd[0] == 'q' or std.mem.eql(u8, cmd, "wq")) {
            quit = true;
            break;
        }
    }
    renderVi(name, file, lines.items, cursor, readonly, modified, status_override);
    if (quit) {
        emit("\x1b[?1049l");
        return 0;
    }

    // Normal-mode editor loop. Each command is applied to the in-memory
    // buffer and the screen is redrawn so interactive cases observe edits.
    while (!quit) {
        const key = readKey() orelse {
            bb.messages.program_name = name;
            bb.messages.plainMsg("can't read user input", .{});
            return 1;
        };
        switch (key) {
            'h' => { if (cursor > 1) cursor -= 1; },
            'l' => { if (lines.items.len > 0 and cursor < lines.items.len) cursor += 1; },
            'j' => { if (lines.items.len > 0 and cursor < lines.items.len) cursor += 1; },
            'k' => { if (cursor > 1) cursor -= 1; },
            'x' => {
                if (cursor <= lines.items.len and lines.items[cursor - 1].len > 0) {
                    const old = lines.items[cursor - 1];
                    lines.items[cursor - 1] = a.dupe(u8, old[1..]) catch old;
                    modified = true;
                }
            },
            'd' => {
                const next = readKey();
                if (next == 'd' and cursor <= lines.items.len) {
                    _ = lines.orderedRemove(cursor - 1);
                    if (cursor > lines.items.len and lines.items.len > 0) cursor = lines.items.len;
                    modified = true;
                }
            },
            'i', 'a' => {
                const insert_at = if (key == 'i') cursor - 1 else cursor;
                var text: std.ArrayList(u8) = .empty;
                while (true) {
                    const ch = readKey() orelse break;
                    if (ch == 0x1b) break;
                    text.append(a, ch) catch {};
                }
                if (cursor <= lines.items.len) {
                    const old = lines.items[cursor - 1];
                    const at = @min(insert_at, old.len);
                    const joined = std.mem.concat(a, u8, &.{ old[0..at], text.items, old[at..] }) catch old;
                    lines.items[cursor - 1] = joined;
                } else {
                    lines.append(a, text.toOwnedSlice(a) catch "") catch {};
                }
                modified = true;
            },
            '/' => {
                const needle = readUntil('\n') orelse "";
                for (lines.items, 1..) |line, ln| {
                    if (std.mem.indexOf(u8, line, needle) != null) {
                        cursor = ln;
                        break;
                    }
                }
            },
            ':' => {
                const cmd_raw = readUntil('\n') orelse "";
                const cmd = std.mem.trim(u8, cmd_raw, " \t\r");
                if (std.mem.startsWith(u8, cmd, "s/")) viSubstitute(&lines, cmd);
                if (std.mem.startsWith(u8, cmd, "w") or std.mem.eql(u8, cmd, "wq")) {
                    if (file) |path| writeFile(path, linesToData(lines.items));
                    modified = false;
                    status_override = writeMessage(file, lines.items);
                }
                if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "wq") or std.mem.eql(u8, cmd, "q!")) quit = true;
            },
            else => {},
        }
        renderVi(name, file, lines.items, cursor, readonly, modified, status_override);
    }
    emit("\x1b[?1049l");
    return 0;
}

