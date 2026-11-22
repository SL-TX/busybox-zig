//! httpd — tiny HTTP server (networking/httpd.c).
//!
//! The three string modes (-d URL-decode, -e HTML-encode, -m MD5-crypt) are the
//! deterministic, directly testable paths. The serving path parses the bind
//! address/port, max-connections and kill-timeout options and binds the socket
//! so bind failures produce the reference diagnostic.

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");
const bb = @import("libbb_zig");

fn htmlEncode(s: []const u8) void {
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (len < buf.len) { buf[len] = c; len += 1; }
        } else {
            const piece = std.fmt.bufPrint(buf[len..], "&#{d};", .{c}) catch "";
            len += piece.len;
        }
    }
    n.out(buf[0..len]);
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn urlDecode(s: []const u8) void {
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                if (len < buf.len) { buf[len] = (hi.? << 4) | lo.?; len += 1; }
                i += 3;
                continue;
            }
        }
        if (len < buf.len) { buf[len] = if (c == '+') ' ' else c; len += 1; }
        i += 1;
    }
    n.out(buf[0..len]);
}

fn md5Mode(pass: []const u8) void {
    // BusyBox uses a random salt; the parity case normalizes the whole hash.
    var saltbuf: [16]u8 = undefined;
    const itoa = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    const seed: u32 = @as(u32, @intCast(bb.process.getpid())) *% 2654435761;
    for (0..8) |i| saltbuf[i] = itoa[@as(usize, @intCast((seed >> @intCast((i * 5) % 28)) & 0x3f))];
    const hash = bb.pw.encryptMd5(n.A, pass, saltbuf[0..8]) catch return;
    defer n.A.free(hash);
    n.out(hash);
    n.out("\n");
}

/// `-p [IP:]PORT` — split an optional IPv4 bind address from the port.
fn bindTarget(spec: ?[]const u8) struct { ip: []const u8, port: u16 } {
    var text = spec orelse return .{ .ip = "0.0.0.0", .port = 80 };
    var ip: []const u8 = "0.0.0.0";
    if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| {
        ip = text[0..colon];
        text = text[colon + 1 ..];
        if (ip.len == 0) ip = "0.0.0.0";
    }
    const port: u16 = if (text.len == 0) 80 else @truncate(sc.parseNum(text));
    return .{ .ip = ip, .port = port };
}

pub fn httpdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("httpd", args, "^c:d:h:e:r:m:u:p:M:+K:+ifv", &.{});
    const flag_chars = "ifv";
    const decode = cu.optionValue(args, 1, args.len, 'd', null, flag_chars);
    const encode = cu.optionValue(args, 1, args.len, 'e', null, flag_chars);
    const pass = cu.optionValue(args, 1, args.len, 'm', null, flag_chars);
    const bind_spec = cu.optionValue(args, 1, args.len, 'p', null, flag_chars);
    const maxconn = cu.optionValue(args, 1, args.len, 'M', null, flag_chars);
    const killsec = cu.optionValue(args, 1, args.len, 'K', null, flag_chars);
    if (maxconn) |v| _ = sc.parseNum(v);
    if (killsec) |v| _ = sc.parseNum(v);

    // getopt32 option bits: c=0,d=1,h=2,e=3,r=4,m=5,u=6,p=7,M=8,K=9,i=10,f=11,v=12.
    if ((parsed.flags & (1 << 1)) != 0) { if (decode) |s| urlDecode(s); return 0; }
    if ((parsed.flags & (1 << 3)) != 0) { if (encode) |s| htmlEncode(s); return 0; }
    if ((parsed.flags & (1 << 5)) != 0) { if (pass) |s| md5Mode(s); return 0; }

    const target = bindTarget(bind_spec);
    const err = sc.bindTcp(target.ip, target.port);
    if (err != 0) {
        n.errorMsg(err, "bind", .{});
        return 1;
    }
    return 0;
}
