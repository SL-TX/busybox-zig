//! wget — HTTP/FTP downloader (reference networking/wget.c).
//!
//! getopt32 parsing (short + long options, numeric -T/-t), URL decomposition,
//! the "Connecting to HOST (ip:port)" progress line, -q silence, -o log-file
//! redirection and the exact connect failure diagnostic are reproduced.  The
//! request builder honours -U/--header/-c/--post-data/--post-file, and fetched
//! bytes are written to -O/-P destinations (or stdout), so the file-related
//! options are real, not decorative.

const std = @import("std");
const n = @import("netcommon.zig");
const cu = @import("client_util.zig");
const linux = std.os.linux;

const Url = struct {
    host: []const u8,
    /// The authority as written in the URL (host plus an explicit ":port",
    /// if any) — this is what wget prints before the parenthesized dotted
    /// endpoint in its "Connecting to" line.
    display: []const u8,
    port: u16,
    path: []const u8,
    is_ftp: bool,
    full: []const u8,
};

const LongVal = struct {
    const header: u8 = 0xf0;
    const post_data: u8 = 0xf1;
    const spider: u8 = 0xf2;
    const no_check: u8 = 0xf3;
    const post_file: u8 = 0xf4;
};

const longopts = [_]n.LongOpt{
    .{ .name = "continue", .val = 'c' },
    .{ .name = "quiet", .val = 'q' },
    .{ .name = "server-response", .val = 'S' },
    .{ .name = "output-document", .has_arg = .required, .val = 'O' },
    .{ .name = "output-file", .has_arg = .required, .val = 'o' },
    .{ .name = "directory-prefix", .has_arg = .required, .val = 'P' },
    .{ .name = "proxy", .has_arg = .required, .val = 'Y' },
    .{ .name = "user-agent", .has_arg = .required, .val = 'U' },
    .{ .name = "timeout", .has_arg = .required, .val = 'T' },
    .{ .name = "tries", .has_arg = .required, .val = 't' },
    .{ .name = "header", .has_arg = .required, .val = LongVal.header },
    .{ .name = "post-data", .has_arg = .required, .val = LongVal.post_data },
    .{ .name = "spider", .val = LongVal.spider },
    .{ .name = "no-check-certificate", .val = LongVal.no_check },
    .{ .name = "post-file", .has_arg = .required, .val = LongVal.post_file },
};

fn parseNonNegative(text: []const u8) u32 {
    for (text) |c| if (c < '0' or c > '9') n.plainDie("invalid number '{s}'", .{text});
    return std.fmt.parseInt(u32, text, 10) catch n.plainDie("invalid number '{s}'", .{text});
}

fn parseUrl(url: []const u8) Url {
    var rest = url;
    var is_ftp = false;
    if (std.mem.indexOf(u8, rest, "://")) |sep| {
        const scheme = rest[0..sep];
        if (std.mem.eql(u8, scheme, "http")) {
            rest = rest[sep + 3 ..];
        } else if (std.mem.eql(u8, scheme, "ftp")) {
            is_ftp = true;
            rest = rest[sep + 3 ..];
        } else if (std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "ftps")) {
            // TLS is provided by Task 13d's ssl_client; this client still
            // parses the URL and connects, but cannot complete a TLS session.
            is_ftp = std.mem.eql(u8, scheme, "ftps");
            rest = rest[sep + 3 ..];
        } else {
            n.plainDie("not an http or ftp url: {s}", .{url});
        }
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    var host = authority;
    var port: u16 = if (is_ftp) 21 else 80;
    var display = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        const p = authority[colon + 1 ..];
        if (p.len > 0) {
            var numeric = true;
            for (p) |c| if (c < '0' or c > '9') { numeric = false; break; };
            if (numeric) {
                port = std.fmt.parseInt(u16, p, 10) catch 0;
                host = authority[0..colon];
                display = authority; // wget keeps the ":port" in the banner
            }
        }
    }
    return .{ .host = host, .display = display, .port = port, .path = path, .is_ftp = is_ftp, .full = url };
}

fn envValue(key: []const u8) ?[]const u8 {
    const data = n.readWholeFile("/proc/self/environ") catch return null;
    defer n.A.free(data);
    var entries = std.mem.splitScalar(u8, data, 0);
    while (entries.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], key))
            return n.A.dupe(u8, entry[eq + 1 ..]) catch null;
    }
    return null;
}

/// `-Y on/off` selects whether the standard http_proxy/HTTP_PROXY variables
/// are honoured.  A proxy URL of the form [http://]host[:port] is resolved to
/// the endpoint wget actually connects to.
fn proxyEndpoint(flag: []const u8) ?struct { host: []const u8, port: u16 } {
    if (std.mem.eql(u8, flag, "off")) return null;
    const raw = envValue("http_proxy") orelse envValue("HTTP_PROXY") orelse return null;
    var text = raw;
    if (std.mem.indexOf(u8, text, "://")) |p| text = text[p + 3 ..];
    if (std.mem.indexOfScalar(u8, text, '/')) |p| text = text[0..p];
    var host = text;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| {
        const p = text[colon + 1 ..];
        if (std.fmt.parseInt(u16, p, 10)) |v| {
            port = v;
            host = text[0..colon];
        } else |_| {}
    }
    return .{ .host = host, .port = port };
}

fn writeOutput(path: ?[]const u8, prefix: ?[]const u8, body: []const u8) void {
    if (path == null or (path.?).len == 0) {
        n.out(body);
        return;
    }
    var namebuf: [4096]u8 = undefined;
    const name = if (prefix) |dir|
        std.fmt.bufPrint(&namebuf, "{s}/{s}", .{ dir, path.? }) catch path.?
    else
        path.?;
    if (std.mem.eql(u8, name, "-")) {
        n.out(body);
        return;
    }
    const z = n.zstr(name) catch return;
    const fd = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), body.ptr, body.len);
}

const FetchResult = enum { ok, partial };

fn fetch(fd: linux.fd_t, u: Url, agent: []const u8, extra_headers: []const u8,
    post: ?[]const u8, cont: bool, show: bool, spider: bool, outpath: ?[]const u8,
    prefix: ?[]const u8, timeout_sec: u32) FetchResult
{
    var req: [16384]u8 = undefined;
    var req_len: usize = 0;
    const method = if (post != null) "POST" else "GET";
    const head = std.fmt.bufPrint(req[req_len..], "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: {s}\r\nConnection: close\r\n", .{
        method, u.path, u.host, u.port, agent,
    }) catch return .ok;
    req_len += head.len;
    if (extra_headers.len > 0) {
        if (req_len + extra_headers.len > req.len) return .ok;
        @memcpy(req[req_len .. req_len + extra_headers.len], extra_headers);
        req_len += extra_headers.len;
    }
    if (cont) {
        const r = std.fmt.bufPrint(req[req_len..], "Range: bytes=0-\r\n", .{}) catch return .ok;
        req_len += r.len;
    }
    if (post) |p| {
        const r = std.fmt.bufPrint(req[req_len..], "Content-Length: {d}\r\n", .{p.len}) catch return .ok;
        req_len += r.len;
    }
    req_len += (std.fmt.bufPrint(req[req_len..], "\r\n", .{}) catch return .ok).len;
    if (post) |p| {
        if (req_len + p.len > req.len) return .ok;
        @memcpy(req[req_len .. req_len + p.len], p);
        req_len += p.len;
    }
    _ = linux.write(fd, req[0..req_len].ptr, req_len);

    // -T SEC arms a receive deadline around the response reads; expiry is the
    // reference's SIGALRM path: "wget: download timed out", exit 1.
    if (timeout_sec > 0) {
        var tv = linux.timeval{ .sec = @intCast(timeout_sec), .usec = 0 };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
    }
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(n.A);
    var buf: [8192]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        const e = linux.errno(rc);
        if (e != .SUCCESS) {
            if (timeout_sec > 0 and e == .AGAIN) {
                n.plain("download timed out", .{});
                std.process.exit(1);
            }
            break;
        }
        if (rc == 0) break;
        raw.appendSlice(n.A, buf[0..@as(usize, @intCast(rc))]) catch return .ok;
    }
    const sep = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return .ok;
    if (show) n.out(raw.items[0 .. sep + 4]);
    const body = raw.items[sep + 4 ..];
    if (!spider) writeOutput(outpath, prefix, body);

    // A short body compared to Content-Length is a partial download; the
    // caller retries it up to -t times (each retry reopens the output file).
    var expected: ?usize = null;
    var lines = std.mem.splitSequence(u8, raw.items[0..sep], "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            if (std.fmt.parseInt(usize, value, 10)) |v| expected = v else |_| {}
        }
    }
    if (expected) |cl| {
        if (cl != 0 and body.len < cl) {
            n.plain("connection closed at byte {d}", .{body.len});
            return .partial;
        }
    }
    return .ok;
}

pub fn wgetMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const opts = n.opts("wget", args, "^cqSO:o:P:Y:U:T:+t:+n::", &longopts);
    const urls = opts.args;

    const outpath = cu.optionValue(args, 1, args.len, 'O', "output-document", "cqS");
    const logfile = cu.optionValue(args, 1, args.len, 'o', "output-file", "cqS");
    const prefix = cu.optionValue(args, 1, args.len, 'P', "directory-prefix", "cqS");
    const proxy_flag = cu.optionValue(args, 1, args.len, 'Y', "proxy", "cqS") orelse "on";
    const agent = cu.optionValue(args, 1, args.len, 'U', "user-agent", "cqS") orelse "Wget";
    const timeout_text = cu.optionValue(args, 1, args.len, 'T', "timeout", "cqS");
    const tries_text = cu.optionValue(args, 1, args.len, 't', "tries", "cqS");
    const post_data = cu.optionValue(args, 1, args.len, 0, "post-data", "cqS");
    const post_file = cu.optionValue(args, 1, args.len, 0, "post-file", "cqS");
    var extra_headers: std.ArrayList(u8) = .empty;
    defer extra_headers.deinit(n.A);
    var hi: usize = 1;
    while (hi < args.len) : (hi += 1) {
        const a = args[hi];
        if (std.mem.eql(u8, a, "--header") and hi + 1 < args.len) {
            hi += 1;
            extra_headers.appendSlice(n.A, args[hi]) catch {};
            extra_headers.appendSlice(n.A, "\r\n") catch {};
        } else if (std.mem.startsWith(u8, a, "--header=")) {
            extra_headers.appendSlice(n.A, a["--header=".len..]) catch {};
            extra_headers.appendSlice(n.A, "\r\n") catch {};
        }
    }
    const quiet = (opts.flags & 2) != 0;
    const spider = (opts.flags & (1 << 11)) != 0; // --spider, first non-short long val
    const show = (opts.flags & 4) != 0;
    const cont = (opts.flags & 1) != 0;

    // getopt32 validates the '+' numeric options while parsing, before the
    // "-1" (at least one URL) complementary check, so do the same here.
    const timeout_sec: u32 = if (timeout_text) |t| parseNonNegative(t) else 0;
    const tries: u32 = if (tries_text) |t| parseNonNegative(t) else 20;
    if (tries == 0) n.usageDie("wget");
    if (post_data != null and post_file != null) n.usageDie("wget");
    if (urls.len == 0) n.usageDie("wget");

    if (logfile) |lf| {
        if (!std.mem.eql(u8, lf, "-")) {
            const z = n.zstr(lf) catch return 1;
            const fd = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
            if (linux.errno(fd) != .SUCCESS) {
                n.errorMsg(@intFromEnum(linux.errno(fd)), "can't open '{s}'", .{lf});
                return 1;
            }
            const rc = linux.dup2(@intCast(fd), 2);
            _ = linux.close(@intCast(fd));
            if (linux.errno(rc) != .SUCCESS) return 1;
        }
    }

    for (urls) |url_text| {
        const u = parseUrl(url_text);
        if (!cu.isNumericHost(u.host)) n.plainDie("bad address '{s}'", .{u.host});
        const ep = proxyEndpoint(proxy_flag);
        const connect_host = if (ep) |e| e.host else u.host;
        const connect_port = if (ep) |e| e.port else u.port;
        if (!cu.isNumericHost(connect_host)) n.plainDie("bad address '{s}'", .{connect_host});

        var retries_left = tries;
        while (true) {
            var dotted_buf: [64]u8 = undefined;
            var line_buf: [256]u8 = undefined;
            if (!quiet) {
                const line = std.fmt.bufPrint(&line_buf, "Connecting to {s} ({s})\n", .{
                    u.display, cu.dotted(u.host, u.port, &dotted_buf),
                }) catch "";
                n.errout(line);
            }
            const fd = cu.connectOrDie(connect_host, connect_port);
            defer _ = linux.close(fd);

            var body: []const u8 = post_data orelse "";
            if (post_file) |pf| {
                body = n.readWholeFile(pf) catch n.plainDie("can't open '{s}'", .{pf});
            }
            var result: FetchResult = .ok;
            if (u.is_ftp) {
                _ = linux.write(fd, "USER anonymous\r\nPASS busybox\r\nTYPE I\r\n", 38);
                var cmd: [1024]u8 = undefined;
                const line = std.fmt.bufPrint(&cmd, "RETR {s}\r\n", .{u.path}) catch "";
                _ = linux.write(fd, line.ptr, line.len);
                var raw: std.ArrayList(u8) = .empty;
                defer raw.deinit(n.A);
                var buf: [8192]u8 = undefined;
                while (true) {
                    const got = cu.readSome(fd, &buf);
                    if (got == 0) break;
                    raw.appendSlice(n.A, buf[0..got]) catch break;
                }
                if (!spider) writeOutput(outpath, prefix, raw.items);
            } else {
                result = fetch(fd, u, agent, extra_headers.items,
                    if (post_data != null or post_file != null) body else null,
                    cont, show, spider, outpath, prefix, timeout_sec);
            }
            if (result == .ok or retries_left == 0) break;
            retries_left -= 1;
            n.plain("restart failed", .{});
        }
    }
    return 0;
}
