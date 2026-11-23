//! libbb `update_passwd` helpers: replace (or append) one name-keyed entry in
//! a passwd/shadow/group file while preserving every other byte, then commit
//! via a temporary file and rename.  Pure helpers; no applet logic.

const std = @import("std");
const linux = std.os.linux;
const max_path = 4096;

fn pathZ(path: []const u8, buf: *[max_path:0]u8) ![:0]const u8 {
    if (path.len == 0 or path.len >= buf.len) return error.InvalidPath;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn readAll(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var zb: [max_path:0]u8 = undefined;
    const z = try pathZ(path, &zb);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY }, 0);
    const e = linux.errno(rc);
    if (e == .NOENT) return error.FileNotFound;
    if (e != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const size64 = linux.lseek(fd, 0, 2); // SEEK_END
    if (linux.errno(@as(isize, @bitCast(size64))) != .SUCCESS) return error.StatFailed;
    const size: usize = @intCast(size64);
    _ = linux.lseek(fd, 0, 0); // SEEK_SET
    const buf = try a.alloc(u8, size);
    errdefer a.free(buf);
    var done: usize = 0;
    while (done < size) {
        const n = linux.read(fd, buf[done..].ptr, size - done);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        done += n;
    }
    return a.realloc(buf, done);
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        done += n;
    }
}

/// Return a copy of `data` with the first line whose colon-delimited name is
/// `name` replaced by `new_line`.  If no such line exists, `new_line` is
/// appended.  Original line endings are preserved for all other lines.
pub fn updateContents(a: std.mem.Allocator, data: []const u8, name: []const u8, new_line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var replaced = false;
    var pos: usize = 0;
    while (pos < data.len) {
        const nl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line_end = if (nl < data.len) nl + 1 else nl;
        const content = data[pos..nl];
        if (!replaced) {
            if (std.mem.indexOfScalar(u8, content, ':')) |colon| {
                if (std.mem.eql(u8, content[0..colon], name)) {
                    try out.appendSlice(a, new_line);
                    try out.appendSlice(a, data[nl..line_end]);
                    replaced = true;
                    pos = line_end;
                    continue;
                }
            }
        }
        try out.appendSlice(a, data[pos..line_end]);
        pos = line_end;
    }
    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        try out.appendSlice(a, new_line);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// Update `path` atomically.  Returns true if the file changed.
pub fn updateFile(a: std.mem.Allocator, path: []const u8, name: []const u8, new_line: []const u8) !bool {
    const old = readAll(a, path) catch |err| switch (err) {
        error.FileNotFound => try a.alloc(u8, 0),
        else => return err,
    };
    defer a.free(old);
    const updated = try updateContents(a, old, name, new_line);
    defer a.free(updated);
    if (std.mem.eql(u8, old, updated)) return false;

    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    defer a.free(tmp);
    var tmp_zb: [max_path:0]u8 = undefined;
    const tmp_z = try pathZ(tmp, &tmp_zb);
    const fd_rc = linux.open(tmp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (linux.errno(fd_rc) != .SUCCESS) return error.CreateFailed;
    const fd: linux.fd_t = @intCast(fd_rc);
    writeAll(fd, updated) catch |err| {
        _ = linux.close(fd);
        _ = linux.unlink(tmp_z);
        return err;
    };
    _ = linux.close(fd);

    var path_zb: [max_path:0]u8 = undefined;
    const path_z = try pathZ(path, &path_zb);
    const rc = linux.rename(tmp_z, path_z);
    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.unlink(tmp_z);
        return error.RenameFailed;
    }
    return true;
}
