//! i2c device tools (reference miscutils/i2c_tools.c).
//! In a sandbox the /dev/i2c-N nodes are not writable, so every successful
//! parse ends at the same `can't open` diagnostic. Parsing, range checks and
//! the sysfs bus listing are implemented for real.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");

fn openBus(name: []const u8, bus: i64) noreturn {
    _ = name;
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/dev/i2c-{d}", .{bus}) catch "/dev/i2c-0";
    const z = c.zstr(std.heap.page_allocator, path) catch std.process.exit(1);
    const rc = linux.open(z, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) == .SUCCESS) {
        _ = linux.close(@intCast(rc));
        std.process.exit(0);
    }
    c.errorMsgAndDie(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{path});
}

fn parseBus(name: []const u8, text: []const u8) i64 {
    _ = name;
    return std.fmt.parseInt(i64, text, 0) catch {
        c.plainMsg("invalid number '{s}'", .{text});
        std.process.exit(1);
    };
}

fn parseAddr(name: []const u8, text: []const u8) i64 {
    _ = name;
    const v = std.fmt.parseInt(i64, text, 0) catch {
        c.plainMsg("invalid number '{s}'", .{text});
        std.process.exit(1);
    };
    if (v < 3 or v > 119) {
        c.plainMsg("number {s} is not in 3..119 range", .{text});
        std.process.exit(1);
    }
    return v;
}

fn listBuses() noreturn {
    // Walk /sys/class/i2c-dev in directory order. Buses whose `name` file is
    // readable are probed by opening /dev/i2c-N; the sandbox denies that and
    // the reference dies with the matching `can't open` diagnostic.
    const dirpath = "/sys/class/i2c-dev";
    const dz = c.zstr(std.heap.page_allocator, dirpath) catch std.process.exit(1);
    const dfd_rc = linux.open(dz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(dfd_rc) != .SUCCESS) std.process.exit(0);
    const dfd: linux.fd_t = @intCast(dfd_rc);
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dfd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var pos: usize = 0;
        while (pos + 19 <= n) {
            const reclen = std.mem.readInt(u16, buf[pos + 16 ..][0..2], .native);
            if (reclen < 19 or pos + reclen > n) break;
            const nb = buf[pos + 19 .. pos + reclen];
            const len = std.mem.indexOfScalar(u8, nb, 0) orelse nb.len;
            if (len > 4 and std.mem.startsWith(u8, nb[0..len], "i2c-")) {
                const bus = std.fmt.parseInt(i64, nb[4..len], 10) catch {
                    pos += reclen;
                    continue;
                };
                var pathbuf: [256]u8 = undefined;
                const namepath = std.fmt.bufPrint(&pathbuf, "{s}/{s}/name", .{ dirpath, nb[0..len] }) catch "";
                var en: c_int = 0;
                if (c.readFile(std.heap.page_allocator, namepath, &en)) |content| {
                    const usable = content.len > 0;
                    std.heap.page_allocator.free(content);
                    if (usable) {
                        // Opening the adapter to query its functionality is
                        // the first operation that touches /dev/i2c-N.
                        openBus("i2cdetect", bus);
                    }
                }
            }
            pos += reclen;
        }
    }
    std.process.exit(0);
}

pub fn i2cdetect_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("i2cdetect");
    var i: usize = 1;
    var list = false;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-l")) list = true;
        if (args[i].len > 1 and args[i][0] == '-') continue;
        break;
    }
    if (list) listBuses();
    const positional = args[i..];
    if (positional.len == 0) c.usageDie("i2cdetect");
    const bus = parseBus("i2cdetect", positional[0]);
    openBus("i2cdetect", bus);
}

pub fn i2cdump_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("i2cdump");
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    for (args[1..]) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        pos.append(a, arg) catch {};
    }
    if (pos.items.len < 2) c.usageDie("i2cdump");
    const bus = parseBus("i2cdump", pos.items[0]);
    _ = parseAddr("i2cdump", pos.items[1]);
    openBus("i2cdump", bus);
}

pub fn i2cget_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("i2cget");
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    for (args[1..]) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        pos.append(a, arg) catch {};
    }
    if (pos.items.len < 2) c.usageDie("i2cget");
    const bus = parseBus("i2cget", pos.items[0]);
    _ = parseAddr("i2cget", pos.items[1]);
    openBus("i2cget", bus);
}

pub fn i2cset_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("i2cset");
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    var skip_next = false;
    for (args[1..]) |arg| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-m")) {
            skip_next = true;
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') continue;
        pos.append(a, arg) catch {};
    }
    if (pos.items.len < 3) c.usageDie("i2cset");
    const bus = parseBus("i2cset", pos.items[0]);
    _ = parseAddr("i2cset", pos.items[1]);
    openBus("i2cset", bus);
}

pub fn i2ctransfer_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("i2ctransfer");
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    for (args[1..]) |arg| {
        if (arg.len > 1 and arg[0] == '-') continue;
        pos.append(a, arg) catch {};
    }
    if (pos.items.len < 2) c.usageDie("i2ctransfer");
    const bus = parseBus("i2ctransfer", pos.items[0]);
    openBus("i2ctransfer", bus);
}
