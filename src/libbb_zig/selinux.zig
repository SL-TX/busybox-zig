//! SELinux helpers for Wave 7 applets: security-context parsing/editing,
//! xattr-backed file labels, and boolean pseudo-file access.  No libselinux
//! dependency: labels are read/written through the `security.selinux` xattr,
//! which is what libselinux itself ultimately does.  Enforcement-specific
//! behaviour is deliberately not implemented here (helpers only).

const std = @import("std");
const linux = std.os.linux;

const max_path = 4096;
pub const selinux_xattr = "security.selinux";

fn pathZ(path: []const u8, buf: *[max_path:0]u8) ![:0]const u8 {
    if (path.len == 0 or path.len >= buf.len) return error.InvalidPath;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn nameZ(name: []const u8, buf: *[256:0]u8) ![:0]const u8 {
    if (name.len == 0 or name.len >= buf.len) return error.InvalidName;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0];
}

fn xattrErr(e: linux.E) anyerror {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NODATA => error.NoData,
        .OPNOTSUPP, .INVAL => error.Unsupported,
        else => error.XattrFailed,
    };
}

/// Read one xattr.  `null` means the attribute is not present (ENODATA).
pub fn get(a: std.mem.Allocator, path: []const u8, name: []const u8) !?[]u8 {
    var pb: [max_path:0]u8 = undefined;
    var nb: [256:0]u8 = undefined;
    const p = try pathZ(path, &pb);
    const n = try nameZ(name, &nb);
    var dummy: [1]u8 = undefined;
    const size_rc = linux.getxattr(p, n, &dummy, 0);
    const e = linux.errno(size_rc);
    if (e == .NODATA) return null;
    if (e != .SUCCESS) return xattrErr(e);
    const size: usize = size_rc;
    const buf = try a.alloc(u8, size);
    errdefer a.free(buf);
    const rc = linux.getxattr(p, n, buf.ptr, size);
    if (linux.errno(rc) != .SUCCESS) return xattrErr(linux.errno(rc));
    return try a.realloc(buf, rc);
}

pub fn set(path: []const u8, name: []const u8, value: []const u8) !void {
    var pb: [max_path:0]u8 = undefined;
    var nb: [256:0]u8 = undefined;
    const p = try pathZ(path, &pb);
    const n = try nameZ(name, &nb);
    const rc = linux.setxattr(p, n, value.ptr, value.len, 0);
    if (linux.errno(rc) != .SUCCESS) return xattrErr(linux.errno(rc));
}

pub fn remove(path: []const u8, name: []const u8) !void {
    var pb: [max_path:0]u8 = undefined;
    var nb: [256:0]u8 = undefined;
    const p = try pathZ(path, &pb);
    const n = try nameZ(name, &nb);
    const rc = linux.removexattr(p, n);
    if (linux.errno(rc) != .SUCCESS) return xattrErr(linux.errno(rc));
}

/// List all xattr names on a path.  Caller frees each name and the slice.
pub fn list(a: std.mem.Allocator, path: []const u8) ![][]u8 {
    var pb: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &pb);
    var dummy: [1]u8 = undefined;
    const size_rc = linux.listxattr(p, &dummy, 0);
    const e = linux.errno(size_rc);
    if (e != .SUCCESS) return xattrErr(e);
    const size: usize = size_rc;
    if (size == 0) return a.alloc([]u8, 0);
    const buf = try a.alloc(u8, size);
    defer a.free(buf);
    const rc = linux.listxattr(p, buf.ptr, size);
    if (linux.errno(rc) != .SUCCESS) return xattrErr(linux.errno(rc));
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |item| a.free(item);
        out.deinit(a);
    }
    var it = std.mem.splitScalar(u8, buf[0..rc], 0);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try out.append(a, try a.dupe(u8, name));
    }
    return out.toOwnedSlice(a);
}

pub fn getFileContext(a: std.mem.Allocator, path: []const u8) !?[]u8 {
    return get(a, path, selinux_xattr);
}

pub fn setFileContext(path: []const u8, context: []const u8) !void {
    var buf: [1024]u8 = undefined;
    if (context.len + 1 > buf.len) return error.ContextTooLong;
    @memcpy(buf[0..context.len], context);
    buf[context.len] = 0;
    try set(path, selinux_xattr, buf[0 .. context.len + 1]);
}

/// `selinux_preserve_fcontext()` equivalent for paths: copy an existing label
/// onto a newly created file.  Missing labels are left untouched.
pub fn copyFileContext(a: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const value = (try getFileContext(a, from)) orelse return;
    defer a.free(value);
    try set(to, selinux_xattr, value);
}

pub const Component = enum { user, role, type, range };

pub const Context = struct {
    user: []const u8,
    role: []const u8,
    type: []const u8,
    range: []const u8,
};

/// Parse `user:role:type:range`; the range may itself contain ':' (MCS/MLS).
pub fn parseContext(text: []const u8) !Context {
    const c1 = std.mem.indexOfScalar(u8, text, ':') orelse return error.MalformedContext;
    const c2 = std.mem.indexOfScalarPos(u8, text, c1 + 1, ':') orelse return error.MalformedContext;
    const c3 = std.mem.indexOfScalarPos(u8, text, c2 + 1, ':') orelse return error.MalformedContext;
    const ctx = Context{
        .user = text[0..c1],
        .role = text[c1 + 1 .. c2],
        .type = text[c2 + 1 .. c3],
        .range = text[c3 + 1 ..],
    };
    if (ctx.user.len == 0 or ctx.role.len == 0 or ctx.type.len == 0 or ctx.range.len == 0) return error.MalformedContext;
    return ctx;
}

pub fn formatContext(a: std.mem.Allocator, ctx: Context) ![]u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{s}:{s}", .{ ctx.user, ctx.role, ctx.type, ctx.range });
}

pub fn setComponent(a: std.mem.Allocator, text: []const u8, component: Component, value: []const u8) ![]u8 {
    if (value.len == 0) return error.MalformedContext;
    var ctx = try parseContext(text);
    switch (component) {
        .user => ctx.user = value,
        .role => ctx.role = value,
        .type => ctx.type = value,
        .range => ctx.range = value,
    }
    return formatContext(a, ctx);
}

pub const Boolean = struct {
    name: []const u8,
    current: bool,
    pending: bool,
};

/// SELinux boolean pseudo-files contain "<current> <pending>\n".
pub fn parseBoolean(text: []const u8) !Boolean {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const a = it.next() orelse return error.MalformedBoolean;
    const b = it.next() orelse return error.MalformedBoolean;
    if (it.next() != null) return error.MalformedBoolean;
    if (!std.mem.eql(u8, a, "0") and !std.mem.eql(u8, a, "1")) return error.MalformedBoolean;
    if (!std.mem.eql(u8, b, "0") and !std.mem.eql(u8, b, "1")) return error.MalformedBoolean;
    return .{ .name = "", .current = a[0] == '1', .pending = b[0] == '1' };
}

pub fn readBoolean(a: std.mem.Allocator, path: []const u8) !Boolean {
    const data = blk: {
        var pb: [max_path:0]u8 = undefined;
        const p = try pathZ(path, &pb);
        const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(rc) != .SUCCESS) return xattrErr(linux.errno(rc));
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var buf: [128]u8 = undefined;
        while (true) {
            const n = linux.read(fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
            if (n == 0) break;
            try out.appendSlice(a, buf[0..n]);
        }
        break :blk try out.toOwnedSlice(a);
    };
    defer a.free(data);
    var result = try parseBoolean(data);
    result.name = std.fs.path.basename(path);
    return result;
}

pub fn writeBoolean(path: []const u8, value: bool) !void {
    var pb: [max_path:0]u8 = undefined;
    const p = try pathZ(path, &pb);
    const rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return xattrErr(linux.errno(rc));
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const text = if (value) "1 1\n" else "0 0\n";
    const n = linux.write(fd, text, text.len);
    if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
}
