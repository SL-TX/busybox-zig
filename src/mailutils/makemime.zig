//! makemime — create a multipart MIME message (reference mailutils/makemime.c).
//!
//! getopt32 accepts -c -e -o -C -N -a; only -c, -C, -o and repeated -a affect
//! the output (-e/-N are compatibility no-ops, like the reference). The random
//! boundary is rendered as %u-%u-%u and normalized by the parity harness.

const std = @import("std");
const linux = std.os.linux;
const m = @import("mail_common.zig");

const SPECS = [_]m.OptSpec{
    .{ .ch = 'c', .kind = .required },
    .{ .ch = 'e', .kind = .required },
    .{ .ch = 'o', .kind = .required },
    .{ .ch = 'C', .kind = .required },
    .{ .ch = 'N', .kind = .required },
    .{ .ch = 'a', .kind = .list },
};

pub fn makemimeMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    m.setProg(argv);
    const av = m.argsFrom(argv, argc);
    const opts = m.parseOptions("makemime", av, &SPECS);

    const content_type = opts.value('c') orelse "application/octet-stream";
    const charset = opts.value('C') orelse "us-ascii";
    if (opts.value('o')) |out_path| {
        const z = m.zstr(out_path) catch return 1;
        const fd = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o666);
        if (linux.errno(fd) == .SUCCESS) {
            _ = linux.dup2(@intCast(fd), 1);
            _ = linux.close(@intCast(fd));
        }
    }

    var files = opts.args;
    if (files.len == 0) {
        const dash = m.A.alloc([]const u8, 1) catch return 1;
        dash[0] = "-";
        files = dash;
    }

    for (opts.list.items) |hdr| {
        m.put("{s}\n", .{hdr});
    }

    var seed: u64 = m.monotonicUs();
    var rnd: [3]u32 = undefined;
    for (&rnd) |*r| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        r.* = @truncate(seed >> 33);
    }
    const boundary = std.fmt.allocPrint(m.A, "{d}-{d}-{d}", .{ rnd[0], rnd[1], rnd[2] }) catch return 1;

    m.put("Mime-Version: 1.0\nContent-Type: multipart/mixed; boundary=\"{s}\"\n", .{boundary});

    for (files) |file| {
        const base = std.fs.path.basename(std.mem.trimEnd(u8, file, "/"));
        m.put("\n--{s}\nContent-Type: {s}; charset={s}\n", .{ boundary, content_type, charset });
        m.put("Content-Disposition: inline; filename=\"{s}\"\n", .{base});
        m.put("Content-Transfer-Encoding: base64\n", .{});
        m.printFileBase64(file);
    }
    m.put("\n--{s}--\n\n", .{boundary});
    return 0;
}
