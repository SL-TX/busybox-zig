//! `getopt32` — the universal option parser from busybox libbb/getopt32.c.
//!
//! The option bit for a short option is its position (ignoring ':' modifiers)
//! in the optstring, exactly as in the reference. Long options reuse the bit
//! of their `val` when it is also a short option, otherwise they get the next
//! free bit. Parsing follows GNU getopt: options may be permuted ahead of
//! positional arguments unless the optstring starts with '+'.
//!
//! Because the public signature carries no allocator, the returned `args`
//! slice points at a module-local static buffer. It is valid until the next
//! call to getopt32 (BusyBox similarly permutes argv in place and is
//! single-threaded). Callers that need to keep it should copy it.

const std = @import("std");
const messages = @import("messages.zig");

pub const Arg = enum { none, required, optional };
pub const LongOpt = struct { name: []const u8, has_arg: Arg = .none, val: u8 };
pub const Options = struct {
    flags: u32,
    index: usize,
    optarg: ?[]const u8,
    args: []const []const u8,
};

pub const GetoptError = error{
    InvalidOption,
    MissingArgument,
    InvalidLongOption,
    AmbiguousOption,
    TooManyOptions,
};

/// Convert the `[*][*:0]const u8` argv applets receive into the
/// `[]const []const u8` form getopt32 expects. This is the only conversion
/// applets need; they must not reimplement it.
pub fn argsToSlices(allocator: std.mem.Allocator, argv: [*][*:0]const u8, argc: usize) ![][]const u8 {
    const out = try allocator.alloc([]const u8, argc);
    for (0..argc) |i| out[i] = std.mem.span(argv[i]);
    return out;
}

var args_store: [1024][]const u8 = undefined;

const OptInfo = struct { ch: u8, bit: u5, arg: Arg };
const LongInfo = struct { name: []const u8, bit: u5, arg: Arg };

fn findShort(infos: []const OptInfo, ch: u8) ?OptInfo {
    for (infos) |info| if (info.ch == ch) return info;
    return null;
}

fn stripPrefixes(input: []const u8, stop_at_nonopt: *bool) []const u8 {
    var s = input;
    if (s.len > 0 and s[0] == '^') s = s[1..]; // opt_complementary follows NUL
    if (s.len > 0 and s[0] == '!') s = s[1..]; // "don't die" (we always return an error)
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        stop_at_nonopt.* = s[0] == '+';
        s = s[1..];
    }
    return s;
}

/// Build the short-option table. Returns the number of option bits used by
/// plain short options so long options without a short twin can continue.
fn buildShorts(os: []const u8, infos: []OptInfo) !usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < os.len) {
        if (os[i] == ':') { // defensive: stray separator
            i += 1;
            continue;
        }
        const ch = os[i];
        i += 1;
        var arg: Arg = .none;
        if (i < os.len and os[i] == ':') {
            arg = .required;
            i += 1;
            if (i < os.len and os[i] == ':') {
                arg = .optional;
                i += 1;
            }
            // "o:+" (non-negative int) and "o:*" (list) are sink modifiers;
            // they do not change parsing, only how the caller stores optarg.
            if (i < os.len and (os[i] == '+' or os[i] == '*')) i += 1;
        }
        if (n >= infos.len) return error.TooManyOptions;
        infos[n] = .{ .ch = ch, .bit = @intCast(n), .arg = arg };
        n += 1;
    }
    return n;
}

fn buildLongs(longopts: []const LongOpt, shorts: []const OptInfo, nshort: usize, out: []LongInfo) !usize {
    var n: usize = 0;
    var next_bit: usize = nshort;
    for (longopts) |lo| {
        if (findShort(shorts, lo.val)) |si| {
            out[n] = .{ .name = lo.name, .bit = si.bit, .arg = lo.has_arg };
        } else {
            if (next_bit >= 32) return error.TooManyOptions;
            out[n] = .{ .name = lo.name, .bit = @intCast(next_bit), .arg = lo.has_arg };
            next_bit += 1;
        }
        n += 1;
    }
    return n;
}

/// GNU getopt_long accepts an unambiguous prefix of a long option name.
fn findLong(infos: []const LongInfo, name: []const u8) ?LongInfo {
    for (infos) |info| if (std.mem.eql(u8, info.name, name)) return info;
    var found: ?LongInfo = null;
    for (infos) |info| {
        if (std.mem.startsWith(u8, info.name, name)) {
            if (found != null) return null; // caller reports ambiguity
            found = info;
        }
    }
    return found;
}

fn isAmbiguous(infos: []const LongInfo, name: []const u8) bool {
    var count: usize = 0;
    for (infos) |info| {
        if (std.mem.startsWith(u8, info.name, name)) count += 1;
    }
    return count > 1;
}

pub fn getopt32(argv: []const []const u8, optstring: []const u8, longopts: []const LongOpt) !Options {
    var opts = Options{ .flags = 0, .index = if (argv.len == 0) 0 else 1, .optarg = null, .args = &.{} };
    var stop_at_nonopt = false;
    const os = stripPrefixes(optstring, &stop_at_nonopt);

    var shorts: [32]OptInfo = undefined;
    const nshort = try buildShorts(os, &shorts);
    var longs: [64]LongInfo = undefined;
    const nlong = try buildLongs(longopts, shorts[0..nshort], nshort, &longs);

    var npos: usize = 0;
    var consumed: usize = 0; // argv slots eaten as options (and their args)
    var end_of_options = false;
    var i: usize = 1;

    while (i < argv.len) : (i += 1) {
        const tok = argv[i];
        if (end_of_options) {
            if (npos >= args_store.len) return error.TooManyOptions;
            args_store[npos] = tok;
            npos += 1;
            continue;
        }
        if (tok.len < 2 or tok[0] != '-') {
            if (stop_at_nonopt) {
                while (i < argv.len) : (i += 1) {
                    if (npos >= args_store.len) return error.TooManyOptions;
                    args_store[npos] = argv[i];
                    npos += 1;
                }
                break;
            }
            if (npos >= args_store.len) return error.TooManyOptions;
            args_store[npos] = tok;
            npos += 1;
            continue;
        }
        if (std.mem.eql(u8, tok, "--")) {
            consumed += 1;
            end_of_options = true;
            continue;
        }
        if (tok[1] == '-') {
            consumed += 1;
            opts.optarg = null;
            const body = tok[2..];
            const eqpos = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eqpos) |p| body[0..p] else body;
            const attached: ?[]const u8 = if (eqpos) |p| body[p + 1 ..] else null;

            if (isAmbiguous(longs[0..nlong], name)) {
                messages.plainMsg("option '--{s}' is ambiguous", .{name});
                return error.AmbiguousOption;
            }
            const info = findLong(longs[0..nlong], name) orelse {
                messages.plainMsg("unrecognized option '--{s}'", .{name});
                return error.InvalidOption;
            };
            opts.flags |= @as(u32, 1) << info.bit;
            switch (info.arg) {
                .none => {
                    if (attached != null) {
                        messages.plainMsg("option '--{s}' doesn't allow an argument", .{name});
                        return error.InvalidOption;
                    }
                    opts.optarg = null;
                },
                .required => {
                    if (attached) |a| {
                        opts.optarg = a;
                    } else if (i + 1 < argv.len) {
                        i += 1;
                        consumed += 1;
                        opts.optarg = argv[i];
                    } else {
                        messages.plainMsg("option '--{s}' requires an argument", .{name});
                        return error.MissingArgument;
                    }
                },
                .optional => opts.optarg = attached,
            }
            continue;
        }

        consumed += 1;
        opts.optarg = null;
        short_loop: while (true) {
            var j: usize = 1;
            // j is tracked inside the loop below; the label exists so a
            // required/optional argument can leave the cluster.
            while (j < tok.len) : (j += 1) {
                const ch = tok[j];
                const info = findShort(shorts[0..nshort], ch) orelse {
                    messages.plainMsg("invalid option -- '{c}'", .{ch});
                    return error.InvalidOption;
                };
                opts.flags |= @as(u32, 1) << info.bit;
                switch (info.arg) {
                    .none => {},
                    .required => {
                        if (j + 1 < tok.len) {
                            opts.optarg = tok[j + 1 ..];
                        } else if (i + 1 < argv.len) {
                            i += 1;
                            consumed += 1;
                            opts.optarg = argv[i];
                        } else {
                            messages.plainMsg("option requires an argument -- '{c}'", .{ch});
                            return error.MissingArgument;
                        }
                        break :short_loop;
                    },
                    .optional => {
                        opts.optarg = if (j + 1 < tok.len) tok[j + 1 ..] else null;
                        break :short_loop;
                    },
                }
            }
            break;
        }
    }

    opts.index = 1 + consumed;
    opts.args = args_store[0..npos];
    return opts;
}
