//! reformime — parse a MIME message on stdin (reference mailutils/reformime.c).
//!
//! Only -x PREFIX and -X PROG are meaningful; the FEATURE_REFORMIME_COMPAT
//! options are accepted and ignored. Multipart/mixed is decoded recursively;
//! base64/7bit/8bit sections are written to PREFIX+filename (or piped to the
//! -X helper with CONTENT_TYPE/CHARSET/ENCODING/FILENAME set).

const std = @import("std");
const linux = std.os.linux;
const m = @import("mail_common.zig");

const SPECS = [_]m.OptSpec{
    .{ .ch = 'x', .kind = .required },
    .{ .ch = 'X', .kind = .none },
    .{ .ch = 'd', .kind = .none },
    .{ .ch = 'e', .kind = .none },
    .{ .ch = 'i', .kind = .none },
    .{ .ch = 's', .kind = .required },
    .{ .ch = 'r', .kind = .none },
    .{ .ch = 'c', .kind = .required },
    .{ .ch = 'm', .kind = .list },
    .{ .ch = 'h', .kind = .required },
    .{ .ch = 'o', .kind = .required },
    .{ .ch = 'O', .kind = .required },
};

const State = struct {
    prefix: []const u8,
    external: ?[]const []const u8,
};

const BIT_X = 1;
const BIT_BIG_X = 2;

pub fn reformimeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    m.setProg(argv);
    const av = m.argsFrom(argv, argc);
    const opts = m.parseOptions("reformime", av, &SPECS);
    if ((opts.flags & BIT_X) != 0 and (opts.flags & BIT_BIG_X) != 0) m.usageDie("reformime");

    const state = State{
        .prefix = opts.value('x') orelse "",
        .external = if ((opts.flags & BIT_BIG_X) != 0) opts.args else null,
    };
    return parse("", state);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsIgnoreCase(a: []const u8, prefix: []const u8) bool {
    return a.len >= prefix.len and eqlIgnoreCase(a[0..prefix.len], prefix);
}

fn findToken(tokens: []const []const u8, key: []const u8, default: ?[]const u8) ?[]const u8 {
    for (tokens, 0..) |tok, i| {
        if (eqlIgnoreCase(tok, key)) {
            if (i + 1 < tokens.len) return tokens[i + 1];
            return default;
        }
    }
    return default;
}

fn tokenize(allocator: std.mem.Allocator, text: []const u8) std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, ";=\" \t\n");
    while (it.next()) |tok| {
        if (result.items.len >= 32) break;
        result.append(allocator, tok) catch break;
    }
    return result;
}

fn lastContentTypeOffset(header: []const u8) usize {
    var s: usize = 0;
    var pos: usize = 0;
    while (pos < header.len) {
        const rel = std.mem.indexOfScalar(u8, header[pos..], '\n') orelse break;
        const after = pos + rel + 1;
        if (after < header.len and startsIgnoreCase(header[after..], "Content-Type:")) s = after;
        pos = after;
    }
    return s;
}

fn parse(boundary: []const u8, state: State) c_int {
    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(m.A);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(m.A);

    while (true) {
        header.clearRetainingCapacity();
        var last_ch: u8 = 0;
        while (true) {
            var byte: [1]u8 = undefined;
            const n = linux.read(0, &byte, 1);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            const ch = byte[0];
            if (ch == '\r') continue;
            if (ch == '\n' and last_ch == '\n') break;
            header.append(m.A, ch) catch break;
            last_ch = ch;
        }
        if (header.items.len == 0) break;

        var tokens = tokenize(m.A, header.items[lastContentTypeOffset(header.items)..]);
        defer tokens.deinit(m.A);
        if (tokens.items.len == 0) break;

        const ctype = findToken(tokens.items, "Content-Type:", "text/plain") orelse "text/plain";
        if (startsIgnoreCase(ctype, "multipart/")) {
            if (!eqlIgnoreCase(ctype[10..], "mixed"))
                m.plainDie("no support of content type '{s}'", .{ctype});
            const sub = findToken(tokens.items, "boundary", null) orelse
                m.plainDie("not found: 'boundary'", .{});
            const rc = parse(sub, state);
            if (rc != 0) return rc;
            continue;
        }

        const charset = findToken(tokens.items, "charset", "us-ascii") orelse "us-ascii";
        const encoding = findToken(tokens.items, "Content-Transfer-Encoding:", "7bit") orelse "7bit";
        var filename: []const u8 = undefined;
        var generated: ?[]u8 = null;
        defer if (generated) |g| m.A.free(g);
        if (findToken(tokens.items, "filename", null)) |fname| {
            filename = std.fs.path.basename(std.mem.trimEnd(u8, fname, "/"));
        } else {
            const us: u64 = m.monotonicUs();
            generated = std.fmt.allocPrint(m.A, "{d}.{d}", .{ us, linux.getpid() }) catch return 1;
            filename = generated.?;
        }

        var target: linux.fd_t = 1;
        var child: ?linux.pid_t = null;
        var opened_path: ?[]u8 = null;
        defer if (opened_path) |p| m.A.free(p);
        if (state.external) |ext| {
            if (ext.len == 0) m.usageDie("reformime");
            const envs = [_]m.EnvVar{
                .{ .key = "CONTENT_TYPE", .value = ctype },
                .{ .key = "CHARSET", .value = charset },
                .{ .key = "ENCODING", .value = encoding },
                .{ .key = "FILENAME", .value = filename },
            };
            const filter = m.spawnFilter(ext, &envs);
            target = filter.fd;
            child = filter.pid;
        } else {
            opened_path = std.fmt.allocPrint(m.A, "{s}{s}", .{ state.prefix, filename }) catch return 1;
            const z = m.zstr(opened_path.?) catch return 1;
            const fd = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
            if (linux.errno(fd) != .SUCCESS)
                m.errorDie(@intFromEnum(linux.errno(fd)), "can't open '{s}'", .{opened_path.?});
            target = @intCast(fd);
        }

        var ended = false;
        if (eqlIgnoreCase(encoding, "base64")) {
            m.readBase64To(0, target);
        } else if (!eqlIgnoreCase(encoding, "7bit") and !eqlIgnoreCase(encoding, "8bit")) {
            m.plainDie("encoding '{s}' not supported", .{encoding});
        } else {
            while (m.readLine(0, true, &line)) |ln| {
                if (ln.len >= 2 and ln[0] == '-' and ln[1] == '-' and
                    std.mem.startsWith(u8, ln[2..], boundary))
                {
                    const tail_idx: usize = 2 + boundary.len;
                    if (ln.len > tail_idx + 1 and ln[tail_idx] == '-' and ln[tail_idx + 1] == '-')
                        ended = true;
                    break;
                }
                m.writeAll(target, ln);
                m.writeAll(target, "\n");
            }
        }
        _ = linux.close(target);
        if (child) |pid| {
            const rc = m.waitChild(pid);
            if (rc != 0) return rc + 20;
        }
        if (ended) break;
    }
    return 0;
}
