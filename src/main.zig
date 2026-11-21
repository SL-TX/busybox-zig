//! BusyBox main entry point.
//! Dispatches to the appropriate applet based on argv[0] (or argv[1] when
//! invoked as `busybox <applet>`), and implements the busybox meta-CLI:
//! --help, --list, --list-full, --show, --install and --version.

const std = @import("std");
const linux = std.os.linux;
const applets = @import("applets.zig");
const libbb_zig = @import("libbb_zig");
const cfg = @import("config");

/// Reference banner from libbb/messages.c: "BusyBox v" BB_VER BB_EXTRA_VERSION.
/// The parenthesized suffix is a build-time timestamp; this build uses the
/// reference commit's timestamp (6412da2, 2026-11-17 18:23:08 +0100).
pub const banner = "BusyBox v1.39.0 (2026-11-17 18:23:08 +0100)";

const mim_script =
    \\#!/bin/sh
    \\MIMFILE="Mimfile"
    \\if [ $# -ge 2 ] && [ "$1" = "-f" ]
    \\then
    \\    MIMFILE="$2"
    \\    shift 2
    \\fi
    \\exec <"$MIMFILE" || exit 1
    \\{
    \\    INCASE=false
    \\    while read -r REPLY
    \\    do
    \\        case $REPLY in
    \\        *:)
    \\            if ! $INCASE
    \\            then
    \\                printf '[ $# -eq 0 ] && set -- "%s"
    \\TARGET="$1"
    \\shift
    \\case "$TARGET" in
    \\' "${REPLY%:}"
    \\            else
    \\                printf ';;\n'
    \\            fi
    \\            printf '%s)\n' "${REPLY%:}"
    \\            INCASE=true
    \\            ;;
    \\        "") ;;
    \\        *) printf '%s\n' "${REPLY##[     ]}";;
    \\        esac
    \\    done
    \\    $INCASE && printf ';;\n'
    \\    printf '*)
    \\echo "Unknown command $TARGET"
    \\exit 1
    \\;;
    \\esac
    \\'
    \\} | sh -s "$@"
;

const nologin_script =
    \\cat /etc/nologin.txt 2>/dev/null || echo This account is not available
    \\sleep 5
    \\exit 1
;

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

pub const FdWriter = struct {
    fd: linux.fd_t,

    pub fn writeAll(self: FdWriter, bytes: []const u8) void {
        _ = linux.write(self.fd, bytes.ptr, bytes.len);
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn printNoArgs(out: anytype) void {
    out.writeAll(banner ++ " multi-call binary.\n");
    out.writeAll(
        "BusyBox is copyrighted by many authors between 1998-2015.\n" ++
            "Licensed under GPLv2. See source distribution for detailed\n" ++
            "copyright notices.\n" ++
            "\n" ++
            "Usage: busybox [function [arguments]...]\n" ++
            "   or: busybox --list",
    );
    if (cfg.CONFIG_FEATURE_INSTALLER) out.writeAll("-full");
    out.writeAll("\n");
    if (cfg.CONFIG_FEATURE_SHOW_SCRIPT) out.writeAll("   or: busybox --show SCRIPT\n");
    if (cfg.CONFIG_FEATURE_INSTALLER) out.writeAll("   or: busybox --install [-s] [DIR]\n");
    out.writeAll(
        "   or: function [arguments]...\n" ++
            "\n",
    );
    if (!cfg.CONFIG_FEATURE_SH_STANDALONE) {
        out.writeAll(
            "\tBusyBox is a multi-call binary that combines many common Unix\n" ++
                "\tutilities into a single executable.  Most people will create a\n" ++
                "\tlink to busybox for each function they wish to use and BusyBox\n" ++
                "\twill act like whatever it was invoked as.\n",
        );
    } else {
        out.writeAll(
            "\tBusyBox is a multi-call binary that combines many common Unix\n" ++
                "\tutilities into a single executable.  The shell in this build\n" ++
                "\tis configured to run built-in utilities without $PATH search.\n" ++
                "\tYou don't need to install a link to busybox for each utility.\n" ++
                "\tTo run external program, use full path (/sbin/ip instead of ip).\n",
        );
    }
    out.writeAll("\nCurrently defined functions:\n");

    const names = applets.appletNames(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(names);
    for (names, 0..) |name, i| {
        if (i != 0) out.writeAll(", ");
        out.writeAll(name);
    }
    out.writeAll("\n");
}

fn writeList(allocator: std.mem.Allocator, out: anytype, full: bool) void {
    const names = if (full)
        applets.appletNamesFull(allocator) catch return
    else
        applets.appletNames(allocator) catch return;
    defer allocator.free(names);
    for (names) |name| {
        out.writeAll(name);
        out.writeAll("\n");
    }
}

fn printAppletHelp(name: []const u8, out: anytype, err: anytype) u8 {
    if (applets.findAppletByName(name) != null) {
        // Task 4 replaces this with the generated per-applet usage text.
        out.writeAll(banner ++ " multi-call binary.\n\nUsage: ");
        out.writeAll(name);
        out.writeAll("\n");
        return 0;
    }
    err.writeAll(name);
    err.writeAll(": applet not found\n");
    return 127;
}

fn showScript(argv: []const []const u8, out: anytype, err: anytype) u8 {
    if (argv.len < 3) {
        err.writeAll("--show requires an argument\n");
        return 1;
    }
    const name = argv[2];
    const applet = applets.findAppletByName(name) orelse {
        err.writeAll("script '");
        err.writeAll(name);
        err.writeAll("' not found\n");
        return 1;
    };
    if (!applet.scripted) {
        err.writeAll("script '");
        err.writeAll(name);
        err.writeAll("' not found\n");
        return 1;
    }
    if (eq(name, "mim")) {
        out.writeAll(mim_script);
    } else if (eq(name, "nologin")) {
        out.writeAll(nologin_script);
    } else {
        err.writeAll("script '");
        err.writeAll(name);
        err.writeAll("' not found\n");
        return 1;
    }
    return 0;
}

fn installDir(location: []const u8) []const u8 {
    if (eq(location, "root")) return "/";
    if (eq(location, "bin")) return "/bin/";
    if (eq(location, "sbin")) return "/sbin/";
    if (eq(location, "usr/bin")) return "/usr/bin/";
    return "/usr/sbin/";
}

fn reportLinkError(path: []const u8, errno: linux.E, err: anytype) void {
    if (errno == .EXIST) return;
    err.writeAll("busybox: cannot create link ");
    err.writeAll(path);
    err.writeAll("\n");
}

/// `busybox --install [-s] [DIR]`: hardlinks by default, symlinks with -s.
fn installApplets(allocator: std.mem.Allocator, argv: []const []const u8, err: anytype) u8 {
    var use_symlink = false;
    var i: usize = 2;
    if (i < argv.len and eq(argv[i], "-s")) {
        use_symlink = true;
        i += 1;
    }
    const custom_dir: ?[]const u8 = if (i < argv.len) argv[i] else null;

    // Prefer the real executable path, as the reference does.
    var target_buf: [4096]u8 = undefined;
    var target: []const u8 = argv[0];
    const n = linux.readlink("/proc/self/exe", &target_buf, target_buf.len);
    if (linux.errno(n) == .SUCCESS and n > 0 and n < target_buf.len) {
        target = target_buf[0..n];
    } else if (target.len == 0 or target[0] != '/') {
        err.writeAll("'");
        err.writeAll(target);
        err.writeAll("' is not an absolute path\n");
        return 1;
    }
    const target_z = allocator.dupeSentinel(u8, target, 0) catch return 1;
    defer allocator.free(target_z);

    const names = applets.appletNames(allocator) catch return 1;
    defer allocator.free(names);
    for (names) |name| {
        const applet = applets.findAppletByName(name).?;
        const dir = custom_dir orelse installDir(applet.location);
        // Default directories end in '/'; a custom DIR from the user may not.
        const sep: []const u8 = if (std.mem.endsWith(u8, dir, "/")) "" else "/";
        const path = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ dir, sep, name }) catch return 1;
        defer allocator.free(path);
        const path_z = allocator.dupeSentinel(u8, path, 0) catch return 1;
        defer allocator.free(path_z);
        const rc = if (use_symlink)
            linux.symlink(target_z.ptr, path_z.ptr)
        else
            linux.link(target_z.ptr, path_z.ptr);
        if (linux.errno(rc) != .SUCCESS) reportLinkError(path_z, linux.errno(rc), err);
    }
    return 0;
}

/// POSIX: "test --help" must be a normal argument, not the meta help request.
/// The same applies to true, false, echo, [ and [[.
fn isDashDashHelpSpecial(name: []const u8) bool {
    return eq(name, "test") or eq(name, "true") or eq(name, "false") or
        eq(name, "echo") or eq(name, "[") or eq(name, "[[");
}

/// Feature-gated SUID policy from the reference's check_suid().
fn checkSuid(applet: applets.Applet, err: anytype) u8 {
    if (!cfg.CONFIG_FEATURE_SUID) return 0;
    const ruid = linux.getuid();
    if (ruid == 0) return 0;
    const euid = linux.geteuid();
    switch (applet.suid) {
        .require => {
            if (euid != 0) {
                err.writeAll("must be suid to work properly\n");
                return 1;
            }
        },
        .drop => {
            _ = linux.setgid(linux.getgid());
            _ = linux.setuid(ruid);
        },
        .maybe => {},
    }
    return 0;
}

/// Dispatch the busybox meta-CLI or a single applet. `argv[0]` is the invoked
/// name ("busybox" for multicall). Writes go to the supplied writers so the
/// meta-CLI can be exercised from unit tests without touching real fds.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, out: anytype, err: anytype) u8 {
    if (argv.len == 0) {
        printNoArgs(out);
        return 0;
    }

    const argv0 = argv[0];
    const base = std.fs.path.basename(argv0);
    const multicall = eq(base, "busybox");

    var name_index: usize = 0;
    if (multicall) {
        if (argv.len < 2) {
            printNoArgs(out);
            return 0;
        }
        name_index = 1;
        const opt = argv[1];
        if (eq(opt, "--version") and argv.len == 2) {
            out.writeAll(banner ++ "\n");
            return 0;
        } else if (eq(opt, "--list")) {
            writeList(allocator, out, false);
            return 0;
        } else if (cfg.CONFIG_FEATURE_INSTALLER and eq(opt, "--list-full")) {
            writeList(allocator, out, true);
            return 0;
        } else if (cfg.CONFIG_FEATURE_SHOW_SCRIPT and eq(opt, "--show")) {
            return showScript(argv, out, err);
        } else if (cfg.CONFIG_FEATURE_INSTALLER and eq(opt, "--install")) {
            return installApplets(allocator, argv, err);
        } else if (eq(opt, "--help")) {
            if (argv.len < 3) {
                printNoArgs(out);
                return 0;
            }
            return printAppletHelp(argv[2], out, err);
        }
    }

    const invoked = argv[name_index];
    const name = std.fs.path.basename(invoked);
    const entry = applets.findAppletByName(name) orelse {
        err.writeAll(name);
        err.writeAll(": applet not found\n");
        return 127;
    };

    // show_usage_if_dash_dash_help(): intercepted before the applet sees it,
    // except for the POSIX special cases listed above.
    if (name_index + 1 < argv.len and eq(argv[name_index + 1], "--help") and !isDashDashHelpSpecial(name)) {
        return printAppletHelp(name, out, err);
    }

    const suid_code = checkSuid(entry, err);
    if (suid_code != 0) return suid_code;

    // The applet sees its own name as argv[0], followed by its arguments.
    var argv_c: [256][*:0]const u8 = undefined;
    var owned: [256][:0]u8 = undefined;
    var argc: c_int = 0;
    var i = name_index;
    while (i < argv.len and argc < 255) : (i += 1) {
        const z = allocator.dupeSentinel(u8, argv[i], 0) catch return 1;
        owned[@intCast(argc)] = z;
        argv_c[@intCast(argc)] = z.ptr;
        argc += 1;
    }
    defer for (owned[0..@intCast(argc)]) |z| allocator.free(z);

    const ret = entry.main(argc, &argv_c);
    // Truncate the bit pattern rather than trapping on a negative c_int.
    return @as(u8, @truncate(@as(u32, @bitCast(ret))));
}

pub fn main(init: Init) u8 {
    libbb_zig.init();
    libbb_zig.env.map = init.environ_map;

    const vec = init.minimal.args.vector;
    const args = init.arena.allocator().alloc([]const u8, vec.len) catch return 1;
    for (vec, 0..) |v, i| args[i] = std.mem.span(v);

    return run(init.gpa, args, FdWriter{ .fd = 1 }, FdWriter{ .fd = 2 });
}
