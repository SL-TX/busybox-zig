//! tc — traffic control (networking/tc.c).
//!
//! The show/list path is real: an RTM_GETQDISC/RTM_GETTCLASS/RTM_GETTFILTER
//! netlink dump request is sent, the reply messages are parsed (nlmsghdr +
//! tcmsg + rtnetlink attributes) and each qdisc/class row is formatted exactly
//! like print_qdisc()/print_class() in the reference.  This works as non-root.
//!
//! The row formatter is a pure function (`formatQdisc` / `formatClass`) so it
//! can be unit-tested with synthetic netlink dump buffers without needing a
//! tc-enabled reference binary.

const std = @import("std");
const n = @import("netcommon.zig");
const linux = std.os.linux;

pub const NLMSG_HDRLEN: usize = 16;
pub const TCMSG_LEN: usize = 16;
pub const RTM_NEWQDISC: u16 = 36;
pub const RTM_DELQDISC: u16 = 37;
pub const RTM_GETQDISC: u16 = 38;
pub const RTM_NEWTCLASS: u16 = 40;
pub const RTM_DELTCLASS: u16 = 41;
pub const RTM_GETTCLASS: u16 = 42;
pub const RTM_NEWTFILTER: u16 = 44;
pub const RTM_DELTFILTER: u16 = 45;
pub const RTM_GETTFILTER: u16 = 46;

const NLMSG_DONE: u16 = 3;
const NLMSG_ERROR: u16 = 2;
const NLM_F_REQUEST: u16 = 0x1;
const NLM_F_DUMP: u16 = 0x300;
const TCA_KIND: u16 = 1;
const TCA_OPTIONS: u16 = 2;
const TCA_PRIO_MQ: u16 = 1;
pub const TC_H_ROOT: u32 = 0xffffffff;

fn align4(x: usize) usize { return (x + 3) & ~@as(usize, 3); }

/// One parsed rtnetlink message carrying a tcmsg (qdisc/class/filter).
pub const Message = struct {
    typ: u16,
    family: u8,
    ifindex: u32,
    handle: u32,
    parent: u32,
    info: u32,
    kind: []const u8,
    options: ?[]const u8,
};

pub const Parsed = struct { msg: Message, next: usize };

/// Parse the nlmsghdr + tcmsg + attributes at `off` of a dump buffer.
pub fn parseMessage(raw: []const u8, off: usize) ?Parsed {
    if (off + NLMSG_HDRLEN + TCMSG_LEN > raw.len) return null;
    const len: usize = std.mem.readInt(u32, raw[off..][0..4], .little);
    if (len < NLMSG_HDRLEN + TCMSG_LEN or off + len > raw.len) return null;
    const typ = std.mem.readInt(u16, raw[off + 4 ..][0..2], .little);
    const base = off + NLMSG_HDRLEN;

    // struct tcmsg: family(u8), pad(u8), ifindex(u16), handle/parent/info(u32).
    const family = raw[base];
    const ifindex: u32 = std.mem.readInt(u16, raw[base + 2 ..][0..2], .little);
    const handle = std.mem.readInt(u32, raw[base + 4 ..][0..4], .little);
    const parent = std.mem.readInt(u32, raw[base + 8 ..][0..4], .little);
    const info = std.mem.readInt(u32, raw[base + 12 ..][0..4], .little);

    var kind: []const u8 = "";
    var options: ?[]const u8 = null;
    var ao = base + TCMSG_LEN; // TCA_RTA(msg)
    const attr_end = off + len;
    while (ao + 4 <= attr_end) {
        const alen: usize = std.mem.readInt(u16, raw[ao..][0..2], .little);
        if (alen < 4 or ao + alen > attr_end) break;
        const atyp = std.mem.readInt(u16, raw[ao + 2 ..][0..2], .little) & 0x3fff;
        const data = raw[ao + 4 .. ao + alen];
        if (atyp == TCA_KIND) {
            const z = std.mem.indexOfScalar(u8, data, 0) orelse data.len;
            kind = data[0..z];
        } else if (atyp == TCA_OPTIONS) {
            options = data;
        }
        ao += align4(alen);
    }
    return .{ .msg = .{
        .typ = typ, .family = family, .ifindex = ifindex,
        .handle = handle, .parent = parent, .info = info,
        .kind = kind, .options = options,
    }, .next = off + align4(len) };
}

/// print_tc_classid(): "none", ":min", "maj:", or "maj:min" (all hex).
pub fn classId(cid: u32, buf: []u8) []const u8 {
    if (cid == 0) return "none";
    const maj = (cid & 0xffff0000) >> 16;
    const min = cid & 0xffff;
    if (maj == 0) return std.fmt.bufPrint(buf, ":{x}", .{min}) catch "";
    if (min == 0) return std.fmt.bufPrint(buf, "{x}:", .{maj}) catch "";
    return std.fmt.bufPrint(buf, "{x}:{x}", .{ maj, min }) catch "";
}

fn put(out: *std.ArrayList(u8), s: []const u8) void {
    out.appendSlice(n.A, s) catch {};
}
fn putFmt(out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
    var b: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    put(out, s);
}

/// prio_print_opt(): "bands N priomap N N ... [multiqueue: on/off]".
fn prioPrint(out: *std.ArrayList(u8), opt: []const u8) void {
    if (opt.len == 0) return;
    const bands = opt[0];
    putFmt(out, "bands {d} priomap ", .{bands});
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const v: u8 = if (opt.len > 1 + i) opt[1 + i] else 0;
        putFmt(out, " {d}", .{v});
    }
    // parse_rtattr_nested_compat(): nested attrs start at RTA_ALIGN(sizeof qopt)
    // where sizeof(struct tc_prio_qopt) == 17 -> aligned to 20.
    var ao: usize = 20;
    if (opt.len >= 24) {
        while (ao + 4 <= opt.len) {
            const alen: usize = std.mem.readInt(u16, opt[ao..][0..2], .little);
            if (alen < 4 or ao + alen > opt.len) break;
            const atyp = std.mem.readInt(u16, opt[ao + 2 ..][0..2], .little) & 0x3fff;
            if (atyp == TCA_PRIO_MQ and alen > 4) {
                putFmt(out, " multiqueue: o{s} ", .{if (opt[ao + 4] != 0) "n" else "ff"});
            }
            ao += align4(alen);
        }
    }
}

fn optionsFor(out: *std.ArrayList(u8), kind: []const u8, opt: []const u8) void {
    if (std.mem.eql(u8, kind, "pfifo_fast") or std.mem.eql(u8, kind, "prio")) {
        prioPrint(out, opt);
    } else {
        putFmt(out, "(options for {s})", .{kind});
    }
}

/// Format one qdisc row exactly like reference print_qdisc().
/// `dev` is the resolved interface name; `filter_ifindex != 0` suppresses the
/// "dev NAME" column (matching `tc qdisc show dev IFACE`).
pub fn formatQdisc(out: *std.ArrayList(u8), m: Message, dev: []const u8, filter_ifindex: u32) void {
    if (m.typ != RTM_NEWQDISC and m.typ != RTM_DELQDISC) return;
    if (filter_ifindex != 0 and filter_ifindex != m.ifindex) return;
    if (m.kind.len == 0) return;

    if (m.typ == RTM_DELQDISC) put(out, "deleted ");
    putFmt(out, "qdisc {s} {x}: ", .{ m.kind, m.handle >> 16 });
    if (filter_ifindex == 0) putFmt(out, "dev {s} ", .{dev});
    if (m.parent == TC_H_ROOT) {
        put(out, "root ");
    } else if (m.parent != 0) {
        var cbuf: [32]u8 = undefined;
        putFmt(out, "parent {s} ", .{classId(m.parent, &cbuf)});
    }
    if (m.info != 1) putFmt(out, "refcnt {d} ", .{m.info});
    if (m.options) |opt| optionsFor(out, m.kind, opt);
    put(out, "\n");
}

/// Format one class row exactly like reference print_class().
pub fn formatClass(out: *std.ArrayList(u8), m: Message, dev: []const u8, filter_ifindex: u32, filter_qdisc: u32) void {
    if (m.typ != RTM_NEWTCLASS and m.typ != RTM_DELTCLASS) return;
    if (filter_qdisc != 0 and ((m.handle ^ filter_qdisc) & 0xffff0000) != 0) return;
    if (m.kind.len == 0) return;

    if (m.typ == RTM_DELTCLASS) put(out, "deleted ");
    var hbuf: [32]u8 = undefined;
    const cid = if (m.handle != 0)
        classId(if (filter_qdisc != 0) m.handle & 0xffff else m.handle, &hbuf)
    else
        "(null)";
    putFmt(out, "class {s} {s} ", .{ m.kind, cid });
    if (filter_ifindex == 0) putFmt(out, "dev {s} ", .{dev});
    if (m.parent == TC_H_ROOT) {
        put(out, "root ");
    } else if (m.parent != 0) {
        var pbuf: [32]u8 = undefined;
        putFmt(out, "parent {s} ", .{classId(if (filter_qdisc != 0) m.parent & 0xffff else m.parent, &pbuf)});
    }
    if (m.info != 0) putFmt(out, "leaf {x} ", .{m.info >> 16});
    if (m.options) |opt| optionsFor(out, m.kind, opt);
    put(out, "\n");
}

// ---------------------------------------------------------------- netlink I/O

/// Send an RTM_GET* dump request with a zeroed tcmsg and collect the reply.
fn netlinkDump(msg_type: u16) ?[]u8 {
    const fd = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW, linux.NETLINK.ROUTE);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));

    var addr: linux.sockaddr.nl = std.mem.zeroes(linux.sockaddr.nl);
    addr.family = linux.AF.NETLINK;
    if (linux.errno(linux.bind(@intCast(fd), @ptrCast(&addr), @sizeOf(linux.sockaddr.nl))) != .SUCCESS) return null;

    var req: [NLMSG_HDRLEN + TCMSG_LEN]u8 = std.mem.zeroes([NLMSG_HDRLEN + TCMSG_LEN]u8);
    std.mem.writeInt(u32, req[0..4], req.len, .little);
    std.mem.writeInt(u16, req[4..6], msg_type, .little);
    std.mem.writeInt(u16, req[6..8], NLM_F_REQUEST | NLM_F_DUMP, .little);
    std.mem.writeInt(u32, req[8..12], 1, .little);
    // tcmsg.tcm_family stays AF_UNSPEC (0), like the reference.

    const sent = linux.write(@intCast(fd), &req, req.len);
    if (linux.errno(sent) != .SUCCESS or sent < req.len) return null;

    var tv = linux.timeval{ .sec = 1, .usec = 0 };
    _ = linux.setsockopt(@intCast(fd), linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(n.A);
    var buf: [65536]u8 = undefined;
    while (true) {
        const got = linux.read(@intCast(fd), &buf, buf.len);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        const count: usize = @intCast(got);
        out.appendSlice(n.A, buf[0..count]) catch return null;
        // Stop at NLMSG_DONE / NLMSG_ERROR in this chunk.
        var off: usize = 0;
        while (off + NLMSG_HDRLEN <= count) {
            const l: usize = std.mem.readInt(u32, buf[off..][0..4], .little);
            const t = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            if (t == NLMSG_DONE or t == NLMSG_ERROR) return out.toOwnedSlice(n.A) catch null;
            if (l < NLMSG_HDRLEN or off + l > count) break;
            off += align4(l);
        }
    }
    if (out.items.len == 0) return null;
    return out.toOwnedSlice(n.A) catch null;
}

fn ifindexByName(name: []const u8) u32 {
    var pathbuf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "/sys/class/net/{s}/ifindex", .{name}) catch return 0;
    const data = n.readWholeFile(path) catch return 0;
    defer n.A.free(data);
    return std.fmt.parseInt(u32, std.mem.trim(u8, data, " \t\n"), 10) catch 0;
}

fn nameByIfindex(wanted: u32, buf: []u8) []const u8 {
    const zpath = n.zstr("/sys/class/net") catch return "unknown";
    const fd = linux.open(zpath, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return "unknown";
    defer _ = linux.close(@intCast(fd));

    var dents: [4096]u8 align(8) = undefined;
    const got = linux.getdents64(@intCast(fd), &dents, dents.len);
    if (linux.errno(got) != .SUCCESS) return "unknown";
    var off: usize = 0;
    while (off + @offsetOf(linux.dirent64, "name") <= @as(usize, @intCast(got))) {
        const dent: *const linux.dirent64 = @ptrCast(@alignCast(dents[off..].ptr));
        if (dent.reclen == 0) break;
        const name_len = dent.reclen - @offsetOf(linux.dirent64, "name");
        const raw = dents[off + @offsetOf(linux.dirent64, "name") ..][0..name_len];
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        const ifname = raw[0..end];
        off += dent.reclen;
        if (ifname.len == 0 or std.mem.eql(u8, ifname, ".") or std.mem.eql(u8, ifname, "..")) continue;
        var pathbuf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&pathbuf, "/sys/class/net/{s}/ifindex", .{ifname}) catch continue;
        const data = n.readWholeFile(path) catch continue;
        defer n.A.free(data);
        const ix = std.fmt.parseInt(u32, std.mem.trim(u8, data, " \t\n"), 10) catch continue;
        if (ix == wanted) return std.fmt.bufPrint(buf, "{s}", .{ifname}) catch "unknown";
    }
    return "unknown";
}

/// Dump and print qdisc/class rows. `obj` uses the reference OBJ_* numbering.
pub fn dumpAndPrint(obj: u8, filter_ifindex: u32, filter_qdisc: u32) c_int {
    const msg_type: u16 = switch (obj) {
        0 => RTM_GETQDISC,
        1 => RTM_GETTCLASS,
        else => RTM_GETTFILTER,
    };
    const raw = netlinkDump(msg_type) orelse {
        n.errorMsg(1, "can't send dump request", .{});
        return 1;
    };
    defer n.A.free(raw);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(n.A);
    var namebuf: [128]u8 = undefined;
    var off: usize = 0;
    while (off + NLMSG_HDRLEN <= raw.len) {
        const len: usize = std.mem.readInt(u32, raw[off..][0..4], .little);
        const typ = std.mem.readInt(u16, raw[off + 4 ..][0..2], .little);
        if (typ == NLMSG_DONE or len < NLMSG_HDRLEN or off + len > raw.len) break;
        if (parseMessage(raw, off)) |entry| {
            const dev = nameByIfindex(entry.msg.ifindex, &namebuf);
            if (obj == 0) {
                formatQdisc(&out, entry.msg, dev, filter_ifindex);
            } else if (obj == 1) {
                formatClass(&out, entry.msg, dev, filter_ifindex, filter_qdisc);
            }
            // print_filter() in the reference is a no-op.
        }
        off += align4(len);
    }
    n.out(out.items);
    return 0;
}

// ------------------------------------------------------------------- argument parsing

const objects = [_][]const u8{ "qdisc", "class", "filter" };
const commands = [_][]const u8{ "add", "delete", "change", "link", "replace", "show", "list" };
const keywords = [_][]const u8{ "dev", "root", "parent", "qdisc", "handle", "classid", "preference", "priority", "protocol", "ingress" };

fn indexOf(s: []const u8, set: []const []const u8) isize {
    for (set, 0..) |v, i| if (std.mem.eql(u8, s, v)) return @intCast(i);
    return -1;
}

fn invarg(arg: []const u8, to: []const u8) noreturn {
    n.plain("invalid argument '{s}' to '{s}'", .{ arg, to });
    std.process.exit(1);
}

/// Parse a handle/classid of the form MAJ:MIN or bare hex into a TC handle.
fn parseHandle(text: []const u8) ?u32 {
    if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
        const maj = std.fmt.parseInt(u32, text[0..colon], 16) catch return null;
        const min = std.fmt.parseInt(u32, text[colon + 1 ..], 16) catch return null;
        return (maj << 16) | (min & 0xffff);
    }
    return std.fmt.parseInt(u32, text, 16) catch null;
}

pub const ParsedArgs = struct {
    obj: u8,
    cmd: isize,
    filter_ifindex: u32 = 0,
    filter_qdisc: u32 = 0,
};

/// Pure argument parser (no netlink). `resolve_iface` maps a `dev` name to an
/// index; injecting it keeps default-command / full-command-set tests possible.
pub fn parseArgs(
    args: []const []const u8,
    resolve_iface: *const fn ([]const u8) u32,
) !ParsedArgs {
    if (args.len < 2) return error.Usage;
    const obj = indexOf(args[1], &objects);
    if (obj < 0) return error.Usage;

    var i: usize = 2;
    var cmd: isize = 5; // CMD_show is the default (list is an alias).
    if (i < args.len) {
        cmd = indexOf(args[i], &commands);
        if (cmd < 0) return error.BadCommand;
        i += 1;
    }

    var filter_ifindex: u32 = 0;
    var filter_qdisc: u32 = 0;
    while (i < args.len) {
        const kw = indexOf(args[i], &keywords);
        if (kw < 0) return error.BadArgument;
        if (i + 1 >= args.len) return error.BadArgument;
        const val = args[i + 1];
        switch (kw) {
            0 => filter_ifindex = resolve_iface(val), // dev
            3, 4 => filter_qdisc = parseHandle(val) orelse return error.BadHandle, // qdisc / handle
            else => {}, // root/parent/classid/preference/priority/protocol/ingress
        }
        i += 2;
    }
    return .{
        .obj = @intCast(obj),
        .cmd = cmd,
        .filter_ifindex = filter_ifindex,
        .filter_qdisc = filter_qdisc,
    };
}

pub fn tcMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = parseArgs(args, ifindexByName) catch |err| switch (err) {
        error.Usage => n.usageDie("tc"),
        error.BadCommand => invarg(args[2], args[1]),
        error.BadArgument => invarg(if (args.len > 2) args[args.len - 1] else "?", "command"),
        error.BadHandle => invarg("handle", "qdisc"),
    };

    if (parsed.cmd >= 5) return dumpAndPrint(parsed.obj, parsed.filter_ifindex, parsed.filter_qdisc);
    // BusyBox tc accepts add/delete/change/link/replace argument syntax but
    // performs no netlink change operation (see tc_main in the reference).
    return 0;
}
