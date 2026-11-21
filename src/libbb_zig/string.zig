//! String utilities ported from busybox libbb.
//! C-string functions take NUL-terminated `[*:0]const u8` pointers; the
//! higher-level helpers work on `[]const u8` slices and return borrowed
//! slices into their input where possible.

const std = @import("std");

const whitespace = " \t\n\r\x0b\x0c";

pub fn strlen(s: [*:0]const u8) usize {
    return std.mem.span(s).len;
}

pub fn strnlen(s: [*:0]const u8, max: usize) usize {
    return @min(std.mem.span(s).len, max);
}

pub fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    const sa = std.mem.span(a);
    const sb = std.mem.span(b);
    const n = @min(sa.len, sb.len);
    for (0..n) |i| {
        if (sa[i] < sb[i]) return -1;
        if (sa[i] > sb[i]) return 1;
    }
    if (sa.len < sb.len) return -1;
    if (sa.len > sb.len) return 1;
    return 0;
}

pub fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) c_int {
    const sa = std.mem.span(a);
    const sb = std.mem.span(b);
    const m = @min(@min(sa.len, sb.len), n);
    for (0..m) |i| {
        if (sa[i] < sb[i]) return -1;
        if (sa[i] > sb[i]) return 1;
    }
    if (m == n) return 0;
    if (sa.len < sb.len) return -1;
    if (sa.len > sb.len) return 1;
    return 0;
}

pub fn strcpy(dst: []u8, src: [*:0]const u8) []u8 {
    const ss = std.mem.span(src);
    @memcpy(dst[0..ss.len], ss);
    dst[ss.len] = 0;
    return dst[0..ss.len];
}

pub fn strncpy(dst: []u8, src: [*:0]const u8, n: usize) []u8 {
    const ss = std.mem.span(src);
    const m = @min(ss.len, n);
    @memcpy(dst[0..m], ss[0..m]);
    if (m < n) @memset(dst[m..n], 0);
    return dst[0..m];
}

pub fn strdup(a: std.mem.Allocator, s: [*:0]const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{std.mem.span(s)}, 0);
}

pub fn strdupz(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return std.mem.concatWithSentinel(a, u8, &.{s}, 0);
}

pub fn strchr(s: [*:0]const u8, c: u8) ?[]const u8 {
    const ss = std.mem.span(s);
    if (std.mem.indexOfScalar(u8, ss, c)) |i| return ss[i..];
    return null;
}

pub fn strrchr(s: [*:0]const u8, c: u8) ?[]const u8 {
    const ss = std.mem.span(s);
    if (std.mem.lastIndexOfScalar(u8, ss, c)) |i| return ss[i..];
    return null;
}

pub fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) ?[]const u8 {
    const h = std.mem.span(haystack);
    const n = std.mem.span(needle);
    if (std.mem.indexOf(u8, h, n)) |i| return h[i..];
    return null;
}

pub fn strrstr(haystack: [*:0]const u8, needle: [*:0]const u8) ?[]const u8 {
    const h = std.mem.span(haystack);
    const n = std.mem.span(needle);
    if (std.mem.lastIndexOf(u8, h, n)) |i| return h[i..];
    return null;
}

pub fn strcasestr(haystack: [*:0]const u8, needle: [*:0]const u8) ?[]const u8 {
    const h = std.mem.span(haystack);
    const n = std.mem.span(needle);
    if (n.len == 0) return h;
    if (n.len > h.len) return null;
    var i: usize = 0;
    while (i + n.len <= h.len) : (i += 1) {
        var match = true;
        for (n, 0..) |ch, j| {
            if (std.ascii.toLower(h[i + j]) != std.ascii.toLower(ch)) {
                match = false;
                break;
            }
        }
        if (match) return h[i..];
    }
    return null;
}

pub fn strsep(stringp: *[*:0]const u8, delim: []const u8) ?[]const u8 {
    const s = std.mem.span(stringp.*);
    if (s.len == 0) return null;
    var end = s.len;
    if (delim.len != 0) {
        for (s, 0..) |ch, i| {
            if (std.mem.indexOfScalar(u8, delim, ch) != null) {
                end = i;
                break;
            }
        }
    }
    const token = s[0..end];
    const next = if (end < s.len) end + 1 else end;
    stringp.* = @ptrCast(s[next..].ptr);
    return token;
}

pub fn startswith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

pub fn endswith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

pub fn is_prefixed_with(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
    return null;
}

pub fn last_char_is(s: []const u8, c: u8) ?[]const u8 {
    if (s.len > 0 and s[s.len - 1] == c) return s[0 .. s.len - 1];
    return null;
}

pub fn chomp(s: []const u8) []const u8 {
    var out = s;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }
    return out;
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, whitespace);
}

pub fn skip_whitespace(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, whitespace);
}

pub fn replace(a: std.mem.Allocator, s: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, s, needle, replacement);
}

pub fn concat_path_file(a: std.mem.Allocator, path: []const u8, file: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(file)) return a.dupe(u8, file);
    if (path.len == 0) return a.dupe(u8, file);
    if (std.mem.endsWith(u8, path, "/")) return std.mem.concat(a, u8, &.{ path, file });
    return std.mem.concat(a, u8, &.{ path, "/", file });
}

pub fn concat_subpath_file(a: std.mem.Allocator, path: []const u8, filename: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, filename, '/') != null) return null;
    return try concat_path_file(a, path, filename);
}

pub fn get_last_path_component(path: []const u8) []const u8 {
    const s = std.mem.trimEnd(u8, path, "/");
    if (s.len == 0) return "/";
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// Collapse redundant separators, "." and ".." components. Leading ".."
/// components are preserved for relative paths; an absolute path stays rooted.
pub fn simplifyPath(a: std.mem.Allocator, p: []const u8) ![]u8 {
    const absolute = p.len > 0 and p[0] == '/';
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(a);
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!absolute) {
                try parts.append(a, part);
            }
            continue;
        }
        try parts.append(a, part);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (absolute) try out.append(a, '/');
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append(a, '/');
        try out.appendSlice(a, part);
    }
    if (out.items.len == 0) try out.append(a, '.');
    return out.toOwnedSlice(a);
}

/// camelCase aliases matching the shared libbb interface.
pub const concatPathFile = concat_path_file;
pub const getLastPathComponent = get_last_path_component;

pub fn match_fstype(mnt_type: []const u8, fstype: []const u8) bool {
    var types = std.mem.splitScalar(u8, mnt_type, ',');
    while (types.next()) |t| {
        var wanted = std.mem.splitScalar(u8, fstype, ',');
        while (wanted.next()) |w| {
            if (std.mem.eql(u8, t, w)) return true;
        }
    }
    return false;
}
