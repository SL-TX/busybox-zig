//! Aggregate test entry point: `zig build test`.

test {
    _ = @import("libbb_zig/string_test.zig");
    _ = @import("libbb_zig/process_test.zig");
    _ = @import("libbb_zig/io_test.zig");
    _ = @import("libbb_zig/hash_test.zig");
    _ = @import("libbb_zig/socket_test.zig");
    _ = @import("libbb_zig/util_test.zig");
    _ = @import("libbb_zig/util_more_test.zig");
    _ = @import("libbb_zig/pw_test.zig");
    _ = @import("applets_test.zig");
    _ = @import("coreutils/coreutils_test.zig");
    _ = @import("coreutils/fileops_test.zig");
    _ = @import("coreutils/textops_test.zig");
    _ = @import("coreutils/recursive_test.zig");
    _ = @import("coreutils/sed_test.zig");
    _ = @import("coreutils/awk_test.zig");
    _ = @import("networking/network_test.zig");
    _ = @import("miscutils/misc_test.zig");
    _ = @import("procps/procps_test.zig");
}
