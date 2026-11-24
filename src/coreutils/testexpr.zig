//! Task 7d: the shared POSIX expression parser behind `test`, `[` and `[[`.
//!
//! Ported from BusyBox coreutils/test.c (1.39.0), including the POSIX 4.62.4
//! short-circuits, the exact syntax diagnostics and exit status 2 on errors.
//! `[[` additionally enables BASH_TEST2: fnmatch for `=`/`==`/`!=`, `=~`
//! regex matching and `&&`/`||` operators.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const A = std.heap.page_allocator;

const Token = enum {
    EOI,
    FILRD,
    FILWR,
    FILEX,
    FILEXIST,
    FILREG,
    FILDIR,
    FILCDEV,
    FILBDEV,
    FILFIFO,
    FILSOCK,
    FILSYM,
    FILGZ,
    FILTT,
    FILSUID,
    FILSGID,
    FILSTCK,
    FILNT,
    FILOT,
    FILEQ,
    FILUID,
    FILGID,
    STREZ,
    STRNZ,
    STREQ,
    STRNE,
    STRLT,
    STRGT,
    REGEX,
    INTEQ,
    INTNE,
    INTGE,
    INTGT,
    INTLE,
    INTLT,
    UNOT,
    BAND,
    BOR,
    LPAREN,
    RPAREN,
    OPERAND,
};

const OpType = enum { NONE, UNOP, BINOP, BBINOP, PAREN };
const Op = struct { num: Token = .EOI, ty: OpType = .NONE };

const OpEntry = struct { text: []const u8, num: Token, ty: OpType };
const ops = [_]OpEntry{
    .{ .text = "-r", .num = .FILRD, .ty = .UNOP },
    .{ .text = "-w", .num = .FILWR, .ty = .UNOP },
    .{ .text = "-x", .num = .FILEX, .ty = .UNOP },
    .{ .text = "-e", .num = .FILEXIST, .ty = .UNOP },
    .{ .text = "-f", .num = .FILREG, .ty = .UNOP },
    .{ .text = "-d", .num = .FILDIR, .ty = .UNOP },
    .{ .text = "-c", .num = .FILCDEV, .ty = .UNOP },
    .{ .text = "-b", .num = .FILBDEV, .ty = .UNOP },
    .{ .text = "-p", .num = .FILFIFO, .ty = .UNOP },
    .{ .text = "-u", .num = .FILSUID, .ty = .UNOP },
    .{ .text = "-g", .num = .FILSGID, .ty = .UNOP },
    .{ .text = "-k", .num = .FILSTCK, .ty = .UNOP },
    .{ .text = "-s", .num = .FILGZ, .ty = .UNOP },
    .{ .text = "-t", .num = .FILTT, .ty = .UNOP },
    .{ .text = "-z", .num = .STREZ, .ty = .UNOP },
    .{ .text = "-n", .num = .STRNZ, .ty = .UNOP },
    .{ .text = "-h", .num = .FILSYM, .ty = .UNOP },
    .{ .text = "-O", .num = .FILUID, .ty = .UNOP },
    .{ .text = "-G", .num = .FILGID, .ty = .UNOP },
    .{ .text = "-L", .num = .FILSYM, .ty = .UNOP },
    .{ .text = "-S", .num = .FILSOCK, .ty = .UNOP },
    .{ .text = "=", .num = .STREQ, .ty = .BINOP },
    .{ .text = "==", .num = .STREQ, .ty = .BINOP },
    .{ .text = "!=", .num = .STRNE, .ty = .BINOP },
    .{ .text = "<", .num = .STRLT, .ty = .BINOP },
    .{ .text = ">", .num = .STRGT, .ty = .BINOP },
    .{ .text = "=~", .num = .REGEX, .ty = .BINOP },
    .{ .text = "-eq", .num = .INTEQ, .ty = .BINOP },
    .{ .text = "-ne", .num = .INTNE, .ty = .BINOP },
    .{ .text = "-ge", .num = .INTGE, .ty = .BINOP },
    .{ .text = "-gt", .num = .INTGT, .ty = .BINOP },
    .{ .text = "-le", .num = .INTLE, .ty = .BINOP },
    .{ .text = "-lt", .num = .INTLT, .ty = .BINOP },
    .{ .text = "-nt", .num = .FILNT, .ty = .BINOP },
    .{ .text = "-ot", .num = .FILOT, .ty = .BINOP },
    .{ .text = "-ef", .num = .FILEQ, .ty = .BINOP },
    .{ .text = "!", .num = .UNOT, .ty = .BBINOP },
    .{ .text = "-a", .num = .BAND, .ty = .BBINOP },
    .{ .text = "-o", .num = .BOR, .ty = .BBINOP },
    .{ .text = "&&", .num = .BAND, .ty = .BBINOP },
    .{ .text = "||", .num = .BOR, .ty = .BBINOP },
    .{ .text = "(", .num = .LPAREN, .ty = .PAREN },
    .{ .text = ")", .num = .RPAREN, .ty = .PAREN },
};

const PErr = error{ Syntax, Silent };

const Info = struct {
    mode: u32,
    size: u64,
    uid: u32,
    gid: u32,
    ino: u64,
    dev: u64,
    mtime_sec: i64,
};

fn statInfo(path: []const u8, follow: bool) ?Info {
    const z = A.dupeSentinel(u8, path, 0) catch return null;
    defer A.free(z);
    var stx: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(@intCast(linux.AT.FDCWD), z.ptr, flags, .BASIC_STATS, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{
        .mode = stx.mode,
        .size = stx.size,
        .uid = stx.uid,
        .gid = stx.gid,
        .ino = stx.ino,
        .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
        .mtime_sec = stx.mtime.sec,
    };
}

fn isGroupMember(gid: u32) bool {
    if (gid == linux.getegid()) return true;
    var groups: [64]linux.gid_t = undefined;
    const n = linux.getgroups(groups.len, &groups);
    if (n > groups.len) return false;
    for (groups[0..n]) |g| if (g == gid) return true;
    return false;
}

/// Mirrors busybox test.c:test_st_mode(): checks permission bits with
/// *effective* uid/gid semantics, without the "root can do anything" shortcut
/// for execute that access(2) has.
fn testStMode(st: Info, access_mode: u32) bool {
    const any_ix: u32 = linux.S.IXUSR | linux.S.IXGRP | linux.S.IXOTH;
    var mode = access_mode;
    if (mode == linux.X_OK) {
        if ((st.mode & any_ix) == 0) return false;
        if ((st.mode & any_ix) == any_ix) return true;
    }
    const euid = linux.geteuid();
    if (euid == 0) {
        if (mode != linux.X_OK) return true;
        mode = any_ix;
    } else if (st.uid == euid) {
        mode <<= 6;
    } else if (isGroupMember(st.gid)) {
        mode <<= 3;
    }
    return (st.mode & mode) != 0;
}

fn filstat(nm: []const u8, n: Token) bool {
    const follow = n != .FILSYM;
    const st = statInfo(nm, follow) orelse return false;
    switch (n) {
        .FILEXIST => return true,
        .FILRD => return testStMode(st, linux.R_OK),
        .FILWR => return testStMode(st, linux.W_OK),
        .FILEX => return testStMode(st, linux.X_OK),
        .FILREG => return st.mode & linux.S.IFMT == linux.S.IFREG,
        .FILDIR => return st.mode & linux.S.IFMT == linux.S.IFDIR,
        .FILCDEV => return st.mode & linux.S.IFMT == linux.S.IFCHR,
        .FILBDEV => return st.mode & linux.S.IFMT == linux.S.IFBLK,
        .FILFIFO => return st.mode & linux.S.IFMT == linux.S.IFIFO,
        .FILSOCK => return st.mode & linux.S.IFMT == linux.S.IFSOCK,
        .FILSYM => return st.mode & linux.S.IFMT == linux.S.IFLNK,
        .FILSUID => return st.mode & linux.S.ISUID != 0,
        .FILSGID => return st.mode & linux.S.ISGID != 0,
        .FILSTCK => return st.mode & linux.S.ISVTX != 0,
        .FILGZ => return st.size != 0,
        .FILUID => return st.uid == linux.geteuid(),
        .FILGID => return st.gid == linux.getegid(),
        else => return true,
    }
}

fn isatty(fd: i64) bool {
    const fdi: i32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(fd)))));
    var buf: [64]u8 align(8) = undefined;
    return linux.errno(linux.ioctl(fdi, 0x5401, @intFromPtr(&buf))) == .SUCCESS;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// regcomp(REG_EXTENDED) rejects a repetition operator that has no preceding
/// atom (`*`, `+`, `?`, `{m,n}`), while this project's regex compiler treats it
/// as an empty atom. Validate the pattern first so `[[ x =~ PATTERN ]]` exits
/// 2 silently on a bad regex, exactly like the reference.
fn validRegex(p: []const u8) bool {
    var atom = false;
    var i: usize = 0;
    while (i < p.len) {
        const c = p[i];
        switch (c) {
            '\\' => {
                if (i + 1 >= p.len) return false;
                i += 2;
                atom = true;
            },
            '(', '|', '^', '$' => {
                atom = false;
                i += 1;
            },
            ')' => {
                atom = true;
                i += 1;
            },
            '*', '+', '?' => {
                if (!atom) return false;
                i += 1;
            },
            '{' => {
                if (!atom) return false;
                var j = i + 1;
                var digits: usize = 0;
                while (j < p.len and p[j] >= '0' and p[j] <= '9') : (j += 1) digits += 1;
                if (digits == 0) return false;
                if (j < p.len and p[j] == ',') {
                    j += 1;
                    while (j < p.len and p[j] >= '0' and p[j] <= '9') : (j += 1) {}
                }
                if (j >= p.len or p[j] != '}') return false;
                i = j + 1;
            },
            '[' => {
                var j = i + 1;
                if (j < p.len and (p[j] == '!' or p[j] == '^')) j += 1;
                if (j < p.len and p[j] == ']') j += 1;
                while (j < p.len and p[j] != ']') : (j += 1) {}
                if (j >= p.len) return false;
                i = j + 1;
                atom = true;
            },
            else => {
                atom = true;
                i += 1;
            },
        }
    }
    return true;
}

fn isLone(s: ?[]const u8, c: u8) bool {
    if (s) |v| return v.len == 1 and v[0] == c;
    return false;
}

/// POSIX fnmatch(pattern, string, 0): '*' spans '/', '?' matches one byte,
/// bracket expressions support ranges and negation, '\' quotes the next byte.
fn fnMatch(p: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    while (pi < p.len) {
        switch (p[pi]) {
            '*' => {
                while (pi < p.len and p[pi] == '*') pi += 1;
                if (pi == p.len) return true;
                var k = si;
                while (k <= s.len) : (k += 1) {
                    if (fnMatch(p[pi..], s[k..])) return true;
                }
                return false;
            },
            '?' => {
                if (si >= s.len) return false;
                si += 1;
                pi += 1;
            },
            '[' => {
                const cls = parseClass(p, pi) orelse {
                    if (si >= s.len or s[si] != '[') return false;
                    si += 1;
                    pi += 1;
                    continue;
                };
                if (si >= s.len or !classMatches(cls, s[si])) return false;
                si += 1;
                pi = cls.end + 1;
            },
            '\\' => {
                if (pi + 1 >= p.len) {
                    if (si >= s.len or s[si] != '\\') return false;
                    si += 1;
                    pi += 1;
                } else {
                    pi += 1;
                    if (si >= s.len or s[si] != p[pi]) return false;
                    si += 1;
                    pi += 1;
                }
            },
            else => {
                if (si >= s.len or s[si] != p[pi]) return false;
                si += 1;
                pi += 1;
            },
        }
    }
    return si == s.len;
}

const Class = struct {
    text: []const u8,
    start: usize,
    end: usize, // index of the closing ']'
    negated: bool,
};

/// `[:name:]` starts at `i`; return the index just past its closing `:]`,
/// or null when there is no complete named class here.
fn namedClassEnd(p: []const u8, i: usize, limit: usize) ?usize {
    if (i + 1 >= limit or p[i] != '[' or p[i + 1] != ':') return null;
    var j = i + 2;
    while (j + 1 < limit) : (j += 1) {
        if (p[j] == ':' and p[j + 1] == ']') return j + 2;
        if (p[j] == '[' and j + 1 < limit and p[j + 1] == ':') return null;
    }
    return null;
}

fn namedClassMatches(name: []const u8, c: u8) bool {
    const upper = c >= 'A' and c <= 'Z';
    const lower = c >= 'a' and c <= 'z';
    const digit = c >= '0' and c <= '9';
    if (std.mem.eql(u8, name, "alpha")) return upper or lower;
    if (std.mem.eql(u8, name, "digit")) return digit;
    if (std.mem.eql(u8, name, "alnum")) return upper or lower or digit;
    if (std.mem.eql(u8, name, "upper")) return upper;
    if (std.mem.eql(u8, name, "lower")) return lower;
    if (std.mem.eql(u8, name, "xdigit")) return digit or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    if (std.mem.eql(u8, name, "space")) return isSpace(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "cntrl")) return c < 0x20 or c == 0x7f;
    if (std.mem.eql(u8, name, "print")) return c >= 0x20 and c <= 0x7e;
    if (std.mem.eql(u8, name, "graph")) return c >= 0x21 and c <= 0x7e;
    if (std.mem.eql(u8, name, "punct")) return c >= 0x21 and c <= 0x7e and
        !(upper or lower or digit);
    return false; // unknown class: matches nothing, as with libc fnmatch
}

fn parseClass(p: []const u8, at: usize) ?Class {
    var i = at + 1;
    if (i >= p.len) return null;
    var neg = false;
    if (p[i] == '!' or p[i] == '^') {
        neg = true;
        i += 1;
    }
    const first = i;
    if (i < p.len and p[i] == ']') i += 1; // ']' as first member is literal
    while (i < p.len) {
        if (namedClassEnd(p, i, p.len)) |end| {
            i = end; // the ']' here closes the class name, not the bracket
            continue;
        }
        if (p[i] == ']') break;
        i += 1;
    }
    if (i >= p.len) return null;
    if (i == first) return null;
    return .{ .text = p, .start = first, .end = i, .negated = neg };
}

fn classMatches(cls: Class, c: u8) bool {
    var i = cls.start;
    var hit = false;
    while (i < cls.end) {
        if (namedClassEnd(cls.text, i, cls.end + 1)) |end| {
            if (namedClassMatches(cls.text[i + 2 .. end - 2], c)) hit = true;
            i = end;
            continue;
        }
        var lo = cls.text[i];
        if (lo == '\\' and i + 1 < cls.end) {
            i += 1;
            lo = cls.text[i];
        }
        i += 1;
        if (i + 1 < cls.end and cls.text[i] == '-') {
            var hi = cls.text[i + 1];
            if (hi == '\\' and i + 2 < cls.end) hi = cls.text[i + 2];
            i += 2;
            if (c >= lo and c <= hi) hit = true;
        } else if (c == lo) hit = true;
    }
    return hit != cls.negated;
}

const Parser = struct {
    work: []?[]const u8,
    len: usize,
    pos: usize = 0,
    last: Op = .{},
    bash_test2: bool,

    fn peek(self: *const Parser, off: usize) ?[]const u8 {
        const i = self.pos + off;
        if (i >= self.len) return null;
        return self.work[i];
    }

    fn prev(self: *const Parser) ?[]const u8 {
        if (self.pos == 0) return null;
        return self.work[self.pos - 1];
    }

    fn syntax(self: *Parser, op: ?[]const u8, msg: []const u8) PErr {
        _ = self;
        if (op) |o| {
            if (o.len != 0) {
                bb.messages.plainMsg("{s}: {s}", .{ o, msg });
                return error.Syntax;
            }
        }
        bb.messages.plainMsg("{s}", .{msg});
        return error.Syntax;
    }

    fn check(self: *Parser, s: ?[]const u8) Token {
        self.last = .{};
        const text = s orelse return .EOI;
        for (ops) |e| {
            if (std.mem.eql(u8, e.text, text)) {
                if (e.num == .REGEX and !self.bash_test2) return .OPERAND;
                if ((e.num == .BAND or e.num == .BOR) and
                    (self.bash_test2 == (text[0] == '-'))) return .OPERAND;
                self.last = .{ .num = e.num, .ty = e.ty };
                return e.num;
            }
        }
        return .OPERAND;
    }

    fn getn(self: *Parser, s: []const u8) PErr!i64 {
        var i: usize = 0;
        while (i < s.len and isSpace(s[i])) i += 1;
        var neg = false;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            neg = s[i] == '-';
            i += 1;
        }
        const digit_start = i;
        const limit: i128 = 9223372036854775808;
        var val: i128 = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            val = val * 10 + @as(i128, s[i] - '0');
            if (val > limit) return self.syntax(s, "out of range");
        }
        if (i == digit_start) return self.syntax(s, "bad number");
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i != s.len) return self.syntax(s, "bad number");
        if (neg) {
            if (val > limit) return self.syntax(s, "out of range");
            return @intCast(-val);
        }
        if (val >= limit) return self.syntax(s, "out of range");
        return @intCast(val);
    }

    fn binop(self: *Parser) PErr!i64 {
        const opnd1 = self.peek(0) orelse return self.syntax(null, "argument expected");
        self.pos += 1;
        _ = self.check(self.peek(0));
        const op = self.last;
        self.pos += 1;
        const opnd2 = self.peek(0) orelse return self.syntax(self.prev(), "argument expected");

        switch (op.num) {
            .INTEQ, .INTNE, .INTGE, .INTGT, .INTLE, .INTLT => {
                const v1 = try self.getn(opnd1);
                const v2 = try self.getn(opnd2);
                return switch (op.num) {
                    .INTEQ => if (v1 == v2) 1 else 0,
                    .INTNE => if (v1 != v2) 1 else 0,
                    .INTGE => if (v1 >= v2) 1 else 0,
                    .INTGT => if (v1 > v2) 1 else 0,
                    .INTLE => if (v1 <= v2) 1 else 0,
                    else => if (v1 < v2) 1 else 0,
                };
            },
            else => {},
        }
        if (self.bash_test2) {
            if (op.num == .STREQ) return if (fnMatch(opnd2, opnd1)) 1 else 0;
            if (op.num == .STRNE) return if (fnMatch(opnd2, opnd1)) 0 else 1;
            if (op.num == .REGEX) {
                if (!validRegex(opnd2)) return error.Silent;
                var re = bb.regex.compile(A, opnd2, .{ .extended = true }) catch return error.Silent;
                defer re.deinit();
                var m: [1]bb.regex.Match = undefined;
                const n = re.exec(opnd1, &m) catch return 0;
                return if (n > 0) 1 else 0;
            }
        }
        switch (op.num) {
            .STREQ, .STRNE, .STRLT, .STRGT => {
                const ord = std.mem.order(u8, opnd1, opnd2);
                return switch (op.num) {
                    .STREQ => if (ord == .eq) 1 else 0,
                    .STRNE => if (ord != .eq) 1 else 0,
                    .STRLT => if (ord == .lt) 1 else 0,
                    else => if (ord == .gt) 1 else 0,
                };
            },
            .FILNT, .FILOT, .FILEQ => {
                const s1 = statInfo(opnd1, true);
                const s2 = statInfo(opnd2, true);
                if (op.num == .FILNT) {
                    if (s1 == null) return 0;
                    if (s2 == null) return 1;
                    // The reference compares st_mtime (whole seconds) only:
                    // test.c:628 uses `b1.st_mtime > b2.st_mtime`.
                    return if (s1.?.mtime_sec > s2.?.mtime_sec) 1 else 0;
                }
                if (op.num == .FILOT) {
                    if (s2 == null) return 0;
                    if (s1 == null) return 1;
                    // test.c:630 uses `b1.st_mtime < b2.st_mtime` (seconds).
                    return if (s1.?.mtime_sec < s2.?.mtime_sec) 1 else 0;
                }
                if (s1 == null or s2 == null) return 0;
                return if (s1.?.dev == s2.?.dev and s1.?.ino == s2.?.ino) 1 else 0;
            },
            else => return 1,
        }
    }

    fn primary(self: *Parser, n: Token) PErr!i64 {
        if (n == .EOI) return self.syntax(null, "argument expected");
        if (n == .LPAREN) {
            self.pos += 1;
            const res = try self.oexpr(self.check(self.peek(0)));
            self.pos += 1;
            if (self.check(self.peek(0)) != .RPAREN) return self.syntax(null, "closing paren expected");
            return res;
        }

        const args0_op = self.last;
        if (self.check(self.peek(1)) != .EOI) {
            if (self.peek(2) != null and self.last.ty == .BINOP) return self.binop();
        }
        if (args0_op.ty == .UNOP) {
            if (self.peek(1) == null) return if ((self.peek(0) orelse @as([]const u8, "")).len == 0) 1 else 0;
            self.pos += 1;
            const arg = self.peek(0) orelse @as([]const u8, "");
            if (n == .STREZ) return if (arg.len == 0) 1 else 0;
            if (n == .STRNZ) return if (arg.len != 0) 1 else 0;
            if (n == .FILTT) {
                const fd = try self.getn(arg);
                return if (isatty(fd)) 1 else 0;
            }
            return if (filstat(arg, n)) 1 else 0;
        }
        if (self.last.ty == .BINOP) return self.binop();
        // check_emptiness:
        return if ((self.peek(0) orelse @as([]const u8, "")).len == 0) 0 else 1;
    }

    fn nexpr(self: *Parser, n: Token) PErr!i64 {
        if (n == .UNOT) {
            self.pos += 1;
            const nn = self.check(self.peek(0));
            if (nn == .EOI) {
                self.pos -= 1;
                return 1;
            }
            const r = try self.nexpr(nn);
            return if (r == 0) 1 else 0;
        }
        return self.primary(n);
    }

    fn aexpr(self: *Parser, n: Token) PErr!i64 {
        const res = try self.nexpr(n);
        self.pos += 1;
        if (self.check(self.peek(0)) == .BAND) {
            self.pos += 1;
            const rhs = try self.aexpr(self.check(self.peek(0)));
            return if (rhs != 0 and res != 0) 1 else 0;
        }
        self.pos -= 1;
        return res;
    }

    fn oexpr(self: *Parser, n: Token) PErr!i64 {
        const res = try self.aexpr(n);
        self.pos += 1;
        if (self.check(self.peek(0)) == .BOR) {
            self.pos += 1;
            const rhs = try self.oexpr(self.check(self.peek(0)));
            return if (rhs != 0 or res != 0) 1 else 0;
        }
        self.pos -= 1;
        return res;
    }
};

/// `kind`: 0 = test, 1 = [, 2 = [[. argv[0] is the applet name.
pub fn run(argc: c_int, argv: [*][*:0]const u8, kind: u2) c_int {
    const prog = std.fs.path.basename(std.mem.span(argv[0]));
    bb.env.setProgramName(prog);

    const nargs: usize = @intCast(argc);
    var raw: [256]?[]const u8 = undefined;
    const n = if (nargs > 0) nargs - 1 else 0;
    for (0..n) |i| raw[i] = std.mem.span(argv[i + 1]);

    // `[ EXPR ]` / `[[ EXPR ]]`: strip the closing token, with the exact
    // reference diagnostics when it is missing.
    var len = n;
    if (kind != 0) {
        if (n == 0 or !std.mem.eql(u8, raw[n - 1] orelse @as([]const u8, ""), if (kind == 1) "]" else "]]")) {
            bb.messages.plainMsg("{s}", .{if (kind == 1) "missing ]" else "missing ]]"});
            return 2;
        }
        len = n - 1;
    }

    var work: [257]?[]const u8 = undefined;
    @memcpy(work[0..len], raw[0..len]);
    work[len] = null;

    var p = Parser{
        .work = work[0 .. len + 1],
        .len = len,
        .bash_test2 = kind == 2,
    };

    // POSIX 4.62.4 short-circuits from test_main2().
    var base: usize = 0;
    var negate = false;
    var early = false;
    var res: i64 = 0;
    while (true) {
        if (base >= len or work[base] == null) {
            res = 1; // test with no arguments is false (exit 1)
            early = true;
            break;
        }
        if (base + 1 >= len or work[base + 1] == null) {
            res = if ((work[base] orelse @as([]const u8, "")).len == 0) 1 else 0;
            early = true;
            break;
        }
        if (base + 2 < len and work[base + 2] != null) {
            if (base + 3 >= len or work[base + 3] == null) {
                _ = p.check(work[base + 1]);
                if (p.last.ty == .BINOP) {
                    p.pos = base;
                    const v = p.binop() catch |e| return fail(e);
                    res = if (v == 0) 1 else 0;
                    early = true; // ret_special
                    break;
                }
            } else if (base + 4 >= len or work[base + 4] == null) {
                if (isLone(work[base], '(') and isLone(work[base + 3], ')')) {
                    work[base + 3] = null;
                    base += 1;
                }
            }
        }
        if (isLone(work[base], '!')) {
            base += 1;
            negate = !negate;
            continue;
        }
        break;
    }
    if (early) {
        if (negate) res = 1 - res;
        return @intCast(res);
    }

    p.pos = 0;
    const first = p.check(work[0]);
    const val = p.oexpr(first) catch |e| return fail(e);
    res = if (val == 0) 1 else 0;

    if (p.peek(0) != null and p.peek(1) != null) {
        bb.messages.plainMsg("{s}: unknown operand", .{p.peek(1).?});
        res = 2;
    }
    return @intCast(res);
}

fn fail(e: PErr) c_int {
    return switch (e) {
        error.Syntax, error.Silent => 2,
    };
}

pub fn testMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, 0);
}

pub fn bracketMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, 1);
}

pub fn dblBracketMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run(argc, argv, 2);
}
