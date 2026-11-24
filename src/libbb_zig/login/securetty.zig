//! /etc/securetty checks, matching BusyBox `is_tty_secure()`: an empty (or
//! missing) securetty file means every tty is considered secure; otherwise
//! the short tty name must appear as a whitespace-delimited token.

const std = @import("std");

pub fn shortName(tty: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tty, "/dev/")) tty[5..] else tty;
}

pub fn isSecure(data: []const u8, tty: []const u8) bool {
    const wanted = shortName(tty);
    var found_entry = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        while (tokens.next()) |token| {
            if (token[0] == '#') break;
            found_entry = true;
            if (std.mem.eql(u8, token, wanted)) return true;
        }
    }
    return !found_entry;
}
