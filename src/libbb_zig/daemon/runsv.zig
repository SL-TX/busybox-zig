//! runit service-directory helpers (Task 25), based on the file layout used by
//! busybox runit/runsv.c. Only paths supplied by the caller are inspected.

const std = @import("std");
const io = @import("../io.zig");

pub const ServiceFiles = struct {
    run: bool = false,
    finish: bool = false,
    check: bool = false,
    down: bool = false,
    log_run: bool = false,
};

pub const ServiceDir = struct {
    path: []u8,
    files: ServiceFiles,
};

fn hasFile(base: []const u8, name: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ base, name }) catch return false;
    return io.isRegular(path);
}

pub fn scanServiceDir(allocator: std.mem.Allocator, path: []const u8) error{ NotDir, OutOfMemory }!ServiceDir {
    if (!io.isDir(path)) return error.NotDir;
    return .{
        .path = try allocator.dupe(u8, path),
        .files = .{
            .run = hasFile(path, "run"),
            .finish = hasFile(path, "finish"),
            .check = hasFile(path, "check"),
            .down = hasFile(path, "down"),
            .log_run = hasFile(path, "log/run"),
        },
    };
}

pub const ServiceState = enum { down, run, finish };

pub const ControlFlag = struct {
    paused: bool = false,
    got_term: bool = false,
    want_down: bool = false,
    want_exit: bool = false,
};

pub const Status = struct {
    state: ServiceState,
    ctrl: ControlFlag = .{},
};

fn stateName(state: ServiceState) []const u8 {
    return switch (state) {
        .down => "down",
        .run => "run",
        .finish => "finish",
    };
}

pub fn parseStatus(text: []const u8) error{MalformedStatus}!Status {
    var parts = std.mem.splitScalar(u8, text, ',');
    const first = parts.next() orelse return error.MalformedStatus;
    const state_name = std.mem.trim(u8, first, " \t\r\n");
    const state: ServiceState = if (std.mem.eql(u8, state_name, "down"))
        .down
    else if (std.mem.eql(u8, state_name, "run"))
        .run
    else if (std.mem.eql(u8, state_name, "finish"))
        .finish
    else
        return error.MalformedStatus;

    var status = Status{ .state = state };
    while (parts.next()) |part| {
        const flag = std.mem.trim(u8, part, " \t\r\n");
        if (std.mem.eql(u8, flag, "paused")) {
            status.ctrl.paused = true;
        } else if (std.mem.eql(u8, flag, "got TERM")) {
            status.ctrl.got_term = true;
        } else if (std.mem.eql(u8, flag, "want down")) {
            status.ctrl.want_down = true;
        } else if (std.mem.eql(u8, flag, "want exit")) {
            status.ctrl.want_exit = true;
        } else {
            return error.MalformedStatus;
        }
    }
    return status;
}

pub fn formatStatus(status: Status, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}{s}\n", .{
        stateName(status.state),
        if (status.ctrl.paused) ", paused" else "",
        if (status.ctrl.got_term) ", got TERM" else "",
        if (status.ctrl.want_down) ", want down" else "",
        if (status.ctrl.want_exit) ", want exit" else "",
    });
}
