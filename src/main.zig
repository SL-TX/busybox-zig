//! BusyBox main entry point.
//! Dispatches to the appropriate applet based on argv[0] (or argv[1] when
//! invoked as `busybox <applet>`).

const std = @import("std");
const applets = @import("applets.zig");
const libbb_zig = @import("libbb_zig");

const version = "1.36.1";

pub const Args = struct {
    vector: []const [*:0]const u8,
};

pub const Init = struct {
    minimal: Minimal,
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    preopens: std.process.Preopens,

    pub const Minimal = struct {
        environ: std.process.Environ,
        args: Args,
    };
};

fn writeMessage(msg: []const u8) void {
    _ = std.os.linux.write(1, msg.ptr, msg.len);
}

fn printVersion() void {
    writeMessage("BusyBox v" ++ version ++ " (multi-call binary)\n");
}

fn printAppletList() void {
    const names = applets.appletNames(std.heap.page_allocator) catch {
        writeMessage("unable to list applets\n");
        return;
    };
    defer std.heap.page_allocator.free(names);
    writeMessage("BusyBox applets:\n");
    for (names, 0..) |name, i| {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d: >4}. {s}\n", .{ i + 1, name }) catch continue;
        writeMessage(line);
    }
}

pub fn main(init: Init) u8 {
    libbb_zig.init();
    libbb_zig.env.map = init.environ_map;

    const vec = init.minimal.args.vector;
    const argv0 = if (vec.len > 0) std.mem.span(vec[0]) else "busybox";
    const base = std.fs.path.basename(argv0);
    const multicall = std.mem.eql(u8, base, "busybox");

    var name_index: usize = 0;
    if (multicall) {
        if (vec.len < 2) {
            printVersion();
            printAppletList();
            return 0;
        }
        name_index = 1;
    }

    const applet_name = std.mem.span(vec[name_index]);
    if (std.mem.eql(u8, applet_name, "--help") or
        std.mem.eql(u8, applet_name, "--list") or
        std.mem.eql(u8, applet_name, "-h"))
    {
        printAppletList();
        return 0;
    }
    if (std.mem.eql(u8, applet_name, "--version")) {
        printVersion();
        return 0;
    }

    const entry = applets.findAppletByName(applet_name) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "BusyBox: '{s}' is not an applet\n", .{applet_name}) catch "BusyBox: unknown applet\n";
        writeMessage(msg);
        return 1;
    };

    // Applets see argv[0] as their own name, followed by their arguments.
    var argv_c: [256][*:0]const u8 = undefined;
    argv_c[0] = vec[name_index];
    var argc: c_int = 1;
    var i = name_index + 1;
    while (i < vec.len and argc < 255) : (i += 1) {
        argv_c[@intCast(argc)] = vec[i];
        argc += 1;
    }

    const ret = entry.main(argc, &argv_c);
    return @as(u8, @intCast(ret));
}
