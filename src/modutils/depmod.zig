//! depmod (modprobe-small flavour) — scan a module tree and write modules.dep.bb.

const std = @import("std");
const c = @import("common.zig");

fn collect(root: []const u8, rel: []const u8, mods: *std.ArrayList(c.ModuleInfo)) void {
    const dirpath = if (rel.len == 0) root else std.fmt.allocPrint(c.A, "{s}/{s}", .{ root, rel }) catch return;
    for (c.dirNames(dirpath)) |entry| {
        const child_rel = if (rel.len == 0) entry else std.fmt.allocPrint(c.A, "{s}/{s}", .{ rel, entry }) catch continue;
        const full = std.fmt.allocPrint(c.A, "{s}/{s}", .{ root, child_rel }) catch continue;
        if (c.isDir(full)) {
            collect(root, child_rel, mods);
        } else if (std.mem.lastIndexOf(u8, entry, ".ko") != null) {
            const image = c.readFile(full) orelse continue;
            mods.append(c.A, c.parseModule(child_rel, image)) catch {};
        }
    }
}

pub fn depmodMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = c.opts(name, args, "naAeF:qru");

    if (!c.chdir("/lib/modules")) {
        c.plainDie("can't change directory to '/lib/modules': {s}", .{"No such file or directory"});
    }
    const version = if (o.args.len > 0) o.args[0] else c.unameRelease();
    const de = c.chdirErr(version);
    if (de != 0) c.plainDie("can't change directory to '{s}': {s}", .{ version, strerror(de) });

    var mods: std.ArrayList(c.ModuleInfo) = .empty;
    collect(".", "", &mods);

    var text: std.ArrayList(u8) = .empty;
    for (mods.items) |m| c.writeDepRecord(&text, m);

    if ((o.flags & (1 << 0)) != 0) { // -n
        c.out(text.items);
        return 0;
    }
    const linux = std.os.linux;
    var fd: linux.fd_t = undefined;
    const created = linux.open("modules.dep.bb.new", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .EXCL = true }, 0o644);
    if (c.err(created) == 17) { // EEXIST
        const reopened = linux.open("modules.dep.bb.new", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        if (c.err(reopened) != 0) {
            c.plain("can't create 'modules.dep.bb'", .{});
            return 1;
        }
        fd = @intCast(reopened);
    } else if (c.err(created) != 0) {
        c.plain("can't create 'modules.dep.bb'", .{});
        return 1;
    } else fd = @intCast(created);
    defer _ = std.os.linux.close(fd);
    var done: usize = 0;
    while (done < text.items.len) {
        const w = std.os.linux.write(fd, text.items[done..].ptr, text.items.len - done);
        if (c.err(w) != 0 or w == 0) break;
        done += w;
    }
    if (std.os.linux.rename("modules.dep.bb.new", "modules.dep.bb") != 0) {
        c.plain("can't create 'modules.dep.bb'", .{});
        return 1;
    }
    return 0;
}

fn strerror(e: c_int) []const u8 {
    return switch (e) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        13 => "Permission denied",
        20 => "Not a directory",
        else => "Unknown error",
    };
}
