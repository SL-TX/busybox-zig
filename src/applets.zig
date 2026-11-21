//! Applet registry — rebuilt from the reference-generated manifest.
//!
//! Every entry in `applet_manifest.entries` becomes a registry record when its
//! generated `APPLET_<name>` config symbol is enabled. Applets without a real
//! Zig implementation use `stubMain`; the 43 implemented applets are mapped by
//! `mainFor`. Internal helper names (tls_aes, tcpudp, isrv, ...) never appear
//! in the manifest and therefore never appear in `--list` or `--list-full`.

const std = @import("std");
const coreutils = @import("coreutils");
const cfg = @import("config");
const config = cfg.config;
const manifest = @import("generated/applet_manifest.zig");

pub const Suid = manifest.Suid;

pub const AppletFlags = struct {
    noexec: bool = false,
    nofork: bool = false,
};

pub const Applet = struct {
    name: []const u8,
    main: *const fn (argc: c_int, argv: [*][*:0]const u8) c_int,
    /// Install location from the reference manifest ("bin", "sbin",
    /// "usr/bin", "usr/sbin" or "root"). Never has a leading slash.
    location: []const u8,
    suid: Suid,
    noexec: bool,
    nofork: bool,
    scripted: bool,
    category: []const u8,
    /// Kconfig symbol, e.g. "CONFIG_CAT".
    config: []const u8,
    /// Alias of `config`, kept for callers that call this field `flag`.
    flag: []const u8,
    default_enabled: bool,
    flags: AppletFlags,
};

pub const MainFn = *const fn (c_int, [*][*:0]const u8) c_int;

/// Unimplemented applets fail loudly instead of exiting silently.
fn stubMain(_: c_int, argv: [*][*:0]const u8) c_int {
    const name = std.mem.span(argv[0]);
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: not implemented\n", .{name}) catch "not implemented\n";
    _ = std.os.linux.write(2, msg.ptr, msg.len);
    return 1;
}

/// Map an applet name to its real main. Only the 43 implemented applets are
/// listed here; every other manifest entry resolves to `stubMain`.
fn mainFor(comptime name: []const u8) MainFn {
    // coreutils
    if (std.mem.eql(u8, name, "cat")) return coreutils.cat_main;
    if (std.mem.eql(u8, name, "ls")) return coreutils.ls_main;
    if (std.mem.eql(u8, name, "echo")) return coreutils.echo_main;
    if (std.mem.eql(u8, name, "printf")) return coreutils.printf_main;
    if (std.mem.eql(u8, name, "cp")) return coreutils.cp_main;
    if (std.mem.eql(u8, name, "mv")) return coreutils.mv_main;
    if (std.mem.eql(u8, name, "rm")) return coreutils.rm_main;
    if (std.mem.eql(u8, name, "mkdir")) return coreutils.mkdir_main;
    if (std.mem.eql(u8, name, "touch")) return coreutils.touch_main;
    if (std.mem.eql(u8, name, "head")) return coreutils.head_main;
    if (std.mem.eql(u8, name, "tail")) return coreutils.tail_main;
    if (std.mem.eql(u8, name, "sort")) return coreutils.sort_main;
    if (std.mem.eql(u8, name, "uniq")) return coreutils.uniq_main;
    if (std.mem.eql(u8, name, "wc")) return coreutils.wc_main;
    if (std.mem.eql(u8, name, "cut")) return coreutils.cut_main;
    if (std.mem.eql(u8, name, "sed")) return coreutils.sed_main;
    if (std.mem.eql(u8, name, "awk")) return coreutils.awk_main;
    if (std.mem.eql(u8, name, "true")) return coreutils.true_main;
    if (std.mem.eql(u8, name, "false")) return coreutils.false_main;
    // util-linux
    if (std.mem.eql(u8, name, "mount")) return @import("util_linux").mount_main;
    if (std.mem.eql(u8, name, "umount")) return @import("util_linux").umount_main;
    if (std.mem.eql(u8, name, "dmesg")) return @import("util_linux").dmesg_main;
    if (std.mem.eql(u8, name, "blkid")) return @import("util_linux").blkid_main;
    // networking
    if (std.mem.eql(u8, name, "ifconfig")) return @import("networking").ifconfig_main;
    if (std.mem.eql(u8, name, "ping")) return @import("networking").ping_main;
    if (std.mem.eql(u8, name, "wget")) return @import("networking").wget_main;
    if (std.mem.eql(u8, name, "nc")) return @import("networking").nc_main;
    // miscutils
    if (std.mem.eql(u8, name, "ionice")) return @import("miscutils").ionice_main;
    if (std.mem.eql(u8, name, "renice")) return @import("miscutils").renice_main;
    if (std.mem.eql(u8, name, "crontab")) return @import("miscutils").crontab_main;
    // procps
    if (std.mem.eql(u8, name, "ps")) return @import("procps").ps_main;
    if (std.mem.eql(u8, name, "top")) return @import("procps").top_main;
    if (std.mem.eql(u8, name, "kill")) return @import("procps").kill_main;
    if (std.mem.eql(u8, name, "killall")) return @import("procps").killall_main;
    if (std.mem.eql(u8, name, "free")) return @import("procps").free_main;
    // shell
    if (std.mem.eql(u8, name, "ash")) return @import("shell").ash_main;
    if (std.mem.eql(u8, name, "hush")) return @import("shell").hush_main;
    // loginutils
    if (std.mem.eql(u8, name, "login")) return @import("loginutils").login_main;
    if (std.mem.eql(u8, name, "passwd")) return @import("loginutils").passwd_main;
    if (std.mem.eql(u8, name, "su")) return @import("loginutils").su_main;
    if (std.mem.eql(u8, name, "cryptpw")) return @import("loginutils").cryptpw_main;
    // remaining
    if (std.mem.eql(u8, name, "ascii")) return @import("remaining").ascii_main;
    if (std.mem.eql(u8, name, "dc")) return @import("remaining").dc_main;
    return stubMain;
}

var applets_map: ?std.StringHashMap(Applet) = null;

pub fn initApplets(allocator: std.mem.Allocator) std.StringHashMap(Applet) {
    @setEvalBranchQuota(100000);
    if (applets_map) |*map| return map.*;
    applets_map = std.StringHashMap(Applet).init(allocator);
    const map = &applets_map.?;

    inline for (manifest.entries) |entry| {
        // Sanitize exactly like scripts/parity/gen_config.py's applet_ident():
        // "[" -> "_", "dpkg-deb" -> "dpkg_deb", leading digits get "_".
        const alias = comptime blk: {
            var buf: [80]u8 = undefined;
            @memcpy(buf[0..7], "APPLET_");
            var n: usize = 7;
            for (entry.name) |c| {
                buf[n] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
                n += 1;
            }
            if (n == 7 or std.ascii.isDigit(buf[7])) {
                var i: usize = n + 1;
                while (i > 8) : (i -= 1) buf[i - 1] = buf[i - 2];
                buf[7] = '_';
                n += 1;
            }
            break :blk buf[0..n];
        };
        const enabled = @field(config, alias);
        // "unit" only exists in unit-test builds. The reference gates the
        // busybox applet with IF_BUSYBOX(IF_FEATURE_SH_STANDALONE(
        // IF_FEATURE_TAB_COMPLETION(...))), so with the committed defconfig
        // (FEATURE_SH_STANDALONE=n) it is absent from the registry and from
        // --list / --list-full (411 applets).
        const register = comptime blk2: {
            if (std.mem.eql(u8, entry.name, "unit"))
                break :blk2 cfg.CONFIG_UNIT_TEST and enabled;
            if (std.mem.eql(u8, entry.name, "busybox"))
                break :blk2 cfg.CONFIG_FEATURE_SH_STANDALONE and
                    cfg.CONFIG_FEATURE_TAB_COMPLETION and enabled;
            break :blk2 enabled;
        };
        if (!register) continue;

        map.put(entry.name, .{
            .name = entry.name,
            .main = mainFor(entry.name),
            .location = entry.location,
            .suid = entry.suid,
            .noexec = entry.noexec,
            .nofork = entry.nofork,
            .scripted = entry.scripted,
            .category = entry.category,
            .config = entry.config,
            .flag = entry.config,
            .default_enabled = entry.default_enabled,
            .flags = .{ .noexec = entry.noexec, .nofork = entry.nofork },
        }) catch unreachable;
    }

    return map.*;
}

pub fn deinitApplets() void {
    applets_map = null;
}

fn ensureInit() *std.StringHashMap(Applet) {
    if (applets_map == null) _ = initApplets(std.heap.page_allocator);
    return &applets_map.?;
}

pub fn countApplets() usize {
    return ensureInit().count();
}

pub fn findAppletByName(name: []const u8) ?Applet {
    return ensureInit().get(name);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn appletNames(allocator: std.mem.Allocator) ![][]const u8 {
    const map = ensureInit();
    const names = try allocator.alloc([]const u8, map.count());
    var it = map.keyIterator();
    var i: usize = 0;
    while (it.next()) |key| : (i += 1) names[i] = key.*;
    std.mem.sort([]const u8, names, {}, lessThan);
    return names;
}

/// Same order as `appletNames`, but each entry is prefixed with the applet's
/// reference install location and has no leading slash ("usr/bin/[", "bin/cat").
/// A "root" location produces the bare applet name, matching install_dir[0]+1
/// in the reference implementation.
/// Storage for the prefixed names. The registry is already a process-global,
/// so reusing a fixed table here keeps `appletNamesFull`'s ownership simple:
/// callers free only the returned slice array.
var full_names_storage: [manifest.entries.len][128]u8 = undefined;

pub fn appletNamesFull(allocator: std.mem.Allocator) ![][]const u8 {
    const names = try appletNames(allocator);
    defer allocator.free(names);
    const full = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |name, i| {
        const applet = findAppletByName(name).?;
        full[i] = if (std.mem.eql(u8, applet.location, "root"))
            name
        else
            std.fmt.bufPrint(&full_names_storage[i], "{s}/{s}", .{ applet.location, name }) catch unreachable;
    }
    return full;
}
