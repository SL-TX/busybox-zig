//! Uniform config-file tokenizer (Task 25), ported from busybox
//! libbb/parse_config.c. It is a pure function over text: callers own the
//! returned slices and decide which paths (if any) to read from disk.

const std = @import("std");

pub const Options = struct {
    comment: u8 = '#',
    delimiters: []const u8 = " \t",
    alt_comment: ?u8 = null,
    max_tokens: usize = 128,
    min_tokens: usize = 0,
    greedy: bool = true,
    trim: bool = true,
    collapse: bool = true,
    eol_comments: bool = true,
    ws_comments: bool = false,
    /// Receives the line number of the most recently examined non-blank line.
    last_lineno: ?*usize = null,
};

pub const Entry = struct {
    lineno: usize,
    tokens: [][]const u8,
};

pub const ConfigError = error{
    TooFewTokens,
    InvalidConfig,
    OutOfMemory,
};

fn isDelimiter(ch: u8, delims: []const u8) bool {
    return std.mem.indexOfScalar(u8, delims, ch) != null;
}

fn freeTokens(allocator: std.mem.Allocator, tokens: [][]const u8) void {
    for (tokens) |tok| allocator.free(tok);
    allocator.free(tokens);
}

fn freeTokenList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |tok| allocator.free(tok);
    list.deinit(allocator);
}

fn processLine(
    allocator: std.mem.Allocator,
    text: []const u8,
    lineno: usize,
    opts: Options,
    out: *std.ArrayList(Entry),
) ConfigError!void {
    var start = text;
    if (opts.ws_comments) start = std.mem.trimStart(u8, start, " \t");
    if (opts.comment != 0 and start.len > 0 and start[0] == opts.comment) return;
    if (opts.alt_comment) |alt| {
        if (start.len > 0 and start[0] == alt) return;
    }

    var work = text;
    if (opts.eol_comments and opts.comment != 0) {
        if (std.mem.indexOfScalar(u8, work, opts.comment)) |i| work = work[0..i];
    }
    if (opts.trim) work = std.mem.trim(u8, work, opts.delimiters);
    if (work.len == 0) return;

    if (opts.last_lineno) |ptr| ptr.* = lineno;

    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer freeTokenList(allocator, &tokens);

    const max_tokens = if (opts.max_tokens == 0) 1 else opts.max_tokens;
    var pos: usize = 0;
    while (pos < work.len and tokens.items.len < max_tokens) {
        if (opts.greedy and tokens.items.len == max_tokens - 1) {
            var rest_start = pos;
            if (opts.trim or opts.collapse) {
                while (rest_start < work.len and isDelimiter(work[rest_start], opts.delimiters)) rest_start += 1;
            }
            var rest = work[rest_start..];
            if (opts.trim) rest = std.mem.trimEnd(u8, rest, opts.delimiters);
            try tokens.append(allocator, try allocator.dupe(u8, rest));
            pos = work.len;
            break;
        }

        if (opts.trim or opts.collapse) {
            while (pos < work.len and isDelimiter(work[pos], opts.delimiters)) pos += 1;
            if (pos >= work.len) break;
        }

        const token_start = pos;
        while (pos < work.len and !isDelimiter(work[pos], opts.delimiters)) pos += 1;
        try tokens.append(allocator, try allocator.dupe(u8, work[token_start..pos]));
        if (pos < work.len) pos += 1;
    }

    if (tokens.items.len < opts.min_tokens) return error.TooFewTokens;
    if (tokens.items.len == 0) return error.InvalidConfig;

    try out.append(allocator, .{ .lineno = lineno, .tokens = try tokens.toOwnedSlice(allocator) });
}

/// Parse `text` into one entry per non-blank, non-comment logical line.
/// Backslash-newline continuations are joined before tokenization.
pub fn parse(allocator: std.mem.Allocator, text: []const u8, opts: Options) ConfigError![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| freeTokens(allocator, entry.tokens);
        entries.deinit(allocator);
    }

    var logical: std.ArrayList(u8) = .empty;
    defer logical.deinit(allocator);

    var lineno: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        lineno += 1;
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > 0 and line[line.len - 1] == '\\') {
            try logical.appendSlice(allocator, line[0 .. line.len - 1]);
            continue;
        }
        try logical.appendSlice(allocator, line);
        try processLine(allocator, logical.items, lineno, opts, &entries);
        logical.clearRetainingCapacity();
    }
    if (logical.items.len > 0) {
        try processLine(allocator, logical.items, lineno, opts, &entries);
    }

    return try entries.toOwnedSlice(allocator);
}

/// Convenience: read a caller-provided text buffer with the busybox
/// "normal" flag combination (collapse + trim + greedy + EOL comments).
pub fn parseNormal(allocator: std.mem.Allocator, text: []const u8, delims: []const u8, max_tokens: usize, min_tokens: usize) ConfigError![]Entry {
    return parse(allocator, text, .{
        .delimiters = delims,
        .max_tokens = max_tokens,
        .min_tokens = min_tokens,
    });
}
