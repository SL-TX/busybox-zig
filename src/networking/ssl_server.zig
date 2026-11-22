//! ssl_server — inetd-style TLS server (networking/ssl_server.c).

const std = @import("std");
const linux = std.os.linux;
const n = @import("netcommon.zig");
const tls = @import("tls_core.zig");
const spawn = @import("ssl_spawn.zig");
const rsa = @import("libbb_zig").tls.rsa;

const Pem = struct {
    key: rsa.PrivateKey,
    certs: []const []const u8,
};

fn readFile(path: []const u8) ![]u8 {
    const p = n.zstr(path) catch return error.OutOfMemory;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        n.errorDie(@intFromEnum(e), "can't read '{s}'", .{path});
    }
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var data = std.ArrayList(u8).empty;
    const a = std.heap.page_allocator;
    var buf: [8192]u8 = undefined;
    while (true) {
        const count = linux.read(fd, &buf, buf.len);
        if (linux.errno(count) != .SUCCESS or count == 0) break;
        data.appendSlice(a, buf[0..@as(usize, count)]) catch return error.OutOfMemory;
    }
    return data.toOwnedSlice(a);
}

fn decodePemBlock(a: std.mem.Allocator, body: []const u8) ![]u8 {
    var compact = std.ArrayList(u8).empty;
    defer compact.deinit(a);
    for (body) |c| switch (c) {
        '\n', '\r', ' ', '\t' => {},
        else => try compact.append(a, c),
    };
    const out = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(compact.items));
    try std.base64.standard.Decoder.decode(out, compact.items);
    return out;
}

fn loadPem(a: std.mem.Allocator, path: []const u8) !Pem {
    const text = try readFile(path);
    defer a.free(text);
    const key = try rsa.parsePrivateKeyPem(a, text);
    var certs = std.ArrayList([]const u8).empty;
    errdefer certs.deinit(a);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "-----BEGIN CERTIFICATE-----")) |b| {
        const begin = (std.mem.indexOfScalarPos(u8, text, b, '\n') orelse break) + 1;
        const end = std.mem.indexOfPos(u8, text, begin, "-----END CERTIFICATE-----") orelse break;
        try certs.append(a, try decodePemBlock(a, text[begin..end]));
        pos = end + 1;
    }
    if (certs.items.len == 0) return error.InvalidKey;
    return .{ .key = key, .certs = try certs.toOwnedSlice(a) };
}

fn handshakeError(e: anyerror) noreturn {
    switch (e) {
        error.ConnectionClosed, error.ReadFailed => n.plainDie("got bad TLS record (len:0) while expecting handshake record", .{}),
        error.InvalidKey => n.plainDie("can't load private key", .{}),
        error.BadFinished => n.plainDie("bad Finished message", .{}),
        error.BadMac => n.plainDie("bad record MAC", .{}),
        else => n.plainDie("TLS handshake error", .{}),
    }
}

fn ignoreSigpipe() void {
    var act = linux.Sigaction{
        .handler = .{ .handler = @ptrFromInt(1) },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

pub fn sslServerMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    ignoreSigpipe();
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = n.opts("ssl_server", args, "+vf:", &.{});
    if ((parsed.flags & 2) == 0 or parsed.args.len == 0) n.usageDie("ssl_server");

    // getopt32 stores only the last optarg; recover -f by scanning argv.
    var pem_path: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (args[i].len >= 2 and args[i][0] == '-' and args[i][1] == 'f') {
            pem_path = if (args[i].len > 2) args[i][2..] else if (i + 1 < args.len) args[i + 1] else "";
            break;
        }
    }

    const a = std.heap.page_allocator;
    const pem = loadPem(a, pem_path) catch n.plainDie("invalid PEM file", .{});

    // In inetd mode, stdin/stdout are already the accepted socket. Shuffle
    // them to 3/4 as the reference does: the copy loop needs plain fds on 0/1.
    if (linux.errno(linux.dup2(0, 3)) != .SUCCESS) n.errorDie(9, "dup", .{});
    if (linux.errno(linux.dup2(1, 4)) != .SUCCESS) n.errorDie(9, "dup", .{});

    var conn = tls.Conn.init(a, 3, 4, .server);
    defer conn.deinit();
    conn.certs = pem.certs;
    conn.privkey = pem.key;
    conn.handshakeServer() catch |e| handshakeError(e);
    for (pem.certs) |der| a.free(der);
    a.free(pem.certs);
    conn.certs = &.{};

    const child = spawn.spawn(parsed.args) catch n.errorDie(5, "pipe", .{});
    if (linux.errno(linux.dup2(child.from_rd, 0)) != .SUCCESS) n.errorDie(9, "dup", .{});
    if (linux.errno(linux.dup2(child.to_wr, 1)) != .SUCCESS) n.errorDie(9, "dup", .{});
    if (child.from_rd > 1) _ = linux.close(child.from_rd);
    if (child.to_wr > 1) _ = linux.close(child.to_wr);

    conn.copyLoop(true) catch |e| {
        if (e == error.WriteFailed) n.errorDie(conn.last_errno, "write error", .{});
        if (e == error.ConnectionClosed or e == error.ReadFailed) return 0;
        n.plainDie("TLS I/O error", .{});
    };
    return 0;
}
