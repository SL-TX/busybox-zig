const std = @import("std");
const getopt = @import("libbb_zig").getopt;
const Options = getopt.Options;
const LongOpt = getopt.LongOpt;

const Case = struct {
    name: []const u8,
    argv: []const []const u8,
    optstring: []const u8,
    longopts: []const LongOpt = &.{},
    flags: u32,
    optarg: ?[]const u8 = null,
    index: usize,
    args: []const []const u8 = &.{},
};

fn check(c: Case) !void {
    const opts = try getopt.getopt32(c.argv, c.optstring, c.longopts);
    try std.testing.expectEqual(c.flags, opts.flags);
    try std.testing.expectEqual(c.index, opts.index);
    if (c.optarg) |want| {
        try std.testing.expect(opts.optarg != null);
        try std.testing.expectEqualStrings(want, opts.optarg.?);
    } else {
        try std.testing.expect(opts.optarg == null);
    }
    try std.testing.expectEqual(c.args.len, opts.args.len);
    for (c.args, opts.args) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "getopt32: clustered short flags" {
    try check(.{
        .name = "-abc",
        .argv = &.{ "prog", "-abc" },
        .optstring = "abc",
        .flags = 0b111,
        .index = 2,
    });
}

test "getopt32: required arg as separate token" {
    try check(.{
        .name = "-o val",
        .argv = &.{ "prog", "-o", "val" },
        .optstring = "o:",
        .flags = 1,
        .optarg = "val",
        .index = 3,
    });
}

test "getopt32: required arg attached" {
    try check(.{
        .name = "-oval",
        .argv = &.{ "prog", "-oval" },
        .optstring = "o:",
        .flags = 1,
        .optarg = "val",
        .index = 2,
    });
}

test "getopt32: flag bit positions skip ':'" {
    try check(.{
        .name = "-c with a:b:c",
        .argv = &.{ "prog", "-c" },
        .optstring = "a:b:c",
        .flags = 0b100,
        .index = 2,
    });
}

test "getopt32: argument embedded in a cluster" {
    try check(.{
        .name = "-abval",
        .argv = &.{ "prog", "-abval" },
        .optstring = "ab:",
        .flags = 0b11,
        .optarg = "val",
        .index = 2,
    });
}

test "getopt32: long option with no argument" {
    try check(.{
        .name = "--long",
        .argv = &.{ "prog", "--long" },
        .optstring = "",
        .longopts = &.{.{ .name = "long", .val = 'l' }},
        .flags = 1,
        .index = 2,
    });
}

test "getopt32: long option with = argument" {
    try check(.{
        .name = "--long=val",
        .argv = &.{ "prog", "--long=val" },
        .optstring = "",
        .longopts = &.{.{ .name = "long", .has_arg = .required, .val = 'l' }},
        .flags = 1,
        .optarg = "val",
        .index = 2,
    });
}

test "getopt32: long option with separate argument" {
    try check(.{
        .name = "--long val",
        .argv = &.{ "prog", "--long", "val" },
        .optstring = "",
        .longopts = &.{.{ .name = "long", .has_arg = .required, .val = 'l' }},
        .flags = 1,
        .optarg = "val",
        .index = 3,
    });
}

test "getopt32: long option reuses the matching short flag bit" {
    try check(.{
        .name = "--all -> bit of 'a'",
        .argv = &.{ "prog", "--all" },
        .optstring = "ab",
        .longopts = &.{.{ .name = "all", .val = 'a' }},
        .flags = 0b01,
        .index = 2,
    });
}

test "getopt32: long option unique abbreviation" {
    try check(.{
        .name = "--verb",
        .argv = &.{ "prog", "--verb" },
        .optstring = "",
        .longopts = &.{
            .{ .name = "verbose", .val = 'v' },
            .{ .name = "version", .val = 'V' },
        },
        .flags = 0b01,
        .index = 2,
    });
}

test "getopt32: optional short argument attached only" {
    try check(.{
        .name = "-oval",
        .argv = &.{ "prog", "-oval" },
        .optstring = "o::",
        .flags = 1,
        .optarg = "val",
        .index = 2,
    });
    try check(.{
        .name = "-o with optional arg absent",
        .argv = &.{ "prog", "-o", "val" },
        .optstring = "o::",
        .flags = 1,
        .index = 2,
        .args = &.{"val"},
    });
}

test "getopt32: optional long argument" {
    try check(.{
        .name = "--long=val",
        .argv = &.{ "prog", "--long=val" },
        .optstring = "",
        .longopts = &.{.{ .name = "long", .has_arg = .optional, .val = 'l' }},
        .flags = 1,
        .optarg = "val",
        .index = 2,
    });
    try check(.{
        .name = "--long",
        .argv = &.{ "prog", "--long" },
        .optstring = "",
        .longopts = &.{.{ .name = "long", .has_arg = .optional, .val = 'l' }},
        .flags = 1,
        .index = 2,
    });
}

test "getopt32: -- terminates option processing" {
    try check(.{
        .name = "--",
        .argv = &.{ "prog", "--", "a", "-b" },
        .optstring = "ab",
        .flags = 0,
        .index = 2,
        .args = &.{ "a", "-b" },
    });
}

test "getopt32: '+' stops at the first non-option" {
    try check(.{
        .name = "+a",
        .argv = &.{ "prog", "-a", "file", "-b" },
        .optstring = "+a",
        .flags = 1,
        .index = 2,
        .args = &.{ "file", "-b" },
    });
}

test "getopt32: GNU permutation of trailing options" {
    try check(.{
        .name = "permute",
        .argv = &.{ "prog", "file", "-a" },
        .optstring = "a",
        .flags = 1,
        .index = 2,
        .args = &.{"file"},
    });
    try check(.{
        .name = "permute with two positionals around an option",
        .argv = &.{ "prog", "one", "-a", "two" },
        .optstring = "a",
        .flags = 1,
        .index = 2,
        .args = &.{ "one", "two" },
    });
}

test "getopt32: optarg is cleared by a following no-argument option" {
    const opts = try getopt.getopt32(&.{ "prog", "-o", "val", "-a" }, "oa", &.{});
    try std.testing.expectEqual(@as(u32, 0b11), opts.flags);
    try std.testing.expect(opts.optarg == null);
}

test "getopt32: unknown short option is an error" {
    try std.testing.expectError(error.InvalidOption, getopt.getopt32(&.{ "prog", "-x" }, "a", &.{}));
}

test "getopt32: missing required argument is an error" {
    try std.testing.expectError(error.MissingArgument, getopt.getopt32(&.{ "prog", "-o" }, "o:", &.{}));
}

test "getopt32: unknown long option is an error" {
    try std.testing.expectError(error.InvalidOption, getopt.getopt32(&.{ "prog", "--nope" }, "", &.{.{ .name = "long", .val = 'l' }}));
}

test "argsToSlices converts the applet C argv" {
    const words = [_][]const u8{ "prog", "-n", "5" };
    var owned: [3][:0]u8 = undefined;
    var ptrs: [3][*:0]const u8 = undefined;
    for (words, 0..) |w, i| {
        owned[i] = try std.testing.allocator.dupeSentinel(u8, w, 0);
        ptrs[i] = owned[i].ptr;
    }
    defer for (owned) |s| std.testing.allocator.free(s);
    const slices = try getopt.argsToSlices(std.testing.allocator, &ptrs, 3);
    defer std.testing.allocator.free(slices);
    try std.testing.expectEqual(@as(usize, 3), slices.len);
    try std.testing.expectEqualStrings("prog", slices[0]);
    try std.testing.expectEqualStrings("-n", slices[1]);
    try std.testing.expectEqualStrings("5", slices[2]);
}
