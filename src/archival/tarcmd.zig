//! `tar` applet: create, list and extract archives using the Task 19 tar
//! helper, with gzip/bzip2/xz/lzma transparent compression.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");
const tar = bb.archive.tar;
const compression = bb.compression;
const archive_cmds = @import("archive_cmds.zig");

const Config = struct {
    action: u8 = 0, // c, x, t
    file: ?[]const u8 = null,
    chdir: ?[]const u8 = null,
    verbose: bool = false,
    to_stdout: bool = false,
    keep_old: bool = false,
    overwrite: bool = false,
    gzip: bool = false,
    bzip2: bool = false,
    xz: bool = false,
    lzma: bool = false,
    autodetect: bool = false,
    follow: bool = false,
    no_mtime: bool = false,
    no_owner: bool = false,
    strip_components: usize = 0,
    no_recursion: bool = false,
    numeric_owner: bool = false,
    no_same_perms: bool = false,
    list_file: ?[]const u8 = null,
    exclude_file: ?[]const u8 = null,
    excludes: std.ArrayList([]const u8) = .empty,
    to_command: ?[]const u8 = null,
};

fn optionValue(av: []const []const u8, i: *usize, inline_val: ?[]const u8, comptime flag: []const u8) ?[]const u8 {
    if (inline_val) |v| return v;
    if (i.* + 1 < av.len) {
        i.* += 1;
        return av[i.*];
    }
    c.eput("tar: option requires an argument -- '{s}'\n", .{flag});
    bb.usage.die("tar");
}

fn parseOptions(av: []const []const u8, cfg: *Config) std.ArrayList([]const u8) {
    var operands: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (a.len == 0) continue;
        if (a[0] == '-' and a.len > 1) {
            const body = if (a[1] == '-') a[2..] else a[1..];
            if (std.mem.eql(u8, body, "--help")) bb.usage.die("tar");
            if (std.mem.eql(u8, body, "lzma")) { cfg.lzma = true; continue; }
            if (std.mem.eql(u8, body, "overwrite")) { cfg.overwrite = true; continue; }
            if (std.mem.eql(u8, body, "no-recursion")) { cfg.no_recursion = true; continue; }
            if (std.mem.eql(u8, body, "numeric-owner")) { cfg.numeric_owner = true; continue; }
            if (std.mem.eql(u8, body, "no-same-permissions")) { cfg.no_same_perms = true; continue; }
            if (std.mem.eql(u8, body, "exclude")) {
                const v = optionValue(av, &i, null, "exclude") orelse continue;
                cfg.excludes.append(c.A, v) catch {};
                continue;
            }
            if (std.mem.eql(u8, body, "strip-components")) {
                const v = optionValue(av, &i, null, "strip-components") orelse continue;
                cfg.strip_components = std.fmt.parseInt(usize, v, 10) catch 0;
                continue;
            }
            if (std.mem.eql(u8, body, "to-command")) {
                cfg.to_command = optionValue(av, &i, null, "to-command");
                continue;
            }
            if (a[1] == '-') {
                c.eput("tar: unrecognized option '--{s}'\n", .{body});
                bb.usage.die("tar");
            }
            // Short options may be clustered.
            var j: usize = 0;
            while (j < body.len) : (j += 1) {
                switch (body[j]) {
                    'c', 'x', 't' => cfg.action = body[j],
                    'f' => cfg.file = optionValue(av, &i, if (j + 1 < body.len) body[j + 1 ..] else null, "f"),
                    'C' => cfg.chdir = optionValue(av, &i, if (j + 1 < body.len) body[j + 1 ..] else null, "C"),
                    'T' => cfg.list_file = optionValue(av, &i, if (j + 1 < body.len) body[j + 1 ..] else null, "T"),
                    'X' => cfg.exclude_file = optionValue(av, &i, if (j + 1 < body.len) body[j + 1 ..] else null, "X"),
                    'v' => cfg.verbose = true,
                    'O' => cfg.to_stdout = true,
                    'm' => cfg.no_mtime = true,
                    'o' => cfg.no_owner = true,
                    'k' => cfg.keep_old = true,
                    'z' => cfg.gzip = true,
                    'j' => cfg.bzip2 = true,
                    'J' => cfg.xz = true,
                    'a' => cfg.autodetect = true,
                    'h' => cfg.follow = true,
                    else => {
                        c.eput("tar: invalid option -- '{c}'\n", .{body[j]});
                        bb.usage.die("tar");
                    },
                }
                if (body[j] == 'f' or body[j] == 'C' or body[j] == 'T' or body[j] == 'X') break;
            }
            continue;
        }
        if (a.len == 1 and (a[0] == 'c' or a[0] == 'x' or a[0] == 't')) {
            cfg.action = a[0];
            continue;
        }
        operands.append(c.A, a) catch {};
    }
    return operands;
}

fn matchPattern(name: []const u8, pat: []const u8) bool {
    if (pat.len == 0) return false;
    if (pat[0] == '*' and pat[pat.len - 1] == '*')
        return std.mem.indexOf(u8, name, pat[1 .. pat.len - 1]) != null;
    if (pat[0] == '*') return std.mem.endsWith(u8, name, pat[1..]);
    if (pat[pat.len - 1] == '*') return std.mem.startsWith(u8, name, pat[0 .. pat.len - 1]);
    return std.mem.eql(u8, name, pat) or std.mem.indexOf(u8, name, pat) != null;
}

fn excluded(name: []const u8, cfg: *const Config) bool {
    for (cfg.excludes.items) |p| {
        if (matchPattern(name, p)) return true;
    }
    return false;
}

fn zstr(s: []const u8) [*:0]const u8 {
    const p = std.mem.concatWithSentinel(c.A, u8, &.{s}, 0) catch linux.exit(127);
    return p.ptr;
}

/// BusyBox passes TAR_* metadata to --to-command children. Build an envp with
/// those values appended to the inherited environment.
fn commandEnv(e: tar.Entry) []?[*:0]const u8 {
    const base = bb.env.buildEnvp(c.A) catch linux.exit(127);
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    for (base) |item| if (item) |v| env.append(c.A, v) catch linux.exit(127);
    const extra = [_][]const u8{
        // BusyBox ORs S_IFREG into the mode it exports (its header reader
        // stores the file type bits alongside the permissions).
        std.fmt.allocPrint(c.A, "TAR_MODE={o}", .{e.mode | 0o100000}) catch linux.exit(127),
        std.fmt.allocPrint(c.A, "TAR_FILENAME={s}", .{e.name}) catch linux.exit(127),
        std.fmt.allocPrint(c.A, "TAR_REALNAME={s}", .{e.name}) catch linux.exit(127),
        std.fmt.allocPrint(c.A, "TAR_SIZE={d}", .{e.realsize}) catch linux.exit(127),
        std.fmt.allocPrint(c.A, "TAR_UID={d}", .{e.uid}) catch linux.exit(127),
        std.fmt.allocPrint(c.A, "TAR_GID={d}", .{e.gid}) catch linux.exit(127),
    };
    for (extra) |v| env.append(c.A, zstr(v)) catch linux.exit(127);
    env.append(c.A, null) catch linux.exit(127);
    return env.toOwnedSlice(c.A) catch linux.exit(127);
}

fn ignoreSigpipe() void {
    var act = linux.Sigaction{
        .handler = .{ .handler = @ptrFromInt(1) }, // SIG_IGN
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

/// Pipe one member's payload to `/bin/sh -c COMMAND`, reproducing BusyBox's
/// --to-command semantics: child stdout/stderr are inherited and a nonzero
/// child status is fatal.
fn runToCommand(e: tar.Entry, cmd: []const u8, data: []const u8) bool {
    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) {
        c.msg("pipe failed", .{});
        return false;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) {
        c.msg("fork failed", .{});
        return false;
    }
    if (pid == 0) {
        _ = linux.close(fds[1]);
        _ = linux.dup2(fds[0], 0);
        if (fds[0] > 0) _ = linux.close(fds[0]);
        const shell = "/bin/sh";
        const args = [_:null]?[*:0]const u8{ zstr(shell), zstr("-c"), zstr(cmd), null };
        const envp = commandEnv(e);
        _ = linux.execve(zstr(shell), @ptrCast(&args), bb.env.envpPtr(envp));
        linux.exit(127);
    }
    _ = linux.close(fds[0]);
    ignoreSigpipe();
    var written: usize = 0;
    while (written < data.len) {
        const n = linux.write(fds[1], data.ptr + written, data.len - written);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        written += @intCast(n);
    }
    _ = linux.close(fds[1]);
    var status: c_int = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const sig: u32 = @as(u32, @bitCast(status)) & 0x7f;
    const code: u32 = (@as(u32, @bitCast(status)) >> 8) & 0xff;
    if (sig != 0) {
        c.eput("tar: '{s}' terminated by signal {d}\n", .{ cmd, sig });
        return false;
    }
    if (code != 0) {
        c.eput("tar: '{s}' returned status {d}\n", .{ cmd, code });
        return false;
    }
    return true;
}

fn decompress(cfg: *const Config, data: []const u8) ?[]u8 {
    if (data.len == 0) return null;
    if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b)
        return compression.gzip.decompress(c.A, data) catch null;
    if (data.len >= 3 and data[0] == 'B' and data[1] == 'Z' and data[2] == 'h')
        return compression.bzip2.decompress(c.A, data) catch null;
    if (data.len >= 6 and std.mem.eql(u8, data[0..6], &.{ 0xfd, '7', 'z', 'X', 'Z', 0 }))
        return compression.xz.decompress(c.A, data) catch null;
    // LZMA "alone" headers have a props byte followed by a little-endian
    // dictionary size (typically 0x00800000); a tar whose first filename is a
    // single letter also starts with "<letter>\0\0", so check the high bytes.
    if (data.len >= 13 and data[0] < 225 and data[1] == 0 and data[2] == 0 and
        (data[3] == 0x80 or data[4] == 0x80))
        return compression.lzma.decompress(c.A, data) catch null;
    _ = cfg;
    return null;
}

fn putVerbose(e: tar.Entry) void {
    var mbuf: [10]u8 = undefined;
    const m = archive_cmds.modeStringPublic(e.mode, &mbuf);
    c.put("{s} {d}/{d} {d: >9} ", .{ m, e.uid, e.gid, e.realsize });
    archive_cmds.putIsoDatePublic(@intCast(e.mtime));
    c.put(" {s}\n", .{e.name});
}

fn strippedName(name: []const u8, n: usize) []const u8 {
    var s = name;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = std.mem.indexOfScalar(u8, s, '/') orelse return s;
        s = s[p + 1 ..];
    }
    return s;
}

fn extractData(data: []const u8, cfg: *const Config) c_int {
    if (data.len == 0) {
        c.msg("short read", .{});
        return 1;
    }
    if (decompress(cfg, data)) |unpacked| {
        if (unpacked.len == 0) {
            c.msg("short read", .{});
            return 1;
        }
        return extractTarBytes(unpacked, cfg);
    }
    if (cfg.gzip or cfg.bzip2 or cfg.xz or cfg.lzma or cfg.autodetect) {
        c.msg("invalid magic", .{});
        return 1;
    }
    return extractTarBytes(data, cfg);
}

fn extractTarBytes(bytes: []const u8, cfg: *const Config) c_int {
    const entries = tar.parse(c.A, bytes) catch {
        c.msg("invalid tar magic", .{});
        return 1;
    };
    defer tar.freeEntries(c.A, entries);
    var rc: c_int = 0;
    for (entries) |e| {
        if (excluded(e.name, cfg)) continue;
        if (cfg.strip_components != 0) {
            var slashes: usize = 0;
            for (e.name) |ch| if (ch == '/') { slashes += 1; };
            if (slashes < cfg.strip_components) continue;
        }
        const name = strippedName(e.name, cfg.strip_components);
        if (name.len == 0) continue;
        if (cfg.to_stdout) {
            c.out(e.data);
            continue;
        }
        if (cfg.keep_old and c.exists(name) and !cfg.overwrite) {
            c.perror(17, "can't open '{s}'", .{name});
            return 1;
        }
        if (cfg.to_command) |cmd| {
            // With --to-command the payload is piped to the command and no
            // file is created. BusyBox dies on the first failing command.
            if (!runToCommand(e, cmd, e.data)) return 1;
            continue;
        }
        const meta = archive_cmds.MetaOpts{
            .restore_mtime = !cfg.no_mtime,
            .restore_owner = !cfg.no_owner,
            .no_same_perms = cfg.no_same_perms,
        };
        if (!archive_cmds.writeEntryAtOpts(e, name, cfg.verbose, meta)) rc = 1;
    }
    return rc;
}

fn listData(data: []const u8, cfg: *const Config) c_int {
    if (data.len == 0) {
        c.msg("short read", .{});
        return 1;
    }
    const bytes = decompress(cfg, data) orelse data;
    if (bytes.len == 0) {
        c.msg("short read", .{});
        return 1;
    }
    const entries = tar.parse(c.A, bytes) catch {
        c.msg("invalid tar magic", .{});
        return 1;
    };
    defer tar.freeEntries(c.A, entries);
    for (entries) |e| {
        if (excluded(e.name, cfg)) continue;
        if (cfg.verbose) putVerbose(e) else c.put("{s}\n", .{e.name});
    }
    return 0;
}

fn collectFiles(operands: []const []const u8, cfg: *const Config) std.ArrayList(tar.Entry) {
    var entries: std.ArrayList(tar.Entry) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(c.A);
    for (operands) |n| names.append(c.A, n) catch {};
    if (cfg.list_file) |lf| {
        if (c.readAll(lf)) |text| {
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \r\t");
                if (t.len != 0) names.append(c.A, t) catch {};
            }
        }
    }
    for (names.items) |n| {
        if (excluded(n, cfg)) continue;
        // tar.freeEntries() frees names, so hand it an owned copy.
        const owned_name = c.A.dupe(u8, n) catch continue;
        const nz = c.A.dupeSentinel(u8, n, 0) catch continue;
        var stx: linux.Statx = undefined;
        const is_link = !cfg.follow and
            linux.errno(linux.statx(linux.AT.FDCWD, nz.ptr, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &stx)) == .SUCCESS and
            (stx.mode & linux.S.IFMT) == linux.S.IFLNK;
        if (is_link) {
            var target_buf: [4096]u8 = undefined;
            const len = linux.readlink(nz.ptr, &target_buf, target_buf.len);
            if (linux.errno(len) != .SUCCESS) continue;
            const target = c.A.dupe(u8, target_buf[0..@intCast(len)]) catch continue;
            entries.append(c.A, .{
                .name = owned_name,
                .linkname = target,
                .mode = 0o120777,
                .typeflag = '2',
                .mtime = @intCast(@max(stx.mtime.sec, 0)),
            }) catch {};
            continue;
        }
        const content = c.readAll(n) orelse continue;
        entries.append(c.A, .{ .name = owned_name, .data = content }) catch {};
    }
    return entries;
}

fn compressForCreate(data: []const u8, cfg: *const Config) []const u8 {
    if (cfg.gzip) return compression.gzip.gzipCompress(c.A, data) catch data;
    if (cfg.bzip2) return compression.bzip2.compress(c.A, data, 9) catch data;
    if (cfg.xz) return compression.xz.compress(c.A, data) catch data;
    if (cfg.lzma) return compression.lzma.compress(c.A, data) catch data;
    if (cfg.autodetect) if (cfg.file) |f| {
        if (std.mem.endsWith(u8, f, ".gz")) return compression.gzip.gzipCompress(c.A, data) catch data;
        if (std.mem.endsWith(u8, f, ".bz2")) return compression.bzip2.compress(c.A, data, 9) catch data;
        if (std.mem.endsWith(u8, f, ".xz")) return compression.xz.compress(c.A, data) catch data;
    };
    return data;
}

pub fn tarMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    if (av_slice.len < 2) bb.usage.die("tar");
    var cfg = Config{};
    var operands = parseOptions(av_slice, &cfg);
    defer operands.deinit(c.A);
    if (cfg.action == 0) bb.usage.die("tar");

    if (cfg.chdir) |d| {
        const z = c.A.dupeSentinel(u8, d, 0) catch return 1;
        if (linux.errno(linux.chdir(z.ptr)) != .SUCCESS) {
            c.perror(2, "can't chdir to '{s}'", .{d});
            return 1;
        }
    }
    if (cfg.exclude_file) |xf| {
        if (c.readAll(xf)) |text| {
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \r\t");
                if (t.len != 0) cfg.excludes.append(c.A, t) catch {};
            }
        }
    }

    const input = if (cfg.action != 'c') blk: {
        if (cfg.file) |f| {
            if (std.mem.eql(u8, f, "-")) break :blk c.readStdin();
            break :blk c.readAll(f) orelse {
                c.perror(2, "can't open '{s}'", .{f});
                return 1;
            };
        }
        break :blk c.readStdin();
    } else "";

    var rc: c_int = 0;
    switch (cfg.action) {
        't' => rc = listData(input, &cfg),
        'x' => rc = extractData(input, &cfg),
        'c' => {
            const entries = collectFiles(operands.items, &cfg);
            defer tar.freeEntries(c.A, entries.items);
            const data = tar.build(c.A, entries.items) catch return 1;
            const out = compressForCreate(data, &cfg);
            if (cfg.file) |f| {
                if (std.mem.eql(u8, f, "-")) c.out(out) else if (!c.writeFile(f, out)) rc = 1;
            } else c.out(out);
        },
        else => {},
    }
    return rc;
}
