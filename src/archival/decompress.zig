//! Compression/decompression applets for the archival wave.
//!
//! gzip, gunzip, zcat, bzip2, bunzip2, bzcat, xz, unxz, xzcat, lzma,
//! unlzma, lzcat, lzop, unlzop and lzopcat share one driver. All codecs come
//! from the Task 19 pure-Zig helpers; this file implements the BusyBox CLI.

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");

const compression = bb.compression;

/// Bit index of `ch` in a getopt32 option string (colons/modifiers ignored).
fn bitFor(comptime os: []const u8, comptime ch: u8) u5 {
    var bit: usize = 0;
    var i: usize = 0;
    while (i < os.len) : (i += 1) {
        if (os[i] == ':' or os[i] == '+' or os[i] == '-' or os[i] == '!') continue;
        if (os[i] == ch) return @intCast(bit);
        bit += 1;
        if (i + 1 < os.len and os[i + 1] == ':') {
            i += 1;
            if (i + 1 < os.len and os[i + 1] == ':') i += 1;
        }
    }
    // An option absent from this applet's optstring can never be set; return
    // an unused high bit so `flagged()` evaluates to false.
    return 31;
}

pub const Codec = enum {
    gzip,
    bzip2,
    xz,
    lzma,
    lzop,
};

fn compressData(codec: Codec, data: []const u8, level: u4) ![]u8 {
    return switch (codec) {
        .gzip => compression.gzip.gzipCompress(c.A, data),
        .bzip2 => compression.bzip2.compress(c.A, data, level),
        .xz => compression.xz.compress(c.A, data),
        .lzma => compression.lzma.compress(c.A, data),
        .lzop => compression.lzop.compress(c.A, data, level),
    };
}

/// Decompress and report errors in the reference's idiom. xz errors are
/// non-fatal (BusyBox emits nothing and succeeds), so they yield empty output.
fn decompressOrEmpty(codec: Codec, data: []const u8) ![]u8 {
    return decompressData(codec, data) catch |e| {
        if (reportCodecError(codec, e, data)) return e;
        return c.A.alloc(u8, 0) catch error.OutOfMemory;
    };
}

fn decompressData(codec: Codec, data: []const u8) ![]u8 {
    return switch (codec) {
        .gzip => compression.gzip.decompress(c.A, data),
        .bzip2 => compression.bzip2.decompress(c.A, data),
        .xz => compression.xz.decompress(c.A, data),
        .lzma => compression.lzma.decompress(c.A, data),
        .lzop => compression.lzop.decompress(c.A, data),
    };
}

/// Report a codec error and return whether it is fatal. BusyBox's xz reader
/// silently ignores data that is not an xz stream, so those errors are not
/// fatal here.
fn reportCodecError(codec: Codec, err: anyerror, data: []const u8) bool {
    switch (codec) {
        .gzip => switch (err) {
            error.BadMagic, error.BadHeader => c.msg("invalid magic", .{}),
            else => c.msg("corrupted data", .{}),
        },
        .bzip2 => switch (err) {
            error.BadMagic, error.BadHeader, error.Truncated => c.msg("invalid magic", .{}),
            else => c.msg("corrupted data", .{}),
        },
        .lzma => {
            // A plausible props byte means the header was accepted and the
            // stream ran out; an obviously foreign magic is a bad header.
            if (data.len >= 13 and data[0] < 225)
                c.msg("unexpected EOF", .{})
            else {
                switch (err) {
                    error.BadMagic, error.BadHeader, error.CorruptInput => c.msg("bad lzma header", .{}),
                    error.Truncated => c.msg("bad lzma header", .{}),
                    else => c.msg("corrupted data", .{}),
                }
            }
        },
        .xz => return false,
        .lzop => {
            if (data.len < 9)
                c.msg("short read", .{})
            else if (!std.mem.eql(u8, data[0..9], &.{ 0x89, 'L', 'Z', 'O', 0, 0x0d, 0x0a, 0x1a, 0x0a }))
                c.msg("bad magic number", .{})
            else if (err == error.Truncated)
                c.msg("short read", .{})
            else
                c.msg("corrupted data", .{});
        },
    }
    return true;
}

const Config = struct {
    /// Applet name used for diagnostics/usage.
    name: []const u8,
    codec: Codec,
    optstring: []const u8,
    /// Default action when neither -d nor an implicit decompress name applies.
    default_decompress: bool,
    /// true for xz/lzma: BusyBox requires an explicit -d.
    require_d: bool = false,
    /// true for zcat/bzcat/lzcat/xzcat/lzopcat: always decompress to stdout.
    cat_mode: bool = false,
    /// 'g','b','x','l','o' suffix appended on compression.
    suffix: []const u8 = ".gz",
    /// Suffixes stripped on decompression.
    strip_suffixes: []const []const u8 = &.{".gz"},
    supports_test: bool = true,
    supports_levels: bool = false,
};

fn hasSuffix(name: []const u8, suffixes: []const []const u8) ?[]const u8 {
    for (suffixes) |s| {
        if (std.mem.endsWith(u8, name, s)) return name[0 .. name.len - s.len];
    }
    return null;
}

fn parseLevel(o: c.Options, comptime level_chars: []const u8, comptime os: []const u8) u4 {
    var level: u4 = 6;
    inline for (level_chars) |ch| {
        if (o.flags & (@as(u32, 1) << bitFor(os, ch)) != 0) {
            level = ch - '0';
        }
    }
    return level;
}

fn filterMain(comptime cfg: Config, argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];

    var decompress = cfg.default_decompress;
    var to_stdout = cfg.cat_mode;
    var keep = false;
    var force = false;
    var test_mode = false;
    var level: u4 = 6;

    const files: []const []const u8 = blk: {
        if (cfg.cat_mode) {
            // cat applets take no options, but unknown ones must still be
            // diagnosed by getopt32 like the reference.
            const o = c.opts(cfg.name, av_slice, "", &.{});
            const copied = c.A.alloc([]const u8, o.args.len) catch bb.usage.die(cfg.name);
            @memcpy(copied, o.args);
            break :blk copied;
        }
        const o = c.opts(cfg.name, av_slice, cfg.optstring, &.{});
        decompress = cfg.default_decompress or c.flagged(o, bitFor(cfg.optstring, 'd'));
        to_stdout = c.flagged(o, bitFor(cfg.optstring, 'c'));
        force = c.flagged(o, bitFor(cfg.optstring, 'f'));
        if (comptime std.mem.indexOfScalar(u8, cfg.optstring, 'k') != null)
            keep = c.flagged(o, bitFor(cfg.optstring, 'k'));
        if (comptime cfg.supports_test and std.mem.indexOfScalar(u8, cfg.optstring, 't') != null)
            test_mode = c.flagged(o, bitFor(cfg.optstring, 't'));
        if (comptime cfg.supports_levels) {
            level = parseLevel(o, "123456789", cfg.optstring);
        }
        if (cfg.require_d and !decompress and !test_mode) bb.usage.die(cfg.name);
        // getopt32's args slice lives in a static buffer; copy it before any
        // second parse can overwrite it.
        const copied = c.A.alloc([]const u8, o.args.len) catch bb.usage.die(cfg.name);
        @memcpy(copied, o.args);
        break :blk copied;
    };
    _ = &keep;
    _ = &force;

    if (cfg.codec == .lzop and level >= 7) {
        c.msg("high compression not compiled in", .{});
        return 1;
    }

    if (files.len == 0) {
        const input = c.readStdin();
        if (test_mode) {
            _ = decompressOrEmpty(cfg.codec, input) catch return 1;
            return 0;
        }
        const result = if (decompress)
            decompressOrEmpty(cfg.codec, input) catch return 1
        else
            compressData(cfg.codec, input, level) catch return 1;
        c.out(result);
        return 0;
    }

    var rc: c_int = 0;
    for (files) |file| {
        const input = c.readAll(file) orelse {
            c.perror(2, "{s}", .{file});
            rc = 1;
            continue;
        };
        if (test_mode) {
            _ = decompressOrEmpty(cfg.codec, input) catch {
                rc = 1;
            };
            continue;
        }
        // The reference validates the output suffix before touching the data.
        const output = if (to_stdout or cfg.cat_mode)
            ""
        else if (decompress) blk: {
            const stripped = hasSuffix(file, cfg.strip_suffixes) orelse {
                c.eput("{s}: {s}: unknown suffix - ignored\n", .{ cfg.name, file });
                rc = 1;
                continue;
            };
            break :blk stripped;
        } else std.fmt.allocPrint(c.A, "{s}{s}", .{ file, cfg.suffix }) catch {
            rc = 1;
            continue;
        };
        const result = if (decompress)
            decompressOrEmpty(cfg.codec, input) catch {
                rc = 1;
                continue;
            }
        else
            compressData(cfg.codec, input, level) catch {
                rc = 1;
                continue;
            };
        if (to_stdout or cfg.cat_mode) {
            c.out(result);
            continue;
        }
        if (!force and c.exists(output)) {
            c.eput("{s}: {s}: already exists; not overwritten\n", .{ cfg.name, output });
            rc = 1;
            continue;
        }
        if (!c.writeFile(output, result)) {
            c.perror(13, "{s}", .{output});
            rc = 1;
            continue;
        }
        if (!keep and !std.mem.eql(u8, file, "-")) c.unlink(file);
    }
    return rc;
}

// ------------------------------------------------------------------ gzip --

fn gzipCfg(comptime name: []const u8, comptime dec: bool) Config {
    return .{
        .name = name,
        .codec = .gzip,
        .optstring = "cfkdt",
        .default_decompress = dec,
    };
}

pub fn gzipMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(gzipCfg("gzip", false), argc, argv);
}
pub fn gunzipMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(gzipCfg("gunzip", true), argc, argv);
}
/// zcat auto-detects gzip, bzip2, xz and LZMA streams (the reference message
/// mentions only three formats but accepts all four).
/// uncompress (compiled out in the reference defconfig) is gunzip's CLI with
/// only -c and -f exposed.
pub fn uncompressMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(.{
        .name = "uncompress", .codec = .gzip, .optstring = "cf",
        .default_decompress = true, .supports_test = false,
    }, argc, argv);
}

pub fn zcatMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    c.setProg(argv);
    const av = c.argsFrom(argv, argc);
    const av_slice = av[0..@intCast(@max(argc, 0))];
    const o = c.opts("zcat", av_slice, "c", &.{});
    const files = o.args;

    const doOne = struct {
        fn call(data: []const u8) bool {
            if (data.len == 0) {
                c.msg("short read", .{});
                return false;
            }
            var codec: Codec = undefined;
            if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b) {
                codec = .gzip;
            } else if (data.len >= 3 and data[0] == 'B' and data[1] == 'Z' and data[2] == 'h') {
                codec = .bzip2;
            } else if (data.len >= 6 and std.mem.eql(u8, data[0..6], &.{ 0xfd, '7', 'z', 'X', 'Z', 0 })) {
                codec = .xz;
            } else if (data.len >= 5 and data[0] < 225 and data[1] == 0 and data[2] == 0) {
                // LZMA "alone" header: props byte followed by a little-endian
                // dictionary size whose two high bytes are normally zero.
                codec = .lzma;
            } else {
                c.msg("no gzip/bzip2/xz magic", .{});
                return false;
            }
            const result = decompressOrEmpty(codec, data) catch return false;
            c.out(result);
            return true;
        }
    }.call;

    if (files.len == 0) return if (doOne(c.readStdin())) 0 else 1;
    var rc: c_int = 0;
    for (files) |file| {
        const data = c.readAll(file) orelse {
            c.perror(2, "{s}", .{file});
            rc = 1;
            continue;
        };
        if (!doOne(data)) rc = 1;
    }
    return rc;
}

// ---------------------------------------------------------------- bzip2 --

fn bzip2Cfg(comptime name: []const u8, comptime dec: bool) Config {
    return .{
        .name = name,
        .codec = .bzip2,
        .optstring = if (dec) "cfkt" else "cfkdt123456789",
        .default_decompress = dec,
        .suffix = ".bz2",
        .strip_suffixes = &.{ ".bz2", ".bz", ".bzip2" },
        .supports_levels = !dec,
    };
}

pub fn bzip2Main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(bzip2Cfg("bzip2", false), argc, argv);
}
pub fn bunzip2Main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(bzip2Cfg("bunzip2", true), argc, argv);
}
pub fn bzcatMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(.{
        .name = "bzcat", .codec = .bzip2, .optstring = "", .default_decompress = true,
        .cat_mode = true, .strip_suffixes = &.{".bz2"},
    }, argc, argv);
}

// ------------------------------------------------------------------- xz --

fn xzCfg(comptime name: []const u8, comptime dec: bool, comptime levels: bool) Config {
    return .{
        .name = name,
        .codec = .xz,
        .optstring = if (dec) "cfkt" else "cdfkt",
        .default_decompress = dec,
        .require_d = !dec,
        .suffix = ".xz",
        .strip_suffixes = &.{ ".xz", ".txz" },
        .supports_levels = levels,
    };
}

pub fn xzMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(xzCfg("xz", false, false), argc, argv);
}
pub fn unxzMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(xzCfg("unxz", true, false), argc, argv);
}
pub fn xzcatMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(.{
        .name = "xzcat", .codec = .xz, .optstring = "", .default_decompress = true,
        .cat_mode = true, .strip_suffixes = &.{".xz"},
    }, argc, argv);
}

// ----------------------------------------------------------------- lzma --

fn lzmaCfg(comptime name: []const u8, comptime dec: bool) Config {
    return .{
        .name = name,
        .codec = .lzma,
        .optstring = if (dec) "cfkt" else "cdfkt",
        .default_decompress = dec,
        .require_d = !dec,
        .suffix = ".lzma",
        .strip_suffixes = &.{ ".lzma", ".tlz" },
    };
}

pub fn lzmaMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(lzmaCfg("lzma", false), argc, argv);
}
pub fn unlzmaMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(lzmaCfg("unlzma", true), argc, argv);
}
pub fn lzcatMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(.{
        .name = "lzcat", .codec = .lzma, .optstring = "", .default_decompress = true,
        .cat_mode = true, .strip_suffixes = &.{".lzma"},
    }, argc, argv);
}

// ------------------------------------------------------------------ lzop --

fn lzopCfg(comptime name: []const u8, comptime dec: bool, comptime cat: bool, comptime levels: bool) Config {
    return .{
        .name = name,
        .codec = .lzop,
        .optstring = if (levels) "cfUvd123456789FC" else "cfUvF",
        .default_decompress = dec,
        .cat_mode = cat,
        .suffix = ".lzo",
        .strip_suffixes = &.{ ".lzo", ".lzop" },
        .supports_test = false,
        .supports_levels = levels,
    };
}

pub fn lzopMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(lzopCfg("lzop", false, false, true), argc, argv);
}
pub fn unlzopMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(lzopCfg("unlzop", true, false, false), argc, argv);
}
pub fn lzopcatMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    return filterMain(lzopCfg("lzopcat", true, true, false), argc, argv);
}
