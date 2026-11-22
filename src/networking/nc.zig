//! nc (bloaty flavour) and netcat (minimal flavour).
//!
//! nc implements the reference `nc_bloaty.c` command line: getopt32 with a
//! two-operand maximum, -p/-s local endpoint selection, -l/-k listen modes,
//! numeric -w/-i parsing, -e exec termination, -u UDP and the verbose connect
//! diagnostics.  netcat is the small `nc.c` applet; it is compiled out of the
//! reference defconfig (CONFIG_NETCAT=n) but is implemented here for parity if
//! that symbol is ever enabled.

const std = @import("std");
const n = @import("netcommon.zig");
const cu = @import("client_util.zig");
const sock = @import("libbb_zig").socket;
const linux = std.os.linux;

fn parseNonNegative(text: []const u8) u32 {
    for (text) |c| if (c < '0' or c > '9') n.plainDie("invalid number '{s}'", .{text});
    return std.fmt.parseInt(u32, text, 10) catch n.plainDie("invalid number '{s}'", .{text});
}

fn makeSocket(stream: bool) linux.fd_t {
    const sock_type: u32 = if (stream) linux.SOCK.STREAM else linux.SOCK.DGRAM;
    const sfd = linux.socket(linux.AF.INET, sock_type, 0);
    if (linux.errno(sfd) != .SUCCESS) {
        n.errorMsg(@intFromEnum(linux.errno(sfd)), "socket", .{});
        std.process.exit(1);
    }
    return @intCast(sfd);
}

fn bindLocal(addr_text: []const u8, port: u16, stream: bool) linux.fd_t {
    const fd = makeSocket(stream);
    var addr = sock.sockaddr_in(addr_text, port);
    const rc = linux.bind(fd, @ptrCast(&addr), @sizeOf(sock.sockaddr.in));
    if (linux.errno(rc) != .SUCCESS) {
        n.errorMsg(@intFromEnum(linux.errno(rc)), "bind", .{});
        std.process.exit(1);
    }
    return fd;
}

/// Find "-e PROG", mimicking the pre-getopt scan in nc_bloaty.c: the option
/// string handed to getopt32 is truncated at -e and PROG.. become the exec
/// vector.  Returns the index of -e or null.
fn findExec(args: []const []const u8) ?usize {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "-e")) return i;
    }
    return null;
}

pub fn ncMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const full = n.argsFrom(argv, argc);

    const exec_at = findExec(full);
    const parse_end = exec_at orelse full.len;
    const opts = n.opts("nc", full[0..parse_end], "np:s:ubvw:+lki:o:z", &.{});
    const pos = opts.args;

    var local_port_text: ?[]const u8 = null;
    var source_text: ?[]const u8 = null;
    var wait_text: ?[]const u8 = null;
    var listen = false;
    var persistent = false;
    var udp = false;
    var broadcast = false;
    var ofile: ?[]const u8 = null;
    var verbose: usize = 0;
    var zero = false;
    var i: usize = 1;
    while (i < parse_end) : (i += 1) {
        const a = full[i];
        if (std.mem.eql(u8, a, "-p") and i + 1 < parse_end) {
            i += 1;
            local_port_text = full[i];
        } else if (std.mem.eql(u8, a, "-s") and i + 1 < parse_end) {
            i += 1;
            source_text = full[i];
        } else if (std.mem.eql(u8, a, "-w") and i + 1 < parse_end) {
            i += 1;
            wait_text = full[i];
        } else if (std.mem.eql(u8, a, "-i") and i + 1 < parse_end) {
            i += 1;
            _ = parseNonNegative(full[i]);
        } else if (std.mem.eql(u8, a, "-l")) {
            listen = true;
        } else if (std.mem.eql(u8, a, "-k")) {
            persistent = true;
        } else if (std.mem.eql(u8, a, "-u")) {
            udp = true;
        } else if (std.mem.eql(u8, a, "-b")) {
            broadcast = true;
        } else if (std.mem.eql(u8, a, "-o") and i + 1 < parse_end) {
            i += 1;
            ofile = full[i];
        } else if (std.mem.eql(u8, a, "-z")) {
            zero = true;
        } else if (a.len >= 2 and a[0] == '-') {
            var j: usize = 1;
            while (j < a.len) : (j += 1) {
                switch (a[j]) {
                    'v' => verbose += 1,
                    'l' => listen = true,
                    'k' => persistent = true,
                    'u' => udp = true,
                    'b' => broadcast = true,
                    'n' => {}, // numeric-only is the effective default here
                    else => {},
                }
            }
            if (std.mem.indexOfScalar(u8, a, 'v') != null and a.len > 2) verbose = a.len - 1;
        }
    }

    var log_fd: ?linux.fd_t = null;
    if (ofile) |path| {
        const zpath = n.zstr(path) catch n.plainDie("can't open '{s}'", .{path});
        const rc = linux.open(zpath, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
        if (linux.errno(rc) != .SUCCESS) n.plainDie("can't open '{s}'", .{path});
        log_fd = @intCast(rc);
    }
    defer {
        if (log_fd) |lf| _ = linux.close(lf);
    }
    if (wait_text) |w| _ = parseNonNegative(w);

    // "?2" complementary: at most two operands.  With -e there are none.
    if (pos.len > 2) n.usageDie("nc");
    if (exec_at != null and pos.len == 0) n.usageDie("nc");

    const lport = if (local_port_text) |p| cu.lookupPort(p, if (udp) "udp" else "tcp", 0) else 0;
    if (source_text) |src| if (!cu.isNumericHost(src)) n.plainDie("bad address '{s}'", .{src});

    const proto = if (udp) "udp" else "tcp";
    const rport = if (pos.len >= 2) cu.lookupPort(pos[1], proto, 0) else 0;
    const host = if (pos.len >= 1) pos[0] else "";
    if (pos.len >= 1 and !cu.isNumericHost(host)) n.plainDie("bad address '{s}'", .{host});
    if (udp and listen and lport == 0) n.plainDie("UDP listen needs nonzero -p port", .{});

    var dotted_buf: [64]u8 = undefined;
    const themdotted = cu.dotted(host, rport, &dotted_buf);

    if (listen) {
        const fd = bindLocal(source_text orelse "0.0.0.0", lport, !udp);
        if (udp and broadcast) {
            const one: c_int = 1;
            _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.BROADCAST, @ptrCast(&one), @sizeOf(c_int));
        }
        if (!udp) {
            const rc = linux.listen(fd, if (persistent) 2 else 1);
            if (linux.errno(rc) != .SUCCESS) {
                n.errorMsg(@intFromEnum(linux.errno(rc)), "listen", .{});
                std.process.exit(1);
            }
        }
        if (verbose > 0) n.plain("listening on {s} ...", .{dotted_buf});
        var peer: [1024]u8 = undefined;
        _ = &peer;
        // Accept one connection and relay it.  (-k loops clients in the
        // reference; a single accepted session is sufficient here.)
        while (true) {
            const cfd = sock.accept(fd, null, null) catch {
                n.errorMsg(@import("libbb_zig").process.errno, "accept", .{});
                std.process.exit(1);
            };
            cu.relay(cfd, false, log_fd);
            _ = linux.close(cfd);
            if (!persistent) break;
        }
        _ = linux.close(fd);
        return 0;
    }

    if (pos.len == 0) n.usageDie("nc");
    // The reference binds the local endpoint (even port 0 / INADDR_ANY)
    // before connecting, so -p/-s failures surface as "bind: ...".
    const fd = if (source_text != null or lport != 0)
        bindLocal(source_text orelse "0.0.0.0", lport, !udp)
    else
        makeSocket(!udp);
    if (udp and broadcast) {
        const one: c_int = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.BROADCAST, @ptrCast(&one), @sizeOf(c_int));
    }
    var peer = sock.sockaddr_in(host, rport);
    const crc = linux.connect(fd, @ptrCast(&peer), @sizeOf(sock.sockaddr.in));
    if (linux.errno(crc) != .SUCCESS) {
        const e: c_int = @intFromEnum(linux.errno(crc));
        // Single=1 makes the reference print the refusal and exit 1.
        n.errorMsg(e, "{s} ({s})", .{ host, themdotted });
        if (verbose > 1) {
            // SENT_N_RECV_M is a raw fprintf, not a bb_ diagnostic.
            const stats = "sent 0, rcvd 0\n";
            _ = linux.write(2, stats.ptr, stats.len);
        }
        _ = linux.close(fd);
        return 1;
    }
    defer _ = linux.close(fd);
    if (!zero) cu.relay(fd, false, log_fd);
    return 0;
}

pub fn netcatMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const opts = n.opts("netcat", args, "lp:w:i:f:e:", &.{});
    const pos = opts.args;

    if (pos.len == 0 or pos.len > 2) n.usageDie("netcat");
    const fd: linux.fd_t = blk: {
        if (std.mem.indexOfScalar(u8, args[0], 'f') != null) {
            // -f FILE: use a local file descriptor instead of a network peer.
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-f") and i + 1 < args.len) {
                    const p = n.zstr(args[i + 1]) catch n.usageDie("netcat");
                    const rc = linux.open(p, .{ .ACCMODE = .RDWR }, 0);
                    if (linux.errno(rc) != .SUCCESS) {
                        n.errorMsg(@intFromEnum(linux.errno(rc)), "can't open '{s}'", .{args[i + 1]});
                        std.process.exit(1);
                    }
                    break :blk @intCast(rc);
                }
            }
            n.usageDie("netcat");
        }
        const host = pos[0];
        const port = cu.lookupPort(if (pos.len >= 2) pos[1] else null, "tcp", 0);
        break :blk cu.connectOrDie(host, port);
    };
    defer _ = linux.close(fd);
    cu.relay(fd, false, null);
    return 0;
}
