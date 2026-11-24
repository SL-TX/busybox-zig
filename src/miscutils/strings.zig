//! strings — print printable character sequences (reference miscutils/strings.c).

const std = @import("std");
const c = @import("common.zig");
const bb = @import("libbb_zig");

fn isPrint(cch: u8) bool {
    return (cch >= 0x20 and cch <= 0x7e) or cch == '\t';
}

pub fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    const a = std.heap.page_allocator;
    const args = c.argsFrom(a, argv, argc) catch return 1;
    c.setName("strings");
    const o = c.opts("strings", args, "afon:t:", &.{});
    // getopt32 in the reference stores each option's argument; for the single
    // -n/-t used by our cases the last value is the effective one.
    var n_arg: []const u8 = "4";
    var radix: []const u8 = "o";
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const tok = args[i];
            if (std.mem.eql(u8, tok, "-n") and i + 1 < args.len) {
                i += 1;
                n_arg = args[i];
            } else if (std.mem.startsWith(u8, tok, "-n") and tok.len > 2) {
                n_arg = tok[2..];
            } else if (std.mem.eql(u8, tok, "-t") and i + 1 < args.len) {
                i += 1;
                radix = args[i];
            } else if (std.mem.startsWith(u8, tok, "-t") and tok.len > 2) {
                radix = tok[2..];
            }
        }
    }
    const min_len = std.fmt.parseInt(usize, n_arg, 10) catch c.usageDie("strings");
    if (min_len == 0) c.usageDie("strings");
    // The reference decrements n after allocating n+1 bytes, so a string is
    // emitted when count reaches (min_len-1) and is min_len bytes long.
    const n = min_len - 1;
    if (radix.len != 1 or (radix[0] != 'd' and radix[0] != 'o' and radix[0] != 'x')) c.usageDie("strings");

    const flags = o.flags;
    const print_name = (flags & 2) != 0;
    const print_offset = (flags & 4) != 0 or (flags & 16) != 0;

    var status: c_int = 0;
    const files: []const []const u8 = if (o.args.len > 0) o.args else &[_][]const u8{"(standard input)"};
    for (files) |name| {
        var data: []u8 = undefined;
        if (o.args.len == 0) {
            data = c.readStdin(a) catch {
                status = 1;
                continue;
            };
        } else {
            var en: c_int = 0;
            data = c.readFile(a, name, &en) orelse {
                c.errorMsg(en, "{s}", .{name});
                status = 1;
                continue;
            };
        }
        defer a.free(data);
        var string = a.alloc(u8, min_len + 1) catch return 1;
        defer a.free(string);
        var count: usize = 0;
        var offset: usize = 0;
        for (data) |ch| {
            if (isPrint(ch)) {
                if (count > n) {
                    c.out(&.{ch});
                } else {
                    string[count] = ch;
                    if (count == n) {
                        if (print_name) c.printfOut("{s}: ", .{name});
                        if (print_offset) {
                            const start = offset - n;
                            const width: usize = 7;
                            const base: u8 = switch (radix[0]) {
                                'd' => 10,
                                'o' => 8,
                                else => 16,
                            };
                            // Format with explicit base and width padding.
                            var rev: [64]u8 = undefined;
                            var len: usize = 0;
                            var v = start;
                            if (v == 0) {
                                rev[len] = '0';
                                len += 1;
                            }
                            while (v > 0) : (v /= base) {
                                const d: u8 = @intCast(v % base);
                                rev[len] = if (d < 10) '0' + d else 'a' + (d - 10);
                                len += 1;
                            }
                            var pad: usize = if (len < width) width - len else 0;
                            while (pad > 0) : (pad -= 1) c.out(" ");
                            while (len > 0) {
                                len -= 1;
                                c.out(rev[len .. len + 1]);
                            }
                            c.out(" ");
                        }
                        c.out(string[0 .. n + 1]);
                    }
                    count += 1;
                }
            } else {
                if (count > n) c.out("\n");
                count = 0;
            }
            offset += 1;
        }
    }
    return status;
}
