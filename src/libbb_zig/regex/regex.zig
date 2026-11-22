//! Public POSIX regex interface, as fixed by the shared interfaces:
//!     compile(allocator, pattern, flags) -> Regex
//!     regex.exec(text, matches) -> number of match slots filled
//! `matches[0]` is the whole match, `[1..]` the capturing groups.
//! Pure Zig, with a configurable step budget against catastrophic backtracking.

const std = @import("std");
const parse = @import("parse.zig");
const execmod = @import("exec.zig");

pub const Flags = parse.Flags;
pub const Match = execmod.Match;
pub const ExecError = execmod.ExecError;
pub const ParseError = parse.ParseError;

/// Default step budget; each compiled Regex gets its own copy and callers may
/// lower or raise it (e.g. `re.max_steps = 2000`).
pub var default_max_steps: usize = 1_000_000;

pub const Regex = struct {
    prog: parse.Program,
    max_steps: usize,

    pub fn deinit(self: *Regex) void {
        self.prog.deinit();
    }

    /// Match starting exactly at `start` (useful for repeated s///g scans).
    pub fn execAt(self: *const Regex, text: []const u8, start: usize, matches: []Match) !?usize {
        return execmod.execAt(&self.prog, text, start, matches, self.max_steps);
    }

    /// Find the leftmost match anywhere in `text`.
    pub fn exec(self: *const Regex, text: []const u8, matches: []Match) !usize {
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (try execmod.execAt(&self.prog, text, start, matches, self.max_steps)) |n| return n;
        }
        return 0;
    }

    /// POSIX leftmost-longest matching, needed by BRE/ERE shell and editor
    /// applets (grep/sed/awk/vi). Additive API: `exec` keeps its historical
    /// leftmost-first behaviour for existing callers.
    pub fn execLongestAt(self: *const Regex, text: []const u8, start: usize, matches: []Match) !?usize {
        return execmod.execLongestAt(&self.prog, text, start, matches, self.max_steps);
    }

    /// Find the leftmost-longest match anywhere in `text`.
    pub fn execLongest(self: *const Regex, text: []const u8, matches: []Match) !usize {
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (try execmod.execLongestAt(&self.prog, text, start, matches, self.max_steps)) |n| return n;
        }
        return 0;
    }
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: Flags) !Regex {
    return .{
        .prog = try parse.compile(allocator, pattern, flags),
        .max_steps = default_max_steps,
    };
}
