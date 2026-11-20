//! Applet registry — all busybox applets are registered here.

const std = @import("std");
const coreutils = @import("coreutils");

pub const AppletFlags = struct {
    noexec: bool = false,
    nofork: bool = false,
};

pub const Applet = struct {
    name: []const u8,
    main: *const fn (argc: c_int, argv: [*][*:0]const u8) c_int,
    flags: AppletFlags,
};

// Stub main functions for all applets.
// These will be replaced with actual implementations in future phases.
pub fn cat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ls_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn echo_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn printf_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn cp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mv_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn rm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mkdir_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn touch_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn head_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tail_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn sort_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn uniq_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn wc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn cut_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn true_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn false_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn date_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn dd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn pwd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ln_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn basename_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn dirname_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn du_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn find_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn grep_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tr_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn readlink_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn seq_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tee_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn uptime_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn who_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn which_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn xargs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn bzip2_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn bunzip2_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn bzcat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn gzip_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn gunzip_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn md5sum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn sha1sum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn sha256sum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn cksum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn base64_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fold_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn join_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nl_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nproc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn od_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn paste_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn shred_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn shuf_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn split_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn stat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn strings_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tsort_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn unexpand_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn yes_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zcat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zcmp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zdiff_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zgrep_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zless_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zmore_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn znew_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mkfifo_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mknod_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mktemp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn realpath_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nohup_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn numfmt_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn crc32_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn sha512sum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn xz_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn xzcat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn unxz_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lzma_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lzop_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lzopcat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn unlzma_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zlib_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zlib1g_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn uncompress_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lzopuncompress_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
// Util-linux stubs
pub fn dmesg_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mount_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn umount_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fdisk_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn blkid_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fallocate_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn flock_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fstrim_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn hwclock_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ionice_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn last_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lsblk_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mdev_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mkhomedir_helper_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn more_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mountpoint_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nsenter_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn pivot_root_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn readprofile_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn renice_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn switch_root_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn taskset_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn unshare_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn setsid_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn chrt_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lsusb_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn uevent_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn acpid_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn eject_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn swaplabel_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn rdate_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fbset_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fdformat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn script_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn scriptreplay_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn losetup_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn freeramdisk_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mkswap_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn blkdiscard_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn cal_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fatlabel_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn rev_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn rdev_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fatattr_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fsfreeze_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nologin_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn wall_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn findfs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn blockdev_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ipcs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ipcrm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn hexdump_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lspci_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn last_fancy_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn uuidgen_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mesg_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn setpriv_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn rtcwake_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn setarch_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
// Networking stubs
pub fn ip_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ping_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ifconfig_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn route_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn wget_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tftp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn httpd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn telnet_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn hostname_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nslookup_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ftpgetput_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn arping_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn netstat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ether_wake_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn whois_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nbd_client_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn zcip_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ftpd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn isrv_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn isrv_identd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nc_bloaty_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn dnsd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn inetd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ifenslave_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn vconfig_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn brctl_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ipcalc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn traceroute_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn telnetd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn pscan_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn slattach_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tunctl_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nameif_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ifplugd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ntpd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn arp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ifupdown_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn interface_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ssl_client_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ssl_server_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_aes_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_aesgcm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_fe_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_pstm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_pstm_mul_comba_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_pstm_sqr_comba_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_pstm_montgomery_reduce_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_rsa_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tls_sp_c32_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn httpd_indexcgi_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn httpd_ssi_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn httpd_ratelimit_cgi_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tcpudp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tcpudp_perhost_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn parse_pasv_epsv_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
// Miscutils stubs
pub fn inotifyd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn watchdog_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn hexedit_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn dc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ubirename_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn time_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn setserial_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn microcom_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn rx_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mt_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn runlevel_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn readahead_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn seedrng_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn raidautorun_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn bbconfig_main(_argc: c_int, _argv: [*][*:0]const u8) c_int {
    _ = _argc;
    _ = _argv;
    const a = std.heap.page_allocator;
    const names = appletNames(a) catch return 1;
    defer a.free(names);
    var line: [256]u8 = undefined;
    var upper: [128]u8 = undefined;
    for (names) |name| {
        if (name.len > upper.len) continue;
        for (name, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
        const text = std.fmt.bufPrint(&line, "CONFIG_{s}=y\n", .{upper[0..name.len]}) catch continue;
        _ = std.os.linux.write(1, text.ptr, text.len);
    }
    return 0;
}
pub fn ascii_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn makedevs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn bc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn flash_eraseall_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tree_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lsscsi_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn crontab_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn volname_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn flashcp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn flash_lock_unlock_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn i2c_tools_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mim_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn beep_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn partprobe_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fbsplash_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn hdparm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn devmem_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ts_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn adjtimex_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ttysize_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn getfattr_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn rfkill_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn chat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn man_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn less_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ubi_tools_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nandwrite_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn conspy_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn crond_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn devfsd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn setfattr_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn setconsole_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mke2fs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn tune2fs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn e2label_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn dump_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn restore_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn debugfs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }

// Procps stubs
pub fn kill_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn killall_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn killall5_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn free_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn pwdx_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn ps_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn top_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn lsof_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn smemcap_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn powertop_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn watch_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn vmstat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn iostat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn fuser_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn pidof_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn pstree_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn nmeter_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn pgrep_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn pmap_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn sysctl_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mpstat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }

// Shell stubs
pub fn ash_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn hush_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn random_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn match_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn cttyhack_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn math_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }

// Loginutils stubs
pub fn vlock_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn deluser_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn adduser_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn login_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn addgroup_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn passwd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn chpasswd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn add_remove_shell_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn su_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn sulogin_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn cryptpw_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn mkpasswd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }
pub fn getty_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; return stubNotImplemented(_argv); }

// Registry — uses StringHashMap for runtime initialization.
// StaticStringMap cannot handle function pointers in struct literals at comptime.

var applets_map: ?std.StringHashMap(Applet) = null;

const config = @import("config").config;
const MainFn = *const fn (c_int, [*][*:0]const u8) c_int;

/// Deferred applets fail loudly instead of exiting silently with no message.
fn stubNotImplemented(argv: [*][*:0]const u8) c_int {
    const name = std.mem.span(argv[0]);
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: not implemented\n", .{name}) catch "not implemented\n";
    _ = std.os.linux.write(2, msg.ptr, msg.len);
    return 1;
}

/// Register an applet only when its Kconfig-style flag is enabled. This is the
/// Zig equivalent of busybox's `#ifdef CONFIG_APPLET`.
fn putIfEnabled(map: *std.StringHashMap(Applet), comptime name: []const u8, main: MainFn) void {
    if (@field(config, "APPLET_" ++ name)) {
        map.put(name, .{ .name = name, .main = main, .flags = .{} }) catch unreachable;
    }
}

pub fn initApplets(allocator: std.mem.Allocator) std.StringHashMap(Applet) {
    if (applets_map) |*map| return map.*;
    applets_map = std.StringHashMap(Applet).init(allocator);
    const map = &applets_map.?;

    // === Coreutils ===
    putIfEnabled(map, "cat", coreutils.cat_main);
    putIfEnabled(map, "ls", coreutils.ls_main);
    putIfEnabled(map, "echo", coreutils.echo_main);
    putIfEnabled(map, "printf", coreutils.printf_main);
    putIfEnabled(map, "cp", coreutils.cp_main);
    putIfEnabled(map, "mv", coreutils.mv_main);
    putIfEnabled(map, "rm", coreutils.rm_main);
    putIfEnabled(map, "mkdir", coreutils.mkdir_main);
    putIfEnabled(map, "touch", coreutils.touch_main);
    putIfEnabled(map, "head", coreutils.head_main);
    putIfEnabled(map, "tail", coreutils.tail_main);
    putIfEnabled(map, "sort", coreutils.sort_main);
    putIfEnabled(map, "uniq", coreutils.uniq_main);
    putIfEnabled(map, "wc", coreutils.wc_main);
    putIfEnabled(map, "cut", coreutils.cut_main);
    putIfEnabled(map, "sed", coreutils.sed_main);
    putIfEnabled(map, "awk", coreutils.awk_main);
    putIfEnabled(map, "true", coreutils.true_main);
    putIfEnabled(map, "false", coreutils.false_main);
    putIfEnabled(map, "date", date_main);
    putIfEnabled(map, "dd", dd_main);
    putIfEnabled(map, "pwd", pwd_main);
    putIfEnabled(map, "ln", ln_main);
    putIfEnabled(map, "basename", basename_main);
    putIfEnabled(map, "dirname", dirname_main);
    putIfEnabled(map, "du", du_main);
    putIfEnabled(map, "find", find_main);
    putIfEnabled(map, "grep", grep_main);
    putIfEnabled(map, "tr", tr_main);
    putIfEnabled(map, "readlink", readlink_main);
    putIfEnabled(map, "seq", seq_main);
    putIfEnabled(map, "tee", tee_main);
    putIfEnabled(map, "uptime", uptime_main);
    putIfEnabled(map, "who", who_main);
    putIfEnabled(map, "which", which_main);
    putIfEnabled(map, "xargs", xargs_main);
    putIfEnabled(map, "bzip2", bzip2_main);
    putIfEnabled(map, "bunzip2", bunzip2_main);
    putIfEnabled(map, "bzcat", bzcat_main);
    putIfEnabled(map, "gzip", gzip_main);
    putIfEnabled(map, "gunzip", gunzip_main);
    putIfEnabled(map, "md5sum", md5sum_main);
    putIfEnabled(map, "sha1sum", sha1sum_main);
    putIfEnabled(map, "sha256sum", sha256sum_main);
    putIfEnabled(map, "cksum", cksum_main);
    putIfEnabled(map, "base64", base64_main);
    putIfEnabled(map, "fold", fold_main);
    putIfEnabled(map, "join", join_main);
    putIfEnabled(map, "nl", nl_main);
    putIfEnabled(map, "nproc", nproc_main);
    putIfEnabled(map, "od", od_main);
    putIfEnabled(map, "paste", paste_main);
    putIfEnabled(map, "shred", shred_main);
    putIfEnabled(map, "shuf", shuf_main);
    putIfEnabled(map, "split", split_main);
    putIfEnabled(map, "stat", stat_main);
    putIfEnabled(map, "strings", strings_main);
    putIfEnabled(map, "tsort", tsort_main);
    putIfEnabled(map, "unexpand", unexpand_main);
    putIfEnabled(map, "yes", yes_main);
    putIfEnabled(map, "zcat", zcat_main);
    putIfEnabled(map, "zcmp", zcmp_main);
    putIfEnabled(map, "zdiff", zdiff_main);
    putIfEnabled(map, "zgrep", zgrep_main);
    putIfEnabled(map, "zless", zless_main);
    putIfEnabled(map, "zmore", zmore_main);
    putIfEnabled(map, "znew", znew_main);
    putIfEnabled(map, "mkfifo", mkfifo_main);
    putIfEnabled(map, "mknod", mknod_main);
    putIfEnabled(map, "mktemp", mktemp_main);
    putIfEnabled(map, "realpath", realpath_main);
    putIfEnabled(map, "nohup", nohup_main);
    putIfEnabled(map, "numfmt", numfmt_main);
    putIfEnabled(map, "crc32", crc32_main);
    putIfEnabled(map, "sha512sum", sha512sum_main);
    putIfEnabled(map, "xz", xz_main);
    putIfEnabled(map, "xzcat", xzcat_main);
    putIfEnabled(map, "unxz", unxz_main);
    putIfEnabled(map, "lzma", lzma_main);
    putIfEnabled(map, "lzop", lzop_main);
    putIfEnabled(map, "lzopcat", lzopcat_main);
    putIfEnabled(map, "unlzma", unlzma_main);
    putIfEnabled(map, "zlib", zlib_main);
    putIfEnabled(map, "zlib1g", zlib1g_main);
    putIfEnabled(map, "uncompress", uncompress_main);
    putIfEnabled(map, "lzopuncompress", lzopuncompress_main);

    // === Util-linux ===
    putIfEnabled(map, "dmesg", @import("util_linux").dmesg_main);
    putIfEnabled(map, "mount", @import("util_linux").mount_main);
    putIfEnabled(map, "umount", @import("util_linux").umount_main);
    putIfEnabled(map, "fdisk", fdisk_main);
    putIfEnabled(map, "blkid", @import("util_linux").blkid_main);
    putIfEnabled(map, "fallocate", fallocate_main);
    putIfEnabled(map, "flock", flock_main);
    putIfEnabled(map, "fstrim", fstrim_main);
    putIfEnabled(map, "hwclock", hwclock_main);
    putIfEnabled(map, "ionice", @import("miscutils").ionice_main);
    putIfEnabled(map, "last", last_main);
    putIfEnabled(map, "lsblk", lsblk_main);
    putIfEnabled(map, "mdev", mdev_main);
    putIfEnabled(map, "mkhomedir_helper", mkhomedir_helper_main);
    putIfEnabled(map, "more", more_main);
    putIfEnabled(map, "mountpoint", mountpoint_main);
    putIfEnabled(map, "nsenter", nsenter_main);
    putIfEnabled(map, "pivot_root", pivot_root_main);
    putIfEnabled(map, "readprofile", readprofile_main);
    putIfEnabled(map, "renice", @import("miscutils").renice_main);
    putIfEnabled(map, "switch_root", switch_root_main);
    putIfEnabled(map, "taskset", taskset_main);
    putIfEnabled(map, "unshare", unshare_main);
    putIfEnabled(map, "setsid", setsid_main);
    putIfEnabled(map, "chrt", chrt_main);
    putIfEnabled(map, "lsusb", lsusb_main);
    putIfEnabled(map, "uevent", uevent_main);
    putIfEnabled(map, "acpid", acpid_main);
    putIfEnabled(map, "eject", eject_main);
    putIfEnabled(map, "swaplabel", swaplabel_main);
    putIfEnabled(map, "rdate", rdate_main);
    putIfEnabled(map, "fbset", fbset_main);
    putIfEnabled(map, "fdformat", fdformat_main);
    putIfEnabled(map, "script", script_main);
    putIfEnabled(map, "scriptreplay", scriptreplay_main);
    putIfEnabled(map, "losetup", losetup_main);
    putIfEnabled(map, "freeramdisk", freeramdisk_main);
    putIfEnabled(map, "mkswap", mkswap_main);
    putIfEnabled(map, "blkdiscard", blkdiscard_main);
    putIfEnabled(map, "cal", cal_main);
    putIfEnabled(map, "fatlabel", fatlabel_main);
    putIfEnabled(map, "rev", rev_main);
    putIfEnabled(map, "rdev", rdev_main);
    putIfEnabled(map, "fatattr", fatattr_main);
    putIfEnabled(map, "fsfreeze", fsfreeze_main);
    putIfEnabled(map, "nologin", nologin_main);
    putIfEnabled(map, "wall", wall_main);
    putIfEnabled(map, "findfs", findfs_main);
    putIfEnabled(map, "blockdev", blockdev_main);
    putIfEnabled(map, "ipcs", ipcs_main);
    putIfEnabled(map, "ipcrm", ipcrm_main);
    putIfEnabled(map, "hexdump", hexdump_main);
    putIfEnabled(map, "lspci", lspci_main);
    putIfEnabled(map, "last_fancy", last_fancy_main);
    putIfEnabled(map, "uuidgen", uuidgen_main);
    putIfEnabled(map, "mesg", mesg_main);
    putIfEnabled(map, "setpriv", setpriv_main);
    putIfEnabled(map, "rtcwake", rtcwake_main);
    putIfEnabled(map, "setarch", setarch_main);

    // === Networking ===
    putIfEnabled(map, "ip", ip_main);
    putIfEnabled(map, "ping", @import("networking").ping_main);
    putIfEnabled(map, "ifconfig", @import("networking").ifconfig_main);
    putIfEnabled(map, "route", route_main);
    putIfEnabled(map, "wget", @import("networking").wget_main);
    putIfEnabled(map, "nc", @import("networking").nc_main);
    putIfEnabled(map, "tftp", tftp_main);
    putIfEnabled(map, "httpd", httpd_main);
    putIfEnabled(map, "telnet", telnet_main);
    putIfEnabled(map, "hostname", hostname_main);
    putIfEnabled(map, "nslookup", nslookup_main);
    putIfEnabled(map, "ftpgetput", ftpgetput_main);
    putIfEnabled(map, "arping", arping_main);
    putIfEnabled(map, "netstat", netstat_main);
    putIfEnabled(map, "ether_wake", ether_wake_main);
    putIfEnabled(map, "whois", whois_main);
    putIfEnabled(map, "nbd_client", nbd_client_main);
    putIfEnabled(map, "zcip", zcip_main);
    putIfEnabled(map, "ftpd", ftpd_main);
    putIfEnabled(map, "isrv", isrv_main);
    putIfEnabled(map, "isrv_identd", isrv_identd_main);
    putIfEnabled(map, "nc_bloaty", nc_bloaty_main);
    putIfEnabled(map, "tc", tc_main);
    putIfEnabled(map, "dnsd", dnsd_main);
    putIfEnabled(map, "inetd", inetd_main);
    putIfEnabled(map, "ifenslave", ifenslave_main);
    putIfEnabled(map, "vconfig", vconfig_main);
    putIfEnabled(map, "brctl", brctl_main);
    putIfEnabled(map, "ipcalc", ipcalc_main);
    putIfEnabled(map, "traceroute", traceroute_main);
    putIfEnabled(map, "telnetd", telnetd_main);
    putIfEnabled(map, "pscan", pscan_main);
    putIfEnabled(map, "slattach", slattach_main);
    putIfEnabled(map, "tunctl", tunctl_main);
    putIfEnabled(map, "nameif", nameif_main);
    putIfEnabled(map, "ifplugd", ifplugd_main);
    putIfEnabled(map, "ntpd", ntpd_main);
    putIfEnabled(map, "arp", arp_main);
    putIfEnabled(map, "ifupdown", ifupdown_main);
    putIfEnabled(map, "interface", interface_main);
    putIfEnabled(map, "ssl_client", ssl_client_main);
    putIfEnabled(map, "ssl_server", ssl_server_main);
    putIfEnabled(map, "tls", tls_main);
    putIfEnabled(map, "tls_aes", tls_aes_main);
    putIfEnabled(map, "tls_aesgcm", tls_aesgcm_main);
    putIfEnabled(map, "tls_fe", tls_fe_main);
    putIfEnabled(map, "tls_pstm", tls_pstm_main);
    putIfEnabled(map, "tls_pstm_mul_comba", tls_pstm_mul_comba_main);
    putIfEnabled(map, "tls_pstm_sqr_comba", tls_pstm_sqr_comba_main);
    putIfEnabled(map, "tls_pstm_montgomery_reduce", tls_pstm_montgomery_reduce_main);
    putIfEnabled(map, "tls_rsa", tls_rsa_main);
    putIfEnabled(map, "tls_sp_c32", tls_sp_c32_main);
    putIfEnabled(map, "httpd_indexcgi", httpd_indexcgi_main);
    putIfEnabled(map, "httpd_ssi", httpd_ssi_main);
    putIfEnabled(map, "httpd_ratelimit_cgi", httpd_ratelimit_cgi_main);
    putIfEnabled(map, "tcpudp", tcpudp_main);
    putIfEnabled(map, "tcpudp_perhost", tcpudp_perhost_main);
    // === Miscutils ===
    putIfEnabled(map, "inotifyd", inotifyd_main);
    putIfEnabled(map, "watchdog", watchdog_main);
    putIfEnabled(map, "hexedit", hexedit_main);
    putIfEnabled(map, "dc", @import("remaining").dc_main);
    putIfEnabled(map, "ubirename", ubirename_main);
    putIfEnabled(map, "time", time_main);
    putIfEnabled(map, "setserial", setserial_main);
    putIfEnabled(map, "microcom", microcom_main);
    putIfEnabled(map, "rx", rx_main);
    putIfEnabled(map, "mt", mt_main);
    putIfEnabled(map, "runlevel", runlevel_main);
    putIfEnabled(map, "readahead", readahead_main);
    putIfEnabled(map, "seedrng", seedrng_main);
    putIfEnabled(map, "raidautorun", raidautorun_main);
    putIfEnabled(map, "bbconfig", bbconfig_main);
    putIfEnabled(map, "ascii", @import("remaining").ascii_main);
    putIfEnabled(map, "makedevs", makedevs_main);
    putIfEnabled(map, "bc", bc_main);
    putIfEnabled(map, "flash_eraseall", flash_eraseall_main);
    putIfEnabled(map, "tree", tree_main);
    putIfEnabled(map, "lsscsi", lsscsi_main);
    putIfEnabled(map, "crontab", @import("miscutils").crontab_main);
    putIfEnabled(map, "volname", volname_main);
    putIfEnabled(map, "flashcp", flashcp_main);
    putIfEnabled(map, "flash_lock_unlock", flash_lock_unlock_main);
    putIfEnabled(map, "i2c_tools", i2c_tools_main);
    putIfEnabled(map, "mim", mim_main);
    putIfEnabled(map, "beep", beep_main);
    putIfEnabled(map, "partprobe", partprobe_main);
    putIfEnabled(map, "fbsplash", fbsplash_main);
    putIfEnabled(map, "hdparm", hdparm_main);
    putIfEnabled(map, "devmem", devmem_main);
    putIfEnabled(map, "ts", ts_main);
    putIfEnabled(map, "adjtimex", adjtimex_main);
    putIfEnabled(map, "ttysize", ttysize_main);
    putIfEnabled(map, "getfattr", getfattr_main);
    putIfEnabled(map, "rfkill", rfkill_main);
    putIfEnabled(map, "chat", chat_main);
    putIfEnabled(map, "man", man_main);
    putIfEnabled(map, "less", less_main);
    putIfEnabled(map, "ubi_tools", ubi_tools_main);
    putIfEnabled(map, "nandwrite", nandwrite_main);
    putIfEnabled(map, "conspy", conspy_main);
    putIfEnabled(map, "crond", crond_main);
    putIfEnabled(map, "devfsd", devfsd_main);
    putIfEnabled(map, "setfattr", setfattr_main);
    putIfEnabled(map, "setconsole", setconsole_main);
    putIfEnabled(map, "mke2fs", mke2fs_main);
    putIfEnabled(map, "tune2fs", tune2fs_main);
    putIfEnabled(map, "e2label", e2label_main);
    putIfEnabled(map, "dump", dump_main);
    putIfEnabled(map, "restore", restore_main);
    putIfEnabled(map, "debugfs", debugfs_main);

    // === Procps ===
    putIfEnabled(map, "kill", @import("procps").kill_main);
    putIfEnabled(map, "killall", @import("procps").killall_main);
    putIfEnabled(map, "killall5", killall5_main);
    putIfEnabled(map, "free", @import("procps").free_main);
    putIfEnabled(map, "pwdx", pwdx_main);
    putIfEnabled(map, "ps", @import("procps").ps_main);
    putIfEnabled(map, "top", @import("procps").top_main);
    putIfEnabled(map, "lsof", lsof_main);
    putIfEnabled(map, "smemcap", smemcap_main);
    putIfEnabled(map, "powertop", powertop_main);
    putIfEnabled(map, "watch", watch_main);
    putIfEnabled(map, "vmstat", vmstat_main);
    putIfEnabled(map, "iostat", iostat_main);
    putIfEnabled(map, "fuser", fuser_main);
    putIfEnabled(map, "pidof", pidof_main);
    putIfEnabled(map, "pstree", pstree_main);
    putIfEnabled(map, "nmeter", nmeter_main);
    putIfEnabled(map, "pgrep", pgrep_main);
    putIfEnabled(map, "pmap", pmap_main);
    putIfEnabled(map, "sysctl", sysctl_main);
    putIfEnabled(map, "mpstat", mpstat_main);

    // === Shell ===
    putIfEnabled(map, "ash", @import("shell").ash_main);
    putIfEnabled(map, "hush", @import("shell").hush_main);
    putIfEnabled(map, "random", random_main);
    putIfEnabled(map, "match", match_main);
    putIfEnabled(map, "cttyhack", cttyhack_main);
    putIfEnabled(map, "math", math_main);

    // === Loginutils ===
    putIfEnabled(map, "vlock", vlock_main);
    putIfEnabled(map, "deluser", deluser_main);
    putIfEnabled(map, "adduser", adduser_main);
    putIfEnabled(map, "login", @import("loginutils").login_main);
    putIfEnabled(map, "addgroup", addgroup_main);
    putIfEnabled(map, "passwd", @import("loginutils").passwd_main);
    putIfEnabled(map, "chpasswd", chpasswd_main);
    putIfEnabled(map, "add_remove_shell", add_remove_shell_main);
    putIfEnabled(map, "su", @import("loginutils").su_main);
    putIfEnabled(map, "sulogin", sulogin_main);
    putIfEnabled(map, "cryptpw", @import("loginutils").cryptpw_main);
    putIfEnabled(map, "mkpasswd", mkpasswd_main);
    putIfEnabled(map, "getty", getty_main);

    return map.*;
}

pub fn deinitApplets() void {
    applets_map = null;
}

fn ensureInit() *std.StringHashMap(Applet) {
    // initApplets is idempotent: it populates on first call and returns the
    // cached map afterwards.
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
