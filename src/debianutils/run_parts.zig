//! debianutils run-parts — run all scripts in a directory.

const std = @import("std");
const c = @import("common.zig");
const bb = c.bb;
const linux = c.linux;

// getopt32: short opts 'a','u' use bits 0,1; long-only opts get 2,3,4,5.
const F_REVERSE: u32 = 1 << 2;
const F_TEST: u32 = 1 << 3;
const F_EXITERR: u32 = 1 << 4;
const F_LIST: u32 = 1 << 5;

const longopts = [_]bb.getopt.LongOpt{
    .{ .name = "arg", .has_arg = .required, .val = 'a' },
    .{ .name = "umask", .has_arg = .required, .val = 'u' },
    .{ .name = "reverse", .val = '\xf0' },
    .{ .name = "test", .val = '\xf1' },
    .{ .name = "exit-on-error", .val = '\xf2' },
    .{ .name = "list", .val = '\xf3' },
};

fn invalidName(path: []const u8) bool {
    const name = c.basename(path);
    if (name.len == 0 or name[0] == '.') return true;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return true;
    }
    return false;
}

fn collectExtraArgs(allocator: std.mem.Allocator, args: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (std.mem.eql(u8, tok, "--")) break;
        if (std.mem.eql(u8, tok, "-a") or std.mem.eql(u8, tok, "--arg")) {
            if (i + 1 < args.len) {
                i += 1;
                try out.append(allocator, args[i]);
            }
        } else if (std.mem.startsWith(u8, tok, "-a") and tok.len > 2) {
            try out.append(allocator, tok[2..]);
        } else if (std.mem.startsWith(u8, tok, "--arg=")) {
            try out.append(allocator, tok[6..]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
fn greaterStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .gt;
}

pub fn runPartsMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const allocator = std.heap.page_allocator;
    const args = c.argsFrom(allocator, argv, argc) catch return 1;
    defer allocator.free(args);
    bb.env.setProgramName(c.basename(args[0]));

    const parsed = bb.getopt.getopt32(args, "^a:*u:", &longopts) catch {
        bb.usage.die(c.basename(args[0]));
    };
    var flags: u32 = 0;
    if ((parsed.flags & (1 << 2)) != 0) flags |= F_REVERSE;
    if ((parsed.flags & (1 << 3)) != 0) flags |= F_TEST;
    if ((parsed.flags & (1 << 4)) != 0) flags |= F_EXITERR;
    if ((parsed.flags & (1 << 5)) != 0) flags |= F_LIST;
    const rest = parsed.args;
    if (rest.len != 1) bb.usage.die(c.basename(args[0]));
    const dir = rest[0];

    const extras = collectExtraArgs(allocator, args) catch return 1;
    defer allocator.free(extras);
    _ = parsed.optarg; // umask accepted but only affects spawned scripts

    var dir_handle = c.DirIter.open(dir) orelse {
        const st = c.statPath(dir, false);
        const eno: c_int = if (st == null) 2 else 20;
        bb.messages.errorMsg(eno, "{s}", .{dir});
        return 0;
    };
    defer dir_handle.close();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    while (dir_handle.next()) |name| {
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (invalidName(name)) continue;
        const full = if (std.mem.endsWith(u8, dir, "/"))
            std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, name })
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
        const path = full catch continue;
        if ((flags & F_LIST) == 0) {
            const st = c.statPath(path, true) orelse continue;
            if ((st.mode & 0o111) == 0) continue;
        }
        names.append(allocator, path) catch allocator.free(path);
    }
    if (flags & F_REVERSE != 0)
        std.mem.sort([]const u8, names.items, {}, greaterStr)
    else
        std.mem.sort([]const u8, names.items, {}, lessStr);

    if (flags & (F_TEST | F_LIST) != 0) {
        for (names.items) |name| {
            c.writeAll(1, name);
            c.writeAll(1, "\n");
        }
        return 0;
    }

    var failed = false;
    for (names.items) |name| {
        var child_argv: std.ArrayList([]const u8) = .empty;
        defer child_argv.deinit(allocator);
        child_argv.append(allocator, name) catch continue;
        for (extras) |x| child_argv.append(allocator, x) catch break;
        const code = c.runChild(allocator, child_argv.items);
        if (code != 0) {
            bb.messages.plainMsg("{s}: exit status {d}", .{ name, code });
            failed = true;
            if (flags & F_EXITERR != 0) std.process.exit(1);
        }
    }
    return if (failed) 1 else 0;
}
