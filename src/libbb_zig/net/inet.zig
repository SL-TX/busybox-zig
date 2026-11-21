//! Internet address parsing/formatting and checksum helpers.
//! Pure Zig replacements for the libbb inet_aton/inet_pton/inet_ntop helpers.

const std = @import("std");

pub const Ip = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    pub fn eql(a: Ip, b: Ip) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .v4 => |x| std.mem.eql(u8, &x, &b.v4),
            .v6 => |x| std.mem.eql(u8, &x, &b.v6),
        };
    }
};

fn hexVal(c: u8) ?u16 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Parse a dotted-quad IPv4 address into four bytes (network order).
pub fn parseV4(text: []const u8) ?[4]u8 {
    if (text.len == 0) return null;
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        var v: u16 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
            if (v > 255) return null;
        }
        out[i] = @intCast(v);
        i += 1;
    }
    if (i != 4) return null;
    return out;
}

/// Format four IPv4 bytes into dotted-quad notation.
pub fn formatV4(ip: [4]u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch "";
}

/// Parse a textual IPv6 address. Supports "::" compression, embedded IPv4,
/// and case-insensitive hexadecimal groups. Returns 16 bytes in network order.
pub fn parseV6(text: []const u8) ?[16]u8 {
    if (text.len == 0) return null;

    var out: [16]u8 = std.mem.zeroes([16]u8);
    // Locate the (at most one) "::" marker.
    const dc = std.mem.indexOf(u8, text, "::");
    if (dc) |pos| {
        if (std.mem.indexOf(u8, text[pos + 2 ..], "::") != null) return null;
    }

    const left = if (dc) |p| text[0..p] else text;
    const right = if (dc) |p| text[p + 2 ..] else text[text.len..];

    var head: [8]u16 = undefined;
    var head_len: usize = 0;
    if (!parseGroups(left, &head, &head_len)) return null;

    var tail: [8]u16 = undefined;
    var tail_len: usize = 0;
    if (!parseGroups(right, &tail, &tail_len)) return null;

    if (dc == null) {
        if (head_len != 8) return null;
        writeGroups(&out, 0, &head, head_len);
        return out;
    }
    // "::" must expand to at least one group.
    if (head_len + tail_len >= 8) return null;
    writeGroups(&out, 0, &head, head_len);
    const tail_start = 8 - tail_len;
    writeGroups(&out, tail_start, &tail, tail_len);
    return out;
}

/// Parse a colon-separated list of hextets (the final one may be IPv4).
fn parseGroups(text: []const u8, groups: *[8]u16, count: *usize) bool {
    count.* = 0;
    if (text.len == 0) return true;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |part| {
        if (count.* >= 8) return false;
        if (part.len == 0) return false;
        // Embedded IPv4 (only legal as the final group).
        if (std.mem.indexOfScalar(u8, part, '.') != null) {
            const v4 = parseV4(part) orelse return false;
            if (it.next() != null) return false;
            groups[count.*] = (@as(u16, v4[0]) << 8) | v4[1];
            count.* += 1;
            groups[count.*] = (@as(u16, v4[2]) << 8) | v4[3];
            count.* += 1;
            return true;
        }
        if (part.len > 4) return false;
        var v: u16 = 0;
        for (part) |c| {
            const h = hexVal(c) orelse return false;
            v = (v << 4) | h;
        }
        groups[count.*] = v;
        count.* += 1;
    }
    return true;
}

fn writeGroups(out: *[16]u8, start: usize, groups: *const [8]u16, count: usize) void {
    for (0..count) |i| {
        const v = groups[i];
        out[(start + i) * 2] = @truncate(v >> 8);
        out[(start + i) * 2 + 1] = @truncate(v);
    }
}

const hex = "0123456789abcdef";

/// Format 16 IPv6 bytes into canonical (compressed) textual notation.
pub fn formatV6(ip: [16]u8, buf: []u8) []const u8 {
    var groups: [8]u16 = undefined;
    for (0..8) |i| groups[i] = (@as(u16, ip[i * 2]) << 8) | ip[i * 2 + 1];

    // Longest run of zero groups (length >= 2).
    var best_start: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] != 0) {
            i += 1;
            continue;
        }
        const s = i;
        while (i < 8 and groups[i] == 0) i += 1;
        if (i - s > best_len) {
            best_len = i - s;
            best_start = s;
        }
    }

    var w: usize = 0;
    const emit = struct {
        fn group(dst: []u8, pos: *usize, v: u16) void {
            if (v == 0) {
                dst[pos.*] = '0';
                pos.* += 1;
                return;
            }
            var shift: i32 = 12;
            var started = false;
            while (shift >= 0) : (shift -= 4) {
                const nibble: usize = @intCast((v >> @intCast(shift)) & 0xf);
                if (nibble != 0 or started) {
                    dst[pos.*] = hex[nibble];
                    pos.* += 1;
                    started = true;
                }
            }
        }
    }.group;

    var g: usize = 0;
    while (g < 8) : (g += 1) {
        if (g == best_start and best_len >= 2) {
            buf[w] = ':';
            w += 1;
            buf[w] = ':';
            w += 1;
            g += best_len - 1;
            continue;
        }
        if (g > 0 and g != best_start + best_len) {
            buf[w] = ':';
            w += 1;
        }
        emit(buf, &w, groups[g]);
    }
    return buf[0..w];
}

/// Parse either IPv4 or IPv6 into a generic Ip value.
pub fn parse(text: []const u8) ?Ip {
    if (parseV4(text)) |v4| return .{ .v4 = v4 };
    if (parseV6(text)) |v6| return .{ .v6 = v6 };
    return null;
}

/// Format an Ip value. Caller provides a buffer of at least INET6_ADDRSTRLEN (46).
pub fn format(ip: Ip, buf: []u8) []const u8 {
    return switch (ip) {
        .v4 => |v| formatV4(v, buf),
        .v6 => |v| formatV6(v, buf),
    };
}

/// Internet checksum (RFC 1071): one's-complement sum of 16-bit big-endian words.
pub fn cksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}
