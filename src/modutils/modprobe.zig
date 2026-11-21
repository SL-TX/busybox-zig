//! modprobe (modprobe-small flavour) — load/unload a module and its deps.

const std = @import("std");
const c = @import("common.zig");
const rmmod = @import("rmmod.zig");
const insmod = @import("insmod.zig");

const SYS_INIT_MODULE: std.os.linux.SYS = @enumFromInt(105);
const SYS_DELETE_MODULE: std.os.linux.SYS = @enumFromInt(176);

fn loadedModules() std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(c.A);
    const data = c.readFile("/proc/modules") orelse return set;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const name = std.mem.sliceTo(line, ' ');
        if (name.len > 0) set.put(c.A.dupe(u8, name) catch name, {}) catch {};
    }
    return set;
}

const Dep = struct { path: []const u8, deps: []const u8 };

fn loadDepBb() std.ArrayList(Dep) {
    var list: std.ArrayList(Dep) = .empty;
    const data = c.readFile("modules.dep.bb") orelse return list;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const path = line[0..sp];
        const deps = if (sp < line.len) std.mem.trim(u8, line[sp + 1 ..], " ") else "";
        list.append(c.A, .{ .path = c.A.dupe(u8, path) catch path, .deps = c.A.dupe(u8, deps) catch deps }) catch {};
        if (deps.len > 0) _ = lines.next(); // dependency line + blank separator
    }
    return list;
}

fn findDep(deps: []const Dep, name: []const u8) ?Dep {
    for (deps) |d| {
        var nb: [64]u8 = undefined;
        const base = std.fs.path.basename(d.path);
        const mod = rmmod.filename2modname(base, &nb);
        if (std.mem.eql(u8, mod, name)) return d;
    }
    return null;
}

fn walkModules(dir: []const u8, want: []const u8, result: *?[]const u8) void {
    for (c.dirNames(dir)) |entry| {
        const path = if (std.mem.eql(u8, dir, ".")) entry else std.fmt.allocPrint(c.A, "{s}/{s}", .{ dir, entry }) catch continue;
        if (c.isDir(path)) {
            walkModules(path, want, result);
        } else if (std.mem.lastIndexOf(u8, entry, ".ko") != null) {
            var nb: [64]u8 = undefined;
            const mod = rmmod.filename2modname(entry, &nb);
            if (std.mem.eql(u8, mod, want) and result.* == null) result.* = c.A.dupe(u8, path) catch path;
        }
    }
}

fn scanFor(name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    walkModules(".", name, &found);
    return found;
}

fn loadOne(path: []const u8, options: []const u8) c_int {
    const image = c.readFile(path) orelse return 2;
    const optz = c.zstr(options) catch return 12;
    defer c.A.free(optz);
    const rc = std.os.linux.syscall3(SYS_INIT_MODULE, @intFromPtr(image.ptr), image.len, @intFromPtr(optz.ptr));
    return c.err(rc);
}

pub fn modprobeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = c.opts(name, args, "^qrfsvwb");
    if (o.args.len == 0) c.usageDie(name);

    var de = c.chdirErr("/lib/modules");
    if (de != 0) c.plainDie("can't change directory to '/lib/modules': {s}", .{c.strerror(de)});
    const release = c.unameRelease();
    de = c.chdirErr(release);
    if (de != 0) c.plainDie("can't change directory to '{s}': {s}", .{ release, c.strerror(de) });

    var loaded = loadedModules();
    defer loaded.deinit();
    const quiet = (o.flags & (1 << 0)) != 0;
    const remove = (o.flags & (1 << 1)) != 0;

    var rc: c_int = 0;
    for (o.args) |arg| {
        var nb: [64]u8 = undefined;
        const modname = rmmod.filename2modname(arg, &nb);
        if (!remove and loaded.contains(modname)) continue;
        if (remove) {
            const p = c.zstr(modname) catch continue;
            defer c.A.free(p);
            const r = std.os.linux.syscall2(SYS_DELETE_MODULE, @intFromPtr(p.ptr), 0x880);
            const e = c.err(r);
            if (e != 0 and !quiet) c.msg(e, "remove '{s}'", .{modname});
            continue;
        }
        var options: std.ArrayList(u8) = .empty;
        for (args[o.index + 1 ..]) |extra| {
            options.appendSlice(c.A, " \"") catch {};
            options.appendSlice(c.A, extra) catch {};
            options.appendSlice(c.A, "\"") catch {};
        }
        const deps = loadDepBb();
        var path: ?[]const u8 = if (findDep(deps.items, modname)) |d| d.path else null;
        if (path == null) path = scanFor(modname);
        if (path == null) {
            if (!quiet) c.plain("module '{s}' not found", .{modname});
            rc = 1;
            continue;
        }
        const e = loadOne(path.?, options.items);
        if (e != 0) {
            if (!quiet) c.plain("'{s}': {s}", .{ path.?, insmod.moderror(e) });
            rc = 1;
        }
    }
    return rc;
}
