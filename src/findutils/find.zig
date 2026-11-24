//! findutils find — search for files and perform actions.

const std = @import("std");
const c = @import("common.zig");
const bb = c.bb;
const linux = c.linux;
const A = std.heap.page_allocator;

const Op = enum {
    name, iname, path, ipath, regex,
    type_, perm, size, mtime, atime, ctime, mmin, amin, cmin,
    newer, inum, links, empty, executable, user, group,
    print, print0, prune, delete, quit,
};

const Exec = struct {
    templates: [][]const u8,
    plus: bool,
    plus_paths: *std.ArrayList([]const u8),
};

const Node = union(enum) {
    pred: struct { op: Op, arg: ?[]const u8 = null, arg2: ?[]const u8 = null },
    negate: *Node,
    conj: struct { l: *Node, r: *Node },
    disj: struct { l: *Node, r: *Node },
    exec: Exec,
    action: Op,
    always,
};

const Info = struct {
    path: []const u8,
    name: []const u8,
    mode: u32,
    size: u64,
    mtime_sec: i64,
    ino: u64,
    nlink: u64,
    uid: u32,
    gid: u32,
    is_dir: bool,
    prune: bool = false,
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    root: *Node,
    maxdepth: ?usize = null,
    mindepth: usize = 0,
    depth: bool = false,
    quit: bool = false,
    status: c_int = 0,
    execs: std.ArrayList(*Exec) = .empty,
};

fn newNode(n: Node) *Node {
    const p = A.create(Node) catch @panic("oom");
    p.* = n;
    return p;
}

fn infoFor(path: []const u8, follow: bool) ?Info {
    const zpath = A.dupeSentinel(u8, path, 0) catch return null;
    defer A.free(zpath);
    var stx: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(@intCast(linux.AT.FDCWD), zpath.ptr, flags, .BASIC_STATS, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{
        .path = path,
        .name = c.basename(path),
        .mode = stx.mode,
        .size = stx.size,
        .mtime_sec = stx.mtime.sec,
        .ino = stx.ino,
        .nlink = stx.nlink,
        .uid = stx.uid,
        .gid = stx.gid,
        .is_dir = (stx.mode & linux.S.IFMT) == linux.S.IFDIR,
    };
}

// ---- fnmatch-like glob (no FNM_PATHNAME: '*' matches '/') -----------------

fn globMatch(pattern: []const u8, text: []const u8, ci: bool) bool {
    return globAt(pattern, 0, text, 0, ci);
}

fn eqch(a: u8, b: u8, ci: bool) bool {
    if (!ci) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn classMatch(pat: []const u8, pidx: usize, ch: u8, ci: bool, consumed: *usize) ?bool {
    // pat[pidx] == '['; find closing ']'
    var i = pidx + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var hit = false;
    var any = false;
    while (i < pat.len and pat[i] != ']') {
        any = true;
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            const lo = pat[i];
            const hi = pat[i + 2];
            const cc = if (ci) std.ascii.toLower(ch) else ch;
            if (cc >= (if (ci) std.ascii.toLower(lo) else lo) and cc <= (if (ci) std.ascii.toLower(hi) else hi)) hit = true;
            i += 3;
        } else {
            if (eqch(pat[i], ch, ci)) hit = true;
            i += 1;
        }
    }
    if (i >= pat.len or !any) return null; // malformed class: literal '['
    consumed.* = i + 1 - pidx;
    return hit != negate;
}

fn globAt(pat: []const u8, pi0: usize, txt: []const u8, ti0: usize, ci: bool) bool {
    var pi = pi0;
    var ti = ti0;
    while (pi < pat.len) {
        switch (pat[pi]) {
            '*' => {
                while (pi < pat.len and pat[pi] == '*') pi += 1;
                if (pi == pat.len) return true;
                var t = ti;
                while (t <= txt.len) : (t += 1) {
                    if (globAt(pat, pi, txt, t, ci)) return true;
                }
                return false;
            },
            '?' => {
                if (ti >= txt.len) return false;
                ti += 1;
                pi += 1;
            },
            '[' => {
                if (ti >= txt.len) return false;
                var used: usize = 0;
                if (classMatch(pat, pi, txt[ti], ci, &used)) |ok| {
                    if (!ok) return false;
                    pi += used;
                    ti += 1;
                } else {
                    if (!eqch('[', txt[ti], ci)) return false;
                    pi += 1;
                    ti += 1;
                }
            },
            '\\' => {
                if (pi + 1 < pat.len) pi += 1;
                if (ti >= txt.len or !eqch(pat[pi], txt[ti], ci)) return false;
                pi += 1;
                ti += 1;
            },
            else => {
                if (ti >= txt.len or !eqch(pat[pi], txt[ti], ci)) return false;
                pi += 1;
                ti += 1;
            },
        }
    }
    return ti == txt.len;
}

// ---- parser --------------------------------------------------------------

const Parser = struct {
    toks: []const []const u8,
    pos: usize = 0,
    has_action: bool = false,
    plus_lists: std.ArrayList(*std.ArrayList([]const u8)) = .empty,

    fn peek(self: *Parser) ?[]const u8 {
        if (self.pos >= self.toks.len) return null;
        return self.toks[self.pos];
    }
    fn take(self: *Parser) []const u8 {
        const t = self.toks[self.pos];
        self.pos += 1;
        return t;
    }
    fn need(self: *Parser, _: []const u8) []const u8 {
        if (self.pos >= self.toks.len) {
            bb.messages.plainMsg("{s} requires an argument", .{self.toks[self.pos - 1]});
            std.process.exit(1);
        }
        return self.take();
    }

    fn parseOr(self: *Parser, prog: []const u8) *Node {
        var left = self.parseAnd(prog);
        while (self.peek()) |t| {
            if (std.mem.eql(u8, t, "-o")) {
                _ = self.take();
                const right = self.parseAnd(prog);
                left = newNode(.{ .disj = .{ .l = left, .r = right } });
            } else break;
        }
        return left;
    }

    fn parseAnd(self: *Parser, prog: []const u8) *Node {
        var left = self.parseNot(prog);
        while (self.peek()) |t| {
            if (std.mem.eql(u8, t, "-o") or std.mem.eql(u8, t, ")")) break;
            if (std.mem.eql(u8, t, "-a")) {
                _ = self.take();
            }
            const right = self.parseNot(prog);
            left = newNode(.{ .conj = .{ .l = left, .r = right } });
        }
        return left;
    }

    fn parseNot(self: *Parser, prog: []const u8) *Node {
        if (self.peek()) |t| {
            if (std.mem.eql(u8, t, "!")) {
                _ = self.take();
                return newNode(.{ .negate = self.parseNot(prog) });
            }
        }
        return self.parsePrimary(prog);
    }

    fn parsePrimary(self: *Parser, prog: []const u8) *Node {
        const t = self.take();
        if (std.mem.eql(u8, t, "(")) {
            const inner = self.parseOr(prog);
            if (self.peek()) |e| {
                if (std.mem.eql(u8, e, ")")) _ = self.take();
            }
            return inner;
        }
        const simple = [_]struct { []const u8, Op }{
            .{ "-name", .name }, .{ "-iname", .iname }, .{ "-path", .path },
            .{ "-ipath", .ipath }, .{ "-regex", .regex }, .{ "-type", .type_ },
            .{ "-perm", .perm }, .{ "-size", .size }, .{ "-mtime", .mtime },
            .{ "-atime", .atime }, .{ "-ctime", .ctime }, .{ "-mmin", .mmin },
            .{ "-amin", .amin }, .{ "-cmin", .cmin }, .{ "-newer", .newer },
            .{ "-inum", .inum }, .{ "-links", .links }, .{ "-empty", .empty },
            .{ "-executable", .executable }, .{ "-user", .user }, .{ "-group", .group },
        };
        for (simple) |s| {
            if (std.mem.eql(u8, t, s[0])) {
                const arg: ?[]const u8 = if (s[1] == .empty or s[1] == .executable) null else self.need(prog);
                return newNode(.{ .pred = .{ .op = s[1], .arg = arg } });
            }
        }
        if (std.mem.eql(u8, t, "-print")) {
            self.has_action = true;
            return newNode(.{ .action = .print });
        }
        if (std.mem.eql(u8, t, "-print0")) {
            self.has_action = true;
            return newNode(.{ .action = .print0 });
        }
        if (std.mem.eql(u8, t, "-prune")) return newNode(.{ .action = .prune });
        if (std.mem.eql(u8, t, "-delete")) {
            self.has_action = true;
            return newNode(.{ .action = .delete });
        }
        if (std.mem.eql(u8, t, "-quit")) {
            self.has_action = true;
            return newNode(.{ .action = .quit });
        }
        if (std.mem.eql(u8, t, "-true")) return newNode(.always);
        if (std.mem.eql(u8, t, "-false")) return newNode(.{ .pred = .{ .op = .inum, .arg = "0" } });
        if (std.mem.eql(u8, t, "-exec") or std.mem.eql(u8, t, "-ok")) {
            self.has_action = true;
            var args: std.ArrayList([]const u8) = .empty;
            while (self.peek()) |a| {
                if (std.mem.eql(u8, a, ";") or std.mem.eql(u8, a, "+")) break;
                args.append(A, a) catch {};
                _ = self.take();
            }
            if (self.peek() == null) {
                bb.messages.plainMsg("missing argument to '-exec'", .{});
                bb.usage.die(prog);
            }
            const terminator = self.take();
            const plus = std.mem.eql(u8, terminator, "+");
            const list = A.create(std.ArrayList([]const u8)) catch @panic("oom");
            list.* = .empty;
            const exec = A.create(Exec) catch @panic("oom");
            exec.* = .{ .templates = args.toOwnedSlice(A) catch &.{}, .plus = plus, .plus_paths = list };
            if (plus) self.plus_lists.append(A, list) catch {};
            return newNode(.{ .exec = exec.* });
        }
        bb.messages.plainMsg("unrecognized: {s}", .{t});
        bb.usage.die(prog);
    }
};

// ---- evaluation ----------------------------------------------------------

fn matchNum(num: u64, spec: []const u8) bool {
    const s = c.parseSignedNumber(spec) orelse return false;
    return switch (s.sign) {
        1 => num > s.value,
        -1 => num < s.value,
        else => num == s.value,
    };
}

fn testOp(n: *const Node, info: *Info) bool {
    const t = n.pred;
    switch (t.op) {
        .name => return globMatch(t.arg orelse return false, info.name, false),
        .iname => return globMatch(t.arg orelse return false, info.name, true),
        .path => return globMatch(t.arg orelse return false, info.path, false),
        .ipath => return globMatch(t.arg orelse return false, info.path, true),
        .regex => {
            var re = bb.regex.compile(A, t.arg orelse return false, .{}) catch return false;
            defer re.deinit();
            var m: [2]bb.regex.Match = undefined;
            return (re.exec(info.path, &m) catch 0) != 0;
        },
        .type_ => {
            const arg = t.arg orelse return false;
            if (arg.len == 0) return false;
            const kind: u32 = switch (arg[0]) {
                'f' => linux.S.IFREG, 'd' => linux.S.IFDIR, 'l' => linux.S.IFLNK,
                'b' => linux.S.IFBLK, 'c' => linux.S.IFCHR, 's' => linux.S.IFSOCK,
                'p' => linux.S.IFIFO, else => return false,
            };
            return (info.mode & linux.S.IFMT) == kind;
        },
        .perm => {
            const arg = t.arg orelse return false;
            const mode = info.mode & 0o7777;
            if (arg[0] == '-') {
                const m = std.fmt.parseInt(u32, arg[1..], 8) catch return false;
                return (mode & m) == m;
            } else if (arg[0] == '+') {
                const m = std.fmt.parseInt(u32, arg[1..], 8) catch return false;
                return (mode & m) != 0;
            } else {
                const m = std.fmt.parseInt(u32, arg, 8) catch return false;
                return mode == m;
            }
        },
        .size => {
            const arg = t.arg orelse return false;
            var unit: u64 = 512;
            var spec = arg;
            if (spec.len > 0) {
                switch (spec[spec.len - 1]) {
                    'c' => unit = 1,
                    'k' => unit = 1024,
                    'b' => unit = 512,
                    'w' => unit = 2,
                    else => {},
                }
                if (spec[spec.len - 1] == 'c' or spec[spec.len - 1] == 'k' or
                    spec[spec.len - 1] == 'b' or spec[spec.len - 1] == 'w')
                    spec = spec[0 .. spec.len - 1];
            }
            const s = c.parseSignedNumber(spec) orelse return false;
            const blocks = (info.size + unit - 1) / unit;
            return switch (s.sign) {
                1 => info.size / unit > s.value,
                -1 => blocks < s.value,
                else => blocks == s.value,
            };
        },
        .mtime, .atime, .ctime, .mmin, .amin, .cmin => {
            const arg = t.arg orelse return false;
            const div: i64 = if (t.op == .mtime or t.op == .atime or t.op == .ctime) 86400 else 60;
            const age = @divTrunc(c.nowSeconds() - info.mtime_sec, div);
            const s = c.parseSignedNumber(arg) orelse return false;
            return switch (s.sign) {
                1 => age > @as(i64, @intCast(s.value)),
                -1 => age < @as(i64, @intCast(s.value)),
                else => age == @as(i64, @intCast(s.value)),
            };
        },
        .newer => {
            const info2 = infoFor(t.arg orelse return false, true) orelse return false;
            return info.mtime_sec > info2.mtime_sec;
        },
        .inum => {
            const s = c.parseSignedNumber(t.arg orelse return false) orelse return false;
            return info.ino == s.value;
        },
        .links => return matchNum(info.nlink, t.arg orelse return false),
        .empty => {
            if (info.is_dir) {
                var d = c.DirIter.open(info.path) orelse return false;
                defer d.close();
                return d.next() == null;
            }
            return info.size == 0;
        },
        .executable => return (info.mode & 0o111) != 0,
        .user => {
            const arg = t.arg orelse return false;
            const uid = std.fmt.parseInt(u32, arg, 10) catch return info.uid == linux.getuid();
            return info.uid == uid;
        },
        .group => {
            const arg = t.arg orelse return false;
            const gid = std.fmt.parseInt(u32, arg, 10) catch return info.gid == linux.getegid();
            return info.gid == gid;
        },
        else => return true,
    }
}

fn replaceAll(allocator: std.mem.Allocator, s: []const u8, needle: []const u8, repl: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, allocator, s, needle, repl) catch s;
}

fn runExec(ctx: *Ctx, ex: *Exec, path: []const u8) void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    for (ex.templates) |t| {
        argv.append(ctx.allocator, replaceAll(ctx.allocator, t, "{}", path)) catch {};
    }
    if (argv.items.len == 0) return;
    if (c.runChild(ctx.allocator, argv.items) != 0) ctx.status = 1;
}

fn eval(node: *Node, info: *Info, ctx: *Ctx) bool {
    if (ctx.quit) return false;
    switch (node.*) {
        .always => return true,
        .pred => return testOp(node, info),
        .negate => return !eval(node.negate, info, ctx),
        .conj => return eval(node.conj.l, info, ctx) and eval(node.conj.r, info, ctx),
        .disj => return eval(node.disj.l, info, ctx) or eval(node.disj.r, info, ctx),
        .action => |op| switch (op) {
            .print => {
                c.writeAll(1, info.path);
                c.writeAll(1, "\n");
                return true;
            },
            .print0 => {
                c.writeAll(1, info.path);
                c.writeAll(1, "\x00");
                return true;
            },
            .prune => {
                info.prune = true;
                return true;
            },
            .delete => {
                var zbuf: [4096:0]u8 = undefined;
                if (c.z(info.path, &zbuf)) |zp| {
                    if (linux.unlink(zp.ptr) != 0) _ = linux.rmdir(zp.ptr);
                } else |_| {}
                return true;
            },
            .quit => {
                ctx.quit = true;
                return true;
            },
            else => return true,
        },
        .exec => |*ex| {
            if (ex.plus) {
                ex.plus_paths.append(ctx.allocator, ctx.allocator.dupe(u8, info.path) catch info.path) catch {};
                return true;
            }
            runExec(ctx, ex, info.path);
            return true;
        },
    }
}

fn walk(path: []const u8, depth: usize, follow: bool, ctx: *Ctx) void {
    if (ctx.quit) return;
    var info = infoFor(path, follow) orelse {
        bb.messages.errorMsg(2, "{s}", .{path});
        ctx.status = 1;
        return;
    };
    if (ctx.depth) {
        if (info.is_dir and !info.prune and (ctx.maxdepth == null or depth < ctx.maxdepth.?)) {
            descend(path, depth, follow, ctx);
        }
        if (depth >= ctx.mindepth) _ = eval(ctx.root, &info, ctx);
    } else {
        if (depth >= ctx.mindepth) _ = eval(ctx.root, &info, ctx);
        if (ctx.quit) return;
        if (info.is_dir and !info.prune and (ctx.maxdepth == null or depth < ctx.maxdepth.?)) {
            descend(path, depth, follow, ctx);
        }
    }
}

fn descend(path: []const u8, depth: usize, follow: bool, ctx: *Ctx) void {
    var dir = c.DirIter.open(path) orelse return;
    defer dir.close();
    while (dir.next()) |name| {
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const full = if (std.mem.endsWith(u8, path, "/"))
            std.fmt.allocPrint(A, "{s}{s}", .{ path, name })
        else
            std.fmt.allocPrint(A, "{s}/{s}", .{ path, name });
        const p = full catch continue;
        walk(p, depth + 1, follow, ctx);
        if (ctx.quit) return;
    }
}

pub fn findMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(A, argv, argc) catch return 1;
    bb.env.setProgramName(c.basename(args[0]));
    const prog = c.basename(args[0]);

    var paths: std.ArrayList([]const u8) = .empty;
    var expr_start: usize = args.len;
    var follow = false;
    var ctx = Ctx{ .allocator = A, .root = newNode(.always) };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const t = args[i];
        if (t.len > 0 and t[0] == '-') {
            if (std.mem.eql(u8, t, "-L") or std.mem.eql(u8, t, "-follow")) {
                follow = true;
                continue;
            }
            if (std.mem.eql(u8, t, "-H")) continue;
            if (std.mem.eql(u8, t, "-xdev")) continue;
            if (std.mem.eql(u8, t, "-maxdepth") or std.mem.eql(u8, t, "-mindepth")) {
                if (i + 1 >= args.len) {
                    bb.messages.plainMsg("{s} requires an argument", .{t});
                    bb.usage.die(prog);
                }
                const v = std.fmt.parseInt(usize, args[i + 1], 10) catch {
                    bb.messages.plainMsg("invalid argument to {s}", .{t});
                    bb.usage.die(prog);
                };
                if (std.mem.eql(u8, t, "-maxdepth")) ctx.maxdepth = v else ctx.mindepth = v;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, t, "-depth")) {
                ctx.depth = true;
                continue;
            }
            expr_start = i;
            break;
        }
        if (std.mem.eql(u8, t, "(") or std.mem.eql(u8, t, "!")) {
            expr_start = i;
            break;
        }
        paths.append(A, t) catch {};
    }
    if (paths.items.len == 0) {
        paths.append(A, ".") catch {};
    }

    var parser = Parser{ .toks = args[expr_start..] };
    var root = if (expr_start < args.len) parser.parseOr(prog) else newNode(.always);
    if (parser.pos < parser.toks.len) {
        bb.messages.plainMsg("unrecognized: {s}", .{parser.toks[parser.pos]});
        bb.usage.die(prog);
    }
    if (!parser.has_action) {
        root = newNode(.{ .conj = .{ .l = root, .r = newNode(.{ .action = .print }) } });
    }
    ctx.root = root;

    for (parser.plus_lists.items) |list| {
        const node = findExecNode(root, list);
        if (node) |ex| {
            ctx.execs.append(A, ex) catch {};
        }
    }

    for (paths.items) |p| walk(p, 0, follow, &ctx);

    // Execute '+' batches using a dedicated path list (templates already expanded)
    for (ctx.execs.items) |ex| {
        if (ex.plus_paths.items.len > 0) {
            var argv2: std.ArrayList([]const u8) = .empty;
            defer argv2.deinit(A);
            for (ex.templates) |tnt| {
                if (std.mem.indexOf(u8, tnt, "{}") != null) {
                    for (ex.plus_paths.items) |p| {
                        argv2.append(A, replaceAll(A, tnt, "{}", p)) catch {};
                    }
                } else {
                    argv2.append(A, tnt) catch {};
                }
            }
            if (argv2.items.len > 0) {
                if (c.runChild(A, argv2.items) != 0) ctx.status = 1;
            }
        }
    }
    return ctx.status;
}

fn findExecNode(root: *Node, list: *std.ArrayList([]const u8)) ?*Exec {
    switch (root.*) {
        .exec => |*ex| if (ex.plus_paths == list) return ex,
        .negate => return findExecNode(root.negate, list),
        .conj => {
            return findExecNode(root.conj.l, list) orelse findExecNode(root.conj.r, list);
        },
        .disj => {
            return findExecNode(root.disj.l, list) orelse findExecNode(root.disj.r, list);
        },
        else => {},
    }
    return null;
}
