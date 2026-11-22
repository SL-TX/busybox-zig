//! Aggregate test entry point: `zig build test`.

test {
    _ = @import("libbb_zig/string_test.zig");
    _ = @import("libbb_zig/process_test.zig");
    _ = @import("libbb_zig/io_test.zig");
    _ = @import("libbb_zig/hash_test.zig");
    _ = @import("libbb_zig/socket_test.zig");
    // Task 12 — libbb networking helpers (Wave 3 prerequisites).
    _ = @import("libbb_zig/net/inet_test.zig");
    _ = @import("libbb_zig/net/socket_test.zig");
    _ = @import("libbb_zig/net/dns_test.zig");
    _ = @import("libbb_zig/net/http_test.zig");
    _ = @import("libbb_zig/net/tls_test.zig");
    _ = @import("libbb_zig/net/dhcp_test.zig");
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
    // Task 19 — libbb compression/archive helpers (Wave 5 prerequisites).
    _ = @import("libbb_zig/compression/gzip_test.zig");
    _ = @import("libbb_zig/compression/bzip2_test.zig");
    _ = @import("libbb_zig/compression/xz_test.zig");
    _ = @import("libbb_zig/compression/lzop_test.zig");
    _ = @import("libbb_zig/archive/tar_test.zig");
    _ = @import("libbb_zig/archive/cpio_test.zig");
    _ = @import("libbb_zig/archive/rpm_test.zig");
    _ = @import("libbb_zig/archive/dpkg_test.zig");
    // Task 15 — libbb process/terminal helpers (Wave 4 prerequisites).
    _ = @import("libbb_zig/procps_test.zig");
    _ = @import("libbb_zig/signals_more_test.zig");
    _ = @import("libbb_zig/pty_test.zig");
    _ = @import("libbb_zig/term/termios_test.zig");
    _ = @import("libbb_zig/term/keyboard_test.zig");
    _ = @import("libbb_zig/term/console_test.zig");
    _ = @import("libbb_zig/term/fb_test.zig");
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
    _ = @import("console_tools/console_tools_test.zig");
    _ = @import("shell/shell_test.zig");
    _ = @import("loginutils/login_test.zig");
    _ = @import("remaining/remaining_test.zig");
    _ = @import("util-linux/util_linux_test.zig");
    _ = @import("e2fsprogs/e2fsprogs_test.zig");
    _ = @import("modutils/modutils_test.zig");
    _ = @import("final_review_test.zig");
}
