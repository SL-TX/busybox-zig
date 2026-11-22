//! cpio "newc" (SVR4) archive helpers: build and parse, with full 4-byte
//! alignment and trailer handling.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadMagic,
    CorruptHeader,
    Truncated,
} || Allocator.Error;

pub const Entry = struct {
    name: []const u8,
    data: []const u8,
    mode: u32 = 0o100644,
    uid: u32 = 0,
    gid: u32 = 0,
    mtime: u32 = 0,
    nlink: u32 = 1,
    ino: u32 = 1,
};

const Header = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    nlink: u32,
    mtime: u32,
    filesize: u32,
    namesize: u32,
};

fn hexValue(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseHex(field: []const u8) Error!u32 {
    var value: u32 = 0;
    for (field) |c| {
        const v = hexValue(c) orelse return error.CorruptHeader;
        value = (value << 4) | v;
    }
    return value;
}

fn appendHex(out: *std.ArrayList(u8), allocator: Allocator, value: u32) Error!void {
    const digits = "0123456789abcdef";
    var buf: [8]u8 = undefined;
    for (0..8) |i| buf[7 - i] = digits[(value >> @intCast(i * 4)) & 0xf];
    try out.appendSlice(allocator, &buf);
}

fn appendHeader(out: *std.ArrayList(u8), allocator: Allocator, e: Entry, name_len: usize, data_len: usize) Error!void {
    try out.appendSlice(allocator, "070701");
    try appendHex(out, allocator, e.ino);
    try appendHex(out, allocator, e.mode);
    try appendHex(out, allocator, e.uid);
    try appendHex(out, allocator, e.gid);
    try appendHex(out, allocator, e.nlink);
    try appendHex(out, allocator, e.mtime);
    try appendHex(out, allocator, @intCast(data_len));
    try appendHex(out, allocator, 0); // devmajor
    try appendHex(out, allocator, 0); // devminor
    try appendHex(out, allocator, 0); // rdevmajor
    try appendHex(out, allocator, 0); // rdevminor
    try appendHex(out, allocator, @intCast(name_len));
    try appendHex(out, allocator, 0); // check (no CRC in newc)
}

fn pad4(out: *std.ArrayList(u8), allocator: Allocator) Error!void {
    const rem = out.items.len % 4;
    if (rem != 0) try out.appendNTimes(allocator, 0, 4 - rem);
}

pub fn build(allocator: Allocator, entries: []const Entry) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (entries) |e| {
        try appendHeader(&out, allocator, e, e.name.len + 1, e.data.len);
        try out.appendSlice(allocator, e.name);
        try out.append(allocator, 0);
        pad4(&out, allocator) catch |err| return err;
        try out.appendSlice(allocator, e.data);
        pad4(&out, allocator) catch |err| return err;
    }
    try appendHeader(&out, allocator, .{ .name = "", .data = "" }, "TRAILER!!!".len + 1, 0);
    try out.appendSlice(allocator, "TRAILER!!!");
    try out.append(allocator, 0);
    pad4(&out, allocator) catch |err| return err;
    return out.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.data);
    }
    allocator.free(entries);
}

pub fn parse(allocator: Allocator, data: []const u8) Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.data);
        }
        out.deinit(allocator);
    }
    var pos: usize = 0;
    while (true) {
        if (data.len - pos < 110) return error.Truncated;
        if (!std.mem.eql(u8, data[pos..][0..6], "070701")) return error.BadMagic;
        const h = Header{
            .mode = try parseHex(data[pos + 14 ..][0..8]),
            .uid = try parseHex(data[pos + 22 ..][0..8]),
            .gid = try parseHex(data[pos + 30 ..][0..8]),
            .nlink = try parseHex(data[pos + 38 ..][0..8]),
            .mtime = try parseHex(data[pos + 46 ..][0..8]),
            .filesize = try parseHex(data[pos + 54 ..][0..8]),
            .namesize = try parseHex(data[pos + 94 ..][0..8]),
        };
        pos += 110;
        if (h.namesize == 0 or h.namesize > data.len - pos) return error.Truncated;
        const name_field = data[pos .. pos + h.namesize];
        const name = name_field[0 .. std.mem.indexOfScalar(u8, name_field, 0) orelse name_field.len];
        pos += h.namesize;
        pos = std.mem.alignForward(usize, pos, 4);
        if (pos > data.len) return error.Truncated;
        if (std.mem.eql(u8, name, "TRAILER!!!")) break;
        if (h.filesize > data.len - pos) return error.Truncated;
        const body = data[pos .. pos + h.filesize];
        pos += h.filesize;
        pos = std.mem.alignForward(usize, pos, 4);
        if (pos > data.len) return error.Truncated;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .data = try allocator.dupe(u8, body),
            .mode = h.mode,
            .uid = h.uid,
            .gid = h.gid,
            .mtime = h.mtime,
            .nlink = h.nlink,
        });
    }
    return out.toOwnedSlice(allocator);
}
