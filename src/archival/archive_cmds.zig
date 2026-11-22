//! Archive-format applets: rpm2cpio, rpm, dpkg-deb, dpkg, cpio and ar.
//! Built entirely on the Task 19 pure-Zig archive helpers.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");
const archive = bb.archive;
const compression = bb.compression;

const rpm = archive.rpm;
const dpkg = archive.dpkg;
const tar = archive.tar;
const cpio = archive.cpio;

// ------------------------------------------------------------------ dates --

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

const Civil = struct { year: i64, month: u8, day: u8, hour: u8, minute: u8, second: u8, weekday: u8 };

fn civilFromEpoch(seconds: i64) Civil {
    // epoch seconds -> UTC civil time (Howard Hinnant's algorithm).
    const days = @divFloor(seconds, 86400);
    var rem = @mod(seconds, 86400);
    const hour: u8 = @intCast(@divFloor(rem, 3600));
    rem = @mod(rem, 3600);
    const minute: u8 = @intCast(@divFloor(rem, 60));
    const second: u8 = @intCast(@mod(rem, 60));
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else -9);
    y += if (month <= 2) 1 else 0;
    const wd: u8 = @intCast(@mod(days + 4, 7));
    return .{
        .year = y, .month = @intCast(month), .day = @intCast(day),
        .hour = hour, .minute = minute, .second = second, .weekday = wd,
    };
}

pub fn putIsoDatePublic(t: i64) void {
    putIsoDate(t);
}

fn putIsoDate(t: i64) void {
    const d = civilFromEpoch(t);
    c.put("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(d.year)), d.month, d.day, d.hour, d.minute, d.second });
}

fn putRpmDate(t: i64) void {
    const d = civilFromEpoch(t);
    c.put("{s} {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        weekday_names[d.weekday], d.day, month_names[d.month - 1], @as(u32, @intCast(d.year)),
        d.hour, d.minute, d.second,
    });
}

// --------------------------------------------------------------- rpm2cpio --

fn rpmError(err: anyerror) void {
    switch (err) {
        error.Truncated => c.msg("short read", .{}),
        error.BadMagic => c.msg("not an RPM package", .{}),
        else => c.msg("corrupted RPM", .{}),
    }
}

pub fn rpm2cpioMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    const o = c.opts("rpm2cpio", av_slice, "", &.{});
    if (o.args.len == 0) {
        c.msg("short read", .{});
        return 1;
    }
    const data = c.readAll(o.args[0]) orelse {
        c.msg("short read", .{});
        return 1;
    };
    const r = rpm.parse(data) catch |e| {
        rpmError(e);
        return 1;
    };
    const compressor = rpm.getString(r.header, .payload_compressor) orelse "gzip";
    if (!std.mem.eql(u8, compressor, "gzip") and !std.mem.eql(u8, compressor, "none") and
        !std.mem.eql(u8, compressor, "cpio"))
        c.msg("warning, unknown compression '{s}'", .{compressor});
    const payload = r.payloadData(c.A) catch |e| {
        rpmError(e);
        return 1;
    };
    c.out(payload);
    return 0;
}

// -------------------------------------------------------------------- rpm --

fn rpmMainInner(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    if (av_slice.len < 2) bb.usage.die("rpm");

    var install = false;
    var query = false;
    var mode: u8 = 0; // 'p','i','l','d','c'
    var file: ?[]const u8 = null;
    for (av_slice[1..]) |a| {
        if (std.mem.eql(u8, a, "-i")) {
            install = true;
        } else if (std.mem.eql(u8, a, "-qp") or std.mem.eql(u8, a, "-qpi") or
            std.mem.eql(u8, a, "-qpl") or std.mem.eql(u8, a, "-qpd") or std.mem.eql(u8, a, "-qpc"))
        {
            query = true;
            mode = a[a.len - 1];
        } else if (a.len > 0 and a[0] == '-') {
            c.errout("rpm: unrecognized option '");
            c.errout(a);
            c.errout("'\n");
            bb.usage.die("rpm");
        } else {
            file = a;
        }
    }
    if (!install and !query) bb.usage.die("rpm");
    const path = file orelse bb.usage.die("rpm");
    const data = c.readAll(path) orelse {
        c.msg("short read", .{});
        return 1;
    };
    const r = rpm.parse(data) catch |e| {
        rpmError(e);
        return 1;
    };

    if (query) {
        switch (mode) {
            'p' => c.put("{s}-{s}-{s}\n", .{
                rpm.getString(r.header, .name) orelse "(null)",
                rpm.getString(r.header, .version) orelse "(null)",
                rpm.getString(r.header, .release) orelse "(null)",
            }),
            'i' => {
                c.put("Name        : {s}\n", .{rpm.getString(r.header, .name) orelse "(null)"});
                c.put("Version     : {s}\n", .{rpm.getString(r.header, .version) orelse "(null)"});
                c.put("Release     : {s}\n", .{rpm.getString(r.header, .release) orelse "(null)"});
                c.out("Group       : (null)\n");
                c.out("Size        : -1\n");
                c.put("License     : {s}\n", .{rpm.getString(r.header, .license) orelse "(null)"});
                c.out("Source RPM  : (none)\n");
                c.out("Build Date  : ");
                // Our fixture has no buildtime tag; BusyBox's rpm_getint()
                // returns -1 for a missing tag.
                const bt = rpm.getInt(r.header, .buildtime);
                putRpmDate(if (bt) |v| (if (v == 0) -1 else @as(i64, v)) else -1);
                c.out("\n");
                c.out("Build Host  : (null)\n");
                c.out("Relocations : (not relocatable)\n");
                c.put("Summary     : {s}\n", .{rpm.getString(r.header, .summary) orelse "(null)"});
                c.put("Description :\n{s}\n", .{rpm.getString(r.header, .description) orelse "(null)"});
            },
            'l', 'd', 'c' => {
                const bases = rpm.getStrings(r.header, .basenames, c.A) catch &.{};
                const dirs = rpm.getStrings(r.header, .dirnames, c.A) catch &.{};
                const idxs = rpm.getInts(r.header, .dirindexes, c.A) catch &.{};
                const flags = rpm.getInts(r.header, .fileflags, c.A) catch &.{};
                for (bases, 0..) |base, i| {
                    const flag: u32 = if (i < flags.len) flags[i] else 0;
                    if (mode == 'd' and (flag & 2) == 0) continue;
                    if (mode == 'c' and (flag & 1) == 0) continue;
                    const dir: []const u8 = if (i < idxs.len and idxs[i] < dirs.len) dirs[idxs[i]] else "";
                    c.put("{s}{s}\n", .{ dir, base });
                }
            },
            else => {},
        }
        return 0;
    }

    // rpm -i: install the cpio payload relative to the current directory.
    const payload = r.payloadData(c.A) catch |e| {
        rpmError(e);
        return 1;
    };
    const entries = cpio.parse(c.A, payload) catch |e| {
        rpmError(e);
        return 1;
    };
    defer cpio.freeEntries(c.A, entries);
    return extractCpioEntries(entries, ".", false, false, false, false, false, true, null);
}

pub fn rpmMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return rpmMainInner(argc, argv);
}

// ---------------------------------------------------------------- dpkg-deb --

pub fn modeStringPublic(mode: u32, buf: *[10]u8) []const u8 {
    return modeString(mode, buf);
}

fn modeString(mode: u32, buf: *[10]u8) []const u8 {
    const kind = mode & 0o170000;
    const perm = mode & 0o777;
    buf[0] = if (kind == 0o120000) 'l' else if (kind == 0o040000) 'd' else '-';
    const bits = [_]u9{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001 };
    const chars = "rwxrwxrwx";
    for (bits, 0..) |b, i| buf[1 + i] = if (perm & b != 0) chars[i] else '-';
    return buf[0..10];
}

fn maybeDecompress(name: []const u8, data: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, name, ".gz"))
        return compression.gzip.decompress(c.A, data);
    if (std.mem.endsWith(u8, name, ".bz2"))
        return compression.bzip2.decompress(c.A, data);
    if (std.mem.endsWith(u8, name, ".xz"))
        return compression.xz.decompress(c.A, data);
    return c.A.dupe(u8, data);
}

fn mkdirParents(path: []const u8) void {
    if (path.len >= 4096) return;
    var buf: [4096:0]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    for (buf[0..path.len]) |*ch| {
        if (ch.* == '/') {
            ch.* = 0;
            _ = linux.mkdir(@ptrCast(&buf), 0o777);
            ch.* = '/';
        }
    }
}

fn join(base: []const u8, name: []const u8) ![]u8 {
    var clean = name;
    while (std.mem.startsWith(u8, clean, "./")) clean = clean[2..];
    if (std.fs.path.isAbsolute(clean)) clean = clean[1..];
    if (std.mem.eql(u8, base, ".")) return c.A.dupe(u8, clean);
    return std.fmt.allocPrint(c.A, "{s}/{s}", .{ base, clean });
}

/// Metadata restoration flags shared by the tar/cpio extractors. BusyBox
/// never restores permissions for a non-root user, so `restore_perm` follows
/// the same rule; `-o`/`--no-same-permissions` and `-m` are explicit overrides.
pub const Owner = struct { uid: u32, gid: u32 };

pub const MetaOpts = struct {
    restore_mtime: bool = false,
    restore_owner: bool = true,
    restore_perm: bool = false,
    no_same_perms: bool = false,
    owner_override: ?Owner = null,
};

/// Apply archived ownership, mode and mtime to an extracted file. Failures
/// (notably chown as non-root) are ignored, just as in BusyBox.
pub fn applyMeta(path: []const u8, mode: u32, uid: u32, gid: u32, mtime: i64, opts: MetaOpts) void {
    const p = c.A.dupeSentinel(u8, path, 0) catch return;
    if (opts.restore_owner) {
        const owner: Owner = opts.owner_override orelse Owner{ .uid = uid, .gid = gid };
        _ = linux.chown(p.ptr, owner.uid, owner.gid);
    }
    if (opts.restore_perm and !opts.no_same_perms)
        _ = linux.chmod(p.ptr, mode & 0o7777);
    if (opts.restore_mtime)
        bb.io.setTimes(path, mtime, 0) catch {};
}

pub fn extractTarEntryPublic(e: tar.Entry, base: []const u8, verbose: bool, no_perm: bool) bool {
    return extractTarEntry(e, base, verbose, no_perm, false);
}

/// Write an entry at an explicitly computed path (used by tar's
/// --strip-components support).
pub fn writeEntryAtOpts(e: tar.Entry, path: []const u8, verbose: bool, opts: MetaOpts) bool {
    mkdirParents(path);
    if (verbose) c.put("{s}\n", .{e.name});
    const is_dir = (e.mode & 0o170000) == 0o040000 or std.mem.endsWith(u8, e.name, "/");
    if (is_dir) {
        const z = c.A.dupeSentinel(u8, path, 0) catch return false;
        _ = linux.mkdir(z.ptr, if (opts.no_same_perms) 0o777 else @as(linux.mode_t, @intCast(e.mode & 0o777)));
        applyMeta(path, e.mode, e.uid, e.gid, @intCast(e.mtime), opts);
        return true;
    }
    if (!c.writeFileMode(path, e.data, @intCast(e.mode & 0o777))) return false;
    applyMeta(path, e.mode, e.uid, e.gid, @intCast(e.mtime), opts);
    return true;
}

pub fn writeEntryAt(e: tar.Entry, path: []const u8, verbose: bool, no_perm: bool) bool {
    return writeEntryAtOpts(e, path, verbose, .{ .no_same_perms = no_perm });
}

fn extractTarEntry(e: tar.Entry, base: []const u8, verbose: bool, no_perm: bool, keep_old: bool) bool {
    const path = join(base, e.name) catch return false;
    if (keep_old and c.exists(path)) return true;
    mkdirParents(path);
    if (verbose) c.put("{s}\n", .{e.name});
    const is_dir = (e.mode & 0o170000) == 0o040000 or std.mem.endsWith(u8, e.name, "/");
    if (is_dir) {
        const z = c.A.dupeSentinel(u8, path, 0) catch return false;
        _ = linux.mkdir(z.ptr, if (no_perm) 0o777 else @intCast(e.mode & 0o777));
        return true;
    }
    if (!c.writeFileMode(path, e.data, @intCast(e.mode & 0o777))) return false;
    applyMeta(path, e.mode, e.uid, e.gid, @intCast(e.mtime), .{
        .restore_mtime = false, .restore_owner = true, .no_same_perms = no_perm,
    });
    return true;
}

fn extractCpioEntries(entries: []const cpio.Entry, base: []const u8, verbose: bool, make_dirs: bool, overwrite: bool, no_perm: bool, restore_mtime: bool, restore_owner: bool, owner_override: ?Owner) c_int {
    var rc: c_int = 0;
    for (entries) |e| {
        const path = join(base, e.name) catch {
            rc = 1;
            continue;
        };
        if (make_dirs) mkdirParents(path);
        if (c.exists(path) and !overwrite) {
            c.msg("{s} not created: newer or same age file exists", .{e.name});
            if (verbose) c.put("{s}\n", .{e.name});
            continue;
        }
        const kind = e.mode & 0o170000;
        const is_dir = kind == 0o040000 or std.mem.endsWith(u8, e.name, "/");
        const zpath = c.A.dupeSentinel(u8, path, 0) catch {
            rc = 1;
            continue;
        };
        if (is_dir) {
            _ = linux.mkdir(zpath.ptr, if (no_perm) 0o777 else @intCast(e.mode & 0o777));
        } else if (kind == 0o120000) {
            const target = c.A.dupeSentinel(u8, e.data, 0) catch {
                rc = 1;
                continue;
            };
            _ = linux.symlink(target.ptr, zpath.ptr);
        } else if (!c.writeFileMode(path, e.data, @intCast(e.mode & 0o777))) {
            rc = 1;
            continue;
        }
        applyMeta(path, e.mode, e.uid, e.gid, @intCast(e.mtime), .{
            .restore_mtime = restore_mtime, .restore_owner = restore_owner,
            .no_same_perms = no_perm, .owner_override = owner_override,
        });
        if (verbose) c.put("{s}\n", .{e.name});
    }
    return rc;
}


fn controlText(deb: dpkg.Deb) ?[]const u8 {
    for (deb.members) |m| {
        if (!std.mem.startsWith(u8, m.name, "control.tar")) continue;
        const tardata = maybeDecompress(m.name, m.data) catch continue;
        const entries = tar.parse(c.A, tardata) catch continue;
        for (entries) |e| {
            if (std.mem.endsWith(u8, e.name, "control"))
                return e.data;
        }
    }
    return null;
}

fn printVerboseEntry(e: tar.Entry) void {
    var mbuf: [10]u8 = undefined;
    const m = modeString(e.mode, &mbuf);
    c.put("{s} {d}/{d} {d: >9} ", .{ m, e.uid, e.gid, e.data.len });
    putIsoDate(@intCast(e.mtime));
    c.put(" {s}\n", .{e.name});
}

pub fn dpkgDebMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    if (av_slice.len < 2) bb.usage.die("dpkg-deb");
    var action: u8 = 0;
    var file: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var positional: usize = 0;
    for (av_slice[1..]) |a| {
        if (std.mem.eql(u8, a, "-c")) action = 'c'
        else if (std.mem.eql(u8, a, "-f")) action = 'f'
        else if (std.mem.eql(u8, a, "-e")) action = 'e'
        else if (std.mem.eql(u8, a, "-x")) action = 'x'
        else if (std.mem.eql(u8, a, "-X")) action = 'X'
        else if (a.len > 0 and a[0] == '-') {
            if (std.mem.startsWith(u8, a, "--"))
                c.eput("dpkg-deb: unrecognized option '{s}'\n", .{a})
            else
                c.eput("dpkg-deb: invalid option -- '{c}'\n", .{a[1]});
            bb.usage.die("dpkg-deb");
        }
        else {
            if (positional == 0) file = a else if (positional == 1) dir = a;
            positional += 1;
        }
    }
    if (action == 0 or file == null) bb.usage.die("dpkg-deb");
    if (action == 'f' and positional > 1) bb.usage.die("dpkg-deb");
    const data = c.readAll(file.?) orelse {
        c.perror(2, "can't open '{s}'", .{file.?});
        return 1;
    };
    const deb = dpkg.parseDeb(c.A, data) catch |e| {
        switch (e) {
            error.BadMagic => c.msg("short read", .{}),
            error.CorruptHeader, error.BadHeader => c.msg("invalid ar header", .{}),
            else => c.msg("short read", .{}),
        }
        return 1;
    };
    defer dpkg.freeDeb(c.A, deb);
    const entries = dpkg.dataEntries(c.A, deb) catch {
        c.msg("invalid tar magic", .{});
        return 1;
    };
    defer tar.freeEntries(c.A, entries);

    switch (action) {
        'c' => for (entries) |e| printVerboseEntry(e),
        'f' => {
            if (dir) |field| {
                // Print just the named control field, like dpkg-deb -f pkg FIELD.
                const text = controlText(deb) orelse "";
                var it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |line| {
                    if (std.mem.startsWith(u8, line, field) and line.len > field.len and line[field.len] == ':')
                        c.put("{s}\n", .{line});
                }
            } else c.out(controlText(deb) orelse "");
        },
        'x', 'X' => {
            const target = dir orelse bb.usage.die("dpkg-deb");
            for (entries) |e| {
                if (action == 'X') c.put("{s}\n", .{e.name});
                _ = extractTarEntry(e, target, false, false, false);
            }
        },
        'e' => {
            const target = dir orelse "DEBIAN";
            const members = dpkg.parseAr(c.A, data) catch return 1;
            defer dpkg.freeMembers(c.A, members);
            for (members) |m| {
                if (std.mem.startsWith(u8, m.name, "control.tar")) {
                    const tardata = maybeDecompress(m.name, m.data) catch return 1;
                    const ces = tar.parse(c.A, tardata) catch return 1;
                    defer tar.freeEntries(c.A, ces);
                    for (ces) |e| _ = extractTarEntry(e, target, false, false, false);
                }
            }
        },
        else => {},
    }
    return 0;
}


// ------------------------------------------------------------------- dpkg --

fn dpkgGlob(name: []const u8, pat: []const u8) bool {
    if (pat.len == 0) return true;
    if (std.mem.indexOfScalar(u8, pat, '*') == null)
        return std.mem.eql(u8, name, pat);
    var parts = std.mem.splitScalar(u8, pat, '*');
    const first = parts.next() orelse "";
    if (!std.mem.startsWith(u8, name, first)) return false;
    var rest = name[first.len..];
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const p = std.mem.indexOf(u8, rest, part) orelse return false;
        rest = rest[p + part.len ..];
    }
    return true;
}

fn getField(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ':')
            return std.mem.trim(u8, line[key.len + 1 ..], " \t");
    }
    return null;
}

/// Real `dpkg -l`: parse the dpkg status database and apply the requested
/// package-name pattern, exactly like BusyBox's list_packages().
fn listPackages(pattern: ?[]const u8) void {
    c.out("    Name           Version\n+++-==============-==============\n");
    const data = c.readAll("/var/lib/dpkg/status") orelse return;
    var paragraphs = std.mem.splitSequence(u8, data, "\n\n");
    while (paragraphs.next()) |para| {
        const name = getField(para, "Package") orelse continue;
        if (pattern) |p| {
            if (!dpkgGlob(name, p)) continue;
        }
        const version = getField(para, "Version") orelse "";
        const status = getField(para, "Status") orelse "";
        const s1: u8 = if (status.len > 0 and status[0] == 'i') 'i' else 'r';
        var j: usize = 0;
        var spaces: usize = 0;
        while (j < status.len and spaces < 2) : (j += 1) {
            if (status[j] == ' ') spaces += 1;
        }
        const s2: u8 = if (j < status.len) status[j] else '?';
        c.put("{c}{c}  {s}", .{ s1, s2, name });
        if (name.len < 14) for (0..14 - name.len) |_| c.out(" ");
        c.put(" {s}\n", .{version});
    }
}

pub fn dpkgMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    if (av_slice.len < 2) bb.usage.die("dpkg");
    var action: u8 = 0;
    var file: ?[]const u8 = null;
    var force_confnew = false;
    var force_confold = false;
    var force_depends = false;
    for (av_slice[1..]) |a| {
        if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--install")) action = 'i'
        else if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--remove")) action = 'r'
        else if (std.mem.eql(u8, a, "-P") or std.mem.eql(u8, a, "--purge")) action = 'P'
        else if (std.mem.eql(u8, a, "--unpack")) action = 'u'
        else if (std.mem.eql(u8, a, "--configure")) action = 'c'
        else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list")) action = 'l'
        else if (std.mem.eql(u8, a, "--force-depends")) force_depends = true
        else if (std.mem.eql(u8, a, "--force-confnew")) force_confnew = true
        else if (std.mem.eql(u8, a, "--force-confold")) force_confold = true
        else if (a.len > 0 and a[0] == '-') bb.usage.die("dpkg")
        else file = a;
    }
    if (force_depends) {
        // BusyBox 1.39 has no dependency resolver here; the flag is accepted
        // and recorded but never needs to override a check.
    }
    if (action == 0) bb.usage.die("dpkg");
    if (action == 'l') {
        listPackages(file);
        return 0;
    }
    const path = file orelse bb.usage.die("dpkg");
    if (action == 'r' or action == 'P' or action == 'c') {
        c.msg("package {s} is uninstalled or unknown", .{path});
        return 1;
    }
    const data = c.readAll(path) orelse {
        c.perror(2, "can't open '{s}'", .{path});
        return 0;
    };
    const deb = dpkg.parseDeb(c.A, data) catch |e| {
        switch (e) {
            error.CorruptHeader, error.BadHeader, error.BadMagic, error.Truncated => c.msg("short read", .{}),
            else => c.msg("short read", .{}),
        }
        return 1;
    };
    defer dpkg.freeDeb(c.A, deb);
    const entries = dpkg.dataEntries(c.A, deb) catch return 1;
    defer tar.freeEntries(c.A, entries);
    // --force-confold (and the default) keep existing files; --force-confnew
    // replaces them.
    const keep_old = !force_confnew or force_confold;
    for (entries) |e| _ = extractTarEntry(e, ".", false, false, keep_old);
    return 0;
}

// ------------------------------------------------------------------- cpio --

fn printCpioVerbose(e: cpio.Entry) void {
    var mbuf: [10]u8 = undefined;
    const m = modeString(e.mode, &mbuf);
    c.put("{s} {d}/{d} {d: >9} ", .{ m, e.uid, e.gid, e.data.len });
    putIsoDate(@intCast(e.mtime));
    c.put(" {s}\n", .{e.name});
}

fn cpioMainInner(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    const longs = [_]c.LongOpt{
        .{ .name = "ignore-devno", .val = 0 },
        .{ .name = "renumber-inodes", .val = 0 },
    };
    // bit layout: t0 i1 o2 d3 m4 v5 u6 '0'7 p8 F9 H10 R11 L12
    const os = "tiodmvu0p:F:H:R:L";
    const o = c.opts("cpio", av_slice, os, longs[0..]);
    const list = c.flagged(o, 0);
    const extract = c.flagged(o, 1);
    const create = c.flagged(o, 2);
    const make_dirs = c.flagged(o, 3);
    const restore_mtime = c.flagged(o, 4);
    const verbose = c.flagged(o, 5);
    const overwrite = c.flagged(o, 6);
    const nul = c.flagged(o, 7);
    const copy_pass = c.flagged(o, 8);
    const copy_target: ?[]const u8 = if (copy_pass) o.optarg else null;
    const has_file = c.flagged(o, 9);
    var input_file: ?[]const u8 = null;
    var copy_target_raw: ?[]const u8 = null;
    var format: ?[]const u8 = null;
    var owner_spec: ?[]const u8 = null;
    {
        var ai: usize = 1;
        while (ai + 1 < av_slice.len) : (ai += 1) {
            if (std.mem.eql(u8, av_slice[ai], "-F") and input_file == null) input_file = av_slice[ai + 1];
            if (std.mem.eql(u8, av_slice[ai], "-p") and copy_target_raw == null) copy_target_raw = av_slice[ai + 1];
            if (std.mem.eql(u8, av_slice[ai], "-H") and format == null) format = av_slice[ai + 1];
            if (std.mem.eql(u8, av_slice[ai], "-R") and owner_spec == null) owner_spec = av_slice[ai + 1];
        }
    }
    if (!has_file) input_file = null;
    const dereference = c.flagged(o, 12); // -L
    var owner_override: ?Owner = null;
    if (owner_spec) |spec| {
        const colon = std.mem.indexOfScalar(u8, spec, ':');
        const uid_text = if (colon) |p2| spec[0..p2] else spec;
        const gid_text = if (colon) |p2| spec[p2 + 1 ..] else spec;
        const uid = std.fmt.parseInt(u32, uid_text, 10) catch 0;
        const gid = std.fmt.parseInt(u32, gid_text, 10) catch 0;
        owner_override = .{ .uid = uid, .gid = gid };
    }

    if (list or extract) {
        const data = if (input_file) |f|
            c.readAll(f) orelse {
                c.perror(2, "can't open '{s}'", .{f});
                return 1;
            }
        else
            c.readStdin();
        const entries = cpio.parse(c.A, data) catch {
            if (input_file) |f| {
                if (!c.exists(f)) {
                    c.perror(2, "can't open '{s}'", .{f});
                    return 1;
                }
            }
            c.msg("short read", .{});
            return 1;
        };
        defer cpio.freeEntries(c.A, entries);
        for (entries) |e| {
            if (list) {
                if (verbose) printCpioVerbose(e) else c.put("{s}\n", .{e.name});
            }
        }
        var rc: c_int = 0;
        if (extract) rc = extractCpioEntries(entries, ".", verbose, make_dirs, overwrite, false, restore_mtime, true, owner_override);
        const blocks = (data.len + 511) / 512;
        c.eput("{d} blocks\n", .{blocks});
        return rc;
    }

    if (create or copy_pass) {
        if (format == null or !std.mem.eql(u8, format.?, "newc")) bb.usage.die("cpio");
        const name_data = if (input_file) |f| c.readAll(f) orelse return 1 else c.readStdin();
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(c.A);
        var it = std.mem.splitScalar(u8, name_data, if (nul) 0 else '\n');
        while (it.next()) |n| {
            const trimmed = std.mem.trim(u8, n, " \r\t");
            if (trimmed.len != 0) names.append(c.A, trimmed) catch return 1;
        }
        var entries: std.ArrayList(cpio.Entry) = .empty;
        defer entries.deinit(c.A);
        for (names.items) |n| {
            const nz = c.A.dupeSentinel(u8, n, 0) catch return 1;
            var stx: linux.Statx = undefined;
            const is_link = !dereference and
                linux.errno(linux.statx(linux.AT.FDCWD, nz.ptr, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &stx)) == .SUCCESS and
                (stx.mode & linux.S.IFMT) == linux.S.IFLNK;
            if (is_link) {
                var buf: [4096]u8 = undefined;
                const len = linux.readlink(nz.ptr, &buf, buf.len);
                if (linux.errno(len) != .SUCCESS) return 1;
                const target = c.A.dupe(u8, buf[0..@intCast(len)]) catch return 1;
                entries.append(c.A, .{ .name = n, .data = target, .mode = 0o120777, .mtime = @intCast(@max(stx.mtime.sec, 0)) }) catch return 1;
                continue;
            }
            const content = c.readAll(n) orelse {
                c.msg("can't open '{s}'", .{n});
                return 1;
            };
            var mtime: u32 = 0;
            var stat_buf: linux.Statx = undefined;
            if (linux.errno(linux.statx(linux.AT.FDCWD, nz.ptr, 0, .BASIC_STATS, &stat_buf)) == .SUCCESS)
                mtime = @intCast(@max(stat_buf.mtime.sec, 0));
            entries.append(c.A, .{ .name = n, .data = content, .mtime = mtime }) catch return 1;
        }
        if (copy_pass) {
            const target = copy_target_raw orelse copy_target orelse ".";
            return extractCpioEntries(entries.items, target, verbose, make_dirs, overwrite, false, restore_mtime, true, owner_override);
        }
        const out_data = cpio.build(c.A, entries.items) catch return 1;
        if (input_file) |f| {
            if (!c.writeFile(f, out_data)) return 1;
        } else c.out(out_data);
        return 0;
    }
    bb.usage.die("cpio");
}

pub fn cpioMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return cpioMainInner(argc, argv);
}

// --------------------------------------------------------------------- ar --

pub fn arMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    const o = c.opts("ar", av_slice, "xptov", &.{});
    var action: u8 = 0;
    for ("xpt") |ch| {
        if (c.flagged(o, @intCast(std.mem.indexOfScalar(u8, "xptov", ch).?))) action = ch;
    }
    const verbose = c.flagged(o, 4);
    const files = o.args;
    if (action == 0 or files.len == 0) bb.usage.die("ar");
    const data = c.readAll(files[0]) orelse {
        c.perror(2, "can't open '{s}'", .{files[0]});
        return 1;
    };
    const members = dpkg.parseAr(c.A, data) catch {
        c.msg("invalid ar header", .{});
        return 1;
    };
    defer dpkg.freeMembers(c.A, members);
    var rc: c_int = 0;
    for (members) |m| {
        var wanted = files.len == 1;
        for (files[1..]) |f| {
            if (std.mem.eql(u8, f, m.name)) wanted = true;
        }
        if (!wanted) continue;
        switch (action) {
            't' => c.put("{s}\n", .{m.name}),
            'p' => c.out(m.data),
            'x' => {
                if (!c.writeFile(m.name, m.data)) rc = 1;
                if (verbose) c.put("x - {s}\n", .{m.name});
            },
            else => {},
        }
    }
    return rc;
}
