//! SELinux applets (Task 24).  The project defconfig compiles these out, but
//! the implementations are real: they use the libbb_zig SELinux helpers
//! (context parsing/editing, `security.selinux` xattrs, boolean files) and the
//! kernel's selinuxfs pseudo-files.  No libselinux, no C code, no shell-out.
//!
//! Differential cases for these applets carry `requires: ["selinux"]`: the
//! reference build has CONFIG_SELINUX=n, so they skip here but would run
//! unchanged against an SELinux-enabled reference.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");

const Allocator = std.mem.Allocator;
const page = std.heap.page_allocator;

pub const init = struct {
    pub fn init() void {}
};

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

fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(page, f, args) catch "out of memory\n";
}

fn die(msg: []const u8) noreturn {
    bb.messages.plainMsg("{s}", .{msg});
    std.process.exit(1);
}

fn usage(name: []const u8) noreturn {
    bb.usage.die(name);
}

fn pathExists(path: []const u8) bool {
    const z = zstr(page, path) catch return false;
    defer page.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

fn readAll(a: Allocator, path: []const u8) ?[]u8 {
    const z = zstr(a, path) catch return null;
    defer a.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        out.appendSlice(a, buf[0..n]) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

fn writeAll(path: []const u8, bytes: []const u8) bool {
    const z = zstr(page, path) catch return false;
    defer page.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        done += n;
    }
    return true;
}

// --------------------------------------------------------- pure helpers

/// SELinuxfs mount point; overridable for tests via SELINUX_MNT.
pub fn root() []const u8 {
    return bb.env.get("SELINUX_MNT") orelse "/sys/fs/selinux";
}

pub fn booleanPath(name: []const u8) []const u8 {
    return fmt("{s}/booleans/{s}", .{ root(), name });
}

/// Read SELINUXTYPE from an /etc/selinux/config-style body.
pub fn configPolicyType(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "SELINUXTYPE=")) continue;
        const value = std.mem.trim(u8, t["SELINUXTYPE=".len..], " \t");
        if (value.len > 0) return value;
    }
    return null;
}

pub fn isEnabled() bool {
    return pathExists(fmt("{s}/enforce", .{root()})) or pathExists(fmt("{s}/status", .{root()}));
}

/// Translate the raw selinuxfs `enforce` value into applet output.
pub fn enforceName(raw: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (eq(t, "1")) return "Enforcing";
    if (eq(t, "0")) return "Permissive";
    return null;
}

pub fn parseSetenforce(arg: []const u8) ?bool {
    if (eq(arg, "1") or std.ascii.eqlIgnoreCase(arg, "enforcing")) return true;
    if (eq(arg, "0") or std.ascii.eqlIgnoreCase(arg, "permissive")) return false;
    return null;
}

/// setsebool accepts 1/0/true/false/on/off (case-insensitive).
pub fn parseBooleanValue(arg: []const u8) ?bool {
    if (eq(arg, "1") or std.ascii.eqlIgnoreCase(arg, "true") or std.ascii.eqlIgnoreCase(arg, "on")) return true;
    if (eq(arg, "0") or std.ascii.eqlIgnoreCase(arg, "false") or std.ascii.eqlIgnoreCase(arg, "off")) return false;
    return null;
}

pub const ContextRule = struct {
    pattern: []const u8,
    context: []const u8,
};

/// Parse one line of a file_contexts file: `regexp [role:]context`.
pub fn parseContextRule(line_raw: []const u8) ?ContextRule {
    const line = std.mem.trim(u8, line_raw, " \t\r\n");
    if (line.len == 0 or line[0] == '#') return null;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const pattern = it.next() orelse return null;
    const context = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{ .pattern = pattern, .context = context };
}

/// Choose the most specific matching rule.  The file_contexts subset used by
/// BusyBox's matchpathcon supports literal prefixes, `(/.*)?`, `.*` and `^`.
/// Specificity is the length of the pattern's literal prefix, with exact
/// matches preferred.  Returns the rule's raw context string.
pub fn matchContext(rules: []const ContextRule, path: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_score: usize = 0;
    for (rules) |rule| {
        var pattern = rule.pattern;
        if (pattern.len > 0 and pattern[0] == '^') pattern = pattern[1..];
        // Strip the common recursive suffix: "/dir(/.*)?" matches "/dir" and
        // everything below it.
        const rec_suffix = "(/.*)?";
        var base = pattern;
        var recursive = false;
        if (std.mem.endsWith(u8, pattern, rec_suffix)) {
            base = pattern[0 .. pattern.len - rec_suffix.len];
            recursive = true;
        } else if (std.mem.endsWith(u8, pattern, ".*")) {
            base = pattern[0 .. pattern.len - 2];
            recursive = true;
        }
        // Trim regexp character-class suffixes such as "/?".
        if (base.len > 1 and base[base.len - 1] == '?') base = base[0 .. base.len - 1];
        if (base.len == 0) continue;
        const matches = if (recursive or eq(base, "/"))
            (std.mem.startsWith(u8, path, base) and
                (path.len == base.len or base[base.len - 1] == '/' or path[base.len] == '/'))
        else
            eq(path, base);
        if (!matches) continue;
        const score = base.len * 2 + @as(usize, if (recursive) 0 else 1);
        if (score >= best_score) {
            best_score = score;
            best = rule.context;
        }
    }
    return best;
}

/// Build a context from a base context and optional component replacements.
pub fn applyComponents(a: Allocator, base: []const u8, user: ?[]const u8, role: ?[]const u8, typ: ?[]const u8, range: ?[]const u8) ![]u8 {
    var ctx = try bb.selinux.parseContext(base);
    if (user) |v| ctx.user = v;
    if (role) |v| ctx.role = v;
    if (typ) |v| ctx.type = v;
    if (range) |v| ctx.range = v;
    return bb.selinux.formatContext(a, ctx);
}

fn requireEnabled() void {
    if (!isEnabled()) die("SELinux is disabled");
}

// ---------------------------------------------------------------- applets

pub fn getenforce_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    if (!isEnabled()) {
        outAll("Disabled\n");
        return 0;
    }
    const raw = readAll(page, fmt("{s}/enforce", .{root()})) orelse die("getenforce() failed");
    defer page.free(raw);
    outAll(enforceName(raw) orelse die("getenforce() failed"));
    outAll("\n");
    return 0;
}

pub fn selinuxenabled_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    return if (isEnabled()) 0 else 1;
}

fn setenforceMain(args: []const []const u8) c_int {
    const name = prog(args);
    if (args.len != 2) usage(name);
    requireEnabled();
    const value = parseSetenforce(args[1]) orelse usage(name);
    if (!writeAll(fmt("{s}/enforce", .{root()}), if (value) "1" else "0")) die("setenforce() failed");
    return 0;
}

pub fn setenforce_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return setenforceMain(argsFrom(argv, argc));
}

fn trimNul(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == 0) end -= 1;
    return s[0..end];
}

/// List directory entries using getdents64 directly (the project avoids the
/// Zig 0.17 std.Io layer in applet code).
pub fn listDirNames(a: Allocator, dir_path: []const u8) ![][]u8 {
    const z = try zstr(a, dir_path);
    defer a.free(z);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var dents: [8192]u8 align(8) = undefined;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| a.free(n);
        out.deinit(a);
    }
    while (true) {
        const got = linux.getdents64(fd, &dents, dents.len);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        const total: usize = got;
        var off: usize = 0;
        while (off + @offsetOf(linux.dirent64, "name") < total) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(dents[off..].ptr));
            if (dent.reclen == 0 or off + dent.reclen > total) break;
            const raw = dents[off + @offsetOf(linux.dirent64, "name") ..][0 .. dent.reclen - @offsetOf(linux.dirent64, "name")];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
            const name = raw[0..end];
            off += dent.reclen;
            if (name.len == 0 or eq(name, ".") or eq(name, "..")) continue;
            try out.append(a, try a.dupe(u8, name));
        }
    }
    return out.toOwnedSlice(a);
}

pub fn isDirectory(path: []const u8) bool {
    var zb: [4096:0]u8 = undefined;
    const z = zstr(page, path) catch return false;
    defer page.free(z);
    _ = &zb;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z, 0, .{}, &stx);
    return linux.errno(rc) == .SUCCESS and (stx.mode & linux.S.IFMT) == linux.S.IFDIR;
}

pub fn booleanNames(a: Allocator, dir_path: []const u8) ![][]u8 {
    return listDirNames(a, dir_path);
}

pub fn getsebool_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    requireEnabled();
    var all = false;
    var start: usize = 1;
    if (args.len > 1 and eq(args[1], "-a")) {
        all = true;
        start = 2;
        if (args.len > 2) usage(name);
    }
    var names: [][]u8 = undefined;
    var owned = false;
    if (all) {
        names = booleanNames(page, fmt("{s}/booleans", .{root()})) catch die("can't get boolean names");
        owned = true;
        if (names.len == 0) {
            outAll("No booleans\n");
            return 0;
        }
    } else {
        if (args.len < 2) usage(name);
        names = page.alloc([]u8, args.len - 1) catch die("out of memory");
        for (args[start..], 0..) |arg, i| names[i] = @constCast(arg);
    }
    defer if (owned) {
        for (names) |n| page.free(n);
        page.free(names);
    };
    for (names) |n| {
        const b = bb.selinux.readBoolean(page, booleanPath(n)) catch die(fmt("error getting active value for {s}", .{n}));
        outAll(fmt("{s} --> {s}\n", .{ n, if (b.current) "on" else "off" }));
        if (b.pending != b.current) {
            outAll(fmt(" pending: {s}\n", .{if (b.pending) "on" else "off"}));
        } else {
            outAll("\n");
        }
    }
    return 0;
}

pub fn setsebool_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    if (args.len != 3) usage(name);
    const value = parseBooleanValue(args[2]) orelse usage(name);
    requireEnabled();
    bb.selinux.writeBoolean(booleanPath(args[1]), value) catch die("can't set boolean");
    return 0;
}

pub fn sestatus_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var verbose = false;
    var booleans = false;
    for (args[1..]) |arg| {
        if (eq(arg, "-v")) verbose = true else if (eq(arg, "-b")) booleans = true else if (arg.len > 1 and arg[0] == '-') usage(name) else usage(name);
    }
    if (!isEnabled()) {
        outAll(fmt("{s:<31} {s}\n", .{ "SELinux status:", "disabled" }));
        return 0;
    }
    const raw = readAll(page, fmt("{s}/enforce", .{root()})) orelse die("libselinux returns unknown state");
    defer page.free(raw);
    const mode = if (eq(std.mem.trim(u8, raw, " \r\n"), "0")) "permissive" else "enforcing";
    outAll(fmt("{s:<31} {s}\n", .{ "SELinux status:", "enabled" }));
    outAll(fmt("{s:<31} {s}\n", .{ "SELinuxfs mount:", root() }));
    outAll(fmt("{s:<31} {s}\n", .{ "Current mode:", mode }));
    outAll(fmt("{s:<31} {s}\n", .{ "Mode from config file:", mode }));
    const pv = readAll(page, fmt("{s}/policyvers", .{root()}));
    defer if (pv) |v| page.free(v);
    const pv_text = if (pv) |v| std.mem.trim(u8, v, " \r\n") else "0";
    outAll(fmt("{s:<31} {s}\n", .{ "Policy version:", pv_text }));
    const cfg = readAll(page, "/etc/selinux/config");
    defer if (cfg) |v| page.free(v);
    const policy = if (cfg) |v| configPolicyType(v) orelse "targeted" else "targeted";
    outAll(fmt("{s:<31} {s}\n", .{ "Policy from config file:", policy }));
    if (booleans) {
        outAll("\nPolicy booleans:\n");
        const names = booleanNames(page, fmt("{s}/booleans", .{root()})) catch &.{};
        for (names) |n| {
            const b = bb.selinux.readBoolean(page, booleanPath(n)) catch continue;
                outAll(fmt("{s:<31} {s}\n", .{ n, if (b.current) "on" else "off" }));
        }
    }
    if (verbose) {
        outAll("\nProcess contexts:\n");
        if (readAll(page, "/proc/self/attr/current")) |ctx| {
            defer page.free(ctx);
            outAll(fmt("{s:<31} {s}\n", .{ "Current context:", trimNul(ctx) }));
        }
        if (readAll(page, "/proc/1/attr/current")) |ctx| {
            defer page.free(ctx);
            outAll(fmt("{s:<31} {s}\n", .{ "Init context:", trimNul(ctx) }));
        }
        outAll("\nFile contexts:\n");
    }
    return 0;
}

fn readRules(path: []const u8) []ContextRule {
    const data = readAll(page, path) orelse return &.{};
    defer page.free(data);
    var out: std.ArrayList(ContextRule) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (parseContextRule(line)) |rule| out.append(page, rule) catch {};
    }
    return out.toOwnedSlice(page) catch &.{};
}

fn contextsPath() []const u8 {
    return fmt("{s}/file_contexts", .{root()});
}

/// Output line produced by matchpathcon -V for one path.  `actual` is null
/// when the file carries no security.selinux xattr.  Pure and unit-tested.
pub fn verifyLine(path: []const u8, expected: []const u8, actual: ?[]const u8) []const u8 {
    if (actual) |a| {
        if (eq(trimNul(a), expected)) return fmt("{s} verified\n", .{path});
        return fmt("{s} has context {s}, should be {s}\n", .{ path, trimNul(a), expected });
    }
    return fmt("actual context unknown: No such file or directory, should be {s}\n", .{expected});
}

pub fn matchpathcon_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    var no_print = false;
    var no_trans = false;
    var verify = false;
    var file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-n")) {
            no_print = true;
        } else if (eq(arg, "-N")) {
            // NOTRANS: read the raw xattr instead of a translated context.
            no_trans = true;
        } else if (eq(arg, "-V")) {
            verify = true;
        } else if (eq(arg, "-f") or eq(arg, "-p")) {
            i += 1;
            if (i >= args.len) usage(name);
            if (eq(arg, "-f")) file = args[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            usage(name);
        } else break;
    }
    if (i >= args.len) usage(name);
    const rules = readRules(file orelse contextsPath());
    var errors: c_int = 0;
    while (i < args.len) : (i += 1) {
        const path = args[i];
        const context = matchContext(rules, path) orelse {
            bb.messages.errorMsg(2, "matchpathcon({s}) failed", .{path});
            errors += 1;
            continue;
        };
        if (verify) {
            const actual = if (no_trans)
                (bb.selinux.get(page, path, bb.selinux.selinux_xattr) catch null)
            else
                (bb.selinux.getFileContext(page, path) catch null);
            defer if (actual) |a| page.free(a);
            outAll(verifyLine(path, context, actual));
            if (actual == null or !eq(trimNul(actual.?), context)) errors += 1;
            continue;
        }
        if (no_print) outAll(fmt("{s}\n", .{context})) else outAll(fmt("{s}\t{s}\n", .{ path, context }));
    }
    return errors;
}

pub const WalkOpts = struct {
    recursive: bool = false,
    verbose: bool = false,
    dry_run: bool = false,
    force: bool = false,
    quiet: bool = false,
    no_follow: bool = false,
    skip_unchanged: bool = false,
    root_prefix: []const u8 = "",
    excludes: []const []const u8 = &.{},
};

/// -r ROOT prefixes every path (setfiles semantics).  Pure and unit-tested.
pub fn effectivePath(root_dir: []const u8, path: []const u8) []const u8 {
    if (root_dir.len == 0) return path;
    return fmt("{s}{s}", .{ root_dir, path });
}

/// -e DIR excludes a directory subtree.  Pure and unit-tested.
pub fn isExcluded(excludes: []const []const u8, path: []const u8) bool {
    for (excludes) |dir| {
        if (dir.len == 0) continue;
        if (std.mem.startsWith(u8, path, dir) and (path.len == dir.len or path[dir.len] == '/')) return true;
    }
    return false;
}

fn setContext(path: []const u8, context: []const u8, no_follow: bool) bool {
    if (!no_follow) {
        bb.selinux.setFileContext(path, context) catch return false;
        return true;
    }
    // chcon -h: lsetfilecon() semantics, never follow a symlink.
    var zb: [4096:0]u8 = undefined;
    const z = zstr(page, path) catch return false;
    defer page.free(z);
    _ = &zb;
    var nb: [256:0]u8 = undefined;
    @memcpy(nb[0..bb.selinux.selinux_xattr.len], bb.selinux.selinux_xattr);
    nb[bb.selinux.selinux_xattr.len] = 0;
    var value: [1024:0]u8 = undefined;
    if (context.len + 1 > value.len) return false;
    @memcpy(value[0..context.len], context);
    value[context.len] = 0;
    const rc = linux.lsetxattr(z.ptr, nb[0..bb.selinux.selinux_xattr.len :0].ptr, value[0 .. context.len + 1].ptr, context.len + 1, 0);
    return linux.errno(rc) == .SUCCESS;
}

/// Apply one context to one path with -v/-n reporting and restorecon's
/// "leave unchanged unless -F" behaviour.
fn applyContext(path: []const u8, context: []const u8, opts: WalkOpts) bool {
    if (opts.dry_run) {
        if (opts.verbose and !opts.quiet) outAll(fmt("context of {s} changed to {s}\n", .{ path, context }));
        return true;
    }
    if (opts.skip_unchanged) {
        if (bb.selinux.getFileContext(page, path) catch null) |cur| {
            defer page.free(cur);
            if (eq(trimNul(cur), context)) return true;
        }
    }
    if (!setContext(path, context, opts.no_follow)) return false;
    if (opts.verbose and !opts.quiet) outAll(fmt("context of {s} changed to {s}\n", .{ path, context }));
    return true;
}

fn walkAndApply(a: Allocator, path_arg: []const u8, rules: []const ContextRule, opts: WalkOpts) bool {
    const path = effectivePath(opts.root_prefix, path_arg);
    if (isExcluded(opts.excludes, path)) return true;
    var ok = true;
    if (opts.recursive) {
        const names = listDirNames(a, path) catch return false;
        defer {
            for (names) |n| a.free(n);
            a.free(names);
        }
        for (names) |name| {
            const child = fmt("{s}/{s}", .{ path, name });
            if (isExcluded(opts.excludes, child)) continue;
            if (isDirectory(child)) {
                ok = walkAndApply(a, child, rules, opts) and ok;
            } else if (matchContext(rules, child)) |ctx| {
                ok = applyContext(child, ctx, opts) and ok;
            }
        }
    }
    if (matchContext(rules, path)) |ctx| {
        ok = applyContext(path, ctx, opts) and ok;
    }
    return ok;
}

fn restoreconMain(args: []const []const u8) c_int {
    const name = prog(args);
    var opts = WalkOpts{ .skip_unchanged = true };
    var excludes: [16][]const u8 = undefined;
    var n_excludes: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-R")) {
            opts.recursive = true;
        } else if (eq(arg, "-v")) {
            opts.verbose = true;
        } else if (eq(arg, "-n")) {
            opts.dry_run = true;
        } else if (eq(arg, "-F")) {
            opts.force = true;
            opts.skip_unchanged = false;
        } else if (eq(arg, "-e")) {
            i += 1;
            if (i >= args.len or n_excludes >= excludes.len) usage(name);
            excludes[n_excludes] = args[i];
            n_excludes += 1;
        } else if (arg.len > 1 and arg[0] == '-') usage(name) else break;
    }
    opts.excludes = excludes[0..n_excludes];
    if (i >= args.len) usage(name);
    requireEnabled();
    const rules = readRules(contextsPath());
    var errors: c_int = 0;
    while (i < args.len) : (i += 1) {
        if (!walkAndApply(page, args[i], rules, opts)) errors += 1;
    }
    return errors;
}

pub fn restorecon_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return restoreconMain(argsFrom(argv, argc));
}

fn setfilesMain(args: []const []const u8) c_int {
    const name = prog(args);
    var opts = WalkOpts{};
    var excludes: [16][]const u8 = undefined;
    var n_excludes: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-R")) {
            opts.recursive = true;
        } else if (eq(arg, "-v")) {
            opts.verbose = true;
        } else if (eq(arg, "-n") or eq(arg, "-d")) {
            opts.dry_run = true;
        } else if (eq(arg, "-q")) {
            // -q suppresses the per-file diagnostics -q is documented for.
            opts.quiet = true;
        } else if (eq(arg, "-r")) {
            i += 1;
            if (i >= args.len) usage(name);
            opts.root_prefix = args[i];
        } else if (eq(arg, "-e")) {
            i += 1;
            if (i >= args.len or n_excludes >= excludes.len) usage(name);
            excludes[n_excludes] = args[i];
            n_excludes += 1;
        } else if (arg.len > 1 and arg[0] == '-') usage(name) else break;
    }
    opts.excludes = excludes[0..n_excludes];
    if (i + 1 >= args.len) usage(name);
    requireEnabled();
    const rules = readRules(args[i]);
    i += 1;
    var errors: c_int = 0;
    while (i < args.len) : (i += 1) {
        if (!walkAndApply(page, args[i], rules, opts)) errors += 1;
    }
    return errors;
}

pub fn setfiles_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return setfilesMain(argsFrom(argv, argc));
}

fn chconMain(args: []const []const u8) c_int {
    const name = prog(args);
    var user: ?[]const u8 = null;
    var role: ?[]const u8 = null;
    var typ: ?[]const u8 = null;
    var range: ?[]const u8 = null;
    var reference: ?[]const u8 = null;
    var verbose = false;
    var changes = false;
    var recursive = false;
    var quiet = false;
    var no_follow = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-u") or eq(arg, "-r") or eq(arg, "-t") or eq(arg, "-l")) {
            i += 1;
            if (i >= args.len) usage(name);
            if (eq(arg, "-u")) user = args[i] else if (eq(arg, "-r")) role = args[i] else if (eq(arg, "-t")) typ = args[i] else range = args[i];
        } else if (std.mem.startsWith(u8, arg, "--reference=")) {
            reference = arg["--reference=".len..];
        } else if (eq(arg, "-v")) verbose = true else if (eq(arg, "-c")) changes = true else if (eq(arg, "-R")) recursive = true else if (eq(arg, "-h")) no_follow = true else if (eq(arg, "-f")) quiet = true else if (arg.len > 1 and arg[0] == '-') usage(name) else break;
    }
    if (i >= args.len) usage(name);
    requireEnabled();
    var specified: ?[]const u8 = null;
    var owned_spec: ?[]u8 = null;
    defer if (owned_spec) |s| page.free(s);
    if (reference) |ref| {
        const ctx = bb.selinux.getFileContext(page, ref) catch die(fmt("getfilecon('{s}') failed", .{ref})) orelse die(fmt("getfilecon('{s}') failed", .{ref}));
        specified = trimNul(ctx);
        owned_spec = @constCast(page.dupe(u8, specified.?) catch die("out of memory"));
        specified = owned_spec.?;
    } else if (user == null and role == null and typ == null and range == null) {
        specified = args[i];
        i += 1;
        if (i >= args.len) die("too few arguments");
    }
    var errors: c_int = 0;
    while (i < args.len) : (i += 1) {
        const path = args[i];
        const context: []const u8 = specified orelse blk: {
            const current = (bb.selinux.getFileContext(page, path) catch null) orelse {
                die(fmt("can't apply partial context to unlabeled file {s}", .{path}));
            };
            defer page.free(current);
            break :blk applyComponents(page, trimNul(current), user, role, typ, range) catch die(fmt("can't compute security context from {s}", .{current}));
        };
        const copts = WalkOpts{ .verbose = verbose or changes, .quiet = quiet, .no_follow = no_follow };
        const ok = applyContext(path, context, copts);
        if (!ok and !quiet) errors += 1;
        if (recursive) {
            const names = listDirNames(page, path) catch continue;
            defer {
                for (names) |n| page.free(n);
                page.free(names);
            }
            for (names) |entry_name| {
                const child = fmt("{s}/{s}", .{ path, entry_name });
                if (!applyContext(child, context, copts) and !quiet) errors += 1;
            }
        }
    }
    return errors;
}

pub fn chcon_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return chconMain(argsFrom(argv, argc));
}

pub const RunconPlan = struct {
    user: ?[]const u8 = null,
    role: ?[]const u8 = null,
    typ: ?[]const u8 = null,
    range: ?[]const u8 = null,
    compute: bool = false,
    /// Explicit positional context, present only when no component was given.
    context: ?[]const u8 = null,
    /// Index of PROG in the argument vector (args.len means "no command").
    command_index: usize = 0,
};

/// Mirror runcon.c: a positional CONTEXT is consumed only when none of
/// -u/-r/-t/-l was supplied; otherwise every leftover argument is PROG ARGS.
pub fn parseRunconArgs(args: []const []const u8, name: []const u8) RunconPlan {
    var plan = RunconPlan{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-u") or eq(arg, "-r") or eq(arg, "-t") or eq(arg, "-l")) {
            i += 1;
            if (i >= args.len) usage(name);
            if (eq(arg, "-u")) plan.user = args[i] else if (eq(arg, "-r")) plan.role = args[i] else if (eq(arg, "-t")) plan.typ = args[i] else plan.range = args[i];
        } else if (eq(arg, "-c")) {
            plan.compute = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            usage(name);
        } else break;
    }
    const has_component = plan.user != null or plan.role != null or plan.typ != null or plan.range != null;
    if (!has_component and i < args.len) {
        plan.context = args[i];
        i += 1;
    }
    plan.command_index = i;
    return plan;
}

pub fn runcon_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    requireEnabled();
    const plan = parseRunconArgs(args, name);
    if (plan.command_index >= args.len) die("no command given");
    const command = args[plan.command_index];

    var context_buf: ?[]u8 = null;
    defer if (context_buf) |v| page.free(v);
    const context: []const u8 = blk: {
        if (plan.context) |explicit| {
            _ = bb.selinux.parseContext(explicit) catch die(fmt("'{s}' is not a valid context", .{explicit}));
            break :blk explicit;
        }
        var base: []const u8 = undefined;
        var owned_base: ?[]u8 = null;
        defer if (owned_base) |v| page.free(v);
        if (plan.compute) {
            // -c computes a transition from the executable's file context.
            owned_base = (bb.selinux.getFileContext(page, command) catch
                die(fmt("can't retrieve attributes of '{s}'", .{command}))) orelse
                die(fmt("can't retrieve attributes of '{s}'", .{command}));
            base = trimNul(owned_base.?);
        } else {
            const cur = readAll(page, "/proc/self/attr/current") orelse die("can't get current context");
            defer page.free(cur);
            owned_base = page.dupe(u8, std.mem.trim(u8, cur, " \r\n")) catch die("out of memory");
            base = owned_base.?;
        }
        context_buf = applyComponents(page, base, plan.user, plan.role, plan.typ, plan.range) catch
            die("can't set up security context");
        break :blk context_buf.?;
    };
    _ = bb.selinux.parseContext(context) catch die(fmt("'{s}' is not a valid context", .{context}));

    // setexeccon(3) is a libselinux wrapper around /proc/self/attr/exec.
    if (pathExists("/proc/self/attr/exec")) {
        _ = writeAll("/proc/self/attr/exec", context);
    }
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return 1;
    if (child == 0) {
        const prog_z = zstr(page, command) catch std.process.exit(127);
        var argv_z = page.allocSentinel(?[*:0]const u8, args.len - plan.command_index + 1, null) catch std.process.exit(127);
        for (args[plan.command_index..], 0..) |a, n| argv_z[n] = (zstr(page, a) catch std.process.exit(127)).ptr;
        argv_z[args.len - plan.command_index] = null;
        const env = bb.env.buildEnvp(page) catch std.process.exit(127);
        _ = linux.execve(prog_z, argv_z.ptr, bb.env.envpPtr(env));
        std.process.exit(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(child), &status, 0);
    return @intCast((status >> 8) & 0xff);
}

pub fn load_policy_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const name = prog(args);
    if (args.len > 1) usage(name);
    requireEnabled();
    const policy = readAll(page, fmt("{s}/policy", .{root()})) orelse die("can't load policy");
    defer page.free(policy);
    if (!writeAll(fmt("{s}/load", .{root()}), policy)) die("can't load policy");
    return 0;
}
