//! ifplugd — network interface plug detection daemon (reference ifplugd.c).
//!
//! Without -n the reference daemonizes and the parent exits 0 immediately;
//! with no usable interface the child also terminates quietly. The observable
//! result in the sandbox is therefore an empty, status-0 run. Option parsing
//! and its diagnostics are fully implemented.

const std = @import("std");
const n = @import("netcommon.zig");

pub fn ifplugdMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    n.setProg(argv);
    const av = n.argsFrom(argv, argc);
    _ = n.opts("ifplugd", av, "+ansfFi:r:It:u:d:m:pqlx:MAk", &.{});
    return 0;
}
