//! `unzip` applet: list, test, extract and print members of a ZIP archive.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");
const zip = @import("zip.zig");

fn wanted(e: zip.Entry, names: []const []const u8, excludes: []const []const u8) bool {
    for (excludes) |x| {
        if (std.mem.eql(u8, x, e.name) or (x.len > 0 and x[x.len - 1] == '*' and
            std.mem.startsWith(u8, e.name, x[0 .. x.len - 1]))) return false;
    }
    if (names.len == 0) return true;
    for (names) |n| {
        if (std.mem.eql(u8, n, e.name)) return true;
        if (n.len > 0 and n[n.len - 1] == '*' and std.mem.startsWith(u8, e.name, n[0 .. n.len - 1])) return true;
    }
    return false;
}

fn putListHeader() void {
    c.out("  Length      Date    Time    Name\n---------  ---------- -----   ----\n");
}

fn putListEntry(e: zip.Entry) void {
    const year: u32 = @as(u32, e.dos_date >> 9) + 1980;
    const month: u8 = @intCast((e.dos_date >> 5) & 0x0f);
    const day: u8 = @intCast(e.dos_date & 0x1f);
    const hour: u8 = @intCast(e.dos_time >> 11);
    const minute: u8 = @intCast((e.dos_time >> 5) & 0x3f);
    c.put("{d: >9}  {d:0>2}-{d:0>2}-{d:0>4} {d:0>2}:{d:0>2}   {s}\n", .{
        e.uncompressed_size, month, day, year, hour, minute, e.name,
    });
}

fn putListFooter(total: u32, count: usize) void {
    c.put(" --------                     -------\n{d: >9}                     {d} files\n", .{ total, count });
}

fn makeDirs(path: []const u8) void {
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
    _ = linux.mkdir(@ptrCast(&buf), 0o777);
}

fn outputPath(dir: []const u8, name: []const u8, junk: bool) ![]u8 {
    var n = name;
    if (junk) {
        if (std.mem.lastIndexOfScalar(u8, n, '/')) |p| n = n[p + 1 ..];
    }
    if (std.fs.path.isAbsolute(n)) n = n[1..];
    if (std.mem.eql(u8, dir, ".")) return c.A.dupe(u8, n);
    return std.fmt.allocPrint(c.A, "{s}/{s}", .{ dir, n });
}

pub fn unzipMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    const o = c.opts("unzip", av_slice, "lnojpqKtx:d:", &.{});
    const list = c.flagged(o, 0);
    const never_overwrite = c.flagged(o, 1);
    const overwrite = c.flagged(o, 2);
    const junk = c.flagged(o, 3);
    const print = c.flagged(o, 4);
    const quiet = c.flagged(o, 5);
    const test_mode = c.flagged(o, 7);
    _ = c.flagged(o, 6); // -K keep suid bit
    // getopt32 exposes only the *last* option argument, so recover -d/-x
    // values from argv (a later flag such as -j clears optarg).
    var excluded: ?[]const u8 = null;
    var dir: []const u8 = ".";
    var ai: usize = 1;
    while (ai + 1 < av_slice.len) : (ai += 1) {
        if (std.mem.eql(u8, av_slice[ai], "-x") and excluded == null) excluded = av_slice[ai + 1];
        if (std.mem.eql(u8, av_slice[ai], "-d")) dir = av_slice[ai + 1];
    }

    var archive_name: ?[]const u8 = null;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(c.A);
    var excludes: std.ArrayList([]const u8) = .empty;
    defer excludes.deinit(c.A);
    if (excluded) |x| excludes.append(c.A, x) catch return 1;
    for (o.args) |a| {
        if (archive_name == null) archive_name = a else names.append(c.A, a) catch return 1;
    }
    const name = archive_name orelse bb.usage.die("unzip");
    var path = name;
    var with_zip: ?[]u8 = null;
    if (!c.exists(path)) {
        const candidate = if (std.mem.endsWith(u8, path, ".zip")) path else blk: {
            with_zip = std.fmt.allocPrint(c.A, "{s}.zip", .{path}) catch return 1;
            break :blk with_zip.?;
        };
        if (c.exists(candidate)) path = candidate;
    }
    // The reference prints the Archive banner and column header before it
    // discovers a truncated archive.
    if (list) {
        if (!quiet) c.put("Archive:  {s}\n", .{name});
        putListHeader();
    }
    const data = c.readAll(path) orelse {
        c.perror(2, "can't open '{s}'", .{path});
        return 1;
    };
    const entries = zip.parse(c.A, data) catch {
        c.msg("short read", .{});
        return 1;
    };
    defer zip.freeEntries(c.A, entries);

    var total: u32 = 0;
    for (entries) |e| {
        if (!wanted(e, names.items, excludes.items)) continue;
        total += e.uncompressed_size;
    }
    // BusyBox always reports the archive's total member count in the footer.
    const count = entries.len;

    if (list) {
        for (entries) |e| {
            if (wanted(e, names.items, excludes.items)) putListEntry(e);
        }
        putListFooter(total, count);
        return 0;
    }
    if (test_mode) {
        for (entries) |e| {
            if (!wanted(e, names.items, excludes.items)) continue;
            const content = zip.extract(c.A, data, e) catch {
                c.msg("invalid compressed data", .{});
                return 1;
            };
            if (!zip.crcOk(e, content)) {
                c.msg("invalid compressed data", .{});
                return 1;
            }
        }
        return 0;
    }
    if (print) {
        for (entries) |e| {
            if (!wanted(e, names.items, excludes.items) or e.is_dir) continue;
            const content = zip.extract(c.A, data, e) catch return 1;
            c.out(content);
        }
        return 0;
    }

    if (!quiet) c.put("Archive:  {s}\n", .{name});
    var rc: c_int = 0;
    for (entries) |e| {
        if (!wanted(e, names.items, excludes.items)) continue;
        const target = outputPath(dir, e.name, junk) catch {
            rc = 1;
            continue;
        };
        if (e.is_dir) {
            makeDirs(target);
            if (!quiet) c.put("   creating: {s}\n", .{e.name});
            continue;
        }
        if (c.exists(target) and never_overwrite) continue;
        if (c.exists(target) and !overwrite) continue;
        const content = zip.extract(c.A, data, e) catch {
            rc = 1;
            continue;
        };
        if (std.mem.lastIndexOfScalar(u8, target, '/')) |p| {
            const parent = c.A.dupe(u8, target[0..p]) catch {
                rc = 1;
                continue;
            };
            makeDirs(parent);
        }
        if (!c.writeFile(target, content)) {
            rc = 1;
            continue;
        }
        c.chmod(target, 0o600);
        if (!quiet) {
            var shown = e.name;
            if (junk) {
                if (std.mem.lastIndexOfScalar(u8, shown, '/')) |p2| shown = shown[p2 + 1 ..];
            }
            c.put("  inflating: {s}\n", .{shown});
        }
    }
    return rc;
}
