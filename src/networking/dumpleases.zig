//! dumpleases — display leases granted by udhcpd (udhcp/dumpleases.c).
//!
//! The binary lease file format is: an 8-byte big-endian "written at" stamp
//! followed by fixed 36-byte records {expires(BE32), nip(net), mac[6],
//! hostname[20], pad[2]}. All column formatting matches the reference exactly.

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const linux = std.os.linux;

const longopts = [_]n.LongOpt{
    .{ .name = "absolute", .val = 'a' },
    .{ .name = "remaining", .val = 'r' },
    .{ .name = "file", .has_arg = .required, .val = 'f' },
    .{ .name = "decimal", .val = 'd' },
};

fn be64(bytes: []const u8) i64 {
    var v: u64 = 0;
    for (bytes) |b| v = (v << 8) | b;
    return @bitCast(v);
}

fn be32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | bytes[3];
}

fn wallClockSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn isLeap(y: i64) bool { return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0); }
fn daysBeforeYear(y: i64) i64 {
    const yy = y - 1;
    return 365 * yy + @divFloor(yy, 4) - @divFloor(yy, 100) + @divFloor(yy, 400);
}
fn daysBeforeYearSinceEpoch(y: i64) i64 {
    return daysBeforeYear(y) - 719162; // daysBeforeYear(1970) == 719162
}
fn epochYear(days: i64) i64 {
    var y: i64 = 1970;
    while (daysBeforeYearSinceEpoch(y + 1) <= days) : (y += 1) {}
    return y;
}
fn monthForDay(y: i64, doy: i64) usize {
    const lens = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var d = doy;
    for (lens, 0..) |len, i| {
        const l = if (i == 1 and isLeap(y)) len + 1 else len;
        if (d < l) return i;
        d -= l;
    }
    return 11;
}
fn daysBeforeMonth(y: i64, m: usize) i64 {
    const lens = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var d: i64 = 0;
    for (lens[0..m], 0..) |len, i| d += if (i == 1 and isLeap(y)) len + 1 else len;
    return d;
}

/// BusyBox ctime(): "Wdy Mon DD HH:MM:SS YYYY\n" (TZ=UTC in the harness).
fn ctime(t: i64, buf: []u8) []const u8 {
    const secs_per_day: i64 = 86400;
    var days = @divFloor(t, secs_per_day);
    var sod = t - days * secs_per_day;
    if (sod < 0) { sod += secs_per_day; days -= 1; }
    const hh = @divTrunc(sod, 3600);
    const mm = @divTrunc(@mod(sod, 3600), 60);
    const ss = @mod(sod, 60);
    const wday: usize = @intCast(@mod(days + 4, 7));
    const year = epochYear(days);
    const doy = days - daysBeforeYearSinceEpoch(year);
    const mon = monthForDay(year, doy);
    const dom = doy - daysBeforeMonth(year, mon) + 1;
    const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mons = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d}\n", .{
        wdays[wday], mons[mon], @as(u64, @intCast(dom)), @as(u64, @intCast(hh)),
        @as(u64, @intCast(mm)), @as(u64, @intCast(ss)), @as(u64, @intCast(year)),
    }) catch "";
}

pub fn dumpleasesMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("dumpleases", args, "^arf:d", &longopts);
    // opt_complementary "=0:a--r:r--a": at most one of -a and -r.
    if ((parsed.flags & 1) != 0 and (parsed.flags & 2) != 0) n.usageDie("dumpleases");

    const absolute = (parsed.flags & 1) != 0;
    const decimal = (parsed.flags & 8) != 0;
    const file = blk: {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-f") and i + 1 < args.len) break :blk args[i + 1];
            if (std.mem.startsWith(u8, args[i], "--file=")) break :blk args[i]["--file=".len..];
            if (std.mem.eql(u8, args[i], "--file") and i + 1 < args.len) break :blk args[i + 1];
        }
        break :blk "/var/lib/misc/udhcpd.leases";
    };

    const data = n.readWholeFile(file) catch {
        n.errorMsg(2, "can't open '{s}'", .{file}); // ENOENT
        return 1;
    };
    defer n.A.free(data);

    n.put("Mac {s:<14}IP {s:<13}Host {s:<15}Expires {s}\n", .{
        "Address", "Address", "Name", if (absolute) "at" else "in",
    });
    if (data.len < 8) return 0;

    var written_at = be64(data[0..8]);
    const curr = wallClockSeconds();
    if (curr < written_at) written_at = curr;

    var linebuf: [1024]u8 = undefined;
    var tbuf: [64]u8 = undefined;
    var off: usize = 8;
    while (off + 36 <= data.len) : (off += 36) {
        const rec = data[off .. off + 36];
        const expires = be32(rec[0..4]);
        const nip = rec[4..8];
        const mac = rec[8..14];
        const host_raw = rec[14..34];

        var macbuf: [64]u8 = undefined;
        var ml: usize = 0;
        for (mac, 0..) |b, i| {
            const piece = std.fmt.bufPrint(macbuf[ml..], "{s}{x:0>2}", .{ if (i == 0) "" else ":", b }) catch "";
            ml += piece.len;
        }
        var host: [20]u8 = undefined;
        var hl: usize = 0;
        for (host_raw) |c| {
            if (c == 0) break;
            host[hl] = c;
            hl += 1;
        }
        const ip = std.fmt.bufPrint(&ipbuf_local, "{d}.{d}.{d}.{d}", .{ nip[0], nip[1], nip[2], nip[3] }) catch "";

        const expires_abs: i64 = @as(i64, expires) + written_at;
        const tail = blk: {
            if (expires_abs <= curr) break :blk "expired\n";
            if (decimal) {
                const v = if (absolute) expires_abs else expires_abs - curr;
                break :blk std.fmt.bufPrint(linebuf[700..], "{d}\n", .{v}) catch "";
            }
            if (!absolute) {
                var rem: u64 = @intCast(expires_abs - curr);
                const d = rem / 86400; rem %= 86400;
                const h = rem / 3600; rem %= 3600;
                const m = rem / 60; rem %= 60;
                if (d != 0) {
                    break :blk std.fmt.bufPrint(linebuf[700..], "{d} days {d:0>2}:{d:0>2}:{d:0>2}\n", .{ d, h, m, rem }) catch "";
                }
                break :blk std.fmt.bufPrint(linebuf[700..], "{d:0>2}:{d:0>2}:{d:0>2}\n", .{ h, m, rem }) catch "";
            }
            const v = ctime(expires_abs, &tbuf);
            break :blk v;
        };
        const line = std.fmt.bufPrint(&linebuf, "{s} {s:<16}{s:<20}{s}", .{
            macbuf[0..ml], ip, host[0..hl], tail,
        }) catch continue;
        n.out(line);
    }
    return 0;
}

var ipbuf_local: [64]u8 = undefined;
