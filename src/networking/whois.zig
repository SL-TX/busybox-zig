//! whois — WHOIS directory client (reference networking/whois.c).
//!
//! The command line is `^ih:p:+` with at least one NAME.  -h sets the server,
//! -p the port (no range check, exactly like the reference), -i requests that
//! redirect responses be printed too.  Each name prints the exact
//! `[Querying host:port 'name']` banner and terminates with the reference
//! connect diagnostic; the response parser follows "Whois Server:" redirects.

const std = @import("std");
const n = @import("netcommon.zig");
const cu = @import("client_util.zig");
const linux = std.os.linux;

fn parseNonNegative(text: []const u8) u32 {
    for (text) |c| if (c < '0' or c > '9') n.plainDie("invalid number '{s}'", .{text});
    return std.fmt.parseInt(u32, text, 10) catch n.plainDie("invalid number '{s}'", .{text});
}

const Query = struct {
    host: []const u8,
    port: u32,
    domain: []const u8,
    prefix: []const u8,
    show_redirects: bool,
    redirect: ?[]const u8 = null,
};

fn query(q: *Query) void {
    n.put("[Querying {s}:{d} '{s}{s}']\n", .{ q.host, q.port, q.prefix, q.domain });
    const fd = cu.connectOrDie(q.host, @truncate(q.port));
    defer _ = linux.close(fd);
    var request: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&request, "{s}{s}\r\n", .{ q.prefix, q.domain }) catch return;
    _ = cu.sendAll(fd, line);

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(n.A);
    var buf: [8192]u8 = undefined;
    while (response.items.len < 32 * 1024) {
        const got = cu.readSome(fd, &buf);
        if (got == 0) break;
        response.appendSlice(n.A, buf[0..got]) catch break;
    }

    var success = false;
    var redir: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, response.items, '\n');
    while (lines.next()) |raw_line| {
        const line_t = std.mem.trim(u8, raw_line, " \t\r");
        if (!success) {
            if (std.ascii.startsWithIgnoreCase(line_t, "domain:") or
                std.ascii.startsWithIgnoreCase(line_t, "domain name:"))
                success = true;
        } else if (redir == null) {
            var rest: ?[]const u8 = null;
            if (std.ascii.startsWithIgnoreCase(line_t, "whois server:")) {
                rest = line_t["whois server:".len..];
            } else if (std.ascii.startsWithIgnoreCase(line_t, "whois:")) {
                rest = line_t["whois:".len..];
            }
            if (rest) |r| redir = std.mem.trim(u8, r, " \t");
        }
    }
    if (!success and q.prefix.len == 0) {
        q.prefix = "domain ";
        response.clearRetainingCapacity();
        query(q); // retry with the "domain " prefix
        return;
    }
    if (redir) |r| {
        if (std.mem.eql(u8, r, q.host)) redir = null;
    }
    if (redir == null or q.show_redirects) {
        n.put("[{s}]\n{s}", .{ q.host, response.items });
    }
    q.redirect = redir;
}

fn recursive(host_in: []const u8, port: u32, domain: []const u8, show: bool) void {
    var host = host_in;
    var port_v = port;
    while (true) {
        var q = Query{
            .host = host,
            .port = port_v,
            .domain = domain,
            .prefix = "",
            .show_redirects = show,
        };
        query(&q);
        if (q.redirect) |r| {
            n.put("[Redirected to {s}]\n", .{r});
            host = r;
            port_v = 43;
            continue;
        }
        break;
    }
}

pub fn whoisMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const opts = n.opts("whois", args, "^ih:p:+", &.{});
    const names = opts.args;
    if (names.len == 0) n.usageDie("whois");

    var host: []const u8 = "whois.iana.org";
    var port: u32 = 43;
    var show_redirects = false;
    if (cu.optionValue(args, 1, args.len, 'h', null, "i")) |h| host = h;
    if (cu.optionValue(args, 1, args.len, 'p', null, "i")) |p| port = parseNonNegative(p);
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-i") or (a.len > 2 and a[0] == '-' and std.mem.indexOfScalar(u8, a[1..], 'i') != null))
            show_redirects = true;
    }

    for (names) |name| recursive(host, port, name, show_redirects);
    return 0;
}
