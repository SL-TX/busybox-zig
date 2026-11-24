//! modinfo — display module metadata fields from a module image.

const std = @import("std");
const c = @import("common.zig");

const shortcuts = [_][]const u8{
    "filename", "author", "description", "license", "parm", "version",
    "alias", "srcversion", "depends", "uts_release", "intree", "vermagic", "firmware",
};

fn display(data: []const u8, pattern: []const u8, mask: u32, nul: bool) void {
    const flag = mask >> 1;
    if ((flag & (flag - 1)) != 0) {
        c.put("{s}:", .{pattern});
        var n: usize = pattern.len + 1;
        while (n < 16) : (n += 1) c.out(" ");
    }
    c.out(data);
    c.out(if (nul) "\x00" else "\n");
}

fn oneField(path: []const u8, image: []const u8, pattern: []const u8, mask: u32, nul: bool) void {
    if (std.mem.eql(u8, pattern, "filename")) {
        display(path, pattern, mask, nul);
        return;
    }
    var pos: usize = 0;
    while (pos + pattern.len < image.len) {
        const hit = std.mem.indexOfPos(u8, image, pos, pattern) orelse break;
        const after = hit + pattern.len;
        if (after < image.len and image[after] == '=' and hit > 0 and (image[hit - 1] & 0x7f) == 0) {
            const value = image[after + 1 ..];
            const end = std.mem.indexOfScalar(u8, value, 0) orelse value.len;
            display(value[0..end], pattern, mask, nul);
            pos = after + 1 + end + 1;
        } else pos = hit + 1;
    }
}

fn showModule(path_in: []const u8, version: []const u8, field: ?[]const u8, mask: u32) void {
    const nul = (mask & 1) != 0;
    const got = c.readFile(path_in);
    var path = path_in;
    var image: []const u8 = undefined;
    if (got) |data| {
        image = data;
    } else {
        if (path.len > 0 and path[0] == '/') return;
        const fallback = std.fmt.allocPrint(c.A, "/lib/modules/{s}/{s}", .{ version, path }) catch return;
        path = fallback;
        const second = c.readFile(path) orelse {
            c.plain("module '{s}' not found", .{path});
            return;
        };
        image = second;
    }

    var j: usize = 1;
    while (j <= 14) : (j += 1) {
        const bit = @as(u32, 1) << @intCast(j);
        if ((mask & bit) == 0) continue;
        const pattern = if (j == 1) field orelse continue else shortcuts[j - 2];
        oneField(path, image, pattern, mask, nul);
    }
}

pub fn modinfoMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = c.opts(name, args, "^0F:nadlp");
    if (o.args.len == 0) c.usageDie(name);

    var mask = o.flags;
    if ((mask & ((1 << 1) | (0x7fff << 2))) == 0) mask |= 0x7fff << 2;
    const field: ?[]const u8 = if ((mask & (1 << 1)) != 0) o.optarg else null;
    const version = c.unameRelease();
    const depfile = std.fmt.allocPrint(c.A, "/lib/modules/{s}/modules.dep", .{version}) catch return 1;
    const data = c.readFile(depfile) orelse c.plainDie("can't open '{s}'", .{depfile});

    var consumed = c.A.alloc(bool, o.args.len) catch return 1;
    @memset(consumed, false);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        var token = line[0..end];
        if (std.mem.endsWith(u8, token, ":")) token = token[0 .. token.len - 1];
        const base = std.fs.path.basename(token);
        var modname_buf: [64]u8 = undefined;
        const n = @min(modname_buf.len, base.len);
        for (base[0..n], 0..) |ch, i| modname_buf[i] = if (ch == '-') '_' else ch;
        const modname = modname_buf[0..n];
        for (o.args, 0..) |want, i| {
            if (consumed[i]) continue;
            if (c.fnmatch(want, modname)) {
                showModule(token, version, field, mask);
                consumed[i] = true;
            }
        }
    }
    for (o.args, 0..) |want, i| {
        if (!consumed[i]) showModule(want, version, field, mask);
    }
    return 0;
}
