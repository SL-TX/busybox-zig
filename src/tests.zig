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
    _ = @import("libbb_zig/xfuncs_test.zig");
    _ = @import("libbb_zig/getopt_test.zig");
    _ = @import("libbb_zig/path_test.zig");
    _ = @import("libbb_zig/regex_test.zig");
    _ = @import("libbb_zig/file_test.zig");
    _ = @import("libbb_zig/copy_test.zig");
    _ = @import("libbb_zig/recursive_test.zig");
    _ = @import("libbb_zig/process_more_test.zig");
    _ = @import("libbb_zig/identity_test.zig");
    _ = @import("libbb_zig/utmp_test.zig");
    _ = @import("libbb_zig/mtab_test.zig");
    _ = @import("applets_test.zig");
    _ = @import("meta_test.zig");
    _ = @import("usage_test.zig");
    _ = @import("coreutils/coreutils_test.zig");
    _ = @import("coreutils/fileops_test.zig");
    _ = @import("coreutils/textops_test.zig");
    _ = @import("coreutils/recursive_test.zig");
    _ = @import("coreutils/sed_test.zig");
    _ = @import("coreutils/awk_test.zig");
    _ = @import("networking/network_test.zig");
    _ = @import("miscutils/misc_test.zig");
    _ = @import("procps/procps_test.zig");
    _ = @import("shell/shell_test.zig");
    _ = @import("loginutils/login_test.zig");
    _ = @import("remaining/remaining_test.zig");
    _ = @import("util-linux/util_linux_test.zig");
    _ = @import("final_review_test.zig");
}
