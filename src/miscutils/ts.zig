//! ts — prepend a timestamp to every stdin line (reference miscutils/ts.c).

const std = @import("std");
const c = @import("common.zig");

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const TimeParts = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    epoch: u64,
};

fn parts(secs_signed: i64) TimeParts {
    const secs: u64 = if (secs_signed < 0) 0 else @intCast(secs_signed);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = @intFromEnum(md.month),
        .day = md.day_index + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
        .second = ds.getSecondsIntoMinute(),
        .epoch = secs,
    };
}

fn put2(buf: []u8, pos: *usize, value: u8, pad_space: bool) void {
    const tens: u8 = value / 10;
    const ones: u8 = value % 10;
    if (tens == 0) {
        buf[pos.*] = if (pad_space) ' ' else '0';
        pos.* += 1;
    } else {
        buf[pos.*] = '0' + tens;
        pos.* += 1;
    }
    buf[pos.*] = '0' + ones;
    pos.* += 1;
}

fn put4(buf: []u8, pos: *usize, value: u16) void {
    buf[pos.*] = '0' + @as(u8, @intCast(value / 1000));
    pos.* += 1;
    buf[pos.*] = '0' + @as(u8, @intCast((value / 100) % 10));
    pos.* += 1;
    buf[pos.*] = '0' + @as(u8, @intCast((value / 10) % 10));
    pos.* += 1;
    buf[pos.*] = '0' + @as(u8, @intCast(value % 10));
    pos.* += 1;
}

fn strftime(buf: []u8, fmt: []const u8, t: TimeParts) usize {
    var p: usize = 0;
    var i: usize = 0;
    while (i < fmt.len and p + 32 < buf.len) : (i += 1) {
        if (fmt[i] != '%') {
            buf[p] = fmt[i];
            p += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) break;
        switch (fmt[i]) {
            'b', 'h' => {
                const name = months[t.month - 1];
                @memcpy(buf[p .. p + 3], name);
                p += 3;
            },
            'Y' => put4(buf, &p, t.year),
            'm' => put2(buf, &p, t.month, false),
            'd' => put2(buf, &p, t.day, false),
            'e' => put2(buf, &p, t.day, true),
            'H' => put2(buf, &p, t.hour, false),
            'M' => put2(buf, &p, t.minute, false),
            'S' => put2(buf, &p, t.second, false),
            'F' => {
                put4(buf, &p, t.year);
                buf[p] = '-';
                p += 1;
                put2(buf, &p, t.month, false);
                buf[p] = '-';
                p += 1;
                put2(buf, &p, t.day, false);
            },
            'T' => {
                put2(buf, &p, t.hour, false);
                buf[p] = ':';
                p += 1;
                put2(buf, &p, t.minute, false);
                buf[p] = ':';
                p += 1;
                put2(buf, &p, t.second, false);
            },
            's' => {
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{t.epoch}) catch "";
                @memcpy(buf[p .. p + s.len], s);
                p += s.len;
            },
            '%' => {
                buf[p] = '%';
                p += 1;
            },
            else => {
                buf[p] = '%';
                p += 1;
                buf[p] = fmt[i];
                p += 1;
            },
        }
    }
    return p;
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("ts");
    const o = c.opts("ts", args, "^is", &.{});
    const elapsed = o.flags != 0;
    const since_prev = (o.flags & 1) != 0;

    const fmt: []const u8 = if (o.args.len > 0)
        o.args[0]
    else if (elapsed)
        "%H:%M:%S"
    else
        "%b %d %H:%M:%S";

    const base = c.realtimeSecs();
    var prev = base;
    const input = c.readStdin(a) catch return 1;
    defer a.free(input);

    if (input.len == 0) return 0;
    var start: usize = 0;
    while (start < input.len) {
        const nl = std.mem.indexOfScalarPos(u8, input, start, '\n');
        const end = nl orelse input.len;
        const line = input[start..end];
        const now = c.realtimeSecs();
        var stamp_secs: i64 = now;
        if (elapsed) {
            stamp_secs = now - base;
            if (since_prev) {
                stamp_secs = now - prev;
                prev = now;
            }
        }
        var buf: [512]u8 = undefined;
        const n = strftime(&buf, fmt, parts(stamp_secs));
        c.out(buf[0..n]);
        c.out(" ");
        c.out(line);
        if (nl != null) c.out("\n");
        if (nl == null) break;
        start = end + 1;
    }
    return 0;
}
