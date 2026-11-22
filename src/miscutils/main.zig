//! miscutils applet implementations (renice, ionice, crontab plus the
//! Task 16a safe-miscutils wave).

const std = @import("std");
const linux = std.os.linux;
const proc = @import("libbb_zig").process;
const env = @import("libbb_zig").env;

pub const init = struct {
    pub fn init() void {}
};

fn out(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}

fn errOut(bytes: []const u8) void {
    _ = linux.write(2, bytes.ptr, bytes.len);
}

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const a = std.heap.page_allocator;
    const result = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| result[i] = std.mem.span(argv[i]);
    return result;
}

fn zstr(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --------------------------------------------------------------- priorities

fn parsePriority(s: []const u8) !i32 {
    const v = std.fmt.parseInt(i32, s, 10) catch return error.InvalidPriority;
    if (v < -20 or v > 19) return error.InvalidPriority;
    return v;
}

pub fn parseRenicePriority(s: []const u8) !i32 {
    return parsePriority(s);
}

fn setPriority(pid: i32, prio: i32) bool {
    const rc = linux.syscall3(.setpriority, 0, @bitCast(@as(i64, pid)), @bitCast(@as(i64, prio)));
    return linux.errno(rc) == .SUCCESS;
}

// ------------------------------------------------------------------- ionice

pub const Ioprio = struct { class: u16, data: u16 };

pub fn parseIonice(s: []const u8) !Ioprio {
    if (eq(s, "none")) return .{ .class = 0, .data = 0 };
    if (eq(s, "idle")) return .{ .class = 3, .data = 0 };

    var class: u16 = undefined;
    var rest: []const u8 = "";
    if (eq(s, "rt")) {
        class = 1;
    } else if (std.mem.startsWith(u8, s, "rt:")) {
        class = 1;
        rest = s[3..];
    } else if (eq(s, "be")) {
        class = 2;
    } else if (std.mem.startsWith(u8, s, "be:")) {
        class = 2;
        rest = s[3..];
    } else if (std.mem.indexOfScalar(u8, s, ':') != null) {
        const colon = std.mem.indexOfScalar(u8, s, ':').?;
        class = std.fmt.parseInt(u16, s[0..colon], 10) catch return error.InvalidPriority;
        rest = s[colon + 1 ..];
    } else {
        // `ionice -c 3` passes the class as a bare number.
        class = std.fmt.parseInt(u16, s, 10) catch return error.InvalidPriority;
        rest = "";
    }
    if (class > 3) return error.InvalidPriority;

    var data: u16 = 0;
    if (rest.len > 0) {
        data = std.fmt.parseInt(u16, rest, 10) catch return error.InvalidPriority;
        if (data > 7) return error.InvalidPriority;
    }
    if (class == 3 and data != 0) return error.InvalidPriority;
    return .{ .class = class, .data = data };
}

pub const IoniceInvocation = struct { prio: Ioprio, pid: i32, command_start: usize };

pub fn parseIoniceArgs(args: []const []const u8) !IoniceInvocation {
    var prio = Ioprio{ .class = 2, .data = 4 };
    var pid: i32 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-c") and i + 1 < args.len) {
            i += 1;
            prio = parseIonice(args[i]) catch return error.InvalidPriority;
        } else if (eq(arg, "-n") and i + 1 < args.len) {
            i += 1;
            prio.data = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPriority;
            if (prio.data > 7) return error.InvalidPriority;
        } else if (eq(arg, "-p") and i + 1 < args.len) {
            i += 1;
            pid = std.fmt.parseInt(i32, args[i], 10) catch return error.InvalidPriority;
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.InvalidPriority;
        } else {
            // A positional may be a class:data string; anything else is the
            // start of the command to run.
            if (parseIonice(arg)) |parsed| {
                prio = parsed;
            } else |_| {
                return .{ .prio = prio, .pid = pid, .command_start = i };
            }
        }
    }
    if (prio.class == 3) prio.data = 0;
    return .{ .prio = prio, .pid = pid, .command_start = args.len };
}

pub fn ioprioValue(p: Ioprio) u16 {
    return (@as(u16, p.class) << 13) | (p.data & 0x1fff);
}

pub fn resolveCommand(a: std.mem.Allocator, name: []const u8, path_var: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return try a.dupe(u8, name);
    var dirs = std.mem.splitScalar(u8, path_var, ':');
    while (dirs.next()) |dir| {
        const candidate = if (dir.len == 0)
            try a.dupe(u8, name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
        const z = try zstr(a, candidate);
        const found = linux.errno(linux.access(z.ptr, linux.X_OK)) == .SUCCESS;
        a.free(z);
        if (found) return candidate;
        a.free(candidate);
    }
    return null;
}

pub fn exitStatus(status: i32) u8 {
    if ((status & 0x7f) != 0) return @intCast(128 + (status & 0x7f));
    return @intCast((status >> 8) & 0xff);
}

fn setIoprio(pid: i32, value: u16) bool {
    // IOPRIO_WHO_PROCESS == 1
    const rc = linux.syscall3(.ioprio_set, 1, @bitCast(@as(i64, pid)), value);
    return linux.errno(rc) == .SUCCESS;
}

// ------------------------------------------------------------------ crontab

pub const CronEntry = struct {
    minute: []const u8,
    hour: []const u8,
    dom: []const u8,
    month: []const u8,
    dow: []const u8,
    command: []const u8,
};

const month_names = [_][]const u8{ "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" };
const day_names = [_][]const u8{ "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" };

fn cronValue(token: []const u8, max: u8, names: []const []const u8) ?u8 {
    if (std.fmt.parseInt(u8, token, 10)) |v| {
        return if (v <= max) v else null;
    } else |_| {}
    for (names, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(token, name)) return @intCast(i + 1);
    }
    return null;
}

fn validCronField(field: []const u8, max: u8, names: []const []const u8) bool {
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        var base = part;
        if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
            const step = std.fmt.parseInt(u8, part[slash + 1 ..], 10) catch return false;
            if (step == 0 or step > max) return false;
            base = part[0..slash];
        }
        if (eq(base, "*")) continue;
        if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
            const lo = cronValue(base[0..dash], max, names) orelse return false;
            const hi = cronValue(base[dash + 1 ..], max, names) orelse return false;
            if (lo > hi) return false;
            continue;
        }
        if (cronValue(base, max, names) == null) return false;
    }
    return true;
}

pub fn parseCrontabLine(line: []const u8) ?CronEntry {
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (t.len == 0 or t[0] == '#') return null;

    var fields: [5][]const u8 = undefined;
    var idx: usize = 0;
    var count: usize = 0;
    while (idx < t.len and count < 5) {
        while (idx < t.len and (t[idx] == ' ' or t[idx] == '\t')) idx += 1;
        const start = idx;
        while (idx < t.len and t[idx] != ' ' and t[idx] != '\t') idx += 1;
        if (start == idx) return null;
        fields[count] = t[start..idx];
        count += 1;
    }
    if (count < 5) return null;
    if (!validCronField(fields[0], 59, &.{}) or !validCronField(fields[1], 23, &.{}) or
        !validCronField(fields[2], 31, &.{}) or !validCronField(fields[3], 12, &month_names) or
        !validCronField(fields[4], 7, &day_names)) return null;

    while (idx < t.len and (t[idx] == ' ' or t[idx] == '\t')) idx += 1;
    if (idx >= t.len) return null;
    return .{
        .minute = fields[0],
        .hour = fields[1],
        .dom = fields[2],
        .month = fields[3],
        .dow = fields[4],
        .command = t[idx..],
    };
}

pub fn spoolPath(a: std.mem.Allocator, which: []const u8) ![]u8 {
    const dir = if (eq(which, "crontab"))
        (env.get("CRONTAB_DIR") orelse "/var/spool/cron/crontabs")
    else
        (env.get("AT_SPOOL_DIR") orelse "/var/spool/at");
    return std.fmt.allocPrint(a, "{s}/{d}", .{ dir, linux.getuid() });
}

fn ensureDir(path: [*:0]const u8) void {
    _ = linux.mkdir(path, 0o700);
}

fn readStdin(a: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try result.appendSlice(a, buf[0..n]);
    }
    return result.toOwnedSlice(a);
}

fn readFile(a: std.mem.Allocator, path: [*:0]const u8) ?[]u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var result: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        result.appendSlice(a, buf[0..n]) catch return null;
    }
    return result.toOwnedSlice(a) catch null;
}

// ------------------------------------------------------------------- applets

pub fn renice_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    var priority: ?i32 = null;
    var failed = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-n") or eq(arg, "-p")) continue;
        if (priority == null) {
            priority = parseRenicePriority(arg) catch return 1;
            continue;
        }
        const pid = std.fmt.parseInt(i32, arg, 10) catch return 1;
        if (!setPriority(pid, priority.?)) failed = true;
    }
    if (priority == null or failed) return 1;
    return 0;
}

pub fn ionice_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const a = std.heap.page_allocator;
    const inv = parseIoniceArgs(args) catch return 1;
    const prio = inv.prio;
    const pid = inv.pid;
    const command_start = inv.command_start;

    if (command_start < args.len) {
        const child = proc.fork() catch return 1;
        if (child == 0) {
            if (!setIoprio(0, ioprioValue(prio))) std.process.exit(1);
            const command = args[command_start];
            const path_var = env.get("PATH") orelse "/bin:/usr/bin";
            const resolved = resolveCommand(a, command, path_var) catch std.process.exit(1) orelse std.process.exit(127);
            const argv_z = a.allocSentinel(?[*:0]const u8, args.len - command_start, null) catch std.process.exit(1);
            argv_z[0] = zstr(a, resolved) catch std.process.exit(1);
            for (args[command_start + 1 ..], 0..) |word, k| {
                argv_z[k + 1] = zstr(a, word) catch std.process.exit(1);
            }
            const envp_z = a.allocSentinel(?[*:0]const u8, 0, null) catch std.process.exit(1);
            proc.execve(argv_z[0].?, argv_z, envp_z) catch std.process.exit(127);
            std.process.exit(127);
        }
        var status: i32 = 0;
        _ = proc.waitpid(child, &status, 0) catch return 1;
        return exitStatus(status);
    }

    return if (setIoprio(pid, ioprioValue(prio))) 0 else 1;
}

pub fn crontab_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    const a = std.heap.page_allocator;
    const path = spoolPath(a, "crontab") catch return 1;
    defer a.free(path);
    const path_z = zstr(a, path) catch return 1;

    var action: enum { list, remove, install } = .install;
    var source: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-l")) {
            action = .list;
        } else if (eq(arg, "-r")) {
            action = .remove;
        } else if (eq(arg, "-e")) {
            errOut("crontab: -e requires an external editor\n");
            return 1;
        } else if (eq(arg, "-")) {
            action = .install;
            source = "-";
        } else if (arg.len > 0 and arg[0] == '-') {
            return 1;
        } else {
            action = .install;
            source = arg;
        }
    }

    switch (action) {
        .list => {
            const content = readFile(a, path_z) orelse {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "no crontab for uid {d}\n", .{linux.getuid()}) catch "";
                out(msg);
                return 1;
            };
            defer a.free(content);
            out(content);
            return 0;
        },
        .remove => {
            const rc = linux.unlink(path_z);
            if (linux.errno(rc) != .SUCCESS) return 1;
            return 0;
        },
        .install => {
            var content: []u8 = undefined;
            if (eq(source, "-") or source.len == 0) {
                content = readStdin(a) catch return 1;
            } else {
                const src_z = zstr(a, source) catch return 1;
                content = readFile(a, src_z) orelse return 1;
            }
            defer a.free(content);

            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                if (parseCrontabLine(line) == null) {
                    errOut("crontab: invalid time fields\n");
                    return 1;
                }
            }

            // The parent directory may not exist in a test environment.
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
                const dir = zstr(a, path[0..slash]) catch return 1;
                ensureDir(dir);
            }
            const fd_rc = linux.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
            if (linux.errno(fd_rc) != .SUCCESS) return 1;
            const fd: linux.fd_t = @intCast(fd_rc);
            defer _ = linux.close(fd);
            var off: usize = 0;
            while (off < content.len) {
                const n = linux.write(fd, content[off..].ptr, content.len - off);
                if (linux.errno(n) != .SUCCESS or n == 0) return 1;
                off += n;
            }
            return 0;
        },
    }
}

// ---------------------------------------------------------------- Task 16a
// Re-exports of the safe miscutils implemented in sibling files. The registry
// (src/applets.zig) resolves each applet name through mainFor().

pub const common = @import("common.zig");
pub const ascii_main = @import("ascii.zig").main;
pub const ttysize_main = @import("ttysize.zig").main;
pub const tree_main = @import("tree.zig").main;
pub const strings_main = @import("strings.zig").main;
pub const ts_main = @import("ts.zig").main;
pub const time_main = @import("time.zig").main;
pub const runlevel_main = @import("runlevel.zig").main;
pub const mim_main = @import("mim.zig").main;
pub const dc_main = @import("dc.zig").main;
pub const bc_main = @import("bc.zig").main;
pub const bbconfig_main = @import("bbconfig.zig").main;
pub const i2cdetect_main = @import("i2c_tools.zig").i2cdetect_main;
pub const i2cdump_main = @import("i2c_tools.zig").i2cdump_main;
pub const i2cget_main = @import("i2c_tools.zig").i2cget_main;
pub const i2cset_main = @import("i2c_tools.zig").i2cset_main;
pub const i2ctransfer_main = @import("i2c_tools.zig").i2ctransfer_main;
pub const devmem_main = @import("device.zig").devmem_main;
pub const lsscsi_main = @import("device.zig").lsscsi_main;
pub const partprobe_main = @import("device.zig").partprobe_main;
pub const readahead_main = @import("device.zig").readahead_main;
pub const volname_main = @import("device.zig").volname_main;
pub const watchdog_main = @import("device.zig").watchdog_main;
pub const beep_main = @import("device.zig").beep_main;
pub const mt_main = @import("device.zig").mt_main;
pub const hdparm_main = @import("device.zig").hdparm_main;
pub const setserial_main = @import("device.zig").setserial_main;
pub const fbsplash_main = @import("device.zig").fbsplash_main;
pub const conspy_main = @import("device.zig").conspy_main;
pub const getfattr_main = @import("batch3.zig").getfattr_main;
pub const setfattr_main = @import("batch3.zig").setfattr_main;
pub const makedevs_main = @import("batch3.zig").makedevs_main;
pub const seedrng_main = @import("batch3.zig").seedrng_main;
pub const crond_main = @import("batch3.zig").crond_main;
pub const chat_main = @import("batch3.zig").chat_main;
pub const less_main = @import("batch3.zig").less_main;
pub const man_main = @import("batch3.zig").man_main;
pub const microcom_main = @import("batch3.zig").microcom_main;
pub const hexedit_main = @import("batch3.zig").hexedit_main;
pub const rx_main = @import("batch3.zig").rx_main;
pub const flash_eraseall_main = @import("batch4.zig").flash_eraseall_main;
pub const flash_lock_main = @import("batch4.zig").flash_lock_main;
pub const flash_unlock_main = @import("batch4.zig").flash_unlock_main;
pub const flashcp_main = @import("batch4.zig").flashcp_main;
pub const inotifyd_main = @import("batch4.zig").inotifyd_main;
pub const rfkill_main = @import("batch4.zig").rfkill_main;

// Task 16b — privileged/device-bound miscutils wave
pub const priv = @import("privileged.zig");
pub const adjtimex_main = priv.adjtimex_main;
pub const devfsd_main = priv.devfsd_main;
pub const nanddump_main = priv.nanddump_main;
pub const nandwrite_main = priv.nandwrite_main;
pub const raidautorun_main = priv.raidautorun_main;
pub const ubiattach_main = priv.ubiattach_main;
pub const ubidetach_main = priv.ubidetach_main;
pub const ubimkvol_main = priv.ubimkvol_main;
pub const ubirename_main = priv.ubirename_main;
pub const ubirmvol_main = priv.ubirmvol_main;
pub const ubirsvol_main = priv.ubirsvol_main;
pub const ubiupdatevol_main = priv.ubiupdatevol_main;
