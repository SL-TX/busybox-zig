//! Small remaining-category applets that are present in the default registry:
//! ascii, dc, bbconfig.

const std = @import("std");
const linux = std.os.linux;

pub const init = struct {
    pub fn init() void {}
};

fn out(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const a = std.heap.page_allocator;
    const result = a.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| result[i] = std.mem.span(argv[i]);
    return result;
}

pub fn formatAsciiLine(code: u8, buf: []u8) ![]const u8 {
    const glyph: u8 = if (code >= 32 and code < 127) code else '.';
    return std.fmt.bufPrint(buf, "{d: >3} 0x{x:0>2} {c}", .{ code, code, glyph });
}

/// Evaluate an integer reverse-Polish expression (the subset of dc we support).
pub fn dcEval(input: []const u8) !i64 {
    var stack: [64]i64 = undefined;
    var depth: usize = 0;
    var it = std.mem.tokenizeAny(u8, input, " \t\n");
    while (it.next()) |token| {
        if (std.fmt.parseInt(i64, token, 10)) |value| {
            if (depth == stack.len) return error.InvalidExpression;
            stack[depth] = value;
            depth += 1;
            continue;
        } else |_| {}

        if (token.len != 1) return error.InvalidExpression;
        if (depth < 2) return error.InvalidExpression;
        const b = stack[depth - 1];
        const a = stack[depth - 2];
        const result: i64 = switch (token[0]) {
            '+' => std.math.add(i64, a, b) catch return error.InvalidExpression,
            '-' => std.math.sub(i64, a, b) catch return error.InvalidExpression,
            '*' => std.math.mul(i64, a, b) catch return error.InvalidExpression,
            '/' => if (b == 0) return error.InvalidExpression else @divTrunc(a, b),
            else => return error.InvalidExpression,
        };
        stack[depth - 2] = result;
        depth -= 1;
    }
    if (depth != 1) return error.InvalidExpression;
    return stack[0];
}

pub fn bbconfigLine(name: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "CONFIG_{s}=y\n", .{name});
}

pub fn ascii_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    var buf: [64]u8 = undefined;
    for (0..256) |code| {
        const line = formatAsciiLine(@intCast(code), &buf) catch continue;
        out(line);
        out("\n");
    }
    return 0;
}

pub fn dc_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const args = argsFrom(argv, argc);
    if (args.len < 2) return 1;
    var expression: std.ArrayList(u8) = .empty;
    const a = std.heap.page_allocator;
    defer expression.deinit(a);
    for (args[1..], 0..) |arg, i| {
        if (i > 0) expression.append(a, ' ') catch return 1;
        expression.appendSlice(a, arg) catch return 1;
    }
    const value = dcEval(expression.items) catch return 1;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{d}\n", .{value}) catch return 1;
    out(line);
    return 0;
}

