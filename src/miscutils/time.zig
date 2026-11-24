//! time — run a program and report resource usage (reference miscutils/time.c).

const std = @import("std");
const linux = std.os.linux;
const c = @import("common.zig");
const bb = @import("libbb_zig");
const misclib = @import("main.zig");

const default_format = "real\t%E\nuser\t%u\nsys\t%T";
const posix_format = "real %e\nuser %U\nsys %S";
var output_fd: linux.fd_t = 2;

fn writeOut(bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(output_fd, bytes.ptr + done, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        done += @intCast(n);
    }
}

const long_format =
    "\tCommand being timed: \"%C\"\n" ++
    "\tUser time (seconds): %U\n" ++
    "\tSystem time (seconds): %S\n" ++
    "\tPercent of CPU this job got: %P\n" ++
    "\tElapsed (wall clock) time (h:mm:ss or m:ss): %E\n" ++
    "\tAverage shared text size (kbytes): %X\n" ++
    "\tAverage unshared data size (kbytes): %D\n" ++
    "\tAverage stack size (kbytes): %p\n" ++
    "\tAverage total size (kbytes): %K\n" ++
    "\tMaximum resident set size (kbytes): %M\n" ++
    "\tAverage resident set size (kbytes): %t\n" ++
    "\tMajor (requiring I/O) page faults: %F\n" ++
    "\tMinor (reclaiming a frame) page faults: %R\n" ++
    "\tVoluntary context switches: %w\n" ++
    "\tInvoluntary context switches: %c\n" ++
    "\tSwaps: %W\n" ++
    "\tFile system inputs: %I\n" ++
    "\tFile system outputs: %O\n" ++
    "\tSocket messages sent: %s\n" ++
    "\tSocket messages received: %r\n" ++
    "\tSignals delivered: %k\n" ++
    "\tPage size (bytes): %Z\n" ++
    "\tExit status: %x";

fn sec2(s: linux.timeval) u64 {
    return @intCast(@max(0, s.sec));
}
fn usec100(s: linux.timeval) u64 {
    return @intCast(@divTrunc(@max(0, s.usec), 10000));
}

fn elapsedHMS(buf: []u8, ms: u64) []const u8 {
    const secs = ms / 1000;
    if (secs >= 3600) {
        return std.fmt.bufPrint(buf, "{d}h {d}m {d:0>2}s", .{ secs / 3600, (secs % 3600) / 60, secs % 60 }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}m {d}.{d:0>2}s", .{ secs / 60, secs % 60, (ms / 10) % 100 }) catch "";
}

fn summarize(fmt: []const u8, cmd: []const []const u8, status: i32, ru: linux.rusage, elapsed_ms: u64, write: *const fn ([]const u8) void) void {
    var buf: [256]u8 = undefined;
    const vv_ms = sec2(ru.utime) * 1000 + sec2(ru.stime) * 1000 + usec100(ru.utime) * 10 + usec100(ru.stime) * 10;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const ch = fmt[i];
        if (ch == '\\') {
            i += 1;
            if (i >= fmt.len) break;
            switch (fmt[i]) {
                't' => write("\t"),
                'n' => write("\n"),
                '\\' => write("\\"),
                else => {
                    write("?\\");
                    write(fmt[i .. i + 1]);
                },
            }
            continue;
        }
        if (ch != '%') {
            write(fmt[i .. i + 1]);
            continue;
        }
        i += 1;
        if (i >= fmt.len) break;
        const s = switch (fmt[i]) {
            '%' => "%",
            'C' => blk: {
                var outbuf: [1024]u8 = undefined;
                var p: usize = 0;
                for (cmd, 0..) |word, k| {
                    const sep = if (k == 0) "" else " ";
                    @memcpy(outbuf[p .. p + sep.len], sep);
                    p += sep.len;
                    @memcpy(outbuf[p .. p + word.len], word);
                    p += word.len;
                }
                break :blk std.fmt.bufPrint(&buf, "{s}", .{outbuf[0..p]}) catch "";
            },
            'E' => elapsedHMS(&buf, elapsed_ms),
            'e' => std.fmt.bufPrint(&buf, "{d}.{d:0>2}", .{ elapsed_ms / 1000, (elapsed_ms / 10) % 100 }) catch "",
            'u' => blk: {
                const t = sec2(ru.utime);
                if (t >= 3600) break :blk std.fmt.bufPrint(&buf, "{d}h {d}m {d:0>2}s", .{ t / 3600, (t % 3600) / 60, t % 60 }) catch "";
                break :blk std.fmt.bufPrint(&buf, "{d}m {d}.{d:0>2}s", .{ t / 60, t % 60, usec100(ru.utime) }) catch "";
            },
            'U' => std.fmt.bufPrint(&buf, "{d}.{d:0>2}", .{ sec2(ru.utime), usec100(ru.utime) }) catch "",
            'T' => blk: {
                const t = sec2(ru.stime);
                if (t >= 3600) break :blk std.fmt.bufPrint(&buf, "{d}h {d}m {d:0>2}s", .{ t / 3600, (t % 3600) / 60, t % 60 }) catch "";
                break :blk std.fmt.bufPrint(&buf, "{d}m {d}.{d:0>2}s", .{ t / 60, t % 60, usec100(ru.stime) }) catch "";
            },
            'S' => std.fmt.bufPrint(&buf, "{d}.{d:0>2}", .{ sec2(ru.stime), usec100(ru.stime) }) catch "",
            'x' => std.fmt.bufPrint(&buf, "{d}", .{@as(u8, @bitCast(@as(i8, @truncate(status >> 8))))}) catch "",
            'P' => if (elapsed_ms > 0)
                std.fmt.bufPrint(&buf, "{d}%", .{@min(@as(u64, 100), vv_ms * 100 / elapsed_ms)}) catch ""
            else
                "?%",
            'M' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.maxrss)))}) catch "",
            'F' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.majflt)))}) catch "",
            'R' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.minflt)))}) catch "",
            'I' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.inblock)))}) catch "",
            'O' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.oublock)))}) catch "",
            'w' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.nvcsw)))}) catch "",
            'c' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.nivcsw)))}) catch "",
            'W' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.nswap)))}) catch "",
            'Z' => "4096",
            'X', 'D', 'K', 'p', 't' => "0",
            's' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.msgsnd)))}) catch "",
            'r' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.msgrcv)))}) catch "",
            'k' => std.fmt.bufPrint(&buf, "{d}", .{@as(u64, @intCast(@max(0, ru.nsignals)))}) catch "",
            else => {
                write(&buf);
                const unknown = [_]u8{ '%', fmt[i] };
                write(&unknown);
                continue;
            },
        };
        write(s);
    }
    write("\n");
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("time");
    const o = c.opts("time", args, "^+vpao:f:", &.{});
    if (o.args.len == 0) c.usageDie("time");

    var fmt: []const u8 = bb.env.get("TIME") orelse default_format;
    var outfile: ?[]const u8 = null;
    var append = false;
    {
        var j: usize = 1;
        while (j < args.len) : (j += 1) {
            const tok = args[j];
            if (tok.len < 2 or tok[0] != '-') break;
            if (std.mem.eql(u8, tok, "-o") and j + 1 < args.len) {
                j += 1;
                outfile = args[j];
            } else if (std.mem.startsWith(u8, tok, "-o") and tok.len > 2) {
                outfile = tok[2..];
            } else if (std.mem.eql(u8, tok, "-f") and j + 1 < args.len) {
                j += 1;
                fmt = args[j];
            } else if (std.mem.startsWith(u8, tok, "-f") and tok.len > 2) {
                fmt = tok[2..];
            }
        }
    }
    if ((o.flags & 1) != 0) fmt = long_format;
    if ((o.flags & 2) != 0) fmt = posix_format;
    append = (o.flags & 4) != 0;

    const cmd = o.args;
    const start_ms = c.monotonicMillis();
    const child = bb.process.fork() catch return 1;
    if (child == 0) {
        const pathvar = bb.env.get("PATH") orelse "/bin:/usr/bin";
        const resolved = misclib.resolveCommand(a, cmd[0], pathvar) catch std.process.exit(127) orelse std.process.exit(127);
        const argv_z = a.allocSentinel(?[*:0]const u8, cmd.len, null) catch std.process.exit(1);
        argv_z[0] = c.zstr(a, resolved) catch std.process.exit(1);
        for (cmd[1..], 1..) |word, k| argv_z[k] = c.zstr(a, word) catch std.process.exit(1);
        const envp_z = a.allocSentinel(?[*:0]const u8, 0, null) catch std.process.exit(1);
        bb.process.execve(argv_z[0].?, argv_z, envp_z) catch std.process.exit(127);
        std.process.exit(127);
    }
    var status: i32 = 0;
    var ru: linux.rusage = std.mem.zeroes(linux.rusage);
    _ = linux.wait4(child, &status, 0, &ru);
    const elapsed_ms: u64 = @intCast(@max(0, c.monotonicMillis() - start_ms));
    const exit_code: u8 = if ((status & 0x7f) != 0) @intCast(128 + (status & 0x7f)) else @intCast((status >> 8) & 0xff);

    // Select the output sink. `summarize` writes through a module-level fd so
    // both stderr and -o files are formatted identically.
    output_fd = 2;
    var opened: ?linux.fd_t = null;
    if (outfile) |name| {
        const z = c.zstr(a, name) catch return 1;
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = append, .TRUNC = !append };
        const rc = linux.open(z, flags, 0o666);
        if (linux.errno(rc) != .SUCCESS) return 1;
        output_fd = @intCast(rc);
        opened = output_fd;
    }
    defer {
        if (opened) |f| _ = linux.close(f);
    }

    if (exit_code != 0 and (status & 0x7f) == 0) {
        writeOut("Command exited with non-zero status ");
        var eb: [32]u8 = undefined;
        writeOut(std.fmt.bufPrint(&eb, "{d}", .{exit_code}) catch "");
        writeOut("\n");
    }
    summarize(fmt, cmd, status, ru, elapsed_ms, writeOut);
    return exit_code;
}
