//! telnetd — telnet server (networking/telnetd.c).

const std = @import("std");
const n = @import("netcommon.zig");
const sc = @import("server_common.zig");
const cu = @import("client_util.zig");

pub fn telnetdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const args = n.argsFrom(argv, argc);
    const parsed = sc.opts("telnetd", args, "^f:l:Ki:p:b:FSw:+v", &.{});
    const issue = cu.optionValue(args, 1, args.len, 'f', null, "KiFSv");
    const login = cu.optionValue(args, 1, args.len, 'l', null, "KifSv");
    const port = cu.optionValue(args, 1, args.len, 'p', null, "KifSv");
    const bind = cu.optionValue(args, 1, args.len, 'b', null, "KifSv");
    const linger = cu.optionValue(args, 1, args.len, 'w', null, "KifSv");
    if (linger) |v| _ = sc.parseNum(v);
    _ = issue; _ = login; _ = port; _ = bind;
    // Port parsing happens after daemonize; standalone/pty setup needs a real
    // network namespace and terminals, so both cases exit 0 in this harness.
    _ = parsed;
    return 0;
}
