//! Identity and environment helpers ported from busybox libbb:
//! change_identity(), setup_environment().

const std = @import("std");
const linux = std.os.linux;
const proc = @import("process.zig");
const env = @import("env.zig");

pub const default_shell = "/bin/sh";
pub const root_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
pub const user_path = "/usr/local/bin:/usr/bin:/bin";

/// Minimalpasswd-shaped record, so helpers do not depend on getpwnam().
pub const PasswdInfo = struct {
    name: []const u8,
    dir: []const u8,
    shell: []const u8 = "",
    uid: linux.uid_t,
    gid: linux.gid_t,
};

pub const SetupFlags = struct {
    chdir: bool = false,
    clear_env: bool = false,
    change_env: bool = false,
    change_env_logname: bool = false,
    to_tmp: bool = false,
};

pub fn effectiveShell(shell: ?[]const u8) []const u8 {
    if (shell) |s| {
        if (s.len != 0) return s;
    }
    return default_shell;
}

pub fn defaultPath(uid: linux.uid_t) []const u8 {
    return if (uid == 0) root_path else user_path;
}

/// Become the given uid/gid (plus clear supplemental groups when privileged),
/// matching busybox change_identity() without abandoning the process on error.
pub fn changeIdentity(uid: linux.uid_t, gid: linux.gid_t) !void {
    if (linux.geteuid() == 0) {
        var dummy: [1]linux.gid_t = .{0};
        proc.setgroups(0, &dummy) catch {};
    }
    try proc.setgid(gid);
    try proc.setuid(uid);
}

/// Apply login-style environment setup. When no environment map has been
/// installed by main(), only the chdir side effect is performed.
pub fn setupEnvironment(shell: ?[]const u8, flags: SetupFlags, pw: PasswdInfo) !void {
    const sh = effectiveShell(shell);

    if (flags.chdir) {
        proc.chdirPath(pw.dir) catch {
            try proc.chdirPath(if (flags.to_tmp) "/tmp" else "/");
        };
    }

    const m = env.map orelse return;

    if (flags.clear_env) {
        const term = m.get("TERM");
        const a = m.allocator;
        var doomed: std.ArrayList([]u8) = .empty;
        defer {
            for (doomed.items) |k| a.free(k);
            doomed.deinit(a);
        }
        for (m.keys()) |k| {
            if (!std.mem.eql(u8, k, "TERM")) {
                try doomed.append(a, try a.dupe(u8, k));
            }
        }
        for (doomed.items) |k| _ = m.swapRemove(k);

        if (term) |t| try m.put("TERM", t);
        try m.put("PATH", defaultPath(pw.uid));
        try m.put("USER", pw.name);
        try m.put("LOGNAME", pw.name);
        try m.put("HOME", pw.dir);
        try m.put("SHELL", sh);
        return;
    }

    if (flags.change_env or flags.change_env_logname) {
        if (flags.change_env_logname or pw.uid != 0) {
            try m.put("USER", pw.name);
            try m.put("LOGNAME", pw.name);
        }
        try m.put("HOME", pw.dir);
        try m.put("SHELL", sh);
    }
}
