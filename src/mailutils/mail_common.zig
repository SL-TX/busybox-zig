//! Shared helpers for the Task 14 mailutils applets (mail.c + getopt32 surface).
//!
//! Everything here is a direct Zig rendering of the small libbb surface used
//! by makemime/reformime/popmaildir/sendmail: program-name wiring, exact usage
//! exits, a getopt32-compatible option scanner (including list and numeric
//! sinks), line readers, base64 encode/decode, loopback connection helpers and
//! the connection/filter helper process launch used by popmaildir/reformime.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const A = std.heap.page_allocator;

pub fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    return bb.getopt.argsToSlices(A, argv, @intCast(argc)) catch &.{};
}

pub fn setProg(argv: [*][*:0]const u8) void {
    bb.env.setProgramName(std.fs.path.basename(std.mem.span(argv[0])));
}

pub fn out(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(1, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn errout(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

pub fn put(comptime fmt: []const u8, args: anytype) void {
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    out(s);
}

pub fn eput(comptime fmt: []const u8, args: anytype) void {
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    errout(s);
}

pub fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

pub fn plain(comptime fmt: []const u8, args: anytype) void {
    bb.messages.plainMsg(fmt, args);
}

pub fn plainDie(comptime fmt: []const u8, args: anytype) noreturn {
    plain(fmt, args);
    std.process.exit(1);
}

pub fn errorMsg(errnum: c_int, comptime fmt: []const u8, args: anytype) void {
    bb.messages.errorMsg(errnum, fmt, args);
}

pub fn errorDie(errnum: c_int, comptime fmt: []const u8, args: anytype) noreturn {
    bb.messages.errorMsgAndDie(errnum, fmt, args);
}

pub fn zstr(s: []const u8) ![:0]const u8 {
    return std.mem.concatWithSentinel(A, u8, &.{s}, 0);
}

pub fn readWholeFile(path: []const u8) ![]u8 {
    const p = try zstr(path);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var data: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try data.appendSlice(A, buf[0..@intCast(n)]);
    }
    return data.toOwnedSlice(A);
}

pub fn md5(bytes: []const u8, digest: *[16]u8) void {
    bb.hash.md5(bytes, digest);
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
}

/// Network timeout shared by popmaildir (-t) and sendmail (-w). The reference
/// arms SIGALRM around each SMTP/POP3 command and reports "timed out" on fire.
pub var timeout_secs: u32 = 0;

fn timeoutHandler(_: linux.SIG) callconv(.c) void {
    const name = bb.env.getProgramName();
    var b: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{s}: timed out\n", .{name}) catch "timed out\n";
    _ = linux.write(2, s.ptr, s.len);
    linux.exit(1);
}

pub fn armTimeout() void {
    if (timeout_secs == 0) return;
    bb.process.signal(.ALRM, timeoutHandler) catch {};
    _ = linux.syscall1(.alarm, @as(usize, timeout_secs));
}

pub fn cancelTimeout() void {
    if (timeout_secs > 0) _ = linux.syscall1(.alarm, 0);
}

pub fn monotonicUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

pub fn getEnv(name: []const u8) ?[]const u8 {
    return bb.env.get(name);
}

pub fn hostname() []const u8 {
    const data = readWholeFile("/proc/sys/kernel/hostname") catch return "?";
    const h = trim(data);
    return if (h.len == 0) "?" else h;
}

// ---------------------------------------------------------------------------
// getopt32-compatible scanner
// ---------------------------------------------------------------------------

pub const ArgKind = enum {
    none,
    required,
    /// `o:*` — multiple occurrences are collected; a missing argument is
    /// silently ignored (this is how the reference behaves for -a:*).
    list,
    /// `o:+` — nonnegative integer, validated while parsing.
    int,
};

pub const OptSpec = struct { ch: u8, kind: ArgKind = .none };

pub const Parsed = struct {
    flags: u32 = 0,
    args: []const []const u8 = &.{},
    list: std.ArrayList([]const u8) = .empty,
    values: [256]?[]const u8 = undefined,
    counts: [256]u32 = undefined,

    pub fn has(self: *const Parsed, ch: u8) bool {
        const idx: u8 = ch;
        return idx < self.values.len and self.values[idx] != null;
    }

    pub fn value(self: *const Parsed, ch: u8) ?[]const u8 {
        return self.values[ch];
    }

    pub fn count(self: *const Parsed, ch: u8) u32 {
        return self.counts[ch];
    }
};

fn parseNonNegative(text: []const u8) void {
    if (text.len == 0) plainDie("invalid number '{s}'", .{text});
    for (text) |c| {
        if (c < '0' or c > '9') plainDie("invalid number '{s}'", .{text});
    }
}

/// Walk argv with GNU-permutation semantics (no `+` prefix in any of our
/// optstrings) and reproduce getopt32's flag bits, per-option values, the
/// `*` list and the `+` integer validation.
pub fn parseOptions(name: []const u8, av: []const []const u8, specs: []const OptSpec) Parsed {
    var res = Parsed{};
    for (&res.values) |*v| v.* = null;
    for (&res.counts) |*c| c.* = 0;
    var positional: std.ArrayList([]const u8) = .empty;
    var end_of_options = false;

    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const tok = av[i];
        if (end_of_options) {
            positional.append(A, tok) catch {};
            continue;
        }
        if (std.mem.eql(u8, tok, "--")) {
            end_of_options = true;
            continue;
        }
        if (tok.len < 2 or tok[0] != '-') {
            positional.append(A, tok) catch {};
            continue;
        }
        if (tok[1] == '-') {
            plain("unrecognized option '{s}'", .{tok});
            usageDie(name); // noreturn, keeps the type checker happy
        }

        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            var found: ?OptSpec = null;
            var bit_index: usize = 0;
            for (specs, 0..) |spec, k| {
                if (spec.ch == ch) {
                    found = spec;
                    bit_index = k;
                    break;
                }
            }
            const spec = found orelse {
                plain("invalid option -- '{c}'", .{ch});
                usageDie(name);
            };
            res.flags |= @as(u32, 1) << @intCast(bit_index);
            res.counts[ch] +%= 1;

            switch (spec.kind) {
                .none => {},
                .required, .int, .list => {
                    var val: ?[]const u8 = null;
                    if (j + 1 < tok.len) {
                        val = tok[j + 1 ..];
                        j = tok.len;
                    } else if (i + 1 < av.len) {
                        i += 1;
                        val = av[i];
                    } else if (spec.kind == .list) {
                        // getopt32's `o:*` silently accepts a bare -o.
                    } else {
                        plain("option requires an argument -- '{c}'", .{ch});
                        usageDie(name);
                    }
                    if (val) |v| {
                        if (spec.kind == .int) parseNonNegative(v);
                        res.values[ch] = v;
                        if (spec.kind == .list) res.list.append(A, v) catch {};
                    }
                    break;
                },
            }
        }
    }
    res.args = positional.toOwnedSlice(A) catch &.{};
    return res;
}

// ---------------------------------------------------------------------------
// Line readers
// ---------------------------------------------------------------------------

/// Read one line from `fd`, dropping the trailing '\n'. With `keep_cr` the
/// preceding '\r' is retained (exactly like xmalloc_fgetline()).
pub fn readLine(fd: linux.fd_t, keep_cr: bool, buf: *std.ArrayList(u8)) ?[]const u8 {
    buf.clearRetainingCapacity();
    var byte: [1]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &byte, 1);
        if (linux.errno(n) != .SUCCESS or n == 0) {
            if (buf.items.len == 0) return null;
            break;
        }
        if (byte[0] == '\n') break;
        buf.append(A, byte[0]) catch return null;
    }
    if (!keep_cr and buf.items.len > 0 and buf.items[buf.items.len - 1] == '\r') {
        _ = buf.pop();
    }
    return buf.items;
}

/// xmalloc_fgets_str(stdin, "\r\n") — the returned line INCLUDES "\r\n".
pub fn readCrLfLine(fd: linux.fd_t, buf: *std.ArrayList(u8)) ?[]const u8 {
    buf.clearRetainingCapacity();
    var byte: [1]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &byte, 1);
        if (linux.errno(n) != .SUCCESS or n == 0) {
            return if (buf.items.len == 0) null else buf.items;
        }
        buf.append(A, byte[0]) catch return null;
        const len = buf.items.len;
        if (len >= 2 and buf.items[len - 2] == '\r' and buf.items[len - 1] == '\n') break;
    }
    return buf.items;
}

// ---------------------------------------------------------------------------
// Base64
// ---------------------------------------------------------------------------

/// BusyBox printfile_base64(): a newline before every 57-byte chunk, then the
/// 76-character base64 line with no trailing newline.
pub fn printFileBase64(path: []const u8) void {
    const data = if (std.mem.eql(u8, path, "-")) readFdAll(0) else openFileOrDie(path);
    defer A.free(data);

    var off: usize = 0;
    var enc: [76]u8 = undefined;
    while (off < data.len) {
        const n = @min(data.len - off, 57);
        out("\n");
        const size = std.base64.standard.Encoder.calcSize(n);
        const s = std.base64.standard.Encoder.encode(enc[0..size], data[off .. off + n]);
        out(s);
        off += n;
    }
}

/// xfopen_for_read(): the diagnostic carries the real strerror() suffix.
pub fn openFileOrDie(path: []const u8) []u8 {
    const z = zstr(path) catch return &.{};
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS)
        errorDie(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{path});
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var data: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        data.appendSlice(A, buf[0..@intCast(n)]) catch break;
    }
    return data.toOwnedSlice(A) catch &.{};
}

pub fn readFdAll(fd: linux.fd_t) []u8 {
    var data: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        data.appendSlice(A, buf[0..@intCast(n)]) catch break;
    }
    return data.toOwnedSlice(A) catch &.{};
}

pub fn base64String(text: []const u8) []const u8 {
    const size = std.base64.standard.Encoder.calcSize(text.len);
    const dst = A.alloc(u8, size) catch return "";
    return std.base64.standard.Encoder.encode(dst, text);
}

/// read_base64(stdin, out, '-'): decode base64 characters until a line that
/// starts with '-' (the MIME boundary) or EOF.
pub fn readByteStdin() ?u8 {
    var byte: [1]u8 = undefined;
    const n = linux.read(0, &byte, 1);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    return byte[0];
}

/// read_base64(stdin, fp, '-'): decoded until EOF or the first '-' of the
/// boundary line (the reference consumes exactly that one byte, so the rest of
/// the boundary line becomes the next header).
pub fn readBase64To(fd: linux.fd_t, write_fd: linux.fd_t) void {
    _ = fd;
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(A);
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(A);
    while (true) {
        chunk.clearRetainingCapacity();
        var terminated = false;
        while (true) {
            const ch = readByteStdin() orelse {
                terminated = true;
                break;
            };
            if (ch == '-') {
                if (chunk.items.len == 0) return; // consumed one boundary byte
                terminated = true;
                break;
            }
            if (ch <= ' ') break;
            chunk.append(A, ch) catch return;
        }
        if (tail.items.len > 0) {
            chunk.insertSlice(A, 0, tail.items) catch return;
            tail.clearRetainingCapacity();
        }
        if (chunk.items.len == 0) {
            if (terminated) return;
            continue;
        }
        const size = std.base64.standard.Decoder.calcSizeForSlice(chunk.items) catch
            plainDie("truncated input", .{});
        const dst = A.alloc(u8, size) catch return;
        defer A.free(dst);
        std.base64.standard.Decoder.decode(dst, chunk.items) catch
            plainDie("truncated input", .{});
        writeAll(write_fd, dst);
        if (terminated) return;
    }
}

pub fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        off += @intCast(n);
    }
}

// ---------------------------------------------------------------------------
// Networking / process helpers
// ---------------------------------------------------------------------------

pub fn isNumericHost(host: []const u8) bool {
    return bb.socket.inet_pton(host) != null;
}

pub fn parseHostPort(text: []const u8, default_port: u16) struct { host: []const u8, port: u16 } {
    if (std.mem.lastIndexOfScalar(u8, text, ':')) |p| {
        const port_text = text[p + 1 ..];
        const v = std.fmt.parseInt(u32, port_text, 10) catch plainDie("bad port '{s}'", .{port_text});
        if (v > 65535) plainDie("bad port '{s}'", .{port_text});
        return .{ .host = text[0..p], .port = @intCast(v) };
    }
    return .{ .host = text, .port = default_port };
}

pub fn connectOrDie(host: []const u8, port: u16) linux.fd_t {
    if (!isNumericHost(host)) plainDie("bad address '{s}'", .{host});
    const sfd = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(sfd) != .SUCCESS) {
        errorMsg(@intFromEnum(linux.errno(sfd)), "socket", .{});
        std.process.exit(1);
    }
    const fd: linux.fd_t = @intCast(sfd);
    var addr = bb.socket.sockaddr_in(host, port);
    const rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    if (linux.errno(rc) != .SUCCESS) {
        const e: c_int = @intFromEnum(linux.errno(rc));
        errorMsg(e, "can't connect to remote host ({s})", .{host});
        std.process.exit(1);
    }
    return fd;
}

fn childExec(argv: []const []const u8) noreturn {
    var resolved: []const u8 = argv[0];
    if (std.mem.indexOfScalar(u8, argv[0], '/') == null) {
        const path = bb.env.get("PATH") orelse "/usr/bin:/bin";
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const cand = std.fmt.allocPrint(A, "{s}/{s}", .{ dir, argv[0] }) catch continue;
            const pz = zstr(cand) catch continue;
            const rc = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(rc) == .SUCCESS) {
                _ = linux.close(@intCast(rc));
                resolved = cand;
                break;
            }
        }
    }
    const args = A.alloc(?[*:0]const u8, argv.len + 1) catch linux.exit(127);
    for (argv, 0..) |arg, k| args[k] = zstr(arg) catch linux.exit(127);
    args[argv.len] = null;
    const envp = buildEnvpExtra(&.{}) catch linux.exit(127);
    _ = linux.execve(zstr(resolved) catch linux.exit(127), @ptrCast(args.ptr), bb.env.envpPtr(envp));
    linux.exit(127);
}

pub const EnvVar = struct { key: []const u8, value: []const u8 };

/// buildEnvp() plus overrides, dropping inherited entries with the same keys.
pub fn buildEnvpExtra(extra: []const EnvVar) ![]?[*:0]const u8 {
    const base = try bb.env.buildEnvp(A);
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    for (base[0 .. base.len - 1]) |entry| {
        if (entry == null) continue;
        const s = std.mem.span(entry.?);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse s.len;
        const key = s[0..eq];
        var shadowed = false;
        for (extra) |e| {
            if (std.mem.eql(u8, key, e.key)) {
                shadowed = true;
                break;
            }
        }
        if (!shadowed) try list.append(A, entry.?);
    }
    for (extra) |e| {
        try list.append(A, try std.fmt.allocPrintSentinel(A, "{s}={s}", .{ e.key, e.value }, 0));
    }
    try list.append(A, null);
    return list.toOwnedSlice(A);
}

fn childExecEnv(argv: []const []const u8, extra: []const EnvVar) noreturn {
    var resolved: []const u8 = argv[0];
    if (std.mem.indexOfScalar(u8, argv[0], '/') == null) {
        const path = bb.env.get("PATH") orelse "/usr/bin:/bin";
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const cand = std.fmt.allocPrint(A, "{s}/{s}", .{ dir, argv[0] }) catch continue;
            const pz = zstr(cand) catch continue;
            const rc = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(rc) == .SUCCESS) {
                _ = linux.close(@intCast(rc));
                resolved = cand;
                break;
            }
        }
    }
    const args = A.alloc(?[*:0]const u8, argv.len + 1) catch linux.exit(127);
    for (argv, 0..) |arg, k| args[k] = zstr(arg) catch linux.exit(127);
    args[argv.len] = null;
    const envp = buildEnvpExtra(extra) catch linux.exit(127);
    _ = linux.execve(zstr(resolved) catch linux.exit(127), @ptrCast(args.ptr), bb.env.envpPtr(envp));
    linux.exit(127);
}

/// mail.c launch_helper(): the helper's stdin is our stdout and its stdout is
/// our stdin. PR_SET_PDEATHSIG makes it follow the parent's exit.
pub fn launchHelper(argv: []const []const u8) void {
    var to_child: [2]linux.fd_t = undefined;
    var from_child: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&to_child, .{})) != .SUCCESS) plainDie("pipe", .{});
    if (linux.errno(linux.pipe2(&from_child, .{})) != .SUCCESS) plainDie("pipe", .{});
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) plainDie("vfork", .{});
    const pid: linux.pid_t = @intCast(pid_rc);
    if (pid == 0) {
        _ = linux.close(to_child[1]);
        _ = linux.close(from_child[0]);
        _ = linux.dup2(to_child[0], 0);
        _ = linux.dup2(from_child[1], 1);
        _ = linux.prctl(1, @as(usize, @intFromEnum(linux.SIG.TERM)), 0, 0, 0); // PR_SET_PDEATHSIG
        childExec(argv);
    }
    _ = linux.close(to_child[0]);
    _ = linux.close(from_child[1]);
    _ = linux.dup2(from_child[0], 0);
    _ = linux.dup2(to_child[1], 1);
    _ = linux.close(from_child[0]);
    _ = linux.close(to_child[1]);
}

/// reformime -X: spawn a filter whose stdin is a pipe we return; its stdout
/// stays inherited from us. The caller sets CONTENT_TYPE/CHARSET/ENCODING/
/// FILENAME in the child environment.
pub const Filter = struct { fd: linux.fd_t, pid: linux.pid_t };

pub fn spawnFilter(argv: []const []const u8, extra: []const EnvVar) Filter {
    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) plainDie("pipe", .{});
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) plainDie("vfork", .{});
    const pid: linux.pid_t = @intCast(pid_rc);
    if (pid == 0) {
        _ = linux.close(fds[1]);
        _ = linux.dup2(fds[0], 0);
        _ = linux.close(fds[0]);
        childExecEnv(argv, extra);
    }
    _ = linux.close(fds[0]);
    return .{ .fd = fds[1], .pid = pid };
}

pub fn waitChild(pid: linux.pid_t) c_int {
    var status: i32 = 0;
    const rc = linux.waitpid(pid, &status, 0);
    if (linux.errno(rc) != .SUCCESS) return 0;
    if (status & 0x7f == 0) return @intCast((status >> 8) & 0xff); // WEXITSTATUS
    return 1;
}
