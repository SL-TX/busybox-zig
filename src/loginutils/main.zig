//! loginutils applet implementations (login, passwd, su, plus existing cryptpw).
//! Real system auth files are only touched when their env overrides point there;
//! tests use temporary files via SHADOW_FILE / PASSWD_FILE.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

pub const init = struct {
    pub fn init() void {}
};

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const out = std.heap.page_allocator.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn zstr(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

fn errOut(bytes: []const u8) void {
    _ = linux.write(2, bytes.ptr, bytes.len);
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

pub fn formatShadowLine(a: std.mem.Allocator, s: ShadowEntry, hash: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ s.name, hash, s.rest });
}

pub fn verifyPassword(a: std.mem.Allocator, hash: []const u8, password: []const u8) !bool {
    if (!std.mem.startsWith(u8, hash, "$1$")) return false;
    const after = hash[3..];
    const end = std.mem.indexOfScalar(u8, after, '$') orelse return false;
    const computed = bb.pw.encryptMd5(a, password, after[0..end]) catch return false;
    defer a.free(computed);
    if (computed.len != hash.len or hash.len > 128) return false;
    var left: [128]u8 = undefined;
    var right: [128]u8 = undefined;
    @memcpy(left[0..computed.len], computed);
    @memcpy(right[0..hash.len], hash);
    return std.crypto.timing_safe.eql([128]u8, left, right);
}

// ------------------------------------------------------------------ file I/O

fn readFile(a: std.mem.Allocator, path: []const u8) ?[]u8 {
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

fn writeFile(path: []const u8, content: []const u8) bool {
    const a = std.heap.page_allocator;
    const p = zstr(a, path) catch return false;
    defer a.free(p);
    const rc = linux.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < content.len) {
        const n = linux.write(fd, content[off..].ptr, content.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        off += n;
    }
    return true;
}

fn readLine(a: std.mem.Allocator) ?[]u8 {
    var result: std.ArrayList(u8) = .empty;
    var buf: [1]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, 1);
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
    return result.toOwnedSlice(a) catch null;
}

fn currentUser(a: std.mem.Allocator) []const u8 {
    if (bb.env.get("USER")) |name| return name;
    return std.fmt.allocPrint(a, "{d}", .{linux.getuid()}) catch "root";
}

// ------------------------------------------------------------------- applets

pub fn cryptpw_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var salt: []const u8 = "12345678";
    var password: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-S")) {
            i += 1;
            if (i < args.len) salt = args[i];
        } else if (std.mem.startsWith(u8, arg, "-a")) {
            // only md5 is supported for now
        } else if (arg.len > 0 and arg[0] == '-') {
            // ignore
        } else if (password.len == 0) {
            password = arg;
        }
    }
    if (password.len == 0) return 1;
    const hash = bb.pw.encryptMd5(std.heap.page_allocator, password, salt) catch return 1;
    defer std.heap.page_allocator.free(hash);
    _ = std.os.linux.write(1, hash.ptr, hash.len);
    _ = std.os.linux.write(1, "\n", 1);
    return 0;
}

pub fn passwd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = argsFrom(argv, argc);
    var salt: ?[]const u8 = null;
    var user: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "-S") and i + 1 < args.len) {
            i += 1;
            salt = args[i];
        } else if (args[i].len > 0 and args[i][0] == '-') {
            return 1;
        } else {
            user = args[i];
        }
    }
    if (user.len == 0) user = currentUser(a);

    const password = readLine(a) orelse return 1;
    defer a.free(password);
    if (password.len == 0) return 1;

    const pid_u: u32 = @intCast(linux.getpid());
    const generated_salt = std.fmt.allocPrint(a, "{d}{d}", .{ pid_u, pid_u % 100000 }) catch return 1;
    defer a.free(generated_salt);
    const hash = bb.pw.encryptMd5(a, password, salt orelse generated_salt) catch return 1;
    defer a.free(hash);

    const shadow_path = bb.env.get("SHADOW_FILE") orelse "/etc/shadow";
    const data = readFile(a, shadow_path) orelse return 1;
    defer a.free(data);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(a);
    var found = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (parseShadowLine(line)) |entry| {
            if (eq(entry.name, user)) {
                const replacement = formatShadowLine(a, entry, hash) catch return 1;
                defer a.free(replacement);
                result.appendSlice(a, replacement) catch return 1;
                found = true;
                continue;
            }
        }
        result.appendSlice(a, line) catch return 1;
        // splitScalar consumed the newline; restore it unless this was the
        // final empty segment after a trailing newline.
        if (lines.index != null and lines.index.? < data.len) result.append(a, '\n') catch return 1;
    }
    if (!found) return 1;
    return if (writeFile(shadow_path, result.items)) 0 else 1;
}

fn lookupUser(a: std.mem.Allocator, name: []const u8) ?PasswdEntry {
    const passwd_path = bb.env.get("PASSWD_FILE") orelse "/etc/passwd";
    const data = readFile(a, passwd_path) orelse return null;
    defer a.free(data);
    const entry = findPasswdEntry(data, name) orelse return null;
    return .{
        .name = a.dupe(u8, entry.name) catch return null,
        .passwd = a.dupe(u8, entry.passwd) catch return null,
        .uid = entry.uid,
        .gid = entry.gid,
        .gecos = entry.gecos,
        .home = a.dupe(u8, entry.home) catch return null,
        .shell = a.dupe(u8, entry.shell) catch return null,
    };
}

/// Drop supplementary groups, then gid, then uid. Any failure is fatal: the
/// caller must never exec a shell with partially changed credentials.
pub fn dropPrivileges(uid: u32, gid: u32) bool {
    // Already the target identity: no privilege boundary to cross, and an
    // unprivileged process cannot call setgroups(2) at all.
    if (linux.geteuid() == uid and linux.getegid() == gid) return true;
    if (linux.errno(linux.syscall2(.setgroups, 0, 0)) != .SUCCESS) return false;
    if (linux.errno(linux.setgid(gid)) != .SUCCESS) return false;
    if (linux.errno(linux.setuid(uid)) != .SUCCESS) return false;
    return true;
}

fn execAsUser(a: std.mem.Allocator, user: PasswdEntry) c_int {
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return 1;
    if (child == 0) {
        if (!dropPrivileges(user.uid, user.gid)) std.process.exit(1);
        const shell_z = zstr(a, user.shell) catch std.process.exit(127);
        const argv_z = a.allocSentinel(?[*:0]const u8, 2, null) catch std.process.exit(127);
        argv_z[0] = shell_z.ptr;
        const dash = zstr(a, "-") catch std.process.exit(127);
        argv_z[1] = dash.ptr;
        const envp_z = a.allocSentinel(?[*:0]const u8, 0, null) catch std.process.exit(127);
        _ = linux.execve(shell_z.ptr, argv_z.ptr, envp_z.ptr);
        std.process.exit(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(child), &status, 0);
    return @intCast((status >> 8) & 0xff);
}

pub fn su_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = argsFrom(argv, argc);
    var name: []const u8 = "root";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "-")) continue;
        if (args[i].len > 0 and args[i][0] == '-') return 1;
        name = args[i];
    }
    const user = lookupUser(a, name) orelse {
        errOut("su: user not found\n");
        return 1;
    };
    return execAsUser(a, user);
}

pub fn login_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    const a = std.heap.page_allocator;
    const username = readLine(a) orelse return 1;
    defer a.free(username);
    const password = readLine(a) orelse return 1;
    defer a.free(password);

    const user = lookupUser(a, username) orelse {
        errOut("Login incorrect\n");
        return 1;
    };
    const shadow_path = bb.env.get("SHADOW_FILE") orelse "/etc/shadow";
    const data = readFile(a, shadow_path) orelse return 1;
    defer a.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    var hash: []const u8 = "";
    while (lines.next()) |line| {
        if (parseShadowLine(line)) |entry| {
            if (eq(entry.name, username)) {
                hash = a.dupe(u8, entry.hash) catch return 1;
                break;
            }
        }
    }
    if (hash.len == 0 or !(verifyPassword(a, hash, password) catch false)) {
        errOut("Login incorrect\n");
        return 1;
    }
    defer a.free(hash);
    return execAsUser(a, user);
}
