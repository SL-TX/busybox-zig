//! Focused unit tests for the Task 13c `tc` fix.
//!
//! The comparison reference binary has CONFIG_TC=n, so the differential `tc`
//! cases are SKIP-gated. These tests make the qdisc display path test-visible
//! by feeding synthetic rtnetlink dump buffers to the real parser/formatter.

const std = @import("std");
const tc = @import("networking").tc;

fn put16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}
fn put32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
fn aligned(x: usize) usize { return (x + 3) & ~@as(usize, 3); }

/// Build one nlmsghdr + tcmsg + TCA_KIND(/TCA_OPTIONS) message.
fn makeMessage(buf: []u8, typ: u16, ifindex: u16, handle: u32, parent: u32, info: u32,
    kind: []const u8, options: ?[]const u8) []const u8
{
    const hlen = tc.NLMSG_HDRLEN;
    const tlen = tc.TCMSG_LEN;
    var off = hlen + tlen;

    // TCA_KIND
    const kind_payload = aligned(kind.len + 1);
    const kind_attr_len = 4 + kind_payload;
    @memset(buf[off .. off + kind_attr_len], 0);
    put16(buf, off, @intCast(kind_attr_len));
    put16(buf, off + 2, 1); // TCA_KIND
    @memcpy(buf[off + 4 .. off + 4 + kind.len], kind);
    off += kind_attr_len;

    if (options) |opt| {
        const opt_attr_len = 4 + opt.len;
        @memset(buf[off .. off + opt_attr_len], 0);
        put16(buf, off, @intCast(opt_attr_len));
        put16(buf, off + 2, 2); // TCA_OPTIONS
        @memcpy(buf[off + 4 .. off + 4 + opt.len], opt);
        off += aligned(opt_attr_len);
    }

    put32(buf, 0, @intCast(off)); // nlmsg_len
    put16(buf, 4, typ);
    put16(buf, 6, 0x301); // REQUEST | DUMP
    put32(buf, 8, 1); // seq

    // tcmsg: family(u8), pad(u8), ifindex(u16), handle, parent, info
    @memset(buf[hlen .. hlen + tlen], 0);
    buf[hlen] = 0; // AF_UNSPEC
    put16(buf, hlen + 2, ifindex);
    put32(buf, hlen + 4, handle);
    put32(buf, hlen + 8, parent);
    put32(buf, hlen + 12, info);
    return buf[0..off];
}

fn format(m: tc.Message, dev: []const u8, filter_ifindex: u32) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    tc.formatQdisc(&out, m, dev, filter_ifindex);
    return out.items;
}

test "tc parseMessage decodes nlmsghdr, tcmsg and TCA_KIND" {
    var buf: [512]u8 = undefined;
    const raw = makeMessage(&buf, tc.RTM_NEWQDISC, 1, 0x00010000, tc.TC_H_ROOT, 1, "pfifo_fast", null);
    const parsed = tc.parseMessage(raw, 0).?;
    try std.testing.expectEqual(@as(u16, tc.RTM_NEWQDISC), parsed.msg.typ);
    try std.testing.expectEqual(@as(u32, 1), parsed.msg.ifindex);
    try std.testing.expectEqual(@as(u32, 0x00010000), parsed.msg.handle);
    try std.testing.expectEqual(@as(u32, tc.TC_H_ROOT), parsed.msg.parent);
    try std.testing.expectEqual(@as(u32, 1), parsed.msg.info);
    try std.testing.expectEqualStrings("pfifo_fast", parsed.msg.kind);
    try std.testing.expect(parsed.msg.options == null);
}

test "tc qdisc row: root pfifo_fast on lo" {
    var buf: [512]u8 = undefined;
    const raw = makeMessage(&buf, tc.RTM_NEWQDISC, 1, 0x00010000, tc.TC_H_ROOT, 1, "pfifo_fast", null);
    const m = tc.parseMessage(raw, 0).?.msg;
    try std.testing.expectEqualStrings("qdisc pfifo_fast 1: dev lo root \n", format(m, "lo", 0));
}

test "tc qdisc row: parent classid and refcnt" {
    var buf: [512]u8 = undefined;
    const raw = makeMessage(&buf, tc.RTM_NEWQDISC, 2, 0x00020000, 0x0001000a, 3, "fq_codel", null);
    const m = tc.parseMessage(raw, 0).?.msg;
    try std.testing.expectEqualStrings(
        "qdisc fq_codel 2: dev eth0 parent 1:a refcnt 3 \n",
        format(m, "eth0", 0),
    );
}

test "tc qdisc row: deleted qdisc with no parent" {
    var buf: [512]u8 = undefined;
    const raw = makeMessage(&buf, tc.RTM_DELQDISC, 2, 0x00030000, 0, 1, "noqueue", null);
    const m = tc.parseMessage(raw, 0).?.msg;
    try std.testing.expectEqualStrings("deleted qdisc noqueue 3: dev eth0 \n", format(m, "eth0", 0));
}

test "tc qdisc row: dev filter suppresses the dev column" {
    var buf: [512]u8 = undefined;
    const raw = makeMessage(&buf, tc.RTM_NEWQDISC, 1, 0x00010000, tc.TC_H_ROOT, 1, "pfifo_fast", null);
    const m = tc.parseMessage(raw, 0).?.msg;
    try std.testing.expectEqualStrings("qdisc pfifo_fast 1: root \n", format(m, "lo", 1));
    // A different filter_ifindex hides the row entirely.
    try std.testing.expectEqualStrings("", format(m, "lo", 2));
}

test "tc qdisc row: unknown-kind options fallback" {
    var buf: [512]u8 = undefined;
    const opt = [_]u8{ 3, 1, 2, 2, 1, 2, 0, 0 };
    const raw = makeMessage(&buf, tc.RTM_NEWQDISC, 1, 0x00010000, tc.TC_H_ROOT, 1, "fq_codel", &opt);
    const m = tc.parseMessage(raw, 0).?.msg;
    try std.testing.expectEqualStrings(
        "qdisc fq_codel 1: dev lo root (options for fq_codel)\n",
        format(m, "lo", 0),
    );
}

test "tc qdisc row: pfifo_fast priomap and multiqueue options" {
    var buf: [512]u8 = undefined;
    // struct tc_prio_qopt: bands(u8) + priomap[16], then a nested rtattr for MQ.
    var opt: [28]u8 = std.mem.zeroes([28]u8);
    opt[0] = 3; // bands
    const priomap = [_]u8{ 1, 2, 2, 2, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    @memcpy(opt[1..17], &priomap);
    // nested TCA_PRIO_MQ at offset 20: len=5, type=1, value=1 (on)
    put16(&opt, 20, 5);
    put16(&opt, 22, 1);
    opt[24] = 1;
    const raw = makeMessage(&buf, tc.RTM_NEWQDISC, 1, 0x00010000, tc.TC_H_ROOT, 1, "prio", &opt);
    const m = tc.parseMessage(raw, 0).?.msg;
    try std.testing.expectEqualStrings(
        "qdisc prio 1: dev lo root bands 3 priomap  1 2 2 2 1 2 0 0 0 0 0 0 0 0 0 0 multiqueue: on \n",
        format(m, "lo", 0),
    );
}

test "tc parseMessage walks a multi-message dump buffer" {
    var buf: [1024]u8 = undefined;
    const first = makeMessage(buf[0..512], tc.RTM_NEWQDISC, 1, 0x00010000, tc.TC_H_ROOT, 1, "pfifo_fast", null);
    const next_index = tc.parseMessage(first, 0).?.next;
    const second = makeMessage(buf[next_index..], tc.RTM_NEWQDISC, 2, 0x00020000, tc.TC_H_ROOT, 1, "noqueue", null);
    const p2 = tc.parseMessage(buf[0..], next_index).?;
    try std.testing.expectEqualStrings("noqueue", p2.msg.kind);
    try std.testing.expectEqual(@as(u32, 2), p2.msg.ifindex);
    _ = second;
}

test "tc print_tc_classid formatting" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("none", tc.classId(0, &b));
    try std.testing.expectEqualStrings(":a", tc.classId(0x0000000a, &b));
    try std.testing.expectEqualStrings("1:", tc.classId(0x00010000, &b));
    try std.testing.expectEqualStrings("1:a", tc.classId(0x0001000a, &b));
}

test "tc class row: handle/parent/leaf" {
    var buf: [512]u8 = undefined;
    const raw = makeMessage(&buf, tc.RTM_NEWTCLASS, 1, 0x0001000a, 0x00010001, 0x00020000, "htb", null);
    const m = tc.parseMessage(raw, 0).?.msg;
    var out: std.ArrayList(u8) = .empty;
    tc.formatClass(&out, m, "lo", 0, 0);
    try std.testing.expectEqualStrings("class htb 1:a dev lo parent 1:1 leaf 2 \n", out.items);
}

fn fakeIfindex(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "lo")) return 1;
    if (std.mem.eql(u8, name, "eth0")) return 2;
    return 0;
}

test "tc argument parser: show is the default command" {
    const parsed = try tc.parseArgs(&.{ "tc", "qdisc" }, fakeIfindex);
    try std.testing.expectEqual(@as(u8, 0), parsed.obj);
    try std.testing.expectEqual(@as(isize, 5), parsed.cmd);
}

test "tc argument parser: full documented object and command set" {
    // Objects qdisc/class/filter.
    try std.testing.expectEqual(@as(u8, 0), (try tc.parseArgs(&.{ "tc", "qdisc", "show" }, fakeIfindex)).obj);
    try std.testing.expectEqual(@as(u8, 1), (try tc.parseArgs(&.{ "tc", "class", "show" }, fakeIfindex)).obj);
    try std.testing.expectEqual(@as(u8, 2), (try tc.parseArgs(&.{ "tc", "filter", "show" }, fakeIfindex)).obj);
    // Commands add/delete/change/link/replace/show/list (list == show+1).
    const cmds = [_][]const u8{ "add", "delete", "change", "link", "replace", "show", "list" };
    for (cmds, 0..) |c, i| {
        const p = try tc.parseArgs(&.{ "tc", "qdisc", c }, fakeIfindex);
        try std.testing.expectEqual(@as(isize, @intCast(i)), p.cmd);
    }
}

test "tc argument parser: dev, handle and invalid inputs" {
    const p = try tc.parseArgs(&.{ "tc", "class", "show", "dev", "eth0", "handle", "1:a" }, fakeIfindex);
    try std.testing.expectEqual(@as(u32, 2), p.filter_ifindex);
    try std.testing.expectEqual(@as(u32, 0x0001000a), p.filter_qdisc);
    try std.testing.expectError(error.Usage, tc.parseArgs(&.{"tc"}, fakeIfindex));
    try std.testing.expectError(error.Usage, tc.parseArgs(&.{ "tc", "bogus" }, fakeIfindex));
    try std.testing.expectError(error.BadCommand, tc.parseArgs(&.{ "tc", "qdisc", "bogus" }, fakeIfindex));
    try std.testing.expectError(error.BadArgument, tc.parseArgs(&.{ "tc", "qdisc", "show", "dev" }, fakeIfindex));
}
