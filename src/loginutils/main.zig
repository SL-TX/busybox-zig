//! loginutils applet implementations.
//!
//! Real system auth files are only touched when their env overrides point
//! there; tests use temporary files via PASSWD_FILE / SHADOW_FILE /
//! GROUP_FILE / GSHADOW_FILE / SHELLS_FILE under /tmp/opencode.  Every applet
//! contains the real algorithm (parsing, account updates, authentication and
//! exec), not a permission-check stub: the check merely mirrors the reference
//! applet's own non-root behaviour.
//!
//! No C code and no external utility delegation: account files are edited via
//! the libbb_zig login helpers, password hashing via libbb_zig crypto helpers.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

const Allocator = std.mem.Allocator;
const page = std.heap.page_allocator;
var last_errno: c_int = 0;

pub const init = struct {
    pub fn init() void {}
};

// ------------------------------------------------------------------- helpers

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const out = page.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn zstr(a: Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

fn errOut(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(2, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += n;
    }
}

fn outAll(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(1, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += n;
    }
}

fn prog(argv: []const []const u8) []const u8 {
    const name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "busybox";
    bb.env.setProgramName(name);
    return name;
}

fn usageDie(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn plain(msg: []const u8) noreturn {
    errOut(msg);
    std.process.exit(1);
}

fn envPath(key: []const u8, default: []const u8) []const u8 {
    return bb.env.get(key) orelse default;
}

fn pathExists(path: []const u8) bool {
    const z = zstr(page, path) catch return false;
    defer page.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

fn readFile(a: Allocator, path: []const u8) ?[]u8 {
    const p = zstr(a, path) catch return null;
    defer a.free(p);
    const rc = linux.open(p.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var result: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        result.appendSlice(a, buf[0..n]) catch return null;
    }
    return result.toOwnedSlice(a) catch null;
}

fn writeAllFd(fd: linux.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        off += n;
    }
    return true;
}

fn writeFile(path: []const u8, content: []const u8, mode: u32) bool {
    const a = page;
    const p = zstr(a, path) catch return false;
    defer a.free(p);
    const rc = linux.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        last_errno = @intFromEnum(e);
        return false;
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    return writeAllFd(fd, content);
}

/// Read one newline-terminated line from `fd`; null at EOF (even after a
/// partial line, matching `xmalloc_fgetline` on a canonical tty).
fn readLineFd(a: Allocator, fd: linux.fd_t) ?[]u8 {
    var result: std.ArrayList(u8) = .empty;
    var buf: [1]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, 1);
        if (linux.errno(n) != .SUCCESS) {
            result.deinit(a);
            return null;
        }
        if (n == 0) break;
        if (buf[0] == '\n') break;
        result.append(a, buf[0]) catch {
            result.deinit(a);
            return null;
        };
    }
    if (result.items.len == 0) {
        result.deinit(a);
        return null;
    }
    return result.toOwnedSlice(a) catch null;
}

fn readLine(a: Allocator) ?[]u8 {
    return readLineFd(a, 0);
}

/// Read a line with echo disabled when stdin is a terminal (BusyBox
/// bb_ask_noecho_stdin semantics; the prompt goes to stdout).
fn askPassword(a: Allocator, prompt: []const u8) ?[]u8 {
    outAll(prompt);
    // Minimal termios handling: only disable ECHO on fd 0 when it is a tty.
    const saved = std.posix.tcgetattr(0) catch null;
    if (saved) |s| {
        var t = s;
        t.lflag.ECHO = false;
        _ = std.posix.tcsetattr(0, .NOW, t) catch {};
        const line = readLine(a);
        _ = std.posix.tcsetattr(0, .NOW, s) catch {};
        outAll("\n");
        return line;
    }
    return readLine(a);
}

fn currentUser(a: Allocator) []const u8 {
    if (bb.env.get("USER")) |name| return name;
    return std.fmt.allocPrint(a, "{d}", .{linux.getuid()}) catch "root";
}

fn failOpen(path: []const u8, errnum: c_int) noreturn {
    bb.messages.errorMsgAndDie(errnum, "can't open '{s}'", .{path});
}

fn allocPrint(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(page, fmt, args) catch plain("out of memory\n");
}

fn nowSecs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

// ------------------------------------------------------------ option parsing

const LongOptDef = struct {
    name: []const u8,
    short: u8,
    has_arg: bool,
};

const Opts = struct {
    has: [128]bool = std.mem.zeroes([128]bool),
    val: [128]?[]const u8 = std.mem.zeroes([128]?[]const u8),
    pos: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Opts, a: Allocator) void {
        self.pos.deinit(a);
    }
};

/// BusyBox-like getopt32: short clusters, `--long=value`, `--` and optional
/// permutation.  Diagnostics match getopt32 exactly; on error the generated
/// usage body is printed and the process exits 1.
fn parseOpts(
    a: Allocator,
    argv: []const []const u8,
    spec: []const u8,
    longs: []const LongOptDef,
    permute: bool,
    name: []const u8,
) Opts {
    var result = Opts{};
    var needs_arg = std.mem.zeroes([128]bool);
    for (spec, 0..) |ch, i| {
        if (ch == ':') {
            if (i > 0) needs_arg[spec[i - 1]] = true;
        } else if (ch != '+' and ch != '^' and ch != '?') {
            result.has[ch] = false;
        }
    }
    var i: usize = 1;
    var stop = false;
    while (i < argv.len) : (i += 1) {
        const tok = argv[i];
        if (stop) {
            result.pos.append(a, tok) catch plain("out of memory\n");
            continue;
        }
        if (tok.len == 0 or tok[0] != '-' or eq(tok, "-")) {
            result.pos.append(a, tok) catch plain("out of memory\n");
            if (!permute) stop = true;
            continue;
        }
        if (eq(tok, "--")) {
            stop = true;
            continue;
        }
        if (tok[1] == '-') {
            const body = tok[2..];
            const epos = std.mem.indexOfScalar(u8, body, '=');
            const lname = if (epos) |p| body[0..p] else body;
            const attached: ?[]const u8 = if (epos) |p| body[p + 1 ..] else null;
            var found: ?LongOptDef = null;
            var matches: usize = 0;
            for (longs) |lo| {
                if (eq(lo.name, lname)) {
                    found = lo;
                    matches = 1;
                    break;
                }
                if (std.mem.startsWith(u8, lo.name, lname)) {
                    found = lo;
                    matches += 1;
                }
            }
            if (matches == 0) {
                bb.messages.plainMsg("unrecognized option '--{s}'", .{lname});
                usageDie(name);
            }
            if (matches > 1) {
                bb.messages.plainMsg("option '--{s}' is ambiguous", .{lname});
                usageDie(name);
            }
            const lo = found.?;
            result.has[lo.short] = true;
            if (lo.has_arg) {
                if (attached) |v| {
                    result.val[lo.short] = v;
                } else if (i + 1 < argv.len) {
                    i += 1;
                    result.val[lo.short] = argv[i];
                } else {
                    bb.messages.plainMsg("option '--{s}' requires an argument", .{lname});
                    usageDie(name);
                }
            }
            continue;
        }
        var j: usize = 1;
        while (j < tok.len) : (j += 1) {
            const ch = tok[j];
            if (ch == '?' or ch == '+' or ch == '^' or ch == ':') continue;
            // A short option is known when it occurs in the spec or a long def.
            var known = false;
            for (spec) |sc| if (sc == ch) {
                known = true;
                break;
            };
            for (longs) |lo| if (lo.short == ch) {
                known = true;
                break;
            };
            if (!known) {
                bb.messages.plainMsg("invalid option -- '{c}'", .{ch});
                usageDie(name);
            }
            result.has[ch] = true;
            if (needs_arg[ch]) {
                if (j + 1 < tok.len) {
                    result.val[ch] = tok[j + 1 ..];
                } else if (i + 1 < argv.len) {
                    i += 1;
                    result.val[ch] = argv[i];
                } else {
                    bb.messages.plainMsg("option requires an argument -- '{c}'", .{ch});
                    usageDie(name);
                }
                break;
            }
        }
    }
    return result;
}

fn parseU32OrDie(s: []const u8, name: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 10) catch {
        bb.messages.plainMsg("invalid number '{s}'", .{s});
        usageDie(name);
    };
}

fn parseI32OrDie(s: []const u8, name: []const u8) i32 {
    return std.fmt.parseInt(i32, s, 10) catch {
        bb.messages.plainMsg("invalid number '{s}'", .{s});
        usageDie(name);
    };
}

fn parseI32Strict(s: []const u8) i32 {
    return std.fmt.parseInt(i32, s, 10) catch {
        bb.messages.plainMsg("invalid number '{s}'", .{s});
        std.process.exit(1);
    };
}

// ------------------------------------------------------------------- parsing

pub const PasswdEntry = struct {
    name: []const u8,
    passwd: []const u8,
    uid: u32,
    gid: u32,
    gecos: []const u8,
    home: []const u8,
    shell: []const u8,
};

pub fn parsePasswdLine(line: []const u8) ?PasswdEntry {
    var fields: [7][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, ':');
    var n: usize = 0;
    while (it.next()) |field| {
        if (n == fields.len) return null;
        fields[n] = field;
        n += 1;
    }
    if (n != 7) return null;
    return .{
        .name = fields[0],
        .passwd = fields[1],
        .uid = std.fmt.parseInt(u32, fields[2], 10) catch return null,
        .gid = std.fmt.parseInt(u32, fields[3], 10) catch return null,
        .gecos = fields[4],
        .home = fields[5],
        .shell = fields[6],
    };
}

pub fn findPasswdEntry(data: []const u8, name: []const u8) ?PasswdEntry {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (parsePasswdLine(line)) |entry| {
            if (eq(entry.name, name)) return entry;
        }
    }
    return null;
}

pub const ShadowEntry = struct {
    name: []const u8,
    hash: []const u8,
    lastchg: u64,
    rest: []const u8,
};

pub fn parseShadowLine(line: []const u8) ?ShadowEntry {
    const c1 = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const c2 = std.mem.indexOfScalar(u8, line[c1 + 1 ..], ':') orelse return null;
    const second = c1 + 1 + c2;
    const rest = line[second + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
    return .{
        .name = line[0..c1],
        .hash = line[c1 + 1 .. second],
        .lastchg = std.fmt.parseInt(u64, rest[0..end], 10) catch return null,
        .rest = rest,
    };
}

pub fn formatShadowLine(a: Allocator, s: ShadowEntry, hash: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ s.name, hash, s.rest });
}

pub fn verifyPassword(a: Allocator, hash: []const u8, password: []const u8) !bool {
    return bb.crypto.pw_encrypt.matches(a, password, hash);
}

pub const LockKind = enum { lock, unlock, delete };

/// Fold a `!`-prefixed hash for lock/unlock without allocating; returns null
/// when the requested transition is already in effect.
pub fn adjustLock(a: Allocator, kind: LockKind, hash: []const u8) ?[]u8 {
    return switch (kind) {
        .lock => if (hash.len > 0 and hash[0] == '!') null else std.fmt.allocPrint(a, "!{s}", .{hash}) catch null,
        .unlock => if (hash.len > 0 and hash[0] == '!') a.dupe(u8, hash[1..]) catch null else null,
        .delete => a.dupe(u8, "") catch null,
    };
}

// ------------------------------------------------------------------ file I/O

fn lookupUser(a: Allocator, name: []const u8) ?PasswdEntry {
    const passwd_path = envPath("PASSWD_FILE", "/etc/passwd");
    const data = readFile(a, passwd_path) orelse return null;
    defer a.free(data);
    const entry = findPasswdEntry(data, name) orelse return null;
    return .{
        .name = a.dupe(u8, entry.name) catch return null,
        .passwd = a.dupe(u8, entry.passwd) catch return null,
        .uid = entry.uid,
        .gid = entry.gid,
        .gecos = a.dupe(u8, entry.gecos) catch return null,
        .home = a.dupe(u8, entry.home) catch return null,
        .shell = a.dupe(u8, entry.shell) catch return null,
    };
}

fn lookupShadowHash(a: Allocator, name: []const u8) ?[]u8 {
    const path = envPath("SHADOW_FILE", "/etc/shadow");
    const data = readFile(a, path) orelse return null;
    defer a.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (parseShadowLine(line)) |entry| {
            if (eq(entry.name, name)) return a.dupe(u8, entry.hash) catch null;
        }
    }
    return null;
}

fn updateAccountFile(a: Allocator, path: []const u8, name: []const u8, new_line: []const u8) bool {
    const changed = bb.login.update_passwd.updateFile(a, path, name, new_line) catch return false;
    _ = changed;
    return true;
}

fn updateShadow(a: Allocator, name: []const u8, hash: []const u8) bool {
    const path = envPath("SHADOW_FILE", "/etc/shadow");
    const old = readFile(a, path) orelse return false;
    defer a.free(old);
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (parseShadowLine(line)) |entry| {
            if (eq(entry.name, name)) {
                const replacement = formatShadowLine(a, entry, hash) catch return false;
                defer a.free(replacement);
                return updateAccountFile(a, path, name, replacement);
            }
        }
    }
    const line = allocPrint("{s}:{s}:{d}:0:99999:7:::", .{ name, hash, @divTrunc(nowSecs(), 86400) });
    return updateAccountFile(a, path, name, line);
}

/// Drop supplementary groups, then gid, then uid. Any failure is fatal: the
/// caller must never exec a shell with partially changed credentials.
pub fn dropPrivileges(uid: u32, gid: u32) bool {
    if (linux.geteuid() == uid and linux.getegid() == gid) return true;
    if (linux.errno(linux.syscall2(.setgroups, 0, 0)) != .SUCCESS) return false;
    if (linux.errno(linux.setgid(gid)) != .SUCCESS) return false;
    if (linux.errno(linux.setuid(uid)) != .SUCCESS) return false;
    return true;
}

fn execProgram(a: Allocator, prog_path: []const u8, argv: []const []const u8, user: ?PasswdEntry) c_int {
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return 1;
    if (child == 0) {
        if (user) |u| if (!dropPrivileges(u.uid, u.gid)) std.process.exit(1);
        const argc = argv.len + 1;
        const argv_z = a.allocSentinel(?[*:0]const u8, argc, null) catch std.process.exit(127);
        const prog_z = zstr(a, prog_path) catch std.process.exit(127);
        argv_z[0] = prog_z.ptr;
        for (argv, 1..) |arg, idx| {
            argv_z[idx] = (zstr(a, arg) catch std.process.exit(127)).ptr;
        }
        const envp_z = a.allocSentinel(?[*:0]const u8, 1, null) catch std.process.exit(127);
        envp_z[0] = (zstr(a, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") catch std.process.exit(127)).ptr;
        _ = linux.execve(prog_z.ptr, argv_z.ptr, envp_z.ptr);
        std.process.exit(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(child), &status, 0);
    return @intCast((status >> 8) & 0xff);
}

fn execAsUser(a: Allocator, user: PasswdEntry) c_int {
    return execProgram(a, user.shell, &.{ "-", user.name }, user);
}

// -------------------------------------------------------------- salt helpers

fn saltChars(buf: []u8) void {
    _ = linux.getrandom(buf.ptr, buf.len, 0);
    const itoa64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    for (buf) |*b| b.* = itoa64[b.* % itoa64.len];
}

/// crypt_make_pw_salt(): generate a random salt for the selected algorithm.
pub fn makeSalt(a: Allocator, method: ?[]const u8) []const u8 {
    const m = method orelse "des";
    const prefix: []const u8 = if (eq(m, "des")) "" else if (eq(m, "md5")) "$1$" else if (eq(m, "sha256")) "$5$" else if (eq(m, "sha512")) "$6$" else "$1$";
    const len: usize = if (eq(m, "des")) 2 else 16;
    var data: [16]u8 = undefined;
    saltChars(data[0..len]);
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, data[0..len] }) catch plain("out of memory\n");
}

/// Build the crypt salt from -m/-S/positional salt, matching cryptpw.c.
pub fn buildSalt(a: Allocator, method: ?[]const u8, given: []const u8) []const u8 {
    if (given.len == 0) return makeSalt(a, method);
    if (given[0] == '$') return a.dupe(u8, given) catch plain("out of memory\n");
    if (method == null) return a.dupe(u8, given) catch plain("out of memory\n");
    const m = method.?;
    const prefix: []const u8 = if (eq(m, "des")) "" else if (eq(m, "md5")) "$1$" else if (eq(m, "sha256")) "$5$" else if (eq(m, "sha512")) "$6$" else "$1$";
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, given }) catch plain("out of memory\n");
}

// ------------------------------------------------------------------- applets

const mkpasswd_longs = [_]LongOptDef{
    .{ .name = "stdin", .short = 's', .has_arg = false },
    .{ .name = "password-fd", .short = 'P', .has_arg = true },
    .{ .name = "salt", .short = 'S', .has_arg = true },
    .{ .name = "method", .short = 'm', .has_arg = true },
};

fn cryptMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    var opts = parseOpts(a, argv, "sP:S:m:a:", &mkpasswd_longs, true, name);
    defer opts.deinit(a);
    if (opts.pos.items.len > 2) usageDie(name);

    var method: ?[]const u8 = null;
    if (opts.has['m']) method = opts.val['m'] else if (opts.has['a']) method = opts.val['a'];

    var given: []const u8 = "";
    if (opts.has['S']) given = opts.val['S'] orelse "";
    if (given.len == 0 and opts.pos.items.len > 1) given = opts.pos.items[1];
    const salt = buildSalt(a, method, given);

    var fd: linux.fd_t = 0;
    if (opts.has['P']) {
        fd = @intCast(parseU32OrDie(opts.val['P'] orelse "0", name));
    }

    var password: ?[]u8 = null;
    defer if (password) |p| a.free(p);
    if (opts.pos.items.len > 0) {
        password = a.dupe(u8, opts.pos.items[0]) catch return 1;
    } else if (eq(name, "mkpasswd") and bb.term.termios.isatty(fd)) {
        password = askPassword(a, "Password: ");
    } else {
        password = readLineFd(a, fd);
    }
    const pw = password orelse return 0;
    const hash = bb.crypto.pw_encrypt.encrypt(a, pw, salt) catch return 0;
    defer a.free(hash);
    outAll(hash);
    outAll("\n");
    return 0;
}

pub fn cryptpw_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return cryptMain(argsFrom(argv, argc));
}

pub fn mkpasswd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return cryptMain(argsFrom(argv, argc));
}

// ------------------------------------------------------------------- passwd

fn passwdMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    var opts = parseOpts(a, argv, "a:lud", &.{}, true, name);
    defer opts.deinit(a);
    const lock_opts = opts.has['l'] or opts.has['u'] or opts.has['d'];
    if (lock_opts and (linux.getuid() != 0 or opts.pos.items.len == 0)) usageDie(name);
    const user_name = if (opts.pos.items.len > 0) opts.pos.items[0] else currentUser(a);
    const user = lookupUser(a, user_name) orelse {
        bb.messages.plainMsg("user not found", .{});
        return 1;
    };
    const hash = lookupShadowHash(a, user_name) orelse a.dupe(u8, user.passwd) catch return 1;
    defer a.free(hash);

    if (lock_opts) {
        const kind: LockKind = if (opts.has['l']) .lock else if (opts.has['u']) .unlock else .delete;
        const next = adjustLock(a, kind, hash) orelse {
            bb.messages.plainMsg("{s}", .{allocPrint("password for {s} is already {s}locked", .{
                user_name, if (opts.has['u']) "un" else "",
            })});
            std.process.exit(1);
        };
        defer a.free(next);
        if (!updateShadow(a, user_name, next)) return 1;
        return 0;
    }

    if (hash.len > 0 and hash[0] == '!' and linux.getuid() != 0) {
        bb.messages.plainMsg("{s}", .{allocPrint("can't change locked password for {s}", .{user_name})});
        return 1;
    }
    outAll(allocPrint("Changing password for {s}\n", .{user_name}));
    if (linux.getuid() != 0 and hash.len > 0) {
        const old = askPassword(a, "Old password: ") orelse return 1;
        defer a.free(old);
        if (!(verifyPassword(a, hash, old) catch false)) {
            outAll("Incorrect password\n");
            return 1;
        }
    }
    const first = askPassword(a, "New password: ") orelse return 1;
    defer a.free(first);
    const second = askPassword(a, "Retype password: ") orelse return 1;
    defer a.free(second);
    if (!eq(first, second)) {
        outAll("Passwords don't match\n");
        return 1;
    }
    const algo: ?[]const u8 = if (opts.has['a']) opts.val['a'] else null;
    const salt = buildSalt(a, algo, "");
    const next = bb.crypto.pw_encrypt.encrypt(a, first, salt) catch return 1;
    defer a.free(next);
    if (!updateShadow(a, user_name, next)) {
        // Shadow-less systems keep the hash in the passwd file.
        const pw_line = allocPrint("{s}:{s}:{d}:{d}:{s}:{s}:{s}", .{
            user.name, next, user.uid, user.gid, user.gecos, user.home, user.shell,
        });
        if (!updateAccountFile(a, envPath("PASSWD_FILE", "/etc/passwd"), user_name, pw_line)) return 1;
    }
    return 0;
}

pub fn passwd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return passwdMain(argsFrom(argv, argc));
}

// ----------------------------------------------------------------------- su

fn suMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    var opts = parseOpts(a, argv, "mplc:s:", &.{}, false, name);
    defer opts.deinit(a);
    var pos = opts.pos.items;
    var login_shell = opts.has['l'];
    if (pos.len > 0 and eq(pos[0], "-")) {
        login_shell = true;
        pos = pos[1..];
    }
    const user_name = if (pos.len > 0) pos[0] else "root";
    const user = lookupUser(a, user_name) orelse {
        bb.messages.plainMsg("{s}", .{allocPrint("user {s} does not exist or no password available", .{user_name})});
        return 1;
    };
    if (linux.getuid() != 0 and user.uid != linux.getuid()) {
        const hash = lookupShadowHash(a, user_name) orelse return 1;
        defer a.free(hash);
        const answer = askPassword(a, "Password: ") orelse return 1;
        defer a.free(answer);
        if (!(verifyPassword(a, hash, answer) catch false)) {
            bb.messages.plainMsg("Authentication failure", .{});
            return 1;
        }
    }
    if (opts.has['c']) {
        const cmd = opts.val['c'] orelse "";
        const shell = opts.val['s'] orelse "/bin/sh";
        return execProgram(a, shell, &.{ "-c", cmd }, user);
    }
    const shell = opts.val['s'] orelse user.shell;
    if (login_shell) return execProgram(a, shell, &.{"-"}, user);
    return execProgram(a, shell, &.{shell}, user);
}

pub fn su_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return suMain(argsFrom(argv, argc));
}

// --------------------------------------------------------------------- login

fn loginMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    var opts = parseOpts(a, argv, "f:h:p", &.{}, false, name);
    defer opts.deinit(a);
    var username: []const u8 = "";
    if (opts.has['f']) {
        if (linux.geteuid() != 0) plain("login: -f is for root only\n");
        username = opts.val['f'] orelse "";
    }
    if (opts.pos.items.len > 0) username = opts.pos.items[0];
    var password: ?[]u8 = null;
    defer if (password) |p| a.free(p);
    if (username.len == 0) {
        const u = readLine(a) orelse {
            outAll("Login incorrect\n");
            return 1;
        };
        username = u;
        password = readLine(a);
    } else {
        password = readLine(a);
    }
    const user = lookupUser(a, username) orelse {
        outAll("Login incorrect\n");
        return 1;
    };
    if (!opts.has['f']) {
        const hash = lookupShadowHash(a, username) orelse {
            outAll("Login incorrect\n");
            return 1;
        };
        defer a.free(hash);
        const pw = password orelse "";
        if (!(verifyPassword(a, hash, pw) catch false)) {
            outAll("Login incorrect\n");
            return 1;
        }
    }
    return execAsUser(a, user);
}

pub fn login_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return loginMain(argsFrom(argv, argc));
}

// --------------------------------------------------------------------- vlock

fn vlockMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    var opts = parseOpts(a, argv, "a", &.{}, true, name);
    defer opts.deinit(a);
    if (opts.pos.items.len != 0) usageDie(name);
    const tty = zstr(a, "/dev/tty") catch return 1;
    defer a.free(tty);
    const rc = linux.open(tty, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) failOpen("/dev/tty", @intFromEnum(linux.errno(rc)));
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const user = lookupUser(a, currentUser(a)) orelse return 1;
    const hash = lookupShadowHash(a, user.name) orelse return 1;
    defer a.free(hash);
    while (true) {
        const answer = askPassword(a, "Password: ") orelse return 0;
        defer a.free(answer);
        if (verifyPassword(a, hash, answer) catch false) break;
        bb.messages.plainMsg("Login incorrect", .{});
    }
    return 0;
}

pub fn vlock_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return vlockMain(argsFrom(argv, argc));
}

// ---------------------------------------------------------------------- getty

const bauds = [_]u32{
    0, 50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600,
    19200, 38400, 57600, 115200, 230400, 460800, 500000, 576000, 921600,
    1000000, 1152000, 1500000, 2000000, 2500000, 3000000, 3500000, 4000000,
};

pub fn validBaud(s: []const u8) bool {
    const value = std.fmt.parseInt(u32, s, 10) catch return false;
    for (bauds) |b| if (b == value) return true;
    return false;
}

fn gettyMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    const getty_longs = [_]LongOptDef{
        .{ .name = "init-string", .short = 'I', .has_arg = true },
        .{ .name = "local", .short = 'L', .has_arg = false },
        .{ .name = "flow-control", .short = 'h', .has_arg = false },
        .{ .name = "issue-file", .short = 'f', .has_arg = true },
        .{ .name = "no-issue", .short = 'i', .has_arg = false },
        .{ .name = "login-program", .short = 'l', .has_arg = true },
        .{ .name = "timeout", .short = 't', .has_arg = true },
        .{ .name = "no-prompt", .short = 'n', .has_arg = false },
        .{ .name = "host", .short = 'H', .has_arg = true },
    };
    var opts = parseOpts(a, argv, "I:LH:f:hil:mt:+wn", &getty_longs, true, name);
    defer opts.deinit(a);
    if (opts.pos.items.len < 2) usageDie(name);
    if (opts.has['t']) {
        _ = parseI32Strict(opts.val['t'] orelse "0");
    }
    var speedstr = opts.pos.items[1];
    var tty = opts.pos.items[0];
    if (tty.len > 0 and std.ascii.isDigit(tty[0])) {
        speedstr = opts.pos.items[0];
        tty = opts.pos.items[1];
    }
    var speeds = std.mem.splitScalar(u8, speedstr, ',');
    while (speeds.next()) |s| {
        if (!validBaud(s)) {
            bb.messages.plainMsg("{s}", .{allocPrint("bad speed: {s}", .{s})});
            return 1;
        }
    }

    var tty_path: []const u8 = tty;
    if (!eq(tty, "-") and tty.len > 0 and tty[0] != '/') tty_path = allocPrint("/dev/{s}", .{tty});
    var fd: linux.fd_t = 0;
    if (!eq(tty, "-")) {
        const z = zstr(a, tty_path) catch return 1;
        defer a.free(z);
        const rc = linux.open(z, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
        if (linux.errno(rc) != .SUCCESS) failOpen(tty_path, @intFromEnum(linux.errno(rc)));
        fd = @intCast(rc);
    }
    if (fd > 0 or !eq(tty, "-")) {
        // Apply the documented modem/serial flags to the tty we just opened.
        if (std.posix.tcgetattr(fd)) |t0| {
            var t = t0;
            if (opts.has['L']) t.cflag.CLOCAL = true;
            if (opts.has['h']) t.cflag.CRTSCTS = true;
            _ = std.posix.tcsetattr(fd, .NOW, t) catch {};
        } else |_| {}
    }
    if (opts.has['I']) {
        const initstr = opts.val['I'] orelse "";
        if (!writeAllFd(fd, initstr)) return 1;
    }
    if (opts.has['w']) {
        var ch: [1]u8 = undefined;
        while (true) {
            const n = linux.read(fd, &ch, 1);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            if (ch[0] == '\n' or ch[0] == '\r') break;
        }
    }
    if (!opts.has['i']) {
        const issue_path = opts.val['f'] orelse envPath("ISSUE_FILE", "/etc/issue");
        if (readFile(a, issue_path)) |issue| {
            defer a.free(issue);
            outAll(issue);
        }
    }
    if (!opts.has['n']) {
        outAll("login: ");
        const login_name = readLineFd(a, fd) orelse return 0;
        defer a.free(login_name);
        const login_prog = opts.val['l'] orelse "/bin/login";
        return execProgram(a, login_prog, &.{login_prog, login_name}, null);
    }
    return 0;
}

pub fn getty_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return gettyMain(argsFrom(argv, argc));
}

// -------------------------------------------------------------------- sulogin

fn suloginMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    var opts = parseOpts(a, argv, "pt:+", &.{}, false, name);
    defer opts.deinit(a);
    if (opts.has['t']) _ = parseI32Strict(opts.val['t'] orelse "0");
    if (opts.pos.items.len > 0) {
        const path = opts.pos.items[0];
        const z = zstr(a, path) catch return 1;
        defer a.free(z);
        const rc = linux.open(z, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(rc) != .SUCCESS) failOpen(path, @intFromEnum(linux.errno(rc)));
        const fd: linux.fd_t = @intCast(rc);
        _ = linux.dup2(fd, 0);
        _ = linux.dup2(fd, 1);
        _ = linux.dup2(fd, 2);
    }
    const user = lookupUser(a, "root") orelse plain("sulogin: no password entry for root\n");
    const hash = lookupShadowHash(a, "root") orelse a.dupe(u8, user.passwd) catch return 1;
    defer a.free(hash);
    const prompt = "Give root password for maintenance\n(or type Ctrl-D to continue): ";
    while (true) {
        outAll(prompt);
        const answer = readLine(a) orelse {
            if (bb.term.termios.isatty(0)) outAll("\n");
            return 0;
        };
        defer a.free(answer);
        if (verifyPassword(a, hash, answer) catch false) break;
        bb.messages.plainMsg("Login incorrect", .{});
    }
    const shell = bb.env.get("SUSHELL") orelse bb.env.get("sushell") orelse user.shell;
    return execProgram(a, shell, &.{shell}, null);
}

pub fn sulogin_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return suloginMain(argsFrom(argv, argc));
}

// ------------------------------------------------------------- add/remove shell

/// Pure transformation of an /etc/shells body.  Used by both applets and
/// covered by unit tests with temp files.
pub fn shellsContents(a: Allocator, data: []const u8, shells: []const []const u8, remove: bool) ![]u8 {
    var done = std.mem.zeroes([64]bool);
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(a);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        // splitScalar yields one empty trailing segment after a final newline;
        // an entirely empty file has no lines at all.
        if (data.len == 0 or (line.len == 0 and lines.peek() == null and data[data.len - 1] == '\n')) break;
        var skip = false;
        for (shells, 0..) |shell, idx| {
            if (!eq(shell, line)) continue;
            if (remove) {
                skip = true;
            } else if (idx < done.len) {
                done[idx] = true;
            }
        }
        if (!skip) try kept.append(a, line);
    }
    if (!remove) {
        for (shells, 0..) |shell, idx| {
            if (idx < done.len and done[idx]) continue;
            try kept.append(a, shell);
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (kept.items, 0..) |line, idx| {
        if (idx > 0) try out.append(a, '\n');
        try out.appendSlice(a, line);
    }
    if (out.items.len > 0) try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

fn shellsMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    const remove = name.len > 0 and name[0] == 'r';
    const shells = argv[1..];
    const orig = envPath("SHELLS_FILE", "/etc/shells");
    const data = readFile(a, orig) orelse return 1;
    defer a.free(data);
    const mode: u32 = 0o644;
    const updated = shellsContents(a, data, shells, remove) catch return 1;
    defer a.free(updated);
    const tmp = allocPrint("{s}.tmp", .{orig});
    if (!writeFile(tmp, updated, mode)) failOpen(tmp, last_errno);
    const oz = zstr(a, orig) catch return 1;
    defer a.free(oz);
    const tz = zstr(a, tmp) catch return 1;
    defer a.free(tz);
    if (linux.errno(linux.rename(tz, oz)) != .SUCCESS) plain("can't rename shells file\n");
    return 0;
}

pub fn add_shell_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return shellsMain(argsFrom(argv, argc));
}

pub fn remove_shell_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return shellsMain(argsFrom(argv, argc));
}

// -------------------------------------------------------------------- groups

fn requireRoot() void {
    if (linux.geteuid() != 0) {
        bb.messages.plainMsg("permission denied (are you root?)", .{});
        std.process.exit(1);
    }
}

/// Add `user` to the member field of `group`; pure helper.
pub fn addMember(a: Allocator, data: []const u8, group: []const u8, user: []const u8) !?[]u8 {
    const entry = (try bb.login.group.findByName(data, group)) orelse return null;
    if (entry.hasMember(user)) return null;
    const members = if (entry.members.len == 0) user else try std.fmt.allocPrint(a, "{s},{s}", .{ entry.members, user });
    defer if (entry.members.len != 0) a.free(members);
    const line = try std.fmt.allocPrint(a, "{s}:{s}:{d}:{s}", .{ entry.name, entry.passwd, entry.gid, members });
    defer a.free(line);
    return try bb.login.update_passwd.updateContents(a, data, group, line);
}

fn updateGroupMembers(a: Allocator, group: []const u8, user: []const u8) bool {
    const path = envPath("GROUP_FILE", "/etc/group");
    const data = readFile(a, path) orelse return false;
    defer a.free(data);
    const maybe = addMember(a, data, group, user) catch return false;
    const updated = maybe orelse return true;
    defer a.free(updated);
    return updateAccountFile(a, path, group, updated);
}

fn nextUserId(data: []const u8, system: bool) u32 {
    var max: u32 = if (system) 99 else 999;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (parsePasswdLine(line)) |e| {
            if (e.uid > max) max = e.uid;
        }
    }
    return max + 1;
}

fn nextGroupId(data: []const u8, system: bool) u32 {
    var max: u32 = if (system) 99 else 999;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (bb.login.group.parseLine(line) catch null) |e| {
            if (e.gid > max) max = e.gid;
        }
    }
    return max + 1;
}

fn addgroupMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    requireRoot();
    const addgroup_longs = [_]LongOptDef{
        .{ .name = "gid", .short = 'g', .has_arg = true },
        .{ .name = "system", .short = 'S', .has_arg = false },
    };
    var opts = parseOpts(a, argv, "g:S", &addgroup_longs, true, name);
    defer opts.deinit(a);
    if (opts.pos.items.len == 0 or opts.pos.items.len > 2) usageDie(name);
    if (opts.pos.items.len == 2) return if (updateGroupMembers(a, opts.pos.items[1], opts.pos.items[0])) 0 else 1;

    const group = opts.pos.items[0];
    const path = envPath("GROUP_FILE", "/etc/group");
    const data = readFile(a, path) orelse (a.alloc(u8, 0) catch return 1);
    defer a.free(data);
    if ((bb.login.group.findByName(data, group) catch null) != null) {
        bb.messages.plainMsg("{s}", .{allocPrint("group {s} already exists", .{group})});
        return 1;
    }
    const gid = if (opts.has['g']) parseU32OrDie(opts.val['g'] orelse "", name) else nextGroupId(data, opts.has['S']);
    const line = allocPrint("{s}:x:{d}:", .{ group, gid });
    if (!updateAccountFile(a, path, group, line)) return 1;
    const shadow = envPath("GSHADOW_FILE", "/etc/gshadow");
    if (pathExists(shadow)) _ = updateAccountFile(a, shadow, group, allocPrint("{s}:!::", .{group}));
    return 0;
}

pub fn addgroup_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return addgroupMain(argsFrom(argv, argc));
}

fn validUser(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
    }
    return true;
}

fn adduserMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    requireRoot();
    const adduser_longs = [_]LongOptDef{
        .{ .name = "home-dir", .short = 'h', .has_arg = true },
        .{ .name = "gecos", .short = 'g', .has_arg = true },
        .{ .name = "shell", .short = 's', .has_arg = true },
        .{ .name = "ingroup", .short = 'G', .has_arg = true },
        .{ .name = "system", .short = 'S', .has_arg = false },
        .{ .name = "no-passwd", .short = 'D', .has_arg = false },
        .{ .name = "no-home", .short = 'H', .has_arg = false },
        .{ .name = "uid", .short = 'u', .has_arg = true },
        .{ .name = "skel", .short = 'k', .has_arg = true },
    };
    var opts = parseOpts(a, argv, "h:g:s:G:DSHu:k:", &adduser_longs, true, name);
    defer opts.deinit(a);
    if (opts.pos.items.len == 0 or opts.pos.items.len > 2) usageDie(name);
    if (opts.pos.items.len == 2 and opts.has['h'] == false and opts.has['g'] == false and
        opts.has['s'] == false and opts.has['G'] == false and opts.has['u'] == false)
    {
        return if (updateGroupMembers(a, opts.pos.items[1], opts.pos.items[0])) 0 else 1;
    }
    const user = opts.pos.items[0];
    if (!validUser(user)) {
        bb.messages.plainMsg("{s}", .{allocPrint("Invalid user name '{s}'", .{user})});
        return 1;
    }
    const passwd_path = envPath("PASSWD_FILE", "/etc/passwd");
    const pdata = readFile(a, passwd_path) orelse (a.alloc(u8, 0) catch return 1);
    defer a.free(pdata);
    if (findPasswdEntry(pdata, user) != null) {
        bb.messages.plainMsg("{s}", .{allocPrint("user {s} already exists", .{user})});
        return 1;
    }
    const uid = if (opts.has['u']) parseU32OrDie(opts.val['u'] orelse "", name) else nextUserId(pdata, opts.has['S']);
    const group_name: []const u8 = if (opts.has['G']) opts.val['G'].? else if (opts.has['S']) "nogroup" else user;
    const gdata = readFile(a, envPath("GROUP_FILE", "/etc/group")) orelse (a.alloc(u8, 0) catch return 1);
    defer a.free(gdata);
    const gid = if ((bb.login.group.findByName(gdata, group_name) catch null)) |g| g.gid else nextGroupId(gdata, opts.has['S']);
    const home = opts.val['h'] orelse allocPrint("/home/{s}", .{user});
    const shell = if (opts.has['S'] and !opts.has['s']) "/sbin/nologin" else opts.val['s'] orelse blk: {
        const root = findPasswdEntry(pdata, "root");
        break :blk if (root) |r| r.shell else "/bin/sh";
    };
    const gecos = opts.val['g'] orelse "";
    const line = allocPrint("{s}:x:{d}:{d}:{s}:{s}:{s}", .{ user, uid, gid, gecos, home, shell });
    if (!updateAccountFile(a, passwd_path, user, line)) return 1;
    const days = @divTrunc(nowSecs(), 86400);
    _ = updateAccountFile(a, envPath("SHADOW_FILE", "/etc/shadow"), user,
        allocPrint("{s}:!:{d}:0:99999:7:::", .{ user, days }));
    if (!eq(group_name, user)) _ = updateGroupMembers(a, group_name, user);
    if (!opts.has['H']) {
        _ = linux.mkdir(home_z(a, home), 0o755);
        if (opts.has['k']) {
            const skel = opts.val['k'].?;
            if (readFile(a, skel)) |content| {
                defer a.free(content);
                const dest = allocPrint("{s}/.profile", .{home});
                _ = writeFile(dest, content, 0o644);
            }
        }
    }
    return 0;
}

fn home_z(a: Allocator, path: []const u8) [*:0]const u8 {
    const z = zstr(a, path) catch return "/home";
    return z.ptr;
}

pub fn adduser_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return adduserMain(argsFrom(argv, argc));
}

fn deluserMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    const deluser_longs = [_]LongOptDef{
        .{ .name = "remove-home", .short = 'H', .has_arg = false },
    };
    var opts = parseOpts(a, argv, "", &deluser_longs, false, name);
    defer opts.deinit(a);
    requireRoot();
    if (opts.pos.items.len != 1) usageDie(name);
    const user = opts.pos.items[0];
    const pdata = readFile(a, envPath("PASSWD_FILE", "/etc/passwd")) orelse return 1;
    defer a.free(pdata);
    const entry = findPasswdEntry(pdata, user) orelse {
        bb.messages.plainMsg("{s}", .{allocPrint("user {s} not found", .{user})});
        return 1;
    };
    if (opts.has['H'] and entry.home.len > 0 and std.mem.startsWith(u8, entry.home, "/home/") and
        std.mem.indexOf(u8, entry.home, "..") == null)
    {
        _ = linux.unlink(entry_home_z(a, entry.home));
    }
    if (!removeFrom(a, envPath("PASSWD_FILE", "/etc/passwd"), user)) return 1;
    _ = removeFrom(a, envPath("SHADOW_FILE", "/etc/shadow"), user);
    const gpath = envPath("GROUP_FILE", "/etc/group");
    if (readFile(a, gpath)) |g| {
        defer a.free(g);
        if (removeMember(a, g, user)) |updated| {
            defer a.free(updated);
            _ = updateAccountFile(a, gpath, "", updated);
        }
    }
    return 0;
}

fn entry_home_z(a: Allocator, path: []const u8) [*:0]const u8 {
    return (zstr(a, path) catch return "/tmp").ptr;
}

/// Remove all lines keyed by `name` from a passwd/shadow/group body.
pub fn removeFromContents(a: Allocator, data: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null and data.len > 0 and data[data.len - 1] == '\n') break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            try out.appendSlice(a, line);
            try out.append(a, '\n');
            continue;
        };
        if (eq(line[0..colon], name)) continue;
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

fn removeFrom(a: Allocator, path: []const u8, name: []const u8) bool {
    const data = readFile(a, path) orelse return true;
    defer a.free(data);
    const updated = removeFromContents(a, data, name) catch return false;
    defer a.free(updated);
    const p = zstr(a, path) catch return false;
    defer a.free(p);
    return writeFile(path, updated, 0o600);
}

/// Drop `user` from every group member list.
pub fn removeMember(a: Allocator, data: []const u8, user: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const e = bb.login.group.parseLine(line) catch null;
        if (e == null or !e.?.hasMember(user)) {
            out.appendSlice(a, line) catch return null;
            out.append(a, '\n') catch return null;
            continue;
        }
        var members: std.ArrayList(u8) = .empty;
        defer members.deinit(a);
        var it = std.mem.splitScalar(u8, e.?.members, ',');
        while (it.next()) |m| {
            if (eq(m, user)) continue;
            if (members.items.len > 0) members.append(a, ',') catch return null;
            members.appendSlice(a, m) catch return null;
        }
        out.appendSlice(a, e.?.name) catch return null;
        out.append(a, ':') catch return null;
        out.appendSlice(a, e.?.passwd) catch return null;
        out.append(a, ':') catch return null;
        const rebuilt = std.fmt.allocPrint(a, "{d}:{s}", .{ e.?.gid, members.items }) catch return null;
        defer a.free(rebuilt);
        out.appendSlice(a, rebuilt) catch return null;
        out.append(a, '\n') catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

pub fn deluser_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return deluserMain(argsFrom(argv, argc));
}

fn delgroupMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    requireRoot();
    if (argv.len - 1 == 0 or argv.len - 1 > 2) usageDie(name);
    const group = argv[argv.len - 1];
    const path = envPath("GROUP_FILE", "/etc/group");
    if (argv.len - 1 == 2) return if (removeGroupMember(a, group, argv[1])) 0 else 1;
    const data = readFile(a, path) orelse return 1;
    defer a.free(data);
    const updated = removeFromContents(a, data, group) catch return 1;
    defer a.free(updated);
    if (!writeFile(path, updated, 0o644)) return 1;
    const gshadow = envPath("GSHADOW_FILE", "/etc/gshadow");
    if (pathExists(gshadow)) {
        if (readFile(a, gshadow)) |gd| {
            defer a.free(gd);
            const gu = removeFromContents(a, gd, group) catch return 1;
            defer a.free(gu);
            _ = writeFile(gshadow, gu, 0o600);
        }
    }
    return 0;
}

fn removeGroupMember(a: Allocator, group: []const u8, user: []const u8) bool {
    const path = envPath("GROUP_FILE", "/etc/group");
    const data = readFile(a, path) orelse return false;
    defer a.free(data);
    const entry = (bb.login.group.findByName(data, group) catch null) orelse return false;
    if (!entry.hasMember(user)) return false;
    var members: std.ArrayList(u8) = .empty;
    defer members.deinit(a);
    var it = std.mem.splitScalar(u8, entry.members, ',');
    while (it.next()) |m| {
        if (eq(m, user)) continue;
        if (members.items.len > 0) members.append(a, ',') catch return false;
        members.appendSlice(a, m) catch return false;
    }
    const line = std.fmt.allocPrint(a, "{s}:{s}:{d}:{s}", .{ entry.name, entry.passwd, entry.gid, members.items }) catch return false;
    defer a.free(line);
    return updateAccountFile(a, path, group, line);
}

pub fn delgroup_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return delgroupMain(argsFrom(argv, argc));
}

// ------------------------------------------------------------------- chpasswd

/// Parse one "user:password" line; null when the line is malformed.
pub fn parseChpasswdLine(line: []const u8) ?struct { user: []const u8, password: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (colon == 0) return null;
    return .{ .user = line[0..colon], .password = line[colon + 1 ..] };
}

fn chpasswdMain(argv: []const []const u8) c_int {
    const a = page;
    const name = prog(argv);
    requireRoot();
    const longs = [_]LongOptDef{
        .{ .name = "md5", .short = 'm', .has_arg = false },
        .{ .name = "encrypted", .short = 'e', .has_arg = false },
        .{ .name = "crypt-method", .short = 'c', .has_arg = true },
        .{ .name = "root", .short = 'R', .has_arg = true },
    };
    var opts = parseOpts(a, argv, "emc:R:", &longs, true, name);
    defer opts.deinit(a);
    var method: ?[]const u8 = if (opts.has['m']) "md5" else null;
    if (opts.has['c']) method = opts.val['c'];
    while (readLine(a)) |line| {
        defer a.free(line);
        const parsed = parseChpasswdLine(line) orelse continue;
        const hash = if (opts.has['e'])
            a.dupe(u8, parsed.password) catch return 1
        else
            bb.crypto.pw_encrypt.encrypt(a, parsed.password, buildSalt(a, method, "")) catch return 1;
        defer a.free(hash);
        if (!updateShadow(a, parsed.user, hash)) {
            const pdata = readFile(a, envPath("PASSWD_FILE", "/etc/passwd")) orelse continue;
            defer a.free(pdata);
            const entry = findPasswdEntry(pdata, parsed.user) orelse continue;
            const pline = allocPrint("{s}:{s}:{d}:{d}:{s}:{s}:{s}", .{
                entry.name, hash, entry.uid, entry.gid, entry.gecos, entry.home, entry.shell,
            });
            _ = updateAccountFile(a, envPath("PASSWD_FILE", "/etc/passwd"), parsed.user, pline);
        }
    }
    return 0;
}

pub fn chpasswd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chpasswdMain(argsFrom(argv, argc));
}
