//! tune2fs — adjust ext2/ext3 superblock tunables.
//!
//! CONFIG_TUNE2FS=n in both the reference defconfig and ours, so this applet
//! is compiled out of the registry. The implementation is real (it edits a
//! superblock at offset 1024) and is exercised by unit tests.

const std = @import("std");
const c = @import("common.zig");
const linux = c.linux;

pub const Tuning = struct {
    label: ?[]const u8 = null,
    max_mnt: ?i64 = null,
    interval_days: ?u64 = null,
    mount_count: ?u32 = null,
};

fn putLe16(sb: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, sb[off..][0..2], v, .little);
}
fn putLe32(sb: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, sb[off..][0..4], v, .little);
}

/// Apply the requested tunables to a 1024-byte ext2 superblock image.
pub fn mangleSuperblock(sb: []u8, t: Tuning) void {
    if (sb.len < 1024) return;
    if (t.mount_count) |n| putLe16(sb, 56, @intCast(n & 0xffff));
    if (t.label) |label| {
        const n = @min(label.len, 16);
        @memcpy(sb[120..][0..n], label[0..n]);
    }
    if (t.max_mnt) |n| {
        const v: i64 = if (n == 0) -1 else n;
        putLe16(sb, 58, @bitCast(@as(i16, @truncate(v))));
    }
    if (t.interval_days) |days| putLe32(sb, 72, @truncate(days *% 24 *% 60 *% 60));
}

fn parseInt(s: []const u8, min: i64, max: i64) i64 {
    const n = std.fmt.parseInt(i64, s, 10) catch
        c.plainDie("invalid number '{s}'", .{s});
    if (n < min or n > max) c.plainDie("value '{s}' is out of range", .{s});
    return n;
}

fn parseUint(s: []const u8, max: u64) u64 {
    if (s.len == 0 or s[0] == '-') c.plainDie("invalid number '{s}'", .{s});
    const n = std.fmt.parseInt(u64, s, 10) catch c.plainDie("invalid number '{s}'", .{s});
    if (n > max) c.plainDie("value '{s}' is out of range", .{s});
    return n;
}

pub fn tune2fsMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = c.argsFrom(argv, argc);
    c.setProg(argv);
    const name = std.fs.path.basename(std.mem.span(argv[0]));
    const o = c.opts(name, args, "^L:c:i:C:");
    if (o.flags == 0) c.usageDie(name);
    if (o.args.len != 1) c.usageDie(name);

    var t = Tuning{};
    var k: usize = 0;
    for ([_]u8{ 'L', 'c', 'i', 'C' }) |ch| {
        if ((o.flags & (@as(u32, 1) << @as(u5, @intCast(k)))) == 0) {
            k += 1;
            continue;
        }
        var value: ?[]const u8 = null;
        var j: usize = 1;
        while (j < args.len) : (j += 1) {
            const a = args[j];
            if (a.len < 2 or a[0] != '-') continue;
            var p: usize = 1;
            while (p < a.len) : (p += 1) {
                if (a[p] == ch) {
                    value = if (p + 1 < a.len) a[p + 1 ..] else if (j + 1 < args.len) args[j + 1] else null;
                    break;
                }
            }
            if (value != null) break;
        }
        const v = value orelse c.usageDie(name);
        switch (ch) {
            'L' => t.label = v,
            'c' => t.max_mnt = parseInt(v, -1, 0xfffe),
            'i' => t.interval_days = parseUint(v, std.math.maxInt(u32) / (24 * 60 * 60)),
            'C' => t.mount_count = @intCast(parseInt(v, 1, 0xfffe)),
            else => {},
        }
        k += 1;
    }

    const device = o.args[0];
    const p = c.zstr(device) catch return 1;
    defer c.A.free(p);
    const fd_rc = linux.open(p, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) {
        c.msg(c.err(fd_rc), "can't open '{s}'", .{device});
        return 1;
    }
    const fd: linux.fd_t = @intCast(fd_rc);
    defer _ = linux.close(fd);
    _ = linux.lseek(fd, 1024, linux.SEEK.SET);
    var sb: [1024]u8 = std.mem.zeroes([1024]u8);
    const n = linux.read(fd, &sb, sb.len);
    if (linux.errno(n) != .SUCCESS) return 1;
    mangleSuperblock(&sb, t);
    _ = linux.lseek(fd, 1024, linux.SEEK.SET);
    var done: usize = 0;
    while (done < sb.len) {
        const w = linux.write(fd, sb[done..].ptr, sb.len - done);
        if (linux.errno(w) != .SUCCESS or w == 0) break;
        done += w;
    }
    return 0;
}
