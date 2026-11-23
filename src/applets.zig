//! Applet registry — rebuilt from the reference-generated manifest.
//!
//! Every entry in `applet_manifest.entries` becomes a registry record when its
//! generated `APPLET_<name>` config symbol is enabled. Applets without a real
//! Zig implementation use `stubMain`; the 43 implemented applets are mapped by
//! `mainFor`. Internal helper names (tls_aes, tcpudp, isrv, ...) never appear
//! in the manifest and therefore never appear in `--list` or `--list-full`.

const std = @import("std");
const coreutils = @import("coreutils");
const cfg = @import("config");
const config = cfg.config;
const manifest = @import("generated/applet_manifest.zig");
const usage = @import("generated/usage.zig");

pub const Suid = manifest.Suid;

pub const AppletFlags = struct {
    noexec: bool = false,
    nofork: bool = false,
};

pub const Applet = struct {
    name: []const u8,
    main: *const fn (argc: c_int, argv: [*][*:0]const u8) c_int,
    /// Install location from the reference manifest ("bin", "sbin",
    /// "usr/bin", "usr/sbin" or "root"). Never has a leading slash.
    location: []const u8,
    suid: Suid,
    noexec: bool,
    nofork: bool,
    scripted: bool,
    category: []const u8,
    /// Exact `APPLET --help` body (everything after the banner line), from the
    /// reference-generated `src/generated/usage.zig`.
    usage: []const u8,
    /// Kconfig symbol, e.g. "CONFIG_CAT".
    config: []const u8,
    /// Alias of `config`, kept for callers that call this field `flag`.
    flag: []const u8,
    default_enabled: bool,
    flags: AppletFlags,
};

pub const MainFn = *const fn (c_int, [*][*:0]const u8) c_int;

/// Unimplemented applets fail loudly instead of exiting silently.
fn stubMain(_: c_int, argv: [*][*:0]const u8) c_int {
    const name = std.mem.span(argv[0]);
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: not implemented\n", .{name}) catch "not implemented\n";
    _ = std.os.linux.write(2, msg.ptr, msg.len);
    return 1;
}

/// Map an applet name to its real main. Only the 43 implemented applets are
/// listed here; every other manifest entry resolves to `stubMain`.
fn mainFor(comptime name: []const u8) MainFn {
    // coreutils
    if (std.mem.eql(u8, name, "cat")) return coreutils.cat_main;
    if (std.mem.eql(u8, name, "ls")) return coreutils.ls_main;
    if (std.mem.eql(u8, name, "echo")) return coreutils.echo_main;
    if (std.mem.eql(u8, name, "printf")) return coreutils.printf_main;
    if (std.mem.eql(u8, name, "cp")) return coreutils.cp_main;
    if (std.mem.eql(u8, name, "mv")) return coreutils.mv_main;
    if (std.mem.eql(u8, name, "rm")) return coreutils.rm_main;
    if (std.mem.eql(u8, name, "mkdir")) return coreutils.mkdir_main;
    if (std.mem.eql(u8, name, "touch")) return coreutils.touch_main;
    if (std.mem.eql(u8, name, "head")) return coreutils.head_main;
    if (std.mem.eql(u8, name, "tail")) return coreutils.tail_main;
    if (std.mem.eql(u8, name, "sort")) return coreutils.sort_main;
    if (std.mem.eql(u8, name, "uniq")) return coreutils.uniq_main;
    if (std.mem.eql(u8, name, "wc")) return coreutils.wc_main;
    if (std.mem.eql(u8, name, "cut")) return coreutils.cut_main;
    // Task 7c — file-and-metadata coreutils wave
    if (std.mem.eql(u8, name, "ln")) return coreutils.ln_main;
    if (std.mem.eql(u8, name, "du")) return coreutils.du_main;
    if (std.mem.eql(u8, name, "df")) return coreutils.df_main;
    if (std.mem.eql(u8, name, "chmod")) return coreutils.chmod_main;
    if (std.mem.eql(u8, name, "chown")) return coreutils.chown_main;
    if (std.mem.eql(u8, name, "chgrp")) return coreutils.chgrp_main;
    if (std.mem.eql(u8, name, "chroot")) return coreutils.chroot_main;
    if (std.mem.eql(u8, name, "stat")) return coreutils.stat_main;
    if (std.mem.eql(u8, name, "dd")) return coreutils.dd_main;
    if (std.mem.eql(u8, name, "date")) return coreutils.date_main;
    if (std.mem.eql(u8, name, "stty")) return coreutils.stty_main;
    if (std.mem.eql(u8, name, "shred")) return coreutils.shred_main;
    // Task 7b — text-and-number coreutils wave
    if (std.mem.eql(u8, name, "fold")) return coreutils.fold_main;
    if (std.mem.eql(u8, name, "expand")) return coreutils.expand_main;
    if (std.mem.eql(u8, name, "unexpand")) return coreutils.unexpand_main;
    if (std.mem.eql(u8, name, "join")) return coreutils.join_main;
    if (std.mem.eql(u8, name, "nl")) return coreutils.nl_main;
    if (std.mem.eql(u8, name, "od")) return coreutils.od_main;
    if (std.mem.eql(u8, name, "paste")) return coreutils.paste_main;
    if (std.mem.eql(u8, name, "split")) return coreutils.split_main;
    if (std.mem.eql(u8, name, "shuf")) return coreutils.shuf_main;
    if (std.mem.eql(u8, name, "comm")) return coreutils.comm_main;
    if (std.mem.eql(u8, name, "sum")) return coreutils.sum_main;
    if (std.mem.eql(u8, name, "cksum")) return coreutils.cksum_main;
    if (std.mem.eql(u8, name, "crc32")) return coreutils.crc32_main;
    if (std.mem.eql(u8, name, "base32")) return coreutils.base32_main;
    if (std.mem.eql(u8, name, "base64")) return coreutils.base64_main;
    if (std.mem.eql(u8, name, "md5sum")) return coreutils.md5sum_main;
    if (std.mem.eql(u8, name, "sha1sum")) return coreutils.sha1sum_main;
    if (std.mem.eql(u8, name, "sha256sum")) return coreutils.sha256sum_main;
    if (std.mem.eql(u8, name, "sha384sum")) return coreutils.sha384sum_main;
    if (std.mem.eql(u8, name, "sha3sum")) return coreutils.sha3sum_main;
    if (std.mem.eql(u8, name, "sha512sum")) return coreutils.sha512sum_main;
    if (std.mem.eql(u8, name, "uudecode")) return coreutils.uudecode_main;
    if (std.mem.eql(u8, name, "uuencode")) return coreutils.uuencode_main;
    if (std.mem.eql(u8, name, "factor")) return coreutils.factor_main;
    if (std.mem.eql(u8, name, "expr")) return coreutils.expr_main;
    if (std.mem.eql(u8, name, "seq")) return coreutils.seq_main;
    if (std.mem.eql(u8, name, "tac")) return coreutils.tac_main;
    if (std.mem.eql(u8, name, "tr")) return coreutils.tr_main;
    if (std.mem.eql(u8, name, "tsort")) return coreutils.tsort_main;
    if (std.mem.eql(u8, name, "dos2unix")) return coreutils.dos2unix_main;
    if (std.mem.eql(u8, name, "unix2dos")) return coreutils.unix2dos_main;
    if (std.mem.eql(u8, name, "sed")) return coreutils.sed_main;
    if (std.mem.eql(u8, name, "awk")) return coreutils.awk_main;
    if (std.mem.eql(u8, name, "true")) return coreutils.true_main;
    if (std.mem.eql(u8, name, "false")) return coreutils.false_main;
    // Task 7d — test builtins share one POSIX expression parser.
    if (std.mem.eql(u8, name, "test")) return coreutils.test_main;
    if (std.mem.eql(u8, name, "[")) return coreutils.lbracket_main;
    if (std.mem.eql(u8, name, "[[")) return coreutils.dbracket_main;
    // Task 7a — simple coreutils wave
    if (std.mem.eql(u8, name, "pwd")) return coreutils.pwd_main;
    if (std.mem.eql(u8, name, "basename")) return coreutils.basename_main;
    if (std.mem.eql(u8, name, "dirname")) return coreutils.dirname_main;
    if (std.mem.eql(u8, name, "tee")) return coreutils.tee_main;
    if (std.mem.eql(u8, name, "yes")) return coreutils.yes_main;
    if (std.mem.eql(u8, name, "sleep")) return coreutils.sleep_main;
    if (std.mem.eql(u8, name, "usleep")) return coreutils.usleep_main;
    if (std.mem.eql(u8, name, "nproc")) return coreutils.nproc_main;
    if (std.mem.eql(u8, name, "sync")) return coreutils.sync_main;
    if (std.mem.eql(u8, name, "fsync")) return coreutils.fsync_main;
    if (std.mem.eql(u8, name, "link")) return coreutils.link_main;
    if (std.mem.eql(u8, name, "unlink")) return coreutils.unlink_main;
    if (std.mem.eql(u8, name, "rmdir")) return coreutils.rmdir_main;
    if (std.mem.eql(u8, name, "mkfifo")) return coreutils.mkfifo_main;
    if (std.mem.eql(u8, name, "mknod")) return coreutils.mknod_main;
    if (std.mem.eql(u8, name, "mktemp")) return coreutils.mktemp_main;
    if (std.mem.eql(u8, name, "readlink")) return coreutils.readlink_main;
    if (std.mem.eql(u8, name, "realpath")) return coreutils.realpath_main;
    if (std.mem.eql(u8, name, "truncate")) return coreutils.truncate_main;
    if (std.mem.eql(u8, name, "install")) return coreutils.install_main;
    if (std.mem.eql(u8, name, "printenv")) return coreutils.printenv_main;
    if (std.mem.eql(u8, name, "env")) return coreutils.env_main;
    if (std.mem.eql(u8, name, "id")) return coreutils.id_main;
    if (std.mem.eql(u8, name, "whoami")) return coreutils.whoami_main;
    if (std.mem.eql(u8, name, "logname")) return coreutils.logname_main;
    if (std.mem.eql(u8, name, "groups")) return coreutils.groups_main;
    if (std.mem.eql(u8, name, "users")) return coreutils.users_main;
    if (std.mem.eql(u8, name, "who")) return coreutils.who_main;
    if (std.mem.eql(u8, name, "w")) return coreutils.w_main;
    if (std.mem.eql(u8, name, "tty")) return coreutils.tty_main;
    if (std.mem.eql(u8, name, "hostid")) return coreutils.hostid_main;
    if (std.mem.eql(u8, name, "uname")) return coreutils.uname_main;
    if (std.mem.eql(u8, name, "arch")) return coreutils.arch_main;
    if (std.mem.eql(u8, name, "nice")) return coreutils.nice_main;
    if (std.mem.eql(u8, name, "nohup")) return coreutils.nohup_main;
    if (std.mem.eql(u8, name, "timeout")) return coreutils.timeout_main;
    // util-linux
    if (std.mem.eql(u8, name, "mount")) return @import("util_linux").mount_main;
    if (std.mem.eql(u8, name, "umount")) return @import("util_linux").umount_main;
    if (std.mem.eql(u8, name, "dmesg")) return @import("util_linux").dmesg_main;
    if (std.mem.eql(u8, name, "blkid")) return @import("util_linux").blkid_main;
    // Task 10a — safe util-linux sub-wave
    if (std.mem.eql(u8, name, "acpid")) return @import("util_linux").acpid_main;
    if (std.mem.eql(u8, name, "blkdiscard")) return @import("util_linux").blkdiscard_main;
    if (std.mem.eql(u8, name, "blockdev")) return @import("util_linux").blockdev_main;
    if (std.mem.eql(u8, name, "cal")) return @import("util_linux").cal_main;
    if (std.mem.eql(u8, name, "eject")) return @import("util_linux").eject_main;
    if (std.mem.eql(u8, name, "fallocate")) return @import("util_linux").fallocate_main;
    if (std.mem.eql(u8, name, "fatattr")) return @import("util_linux").fatattr_main;
    if (std.mem.eql(u8, name, "fatlabel")) return @import("util_linux").fatlabel_main;
    if (std.mem.eql(u8, name, "fdflush")) return @import("util_linux").fdflush_main;
    if (std.mem.eql(u8, name, "flock")) return @import("util_linux").flock_main;
    if (std.mem.eql(u8, name, "freeramdisk")) return @import("util_linux").freeramdisk_main;
    if (std.mem.eql(u8, name, "fsfreeze")) return @import("util_linux").fsfreeze_main;
    if (std.mem.eql(u8, name, "fstrim")) return @import("util_linux").fstrim_main;
    if (std.mem.eql(u8, name, "getopt")) return @import("util_linux").getopt_main;
    if (std.mem.eql(u8, name, "hd")) return @import("util_linux").hd_main;
    if (std.mem.eql(u8, name, "hexdump")) return @import("util_linux").hexdump_main;
    if (std.mem.eql(u8, name, "hwclock")) return @import("util_linux").hwclock_main;
    if (std.mem.eql(u8, name, "ionice")) return @import("util_linux").ionice_main;
    if (std.mem.eql(u8, name, "ipcrm")) return @import("util_linux").ipcrm_main;
    if (std.mem.eql(u8, name, "ipcs")) return @import("util_linux").ipcs_main;
    if (std.mem.eql(u8, name, "last")) return @import("util_linux").last_main;
    if (std.mem.eql(u8, name, "linux32")) return @import("util_linux").linux32_main;
    if (std.mem.eql(u8, name, "linux64")) return @import("util_linux").linux64_main;
    if (std.mem.eql(u8, name, "lsblk")) return @import("util_linux").lsblk_main;
    if (std.mem.eql(u8, name, "lspci")) return @import("util_linux").lspci_main;
    if (std.mem.eql(u8, name, "lsusb")) return @import("util_linux").lsusb_main;
    if (std.mem.eql(u8, name, "mesg")) return @import("util_linux").mesg_main;
    if (std.mem.eql(u8, name, "more")) return @import("util_linux").more_main;
    if (std.mem.eql(u8, name, "mountpoint")) return @import("util_linux").mountpoint_main;
    if (std.mem.eql(u8, name, "nologin")) return @import("util_linux").nologin_main;
    if (std.mem.eql(u8, name, "readprofile")) return @import("util_linux").readprofile_main;
    if (std.mem.eql(u8, name, "renice")) return @import("util_linux").renice_main;
    if (std.mem.eql(u8, name, "rev")) return @import("util_linux").rev_main;
    if (std.mem.eql(u8, name, "rtcwake")) return @import("util_linux").rtcwake_main;
    if (std.mem.eql(u8, name, "script")) return @import("util_linux").script_main;
    if (std.mem.eql(u8, name, "scriptreplay")) return @import("util_linux").scriptreplay_main;
    if (std.mem.eql(u8, name, "setarch")) return @import("util_linux").setarch_main;
    if (std.mem.eql(u8, name, "setpriv")) return @import("util_linux").setpriv_main;
    if (std.mem.eql(u8, name, "setsid")) return @import("util_linux").setsid_main;
    if (std.mem.eql(u8, name, "swaplabel")) return @import("util_linux").swaplabel_main;
    if (std.mem.eql(u8, name, "taskset")) return @import("util_linux").taskset_main;
    if (std.mem.eql(u8, name, "uevent")) return @import("util_linux").uevent_main;
    if (std.mem.eql(u8, name, "uuidgen")) return @import("util_linux").uuidgen_main;
    if (std.mem.eql(u8, name, "wall")) return @import("util_linux").wall_main;
    if (std.mem.eql(u8, name, "xxd")) return @import("util_linux").xxd_main;
    // Task 10b — privileged/destructive util-linux sub-wave
    if (std.mem.eql(u8, name, "chrt")) return @import("util_linux").chrt_main;
    if (std.mem.eql(u8, name, "fbset")) return @import("util_linux").fbset_main;
    if (std.mem.eql(u8, name, "fdformat")) return @import("util_linux").fdformat_main;
    if (std.mem.eql(u8, name, "fdisk")) return @import("util_linux").fdisk_main;
    if (std.mem.eql(u8, name, "findfs")) return @import("util_linux").findfs_main;
    if (std.mem.eql(u8, name, "fsck.minix")) return @import("util_linux").fsck_minix_main;
    if (std.mem.eql(u8, name, "losetup")) return @import("util_linux").losetup_main;
    if (std.mem.eql(u8, name, "mdev")) return @import("util_linux").mdev_main;
    if (std.mem.eql(u8, name, "mkdosfs")) return @import("util_linux").mkdosfs_main;
    if (std.mem.eql(u8, name, "mke2fs")) return @import("util_linux").mke2fs_main;
    if (std.mem.eql(u8, name, "mkfs.ext2")) return @import("util_linux").mkfs_ext2_main;
    if (std.mem.eql(u8, name, "mkfs.minix")) return @import("util_linux").mkfs_minix_main;
    if (std.mem.eql(u8, name, "mkfs.vfat")) return @import("util_linux").mkfs_vfat_main;
    if (std.mem.eql(u8, name, "mkswap")) return @import("util_linux").mkswap_main;
    if (std.mem.eql(u8, name, "nsenter")) return @import("util_linux").nsenter_main;
    if (std.mem.eql(u8, name, "pivot_root")) return @import("util_linux").pivot_root_main;
    if (std.mem.eql(u8, name, "rdate")) return @import("util_linux").rdate_main;
    if (std.mem.eql(u8, name, "rdev")) return @import("util_linux").rdev_main;
    if (std.mem.eql(u8, name, "run-init")) return @import("util_linux").run_init_main;
    if (std.mem.eql(u8, name, "swapoff")) return @import("util_linux").swapoff_main;
    if (std.mem.eql(u8, name, "swapon")) return @import("util_linux").swapon_main;
    if (std.mem.eql(u8, name, "switch_root")) return @import("util_linux").switch_root_main;
    if (std.mem.eql(u8, name, "unshare")) return @import("util_linux").unshare_main;
    // networking
    if (std.mem.eql(u8, name, "ifconfig")) return @import("networking").ifconfig_main;
    if (std.mem.eql(u8, name, "ping")) return @import("networking").ping_main;
    if (std.mem.eql(u8, name, "ping6")) return @import("networking").ping6_main;
    if (std.mem.eql(u8, name, "traceroute")) return @import("networking").traceroute_main;
    if (std.mem.eql(u8, name, "traceroute6")) return @import("networking").traceroute6_main;
    if (std.mem.eql(u8, name, "wget")) return @import("networking").wget_main;
    if (std.mem.eql(u8, name, "nc")) return @import("networking").nc_main;
    // Task 13a — diagnostics and addressing
    if (std.mem.eql(u8, name, "ipcalc")) return @import("networking").ipcalc_main;
    if (std.mem.eql(u8, name, "nslookup")) return @import("networking").nslookup_main;
    if (std.mem.eql(u8, name, "arp")) return @import("networking").arp_main;
    if (std.mem.eql(u8, name, "netstat")) return @import("networking").netstat_main;
    if (std.mem.eql(u8, name, "route")) return @import("networking").route_main;
    if (std.mem.eql(u8, name, "ip")) return @import("networking").ip_main;
    if (std.mem.eql(u8, name, "ipaddr")) return @import("networking").ipaddr_main;
    if (std.mem.eql(u8, name, "iplink")) return @import("networking").iplink_main;
    if (std.mem.eql(u8, name, "ipneigh")) return @import("networking").ipneigh_main;
    if (std.mem.eql(u8, name, "iproute")) return @import("networking").iproute_main;
    if (std.mem.eql(u8, name, "iprule")) return @import("networking").iprule_main;
    if (std.mem.eql(u8, name, "iptunnel")) return @import("networking").iptunnel_main;
    if (std.mem.eql(u8, name, "arping")) return @import("networking").arping_main;
    if (std.mem.eql(u8, name, "brctl")) return @import("networking").brctl_main;
    if (std.mem.eql(u8, name, "dnsdomainname")) return @import("networking").dnsdomainname_main;
    if (std.mem.eql(u8, name, "ether-wake")) return @import("networking").ether_wake_main;
    if (std.mem.eql(u8, name, "hostname")) return @import("networking").hostname_main;
    if (std.mem.eql(u8, name, "ifdown")) return @import("networking").ifdown_main;
    if (std.mem.eql(u8, name, "ifenslave")) return @import("networking").ifenslave_main;
    if (std.mem.eql(u8, name, "ifplugd")) return @import("networking").ifplugd_main;
    if (std.mem.eql(u8, name, "ifup")) return @import("networking").ifup_main;
    if (std.mem.eql(u8, name, "nameif")) return @import("networking").nameif_main;
    if (std.mem.eql(u8, name, "slattach")) return @import("networking").slattach_main;
    if (std.mem.eql(u8, name, "tunctl")) return @import("networking").tunctl_main;
    if (std.mem.eql(u8, name, "vconfig")) return @import("networking").vconfig_main;
    if (std.mem.eql(u8, name, "zcip")) return @import("networking").zcip_main;
    // Task 13b — network clients
    if (std.mem.eql(u8, name, "ftpget")) return @import("networking").ftpget_main;
    if (std.mem.eql(u8, name, "ftpput")) return @import("networking").ftpput_main;
    if (std.mem.eql(u8, name, "telnet")) return @import("networking").telnet_main;
    if (std.mem.eql(u8, name, "tftp")) return @import("networking").tftp_main;
    if (std.mem.eql(u8, name, "whois")) return @import("networking").whois_main;
    if (std.mem.eql(u8, name, "netcat")) return @import("networking").netcat_main;
    // Task 13c — network servers
    if (std.mem.eql(u8, name, "dumpleases")) return @import("networking").dumpleases_main;
    if (std.mem.eql(u8, name, "dhcprelay")) return @import("networking").dhcprelay_main;
    if (std.mem.eql(u8, name, "dnsd")) return @import("networking").dnsd_main;
    if (std.mem.eql(u8, name, "httpd")) return @import("networking").httpd_main;
    if (std.mem.eql(u8, name, "fakeidentd")) return @import("networking").fakeidentd_main;
    if (std.mem.eql(u8, name, "pscan")) return @import("networking").pscan_main;
    if (std.mem.eql(u8, name, "ftpd")) return @import("networking").ftpd_main;
    if (std.mem.eql(u8, name, "tftpd")) return @import("networking").tftpd_main;
    if (std.mem.eql(u8, name, "inetd")) return @import("networking").inetd_main;
    if (std.mem.eql(u8, name, "ntpd")) return @import("networking").ntpd_main;
    if (std.mem.eql(u8, name, "tcpsvd")) return @import("networking").tcpsvd_main;
    if (std.mem.eql(u8, name, "udpsvd")) return @import("networking").udpsvd_main;
    if (std.mem.eql(u8, name, "udhcpc")) return @import("networking").udhcpc_main;
    if (std.mem.eql(u8, name, "udhcpc6")) return @import("networking").udhcpc6_main;
    if (std.mem.eql(u8, name, "udhcpd")) return @import("networking").udhcpd_main;
    if (std.mem.eql(u8, name, "telnetd")) return @import("networking").telnetd_main;
    if (std.mem.eql(u8, name, "tc")) return @import("networking").tc_main;
    // Task 13d — TLS and special network applets
    if (std.mem.eql(u8, name, "ssl_client")) return @import("networking").ssl_client_main;
    if (std.mem.eql(u8, name, "ssl_server")) return @import("networking").ssl_server_main;
    if (std.mem.eql(u8, name, "nbd-client")) return @import("networking").nbdclient_main;
    // miscutils
    if (std.mem.eql(u8, name, "ionice")) return @import("miscutils").ionice_main;
    if (std.mem.eql(u8, name, "renice")) return @import("miscutils").renice_main;
    if (std.mem.eql(u8, name, "crontab")) return @import("miscutils").crontab_main;
    // Task 16a — safe miscutils wave
    if (std.mem.eql(u8, name, "ascii")) return @import("miscutils").ascii_main;
    if (std.mem.eql(u8, name, "bbconfig")) return @import("miscutils").bbconfig_main;
    if (std.mem.eql(u8, name, "bc")) return @import("miscutils").bc_main;
    if (std.mem.eql(u8, name, "dc")) return @import("miscutils").dc_main;
    if (std.mem.eql(u8, name, "mim")) return @import("miscutils").mim_main;
    if (std.mem.eql(u8, name, "runlevel")) return @import("miscutils").runlevel_main;
    if (std.mem.eql(u8, name, "strings")) return @import("miscutils").strings_main;
    if (std.mem.eql(u8, name, "time")) return @import("miscutils").time_main;
    if (std.mem.eql(u8, name, "tree")) return @import("miscutils").tree_main;
    if (std.mem.eql(u8, name, "ts")) return @import("miscutils").ts_main;
    if (std.mem.eql(u8, name, "ttysize")) return @import("miscutils").ttysize_main;
    if (std.mem.eql(u8, name, "beep")) return @import("miscutils").beep_main;
    if (std.mem.eql(u8, name, "conspy")) return @import("miscutils").conspy_main;
    if (std.mem.eql(u8, name, "devmem")) return @import("miscutils").devmem_main;
    if (std.mem.eql(u8, name, "fbsplash")) return @import("miscutils").fbsplash_main;
    if (std.mem.eql(u8, name, "hdparm")) return @import("miscutils").hdparm_main;
    if (std.mem.eql(u8, name, "i2cdetect")) return @import("miscutils").i2cdetect_main;
    if (std.mem.eql(u8, name, "i2cdump")) return @import("miscutils").i2cdump_main;
    if (std.mem.eql(u8, name, "i2cget")) return @import("miscutils").i2cget_main;
    if (std.mem.eql(u8, name, "i2cset")) return @import("miscutils").i2cset_main;
    if (std.mem.eql(u8, name, "i2ctransfer")) return @import("miscutils").i2ctransfer_main;
    if (std.mem.eql(u8, name, "lsscsi")) return @import("miscutils").lsscsi_main;
    if (std.mem.eql(u8, name, "mt")) return @import("miscutils").mt_main;
    if (std.mem.eql(u8, name, "partprobe")) return @import("miscutils").partprobe_main;
    if (std.mem.eql(u8, name, "readahead")) return @import("miscutils").readahead_main;
    if (std.mem.eql(u8, name, "setserial")) return @import("miscutils").setserial_main;
    if (std.mem.eql(u8, name, "volname")) return @import("miscutils").volname_main;
    if (std.mem.eql(u8, name, "watchdog")) return @import("miscutils").watchdog_main;
    if (std.mem.eql(u8, name, "chat")) return @import("miscutils").chat_main;
    if (std.mem.eql(u8, name, "crond")) return @import("miscutils").crond_main;
    if (std.mem.eql(u8, name, "getfattr")) return @import("miscutils").getfattr_main;
    if (std.mem.eql(u8, name, "hexedit")) return @import("miscutils").hexedit_main;
    if (std.mem.eql(u8, name, "less")) return @import("miscutils").less_main;
    if (std.mem.eql(u8, name, "makedevs")) return @import("miscutils").makedevs_main;
    if (std.mem.eql(u8, name, "man")) return @import("miscutils").man_main;
    if (std.mem.eql(u8, name, "microcom")) return @import("miscutils").microcom_main;
    if (std.mem.eql(u8, name, "rx")) return @import("miscutils").rx_main;
    if (std.mem.eql(u8, name, "flash_eraseall")) return @import("miscutils").flash_eraseall_main;
    if (std.mem.eql(u8, name, "flash_lock")) return @import("miscutils").flash_lock_main;
    if (std.mem.eql(u8, name, "flash_unlock")) return @import("miscutils").flash_unlock_main;
    if (std.mem.eql(u8, name, "flashcp")) return @import("miscutils").flashcp_main;
    if (std.mem.eql(u8, name, "inotifyd")) return @import("miscutils").inotifyd_main;
    if (std.mem.eql(u8, name, "rfkill")) return @import("miscutils").rfkill_main;
    if (std.mem.eql(u8, name, "seedrng")) return @import("miscutils").seedrng_main;
    if (std.mem.eql(u8, name, "setfattr")) return @import("miscutils").setfattr_main;
    // Task 16b — privileged/device-bound miscutils wave
    if (std.mem.eql(u8, name, "adjtimex")) return @import("miscutils").adjtimex_main;
    if (std.mem.eql(u8, name, "devfsd")) return @import("miscutils").devfsd_main;
    if (std.mem.eql(u8, name, "nanddump")) return @import("miscutils").nanddump_main;
    if (std.mem.eql(u8, name, "nandwrite")) return @import("miscutils").nandwrite_main;
    if (std.mem.eql(u8, name, "raidautorun")) return @import("miscutils").raidautorun_main;
    if (std.mem.eql(u8, name, "ubiattach")) return @import("miscutils").ubiattach_main;
    if (std.mem.eql(u8, name, "ubidetach")) return @import("miscutils").ubidetach_main;
    if (std.mem.eql(u8, name, "ubimkvol")) return @import("miscutils").ubimkvol_main;
    if (std.mem.eql(u8, name, "ubirename")) return @import("miscutils").ubirename_main;
    if (std.mem.eql(u8, name, "ubirmvol")) return @import("miscutils").ubirmvol_main;
    if (std.mem.eql(u8, name, "ubirsvol")) return @import("miscutils").ubirsvol_main;
    if (std.mem.eql(u8, name, "ubiupdatevol")) return @import("miscutils").ubiupdatevol_main;
    // Task 17 — procps wave (24 applets)
    if (std.mem.eql(u8, name, "free")) return @import("procps").free_main;
    if (std.mem.eql(u8, name, "fuser")) return @import("procps").fuser_main;
    if (std.mem.eql(u8, name, "iostat")) return @import("procps").iostat_main;
    if (std.mem.eql(u8, name, "kill")) return @import("procps").kill_main;
    if (std.mem.eql(u8, name, "killall")) return @import("procps").killall_main;
    if (std.mem.eql(u8, name, "killall5")) return @import("procps").killall5_main;
    if (std.mem.eql(u8, name, "lsof")) return @import("procps").lsof_main;
    if (std.mem.eql(u8, name, "mpstat")) return @import("procps").mpstat_main;
    if (std.mem.eql(u8, name, "nmeter")) return @import("procps").nmeter_main;
    if (std.mem.eql(u8, name, "pgrep")) return @import("procps").pgrep_main;
    if (std.mem.eql(u8, name, "pidof")) return @import("procps").pidof_main;
    if (std.mem.eql(u8, name, "pkill")) return @import("procps").pkill_main;
    if (std.mem.eql(u8, name, "pmap")) return @import("procps").pmap_main;
    if (std.mem.eql(u8, name, "powertop")) return @import("procps").powertop_main;
    if (std.mem.eql(u8, name, "ps")) return @import("procps").ps_main;
    if (std.mem.eql(u8, name, "pstree")) return @import("procps").pstree_main;
    if (std.mem.eql(u8, name, "pwdx")) return @import("procps").pwdx_main;
    if (std.mem.eql(u8, name, "smemcap")) return @import("procps").smemcap_main;
    if (std.mem.eql(u8, name, "sysctl")) return @import("procps").sysctl_main;
    if (std.mem.eql(u8, name, "top")) return @import("procps").top_main;
    if (std.mem.eql(u8, name, "uptime")) return @import("procps").uptime_main;
    if (std.mem.eql(u8, name, "vmstat")) return @import("procps").vmstat_main;
    if (std.mem.eql(u8, name, "watch")) return @import("procps").watch_main;
    // Task 18 — console-tools wave (16 applets)
    if (std.mem.eql(u8, name, "chvt")) return @import("console_tools").chvt_main;
    if (std.mem.eql(u8, name, "clear")) return @import("console_tools").clear_main;
    if (std.mem.eql(u8, name, "deallocvt")) return @import("console_tools").deallocvt_main;
    if (std.mem.eql(u8, name, "dumpkmap")) return @import("console_tools").dumpkmap_main;
    if (std.mem.eql(u8, name, "fgconsole")) return @import("console_tools").fgconsole_main;
    if (std.mem.eql(u8, name, "kbd_mode")) return @import("console_tools").kbd_mode_main;
    if (std.mem.eql(u8, name, "loadfont")) return @import("console_tools").loadfont_main;
    if (std.mem.eql(u8, name, "setfont")) return @import("console_tools").setfont_main;
    if (std.mem.eql(u8, name, "loadkmap")) return @import("console_tools").loadkmap_main;
    if (std.mem.eql(u8, name, "openvt")) return @import("console_tools").openvt_main;
    if (std.mem.eql(u8, name, "reset")) return @import("console_tools").reset_main;
    if (std.mem.eql(u8, name, "resize")) return @import("console_tools").resize_main;
    if (std.mem.eql(u8, name, "setconsole")) return @import("console_tools").setconsole_main;
    if (std.mem.eql(u8, name, "setkeycodes")) return @import("console_tools").setkeycodes_main;
    if (std.mem.eql(u8, name, "setlogcons")) return @import("console_tools").setlogcons_main;
    if (std.mem.eql(u8, name, "showkey")) return @import("console_tools").showkey_main;
    // Task 20 — archival wave
    if (std.mem.eql(u8, name, "gzip")) return @import("archival").gzip_main;
    if (std.mem.eql(u8, name, "gunzip")) return @import("archival").gunzip_main;
    if (std.mem.eql(u8, name, "zcat")) return @import("archival").zcat_main;
    if (std.mem.eql(u8, name, "bzip2")) return @import("archival").bzip2_main;
    if (std.mem.eql(u8, name, "bunzip2")) return @import("archival").bunzip2_main;
    if (std.mem.eql(u8, name, "bzcat")) return @import("archival").bzcat_main;
    if (std.mem.eql(u8, name, "xz")) return @import("archival").xz_main;
    if (std.mem.eql(u8, name, "unxz")) return @import("archival").unxz_main;
    if (std.mem.eql(u8, name, "xzcat")) return @import("archival").xzcat_main;
    if (std.mem.eql(u8, name, "lzma")) return @import("archival").lzma_main;
    if (std.mem.eql(u8, name, "unlzma")) return @import("archival").unlzma_main;
    if (std.mem.eql(u8, name, "lzcat")) return @import("archival").lzcat_main;
    if (std.mem.eql(u8, name, "lzop")) return @import("archival").lzop_main;
    if (std.mem.eql(u8, name, "unlzop")) return @import("archival").unlzop_main;
    if (std.mem.eql(u8, name, "lzopcat")) return @import("archival").lzopcat_main;
    if (std.mem.eql(u8, name, "uncompress")) return @import("archival").uncompress_main;
    if (std.mem.eql(u8, name, "ar")) return @import("archival").ar_main;
    if (std.mem.eql(u8, name, "cpio")) return @import("archival").cpio_main;
    if (std.mem.eql(u8, name, "dpkg")) return @import("archival").dpkg_main;
    if (std.mem.eql(u8, name, "dpkg-deb")) return @import("archival").dpkg_deb_main;
    if (std.mem.eql(u8, name, "rpm")) return @import("archival").rpm_main;
    if (std.mem.eql(u8, name, "rpm2cpio")) return @import("archival").rpm2cpio_main;
    if (std.mem.eql(u8, name, "unzip")) return @import("archival").unzip_main;
    if (std.mem.eql(u8, name, "tar")) return @import("archival").tar_main;
    // shell — sh and bash are ash aliases in the reference configuration
    if (std.mem.eql(u8, name, "ash")) return @import("shell").ash_main;
    if (std.mem.eql(u8, name, "sh")) return @import("shell").ash_main;
    if (std.mem.eql(u8, name, "bash")) return @import("shell").ash_main;
    if (std.mem.eql(u8, name, "hush")) return @import("shell").hush_main;
    if (std.mem.eql(u8, name, "cttyhack")) return @import("shell").cttyhack_main;
    // loginutils — Task 24 wave (all 15 default-enabled applets)
    if (std.mem.eql(u8, name, "login")) return @import("loginutils").login_main;
    if (std.mem.eql(u8, name, "passwd")) return @import("loginutils").passwd_main;
    if (std.mem.eql(u8, name, "su")) return @import("loginutils").su_main;
    if (std.mem.eql(u8, name, "cryptpw")) return @import("loginutils").cryptpw_main;
    if (std.mem.eql(u8, name, "mkpasswd")) return @import("loginutils").mkpasswd_main;
    if (std.mem.eql(u8, name, "add-shell")) return @import("loginutils").add_shell_main;
    if (std.mem.eql(u8, name, "remove-shell")) return @import("loginutils").remove_shell_main;
    if (std.mem.eql(u8, name, "addgroup")) return @import("loginutils").addgroup_main;
    if (std.mem.eql(u8, name, "adduser")) return @import("loginutils").adduser_main;
    if (std.mem.eql(u8, name, "delgroup")) return @import("loginutils").delgroup_main;
    if (std.mem.eql(u8, name, "deluser")) return @import("loginutils").deluser_main;
    if (std.mem.eql(u8, name, "chpasswd")) return @import("loginutils").chpasswd_main;
    if (std.mem.eql(u8, name, "getty")) return @import("loginutils").getty_main;
    if (std.mem.eql(u8, name, "sulogin")) return @import("loginutils").sulogin_main;
    if (std.mem.eql(u8, name, "vlock")) return @import("loginutils").vlock_main;
    // selinux — real implementations, compiled out by the defconfig
    // (CONFIG_SELINUX=n); wired for SELinux-enabled builds.
    if (std.mem.eql(u8, name, "chcon")) return @import("selinux").chcon_main;
    if (std.mem.eql(u8, name, "getenforce")) return @import("selinux").getenforce_main;
    if (std.mem.eql(u8, name, "getsebool")) return @import("selinux").getsebool_main;
    if (std.mem.eql(u8, name, "load_policy")) return @import("selinux").load_policy_main;
    if (std.mem.eql(u8, name, "matchpathcon")) return @import("selinux").matchpathcon_main;
    if (std.mem.eql(u8, name, "restorecon")) return @import("selinux").restorecon_main;
    if (std.mem.eql(u8, name, "runcon")) return @import("selinux").runcon_main;
    if (std.mem.eql(u8, name, "selinuxenabled")) return @import("selinux").selinuxenabled_main;
    if (std.mem.eql(u8, name, "sestatus")) return @import("selinux").sestatus_main;
    if (std.mem.eql(u8, name, "setenforce")) return @import("selinux").setenforce_main;
    if (std.mem.eql(u8, name, "setfiles")) return @import("selinux").setfiles_main;
    if (std.mem.eql(u8, name, "setsebool")) return @import("selinux").setsebool_main;
    // Task 8 — findutils
    if (std.mem.eql(u8, name, "find")) return @import("findutils").find_main;
    if (std.mem.eql(u8, name, "grep")) return @import("findutils").grep_main;
    if (std.mem.eql(u8, name, "egrep")) return @import("findutils").egrep_main;
    if (std.mem.eql(u8, name, "fgrep")) return @import("findutils").fgrep_main;
    if (std.mem.eql(u8, name, "xargs")) return @import("findutils").xargs_main;
    // Task 8 — debianutils
    if (std.mem.eql(u8, name, "which")) return @import("debianutils").which_main;
    if (std.mem.eql(u8, name, "pipe_progress")) return @import("debianutils").pipe_progress_main;
    if (std.mem.eql(u8, name, "run-parts")) return @import("debianutils").run_parts_main;
    if (std.mem.eql(u8, name, "start-stop-daemon")) return @import("debianutils").start_stop_daemon_main;
    // Task 8 — printutils
    if (std.mem.eql(u8, name, "lpd")) return @import("printutils").lpd_main;
    if (std.mem.eql(u8, name, "lpq")) return @import("printutils").lpq_main;
    if (std.mem.eql(u8, name, "lpr")) return @import("printutils").lpr_main;
    // Task 8 — klibc
    if (std.mem.eql(u8, name, "nuke")) return @import("klibc").nuke_main;
    if (std.mem.eql(u8, name, "resume")) return @import("klibc").resume_main;
    // Task 11 — e2fsprogs (tune2fs is wired but compiled out in the defconfig)
    if (std.mem.eql(u8, name, "chattr")) return @import("e2fsprogs").chattr_main;
    if (std.mem.eql(u8, name, "lsattr")) return @import("e2fsprogs").lsattr_main;
    if (std.mem.eql(u8, name, "fsck")) return @import("e2fsprogs").fsck_main;
    if (std.mem.eql(u8, name, "tune2fs")) return @import("e2fsprogs").tune2fs_main;
    // Task 11 — modutils (modprobe-small flavour in the reference binary)
    if (std.mem.eql(u8, name, "depmod")) return @import("modutils").depmod_main;
    if (std.mem.eql(u8, name, "insmod")) return @import("modutils").insmod_main;
    if (std.mem.eql(u8, name, "lsmod")) return @import("modutils").lsmod_main;
    if (std.mem.eql(u8, name, "modinfo")) return @import("modutils").modinfo_main;
    if (std.mem.eql(u8, name, "modprobe")) return @import("modutils").modprobe_main;
    if (std.mem.eql(u8, name, "rmmod")) return @import("modutils").rmmod_main;
    // Task 14 — mailutils
    if (std.mem.eql(u8, name, "makemime")) return @import("mailutils").makemime_main;
    if (std.mem.eql(u8, name, "popmaildir")) return @import("mailutils").popmaildir_main;
    if (std.mem.eql(u8, name, "reformime")) return @import("mailutils").reformime_main;
    if (std.mem.eql(u8, name, "sendmail")) return @import("mailutils").sendmail_main;
    // remaining (ascii/dc were moved to the Task 16a miscutils implementations)
    return stubMain;
}

var applets_map: ?std.StringHashMap(Applet) = null;

pub fn initApplets(allocator: std.mem.Allocator) std.StringHashMap(Applet) {
    @setEvalBranchQuota(100000);
    if (applets_map) |*map| return map.*;
    applets_map = std.StringHashMap(Applet).init(allocator);
    const map = &applets_map.?;

    inline for (manifest.entries) |entry| {
        // Sanitize exactly like scripts/parity/gen_config.py's applet_ident():
        // "[" -> "_", "dpkg-deb" -> "dpkg_deb", leading digits get "_".
        const alias = comptime blk: {
            var buf: [80]u8 = undefined;
            @memcpy(buf[0..7], "APPLET_");
            var n: usize = 7;
            for (entry.name) |c| {
                buf[n] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
                n += 1;
            }
            if (n == 7 or std.ascii.isDigit(buf[7])) {
                var i: usize = n + 1;
                while (i > 8) : (i -= 1) buf[i - 1] = buf[i - 2];
                buf[7] = '_';
                n += 1;
            }
            break :blk buf[0..n];
        };
        const enabled = @field(config, alias);
        // "unit" only exists in unit-test builds. The reference gates the
        // busybox applet with IF_BUSYBOX(IF_FEATURE_SH_STANDALONE(
        // IF_FEATURE_TAB_COMPLETION(...))), so with the committed defconfig
        // (FEATURE_SH_STANDALONE=n) it is absent from the registry and from
        // --list / --list-full (411 applets).
        const register = comptime blk2: {
            if (std.mem.eql(u8, entry.name, "unit"))
                break :blk2 cfg.CONFIG_UNIT_TEST and enabled;
            if (std.mem.eql(u8, entry.name, "busybox"))
                break :blk2 cfg.CONFIG_FEATURE_SH_STANDALONE and
                    cfg.CONFIG_FEATURE_TAB_COMPLETION and enabled;
            break :blk2 enabled;
        };
        if (!register) continue;

        map.put(entry.name, .{
            .name = entry.name,
            .main = mainFor(entry.name),
            .location = entry.location,
            .suid = entry.suid,
            .noexec = entry.noexec,
            .nofork = entry.nofork,
            .scripted = entry.scripted,
            .category = entry.category,
            .usage = usage.usageFor(entry.name) orelse "",
            .config = entry.config,
            .flag = entry.config,
            .default_enabled = entry.default_enabled,
            .flags = .{ .noexec = entry.noexec, .nofork = entry.nofork },
        }) catch unreachable;
    }

    return map.*;
}

pub fn deinitApplets() void {
    applets_map = null;
}

fn ensureInit() *std.StringHashMap(Applet) {
    if (applets_map == null) _ = initApplets(std.heap.page_allocator);
    return &applets_map.?;
}

pub fn countApplets() usize {
    return ensureInit().count();
}

pub fn findAppletByName(name: []const u8) ?Applet {
    return ensureInit().get(name);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn appletNames(allocator: std.mem.Allocator) ![][]const u8 {
    const map = ensureInit();
    const names = try allocator.alloc([]const u8, map.count());
    var it = map.keyIterator();
    var i: usize = 0;
    while (it.next()) |key| : (i += 1) names[i] = key.*;
    std.mem.sort([]const u8, names, {}, lessThan);
    return names;
}

/// Same order as `appletNames`, but each entry is prefixed with the applet's
/// reference install location and has no leading slash ("usr/bin/[", "bin/cat").
/// A "root" location produces the bare applet name, matching install_dir[0]+1
/// in the reference implementation.
/// Storage for the prefixed names. The registry is already a process-global,
/// so reusing a fixed table here keeps `appletNamesFull`'s ownership simple:
/// callers free only the returned slice array.
var full_names_storage: [manifest.entries.len][128]u8 = undefined;

pub fn appletNamesFull(allocator: std.mem.Allocator) ![][]const u8 {
    const names = try appletNames(allocator);
    defer allocator.free(names);
    const full = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |name, i| {
        const applet = findAppletByName(name).?;
        full[i] = if (std.mem.eql(u8, applet.location, "root"))
            name
        else
            std.fmt.bufPrint(&full_names_storage[i], "{s}/{s}", .{ applet.location, name }) catch unreachable;
    }
    return full;
}
