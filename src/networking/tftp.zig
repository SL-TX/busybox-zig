//! tftp — trivial file transfer client (reference networking/tftp.c).
//!
//! -g/-p (exactly one), -l/-r file names and -b blocksize are all honoured:
//! the blocksize is range-checked before any network access, the local upload
//! file is opened before the first datagram, and the constructed RRQ/WRQ
//! packet carries the negotiated blksize/tsize options.  Retries and the exact
//! "server error: (N) text" / "timeout" diagnostics mirror the reference.

const std = @import("std");
const n = @import("netcommon.zig");
const cu = @import("client_util.zig");
const sock = @import("libbb_zig").socket;
const linux = std.os.linux;

const RRQ: u16 = 1;
const WRQ: u16 = 2;
const DATA: u16 = 3;
const ACK: u16 = 4;
const ERROR: u16 = 5;
const OACK: u16 = 6;

// MIN_BLKSIZE from the reference:
// 2 + sizeof("blksize\0" "NNNNN\0" "tsize\0") + sizeof(off_t)*3 + 16
const MIN_BLKSIZE: u32 = 2 + 21 + @sizeOf(i64) * 3 + 16; // = 63
const MAX_BLKSIZE: u32 = 65464;

fn checkBlocksize(text: []const u8) ?u32 {
    const v = std.fmt.parseInt(u32, text, 10) catch {
        n.plain("bad blocksize '{s}'", .{text});
        return null;
    };
    if (v < MIN_BLKSIZE or v > MAX_BLKSIZE) {
        n.plain("bad blocksize '{s}'", .{text});
        return null;
    }
    return v;
}

fn appendZ(buf: []u8, at: *usize, text: []const u8) bool {
    if (at.* + text.len + 1 > buf.len) return false;
    @memcpy(buf[at.* .. at.* + text.len], text);
    at.* += text.len;
    buf[at.*] = 0;
    at.* += 1;
    return true;
}

fn serverError(code: u16, payload: []const u8) void {
    const names = [_][]const u8{
        "", "file not found", "access violation", "disk full", "bad operation",
        "unknown transfer id", "file already exists", "no such user", "bad option",
    };
    var msg: []const u8 = "";
    if (payload.len > 0 and payload[0] != 0) {
        msg = payload;
    } else if (code < names.len) {
        msg = names[code];
    }
    n.plain("server error: ({d}) {s}", .{ code, msg });
}

fn transfer(fd: linux.fd_t, get: bool, local_fd_in: ?linux.fd_t, local_path: ?[]const u8, remote_file: []const u8, blksize: u32) bool {
    var local_fd = local_fd_in;
    var buf: [MAX_BLKSIZE + 64]u8 = undefined;
    var at: usize = 2;
    std.mem.writeInt(u16, buf[0..2], if (get) RRQ else WRQ, .big);
    if (!appendZ(&buf, &at, remote_file) or !appendZ(&buf, &at, "octet")) {
        n.plain("remote filename is too long", .{});
        return false;
    }
    if (blksize != 512) {
        var bs: [16]u8 = undefined;
        const bs_text = std.fmt.bufPrint(&bs, "{d}", .{blksize}) catch return false;
        _ = appendZ(&buf, &at, "blksize") and appendZ(&buf, &at, bs_text);
        _ = appendZ(&buf, &at, "tsize") and appendZ(&buf, &at, "0");
    }

    var retries: usize = 12;
    var wait_ms: i32 = 100;
    var block: u16 = 1;
    var sent_len = at;
    var expect_oack = blksize != 512;
    var finished = false;
    var own_fd: ?linux.fd_t = null;
    defer {
        if (own_fd) |lf| _ = linux.close(lf);
    }

    _ = sock.send(fd, buf[0..sent_len], 0) catch {};

    while (!finished) {
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&fds, 1, wait_ms);
        if (linux.errno(pr) != .SUCCESS) return false;
        if (pr == 0) {
            retries -= 1;
            if (retries == 0) {
                n.plain("timeout", .{});
                return false;
            }
            wait_ms += @divTrunc(wait_ms, 2);
            if (wait_ms > 2000) wait_ms = 2000;
            _ = sock.send(fd, buf[0..sent_len], 0) catch {};
            continue;
        }
        const got = sock.recv(fd, &buf, 0) catch continue;
        if (got < 4) continue;
        const opcode = std.mem.readInt(u16, buf[0..2], .big);
        const recv_block = std.mem.readInt(u16, buf[2..4], .big);
        if (opcode == ERROR) {
            serverError(recv_block, std.mem.trim(u8, buf[4..got], "\x00\r\n"));
            return false;
        }
        if (expect_oack) {
            expect_oack = false;
            if (opcode == OACK) {
                if (get) block = 0;
                continue;
            }
            n.plain("falling back to blocksize 512", .{});
        }
        if (get and opcode == DATA and recv_block == block) {
            if (local_fd == null and local_path != null) {
                const pz = n.zstr(local_path.?) catch return false;
                const orc = linux.open(pz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
                if (linux.errno(orc) != .SUCCESS) {
                    n.errorMsg(@intFromEnum(linux.errno(orc)), "can't create '{s}'", .{local_path.?});
                    return false;
                }
                local_fd = @intCast(orc);
                own_fd = local_fd;
            }
            if (local_fd) |lf| {
                _ = linux.write(lf, buf[4..got].ptr, got - 4);
            } else {
                n.out(buf[4..got]);
            }
            if (got - 4 < blksize) finished = true;
            std.mem.writeInt(u16, buf[0..2], ACK, .big);
            std.mem.writeInt(u16, buf[2..4], block, .big);
            sent_len = 4;
            block +%= 1;
            retries = 12;
            wait_ms = 100;
            _ = sock.send(fd, buf[0..sent_len], 0) catch {};
            continue;
        }
        if (!get and opcode == ACK and recv_block == block -% 1) {
            if (finished) return true;
            sentinel: {
                if (local_fd) |lf| {
                    const got_data = linux.read(lf, buf[4 .. 4 + @as(usize, @intCast(blksize))].ptr, blksize);
                    if (linux.errno(got_data) != .SUCCESS) break :sentinel;
                    const cnt: usize = @intCast(got_data);
                    if (cnt < blksize) finished = true;
                    std.mem.writeInt(u16, buf[0..2], DATA, .big);
                    std.mem.writeInt(u16, buf[2..4], block, .big);
                    sent_len = 4 + cnt;
                    block +%= 1;
                } else {
                    break :sentinel;
                }
            }
            retries = 12;
            wait_ms = 100;
            _ = sock.send(fd, buf[0..sent_len], 0) catch {};
            continue;
        }
    }
    return true;
}

pub fn tftpMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const opts = n.opts("tftp", args, "gpl:r:b:m:", &.{});
    const pos = opts.args;

    const get_flag = (opts.flags & 1) != 0;
    const put_flag = (opts.flags & 2) != 0;
    if (get_flag == put_flag) n.usageDie("tftp");

    // Attached forms such as -b63 are accepted by getopt32 as well.
    var local_file = cu.optionValue(args, 1, args.len, 'l', null, "gp");
    var remote_file = cu.optionValue(args, 1, args.len, 'r', null, "gp");
    const blksize_text = cu.optionValue(args, 1, args.len, 'b', null, "gp") orelse "512";

    const blksize = checkBlocksize(blksize_text) orelse return 1;

    if (remote_file) |rf| {
        if (local_file == null) {
            local_file = std.fs.path.basename(rf);
        }
    } else {
        remote_file = local_file;
    }
    if (remote_file == null or pos.len == 0) n.usageDie("tftp");

    const host = pos[0];
    const port = cu.lookupPort(if (pos.len >= 2) pos[1] else null, "udp", 69);
    if (!cu.isNumericHost(host)) n.plainDie("bad address '{s}'", .{host});

    var local_fd: ?linux.fd_t = null;
    if (put_flag) {
        const path = local_file.?;
        const p = n.zstr(path) catch return 1;
        const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(rc) != .SUCCESS) {
            n.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{path});
            return 1;
        }
        local_fd = @intCast(rc);
    }
    defer {
        if (local_fd) |lf| _ = linux.close(lf);
    }

    const sfd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (linux.errno(sfd) != .SUCCESS) {
        n.errorMsg(@intFromEnum(linux.errno(sfd)), "socket", .{});
        return 1;
    }
    const fd: linux.fd_t = @intCast(sfd);
    defer _ = linux.close(fd);
    var addr = sock.sockaddr_in(host, port);
    const conn = linux.connect(fd, @ptrCast(&addr), @sizeOf(sock.sockaddr.in));
    if (linux.errno(conn) != .SUCCESS) {
        n.errorMsg(@intFromEnum(linux.errno(conn)), "connect", .{});
        return 1;
    }

    const ok = transfer(fd, get_flag, local_fd, local_file, remote_file.?, blksize);
    return if (ok) 0 else 1;
}
