//! Password hashing for busybox applets. Currently MD5-crypt ($1$).

const std = @import("std");
const Md5 = std.crypto.hash.Md5;

const itoa64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

fn appendB64(a: std.mem.Allocator, out: *std.ArrayList(u8), value: u32, count: usize) !void {
    var v = value;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.append(a, itoa64[@intCast(v & 0x3f)]);
        v >>= 6;
    }
}

pub fn encryptMd5(a: std.mem.Allocator, password: []const u8, salt: []const u8) ![]u8 {
    const s = salt[0..@min(salt.len, 8)];

    var ctx = Md5.init(.{});
    ctx.update(password);
    ctx.update("$1$");
    ctx.update(s);

    var alt_ctx = Md5.init(.{});
    alt_ctx.update(password);
    alt_ctx.update(s);
    alt_ctx.update(password);
    var alt: [16]u8 = undefined;
    alt_ctx.final(&alt);

    for (0..password.len) |i| ctx.update(alt[i % 16 ..][0..1]);

    var n = password.len;
    while (n > 0) : (n >>= 1) {
        if (n & 1 != 0) {
            ctx.update(&.{0}); // `final` was zeroed above
        } else {
            ctx.update(password[0..1]); // FreeBSD uses a single byte here
        }
    }
    var digest: [16]u8 = undefined;
    ctx.final(&digest);

    var round: usize = 0;
    while (round < 1000) : (round += 1) {
        var c = Md5.init(.{});
        if (round & 1 != 0) c.update(password) else c.update(&digest);
        if (round % 3 != 0) c.update(s);
        if (round % 7 != 0) c.update(password);
        if (round & 1 != 0) c.update(&digest) else c.update(password);
        c.final(&digest);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "$1$");
    try out.appendSlice(a, s);
    try out.append(a, '$');
    try appendB64(a, &out, (@as(u32, digest[0]) << 16) | (@as(u32, digest[6]) << 8) | digest[12], 4);
    try appendB64(a, &out, (@as(u32, digest[1]) << 16) | (@as(u32, digest[7]) << 8) | digest[13], 4);
    try appendB64(a, &out, (@as(u32, digest[2]) << 16) | (@as(u32, digest[8]) << 8) | digest[14], 4);
    try appendB64(a, &out, (@as(u32, digest[3]) << 16) | (@as(u32, digest[9]) << 8) | digest[15], 4);
    try appendB64(a, &out, (@as(u32, digest[4]) << 16) | (@as(u32, digest[10]) << 8) | digest[5], 4);
    try appendB64(a, &out, digest[11], 2);
    return out.toOwnedSlice(a);
}
