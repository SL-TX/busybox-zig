//! .deb helpers: ar container (incl. GNU long member names), control.tar*
//! parsing and a small RFC 822-style control field parser.

const std = @import("std");
const gzip = @import("../compression/gzip.zig");
const tar = @import("tar.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadMagic,
    BadHeader,
    ChecksumMismatch,
    CorruptInput,
    CorruptHeader,
    SizeMismatch,
    Truncated,
    Unsupported,
} || Allocator.Error;

pub const Member = struct { name: []const u8, data: []const u8 };

pub const Control = struct {
    package: []const u8 = "",
    version: []const u8 = "",
    architecture: []const u8 = "",
    depends: []const u8 = "",
    description: []const u8 = "",
};

pub const Deb = struct {
    members: []Member,
    control: Control,
    control_tar: []u8,
    data_tar: []u8,

    pub fn deinit(self: Deb, allocator: Allocator) void {
        freeMembers(allocator, self.members);
        allocator.free(self.control_tar);
        allocator.free(self.data_tar);
    }
};

fn writeNum(dst: []u8, value: usize) Error!void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.CorruptHeader;
    @memset(dst, ' ');
    @memcpy(dst[dst.len - s.len ..], s);
}

fn readNum(src: []const u8) Error!usize {
    const trimmed = std.mem.trim(u8, src, " ");
    return std.fmt.parseInt(usize, trimmed, 10) catch error.CorruptHeader;
}

pub fn parseAr(allocator: Allocator, data: []const u8) Error![]Member {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], "!<arch>\n")) return error.BadMagic;
    var out: std.ArrayList(Member) = .empty;
    errdefer {
        for (out.items) |m| {
            allocator.free(m.name);
            allocator.free(m.data);
        }
        out.deinit(allocator);
    }
    var string_table: []const u8 = "";
    var pos: usize = 8;
    while (pos < data.len) {
        if (data.len - pos < 60) return error.Truncated;
        if (!std.mem.eql(u8, data[pos + 58 ..][0..2], "`\n")) return error.CorruptHeader;
        const raw_name = std.mem.trimEnd(u8, data[pos..][0..16], " ");
        const size = try readNum(data[pos + 48 ..][0..10]);
        pos += 60;
        if (size > data.len - pos) return error.Truncated;
        const body = data[pos .. pos + size];
        pos += size;
        if (pos % 2 != 0) pos += 1;

        if (std.mem.eql(u8, raw_name, "//")) {
            string_table = body;
            continue;
        }
        var name: []const u8 = undefined;
        if (raw_name.len > 1 and raw_name[0] == '/' and std.ascii.isDigit(raw_name[1])) {
            const start = std.fmt.parseInt(usize, raw_name[1..], 10) catch return error.CorruptHeader;
            if (start >= string_table.len) return error.CorruptHeader;
            const rest = string_table[start..];
            const end = std.mem.indexOfAny(u8, rest, "/\n") orelse rest.len;
            name = rest[0..end];
        } else {
            name = std.mem.trimEnd(u8, raw_name, "/");
        }
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .data = try allocator.dupe(u8, body),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeMembers(allocator: Allocator, members: []Member) void {
    for (members) |m| {
        allocator.free(m.name);
        allocator.free(m.data);
    }
    allocator.free(members);
}

pub fn buildAr(allocator: Allocator, members: []const Member) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "!<arch>\n");
    // Build the GNU string table for names longer than 15 characters.
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(allocator);
    for (members) |m| if (m.name.len > 15) {
        try table.appendSlice(allocator, m.name);
        try table.appendSlice(allocator, "/\n");
    };
    if (table.items.len > 0) {
        try appendMember(&out, allocator, "//", table.items);
    }
    var table_pos: usize = 0;
    for (members) |m| {
        if (m.name.len <= 15) {
            try appendMember(&out, allocator, m.name, m.data);
        } else {
            var ref: [16]u8 = @splat(' ');
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "/{d}", .{table_pos}) catch return error.CorruptHeader;
            @memcpy(ref[0..s.len], s);
            try appendMember(&out, allocator, &ref, m.data);
            table_pos += m.name.len + 2;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendMember(out: *std.ArrayList(u8), allocator: Allocator, name: []const u8, body: []const u8) Error!void {
    var header: [60]u8 = @splat(' ');
    @memcpy(header[0..name.len], name);
    try writeNum(header[16..28], 0);
    try writeNum(header[28..34], 0);
    try writeNum(header[34..40], 0);
    try writeNum(header[40..48], 0o100644);
    try writeNum(header[48..58], body.len);
    header[58] = '`';
    header[59] = '\n';
    try out.appendSlice(allocator, &header);
    try out.appendSlice(allocator, body);
    if (body.len % 2 != 0) try out.append(allocator, '\n');
}

pub fn parseControl(allocator: Allocator, control: []const u8) Error!Control {
    var result = Control{};
    var lines = std.mem.splitScalar(u8, control, '\n');
    var last_key: []const u8 = "";
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (std.mem.eql(u8, last_key, "Description")) {
                const extra = std.mem.trimEnd(u8, line, " \t");
                if (result.description.len > 0) {
                    const joined = try std.mem.concat(allocator, u8, &.{ result.description, "\n", extra });
                    allocator.free(result.description);
                    result.description = joined;
                }
            }
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        last_key = key;
        if (std.mem.eql(u8, key, "Package")) result.package = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "Version")) result.version = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "Architecture")) result.architecture = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "Depends")) result.depends = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "Description")) result.description = try allocator.dupe(u8, value);
    }
    return result;
}

fn maybeDecompress(allocator: Allocator, name: []const u8, bytes: []const u8) Error![]u8 {
    if (std.mem.endsWith(u8, name, ".gz")) return gzip.decompress(allocator, bytes);
    if (std.mem.endsWith(u8, name, ".xz") or std.mem.endsWith(u8, name, ".bz2")) return error.Unsupported;
    return allocator.dupe(u8, bytes);
}

fn findMember(members: []const Member, prefix: []const u8) ?Member {
    for (members) |m| if (std.mem.startsWith(u8, m.name, prefix)) {
        return m;
    };
    return null;
}

pub fn parseDeb(allocator: Allocator, data: []const u8) Error!Deb {
    const members = try parseAr(allocator, data);
    errdefer freeMembers(allocator, members);
    if (findMember(members, "debian-binary") == null) return error.CorruptHeader;
    const control_member = findMember(members, "control.tar") orelse return error.CorruptHeader;
    const data_member = findMember(members, "data.tar") orelse return error.CorruptHeader;
    const control_tar = try maybeDecompress(allocator, control_member.name, control_member.data);
    errdefer allocator.free(control_tar);
    const data_tar = try maybeDecompress(allocator, data_member.name, data_member.data);
    errdefer allocator.free(data_tar);
    const entries = try tar.parse(allocator, control_tar);
    defer tar.freeEntries(allocator, entries);
    var control_bytes: []const u8 = "";
    for (entries) |entry| {
        const base = std.fs.path.basename(entry.name);
        if (std.mem.eql(u8, base, "control")) {
            control_bytes = entry.data;
            break;
        }
    }
    if (control_bytes.len == 0) return error.CorruptHeader;
    return .{
        .members = members,
        .control = try parseControl(allocator, control_bytes),
        .control_tar = control_tar,
        .data_tar = data_tar,
    };
}

pub fn freeDeb(allocator: Allocator, deb: Deb) void {
    if (deb.control.package.len > 0) allocator.free(deb.control.package);
    if (deb.control.version.len > 0) allocator.free(deb.control.version);
    if (deb.control.architecture.len > 0) allocator.free(deb.control.architecture);
    if (deb.control.depends.len > 0) allocator.free(deb.control.depends);
    if (deb.control.description.len > 0) allocator.free(deb.control.description);
    deb.deinit(allocator);
}

pub fn dataEntries(allocator: Allocator, deb: Deb) Error![]tar.Entry {
    return tar.parse(allocator, deb.data_tar);
}

pub fn buildDeb(allocator: Allocator, control_tar: []const u8, data_tar: []const u8) Error![]u8 {
    const members = [_]Member{
        .{ .name = "debian-binary", .data = "2.0\n" },
        .{ .name = "control.tar.gz", .data = undefined },
        .{ .name = "data.tar.gz", .data = undefined },
    };
    const ctrl_gz = try gzip.compress(allocator, control_tar, .gzip);
    defer allocator.free(ctrl_gz);
    const data_gz = try gzip.compress(allocator, data_tar, .gzip);
    defer allocator.free(data_gz);
    var real = members;
    real[1].data = ctrl_gz;
    real[2].data = data_gz;
    return buildAr(allocator, &real);
}
