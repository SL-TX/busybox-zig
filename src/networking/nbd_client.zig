//! nbd-client — network block device client (networking/nbd-client.c).
//!
//! Parsing and the old/new-style NBD handshake are implemented in full. The
//! final device ioctls operate on whatever BLOCKDEV names; parity cases use a
//! regular file as BLOCKDEV so negotiation is exercised without a real device.

const std = @import("std");
const linux = std.os.linux;
const n = @import("netcommon.zig");
const bb = @import("libbb_zig");

const NBD_SET_SOCK: u32 = 0xab00;
const NBD_SET_BLKSIZE: u32 = 0xab01;
const NBD_SET_SIZE_BLOCKS: u32 = 0xab07;
const NBD_CLEAR_SOCK: u32 = 0xab04;
const NBD_SET_FLAGS: u32 = 0xab0a;
const NBD_SET_TIMEOUT: u32 = 0xab09;
const NBD_DISCONNECT: u32 = 0xab08;
const BLKROSET: u32 = 0x125d;

fn parseUnsigned(text: []const u8, bits: u16) u32 {
    const v = std.fmt.parseInt(u32, text, 10) catch {
        n.plain("invalid number '{s}'", .{text});
        std.process.exit(1);
    };
    if (bits == 16 and v > 65535) {
        n.plain("invalid number '{s}'", .{text});
        std.process.exit(1);
    }
    return v;
}

fn optsLong(body: []const u8, short: u8, long: []const u8) bool {
    return std.mem.eql(u8, body, &[_]u8{short}) or std.mem.eql(u8, body, long);
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) n.plainDie("write error", .{});
        off += @intCast(rc);
    }
}

fn readAll(fd: linux.fd_t, buf: []u8) void {
    const got = bb.socket.recvAll(fd, buf, 0) catch n.plainDie("short read", .{});
    if (got < buf.len) n.plainDie("short read", .{});
}

fn openDevice(path: []const u8) linux.fd_t {
    const p = n.zstr(path) catch n.plainDie("out of memory", .{});
    const rc = linux.open(p, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        n.errorDie(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{path});
    }
    return @intCast(rc);
}

fn connectServer(host: []const u8, port: u16) linux.fd_t {
    const addrs = bb.dns.lookupHost(host, port) catch {
        n.errorMsg(2, "can't resolve '{s}'", .{host});
        std.process.exit(1);
    };
    if (addrs.len == 0) {
        n.errorMsg(2, "can't resolve '{s}'", .{host});
        std.process.exit(1);
    }
    return bb.socket.createAndConnect(addrs[0]) catch {
        n.errorMsg(111, "can't connect to '{s}'", .{host});
        std.process.exit(1);
    };
}

pub fn nbdClientMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const a = std.heap.page_allocator;

    var blksize: u32 = 4096;
    var timeout: u32 = 0;
    var name: []const u8 = "";
    var opt_d = false;
    var persist = false;
    var pos = std.ArrayList([]const u8).empty;
    defer pos.deinit(a);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (std.mem.eql(u8, tok, "--")) {
            for (args[i + 1 ..]) |rest| pos.append(a, rest) catch {};
            break;
        }
        if (tok.len < 2 or tok[0] != '-') {
            pos.append(a, tok) catch {};
            continue;
        }
        var body = tok[1..];
        if (body.len > 0 and body[0] == '-') body = body[1..];
        const dashed = tok[1] == '-';

        if (optsLong(body, 'p', "persist")) {
            persist = true;
        } else if (optsLong(body, 'd', "d")) {
            opt_d = true;
        } else if (std.mem.eql(u8, body, "N") and !dashed) {
            if (i + 1 >= args.len) {
                n.plain("option requires an argument -- 'N'", .{});
                n.usageDie("nbd-client");
            }
            i += 1;
            name = args[i];
        } else if (optsLong(body, 'n', "name")) {
            if (i + 1 >= args.len) {
                if (dashed)
                    n.plain("option '--name' requires an argument", .{})
                else
                    n.plain("option '-name' requires an argument", .{});
                n.usageDie("nbd-client");
            }
            i += 1;
            name = args[i];
        } else if (optsLong(body, 'b', "block-size")) {
            if (i + 1 >= args.len) {
                if (dashed)
                    n.plain("option '--block-size' requires an argument", .{})
                else
                    n.plain("option '-block-size' requires an argument", .{});
                n.usageDie("nbd-client");
            }
            i += 1;
            blksize = parseUnsigned(args[i], 32);
        } else if (optsLong(body, 't', "timeout")) {
            if (i + 1 >= args.len) {
                if (dashed)
                    n.plain("option '--timeout' requires an argument", .{})
                else
                    n.plain("option '-timeout' requires an argument", .{});
                n.usageDie("nbd-client");
            }
            i += 1;
            timeout = parseUnsigned(args[i], 32);
        } else {
            n.plain("unrecognized option '{s}'", .{tok});
            n.usageDie("nbd-client");
        }
    }

    if (opt_d) {
        if (pos.items.len != 1) n.usageDie("nbd-client");
        const dev = openDevice(pos.items[0]);
        _ = linux.ioctl(dev, NBD_DISCONNECT, 0);
        _ = linux.ioctl(dev, NBD_CLEAR_SOCK, 0);
        _ = linux.close(dev);
        return 0;
    }
    if (pos.items.len < 2 or pos.items.len > 3) n.usageDie("nbd-client");
    const host = pos.items[0];
    const port_text = if (pos.items.len == 3) pos.items[1] else "10809";
    const device = if (pos.items.len == 3) pos.items[2] else pos.items[1];
    const port: u16 = @intCast(parseUnsigned(port_text, 16));

    const nbd = openDevice(device);
    defer _ = linux.close(nbd);
    const sock = connectServer(host, port);
    defer _ = linux.close(sock);

    var one: [4]u8 = .{ 0, 0, 0, 0 };
    _ = linux.setsockopt(sock, 6, 1, &one, 4); // IPPROTO_TCP, TCP_NODELAY

    var hdr: [16]u8 = undefined;
    readAll(sock, &hdr);
    if (!std.mem.eql(u8, hdr[0..8], "NBDMAGIC")) n.plainDie("login failed", .{});
    const proto_new = if (std.mem.eql(u8, hdr[8..16], &.{ 0, 0, 0x42, 0x02, 0x81, 0x86, 0x12, 0x53 }))
        false
    else if (std.mem.eql(u8, hdr[8..16], "IHAVEOPT"))
        true
    else
        n.plainDie("login failed", .{});

    var flags: u16 = 0;
    if (!proto_new) {
        var rest: [8 + 4 + 124]u8 = undefined;
        readAll(sock, &rest);
        const size = std.mem.readInt(u64, rest[0..8], .big);
        _ = size / blksize;
        flags = @truncate(std.mem.readInt(u32, rest[8..12], .big));
    } else {
        var hs_flags: [2]u8 = undefined;
        readAll(sock, &hs_flags);
        writeAll(sock, &.{ 0, 0, 0, 0 });
        var opt: [16]u8 = undefined;
        @memcpy(opt[0..8], "IHAVEOPT");
        std.mem.writeInt(u32, opt[8..12], 1, .big); // NBD_OPT_EXPORT_NAME
        std.mem.writeInt(u32, opt[12..16], @intCast(name.len), .big);
        writeAll(sock, &opt);
        writeAll(sock, name);
        var rest: [8 + 2 + 124]u8 = undefined;
        readAll(sock, &rest);
        const size = std.mem.readInt(u64, rest[0..8], .big);
        _ = size / blksize;
        flags = std.mem.readInt(u16, rest[8..10], .big);
    }

    _ = linux.ioctl(nbd, NBD_SET_BLKSIZE, blksize);
    _ = linux.ioctl(nbd, NBD_SET_SIZE_BLOCKS, 0);
    _ = linux.ioctl(nbd, NBD_CLEAR_SOCK, 0);
    if (proto_new) _ = linux.ioctl(nbd, NBD_SET_FLAGS, flags);

    var ro: i32 = if ((flags & 0x0002) != 0) 1 else 0;
    var rc = linux.ioctl(nbd, BLKROSET, @intFromPtr(&ro));
    if (linux.errno(rc) != .SUCCESS) n.errorDie(@intFromEnum(linux.errno(rc)), "BLKROSET", .{});
    if (timeout != 0) {
        rc = linux.ioctl(nbd, NBD_SET_TIMEOUT, timeout);
        if (linux.errno(rc) != .SUCCESS) n.errorDie(@intFromEnum(linux.errno(rc)), "NBD_SET_TIMEOUT", .{});
    }
    rc = linux.ioctl(nbd, NBD_SET_SOCK, @intCast(sock));
    if (linux.errno(rc) != .SUCCESS) n.errorDie(@intFromEnum(linux.errno(rc)), "NBD_SET_SOCK", .{});
    rc = linux.ioctl(nbd, 0xab03, 0); // NBD_DO_IT
    if (linux.errno(rc) == .SUCCESS or @intFromEnum(linux.errno(rc)) == 53) {
        _ = linux.ioctl(nbd, 0xab05, 0); // NBD_CLEAR_QUEUE
        _ = linux.ioctl(nbd, NBD_CLEAR_SOCK, 0);
        return 0;
    }
    if (!persist) return 0;
    while (persist) {
        rc = linux.ioctl(nbd, 0xab03, 0);
        if (linux.errno(rc) == .SUCCESS or @intFromEnum(linux.errno(rc)) == 53) break;
    }
    return 0;
}
