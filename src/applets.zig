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
pub fn cat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ls_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn echo_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn printf_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn cp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mv_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn rm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mkdir_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn touch_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn head_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tail_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn sort_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn uniq_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn wc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn cut_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn true_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn false_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn date_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn dd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn pwd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ln_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn basename_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn dirname_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn du_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn find_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn grep_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tr_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn readlink_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn seq_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tee_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn uptime_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn who_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn which_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn xargs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn bzip2_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn bunzip2_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn bzcat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn gzip_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn gunzip_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn md5sum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn sha1sum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn sha256sum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn cksum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn base64_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fold_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn join_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nl_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nproc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn od_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn paste_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn shred_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn shuf_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn split_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn stat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn strings_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tsort_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn unexpand_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn yes_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zcat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zcmp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zdiff_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zgrep_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zless_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zmore_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn znew_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mkfifo_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mknod_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mktemp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn realpath_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nohup_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn numfmt_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn crc32_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn sha512sum_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn xz_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn xzcat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn unxz_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lzma_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lzop_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lzopcat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn unlzma_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zlib_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zlib1g_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn uncompress_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lzopuncompress_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
// Util-linux stubs
pub fn dmesg_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mount_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn umount_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fdisk_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn blkid_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fallocate_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn flock_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fstrim_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn hwclock_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ionice_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn last_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lsblk_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mdev_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mkhomedir_helper_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn more_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mountpoint_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nsenter_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn pivot_root_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn readprofile_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn renice_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn switch_root_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn taskset_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn unshare_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn setsid_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn chrt_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lsusb_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn uevent_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn acpid_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn eject_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn swaplabel_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn rdate_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fbset_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fdformat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn script_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn scriptreplay_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn losetup_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn freeramdisk_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mkswap_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn blkdiscard_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn cal_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fatlabel_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn rev_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn rdev_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fatattr_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fsfreeze_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nologin_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn wall_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn findfs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn blockdev_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ipcs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ipcrm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn hexdump_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lspci_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn last_fancy_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn uuidgen_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mesg_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn setpriv_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn rtcwake_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn setarch_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
// Networking stubs
pub fn ip_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ping_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ifconfig_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn route_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn wget_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tftp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn httpd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn telnet_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn hostname_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nslookup_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ftpgetput_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn arping_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn netstat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ether_wake_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn whois_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nbd_client_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn zcip_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ftpd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn isrv_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn isrv_identd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nc_bloaty_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn dnsd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn inetd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ifenslave_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn vconfig_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn brctl_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ipcalc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn traceroute_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn telnetd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn pscan_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn slattach_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tunctl_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nameif_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ifplugd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ntpd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn arp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ifupdown_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn interface_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ssl_client_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ssl_server_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_aes_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_aesgcm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_fe_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_pstm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_pstm_mul_comba_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_pstm_sqr_comba_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_pstm_montgomery_reduce_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_rsa_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tls_sp_c32_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn httpd_indexcgi_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn httpd_ssi_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn httpd_ratelimit_cgi_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tcpudp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tcpudp_perhost_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn parse_pasv_epsv_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
// Miscutils stubs
pub fn inotifyd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn watchdog_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn hexedit_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn dc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ubirename_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn time_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn setserial_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn microcom_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn rx_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mt_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn runlevel_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn readahead_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn seedrng_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn raidautorun_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn bbconfig_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ascii_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn makedevs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn bc_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn flash_eraseall_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tree_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lsscsi_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn crontab_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn volname_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn flashcp_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn flash_lock_unlock_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn i2c_tools_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mim_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn beep_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn partprobe_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fbsplash_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn hdparm_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn devmem_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ts_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn adjtimex_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ttysize_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn getfattr_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn rfkill_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn chat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn man_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn less_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ubi_tools_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nandwrite_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn conspy_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn crond_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn devfsd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn setfattr_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn setconsole_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mke2fs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn tune2fs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn e2label_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn dump_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn restore_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn debugfs_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }

// Procps stubs
pub fn kill_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn killall_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn killall5_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn free_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn pwdx_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn ps_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn top_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn lsof_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn smemcap_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn powertop_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn watch_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn vmstat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn iostat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn fuser_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn pidof_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn pstree_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn nmeter_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn pgrep_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn pmap_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn sysctl_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mpstat_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }

// Shell stubs
pub fn ash_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn hush_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn random_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn match_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn cttyhack_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn math_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }

// Loginutils stubs
pub fn vlock_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn deluser_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn adduser_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn login_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn addgroup_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn passwd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn chpasswd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn add_remove_shell_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn su_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn sulogin_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn cryptpw_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn mkpasswd_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }
pub fn getty_main(_argc: c_int, _argv: [*][*:0]const u8) c_int { _ = _argc; _ = _argv; std.process.exit(1); }

// Registry — uses StringHashMap for runtime initialization.
// StaticStringMap cannot handle function pointers in struct literals at comptime.

var applets_map: ?std.StringHashMap(Applet) = null;

pub fn initApplets(allocator: std.mem.Allocator) std.StringHashMap(Applet) {
    if (applets_map) |*map| return map.*;
    applets_map = std.StringHashMap(Applet).init(allocator);
    const map = &applets_map.?;

    // === Coreutils ===
    map.put("cat", Applet{ .name = "cat", .main = coreutils.cat_main, .flags = .{} }) catch unreachable;
    map.put("ls", Applet{ .name = "ls", .main = coreutils.ls_main, .flags = .{} }) catch unreachable;
    map.put("echo", Applet{ .name = "echo", .main = coreutils.echo_main, .flags = .{} }) catch unreachable;
    map.put("printf", Applet{ .name = "printf", .main = coreutils.printf_main, .flags = .{} }) catch unreachable;
    map.put("cp", Applet{ .name = "cp", .main = cp_main, .flags = .{} }) catch unreachable;
    map.put("mv", Applet{ .name = "mv", .main = mv_main, .flags = .{} }) catch unreachable;
    map.put("rm", Applet{ .name = "rm", .main = rm_main, .flags = .{} }) catch unreachable;
    map.put("mkdir", Applet{ .name = "mkdir", .main = mkdir_main, .flags = .{} }) catch unreachable;
    map.put("touch", Applet{ .name = "touch", .main = touch_main, .flags = .{} }) catch unreachable;
    map.put("head", Applet{ .name = "head", .main = head_main, .flags = .{} }) catch unreachable;
    map.put("tail", Applet{ .name = "tail", .main = tail_main, .flags = .{} }) catch unreachable;
    map.put("sort", Applet{ .name = "sort", .main = sort_main, .flags = .{} }) catch unreachable;
    map.put("uniq", Applet{ .name = "uniq", .main = uniq_main, .flags = .{} }) catch unreachable;
    map.put("wc", Applet{ .name = "wc", .main = wc_main, .flags = .{} }) catch unreachable;
    map.put("cut", Applet{ .name = "cut", .main = cut_main, .flags = .{} }) catch unreachable;
    map.put("true", Applet{ .name = "true", .main = coreutils.true_main, .flags = .{} }) catch unreachable;
    map.put("false", Applet{ .name = "false", .main = coreutils.false_main, .flags = .{} }) catch unreachable;
    map.put("date", Applet{ .name = "date", .main = date_main, .flags = .{} }) catch unreachable;
    map.put("dd", Applet{ .name = "dd", .main = dd_main, .flags = .{} }) catch unreachable;
    map.put("pwd", Applet{ .name = "pwd", .main = pwd_main, .flags = .{} }) catch unreachable;
    map.put("ln", Applet{ .name = "ln", .main = ln_main, .flags = .{} }) catch unreachable;
    map.put("basename", Applet{ .name = "basename", .main = basename_main, .flags = .{} }) catch unreachable;
    map.put("dirname", Applet{ .name = "dirname", .main = dirname_main, .flags = .{} }) catch unreachable;
    map.put("du", Applet{ .name = "du", .main = du_main, .flags = .{} }) catch unreachable;
    map.put("find", Applet{ .name = "find", .main = find_main, .flags = .{} }) catch unreachable;
    map.put("grep", Applet{ .name = "grep", .main = grep_main, .flags = .{} }) catch unreachable;
    map.put("tr", Applet{ .name = "tr", .main = tr_main, .flags = .{} }) catch unreachable;
    map.put("readlink", Applet{ .name = "readlink", .main = readlink_main, .flags = .{} }) catch unreachable;
    map.put("seq", Applet{ .name = "seq", .main = seq_main, .flags = .{} }) catch unreachable;
    map.put("tee", Applet{ .name = "tee", .main = tee_main, .flags = .{} }) catch unreachable;
    map.put("uptime", Applet{ .name = "uptime", .main = uptime_main, .flags = .{} }) catch unreachable;
    map.put("who", Applet{ .name = "who", .main = who_main, .flags = .{} }) catch unreachable;
    map.put("which", Applet{ .name = "which", .main = which_main, .flags = .{} }) catch unreachable;
    map.put("xargs", Applet{ .name = "xargs", .main = xargs_main, .flags = .{} }) catch unreachable;
    map.put("bzip2", Applet{ .name = "bzip2", .main = bzip2_main, .flags = .{} }) catch unreachable;
    map.put("bunzip2", Applet{ .name = "bunzip2", .main = bunzip2_main, .flags = .{} }) catch unreachable;
    map.put("bzcat", Applet{ .name = "bzcat", .main = bzcat_main, .flags = .{} }) catch unreachable;
    map.put("gzip", Applet{ .name = "gzip", .main = gzip_main, .flags = .{} }) catch unreachable;
    map.put("gunzip", Applet{ .name = "gunzip", .main = gunzip_main, .flags = .{} }) catch unreachable;
    map.put("md5sum", Applet{ .name = "md5sum", .main = md5sum_main, .flags = .{} }) catch unreachable;
    map.put("sha1sum", Applet{ .name = "sha1sum", .main = sha1sum_main, .flags = .{} }) catch unreachable;
    map.put("sha256sum", Applet{ .name = "sha256sum", .main = sha256sum_main, .flags = .{} }) catch unreachable;
    map.put("cksum", Applet{ .name = "cksum", .main = cksum_main, .flags = .{} }) catch unreachable;
    map.put("base64", Applet{ .name = "base64", .main = base64_main, .flags = .{} }) catch unreachable;
    map.put("fold", Applet{ .name = "fold", .main = fold_main, .flags = .{} }) catch unreachable;
    map.put("join", Applet{ .name = "join", .main = join_main, .flags = .{} }) catch unreachable;
    map.put("nl", Applet{ .name = "nl", .main = nl_main, .flags = .{} }) catch unreachable;
    map.put("nproc", Applet{ .name = "nproc", .main = nproc_main, .flags = .{} }) catch unreachable;
    map.put("od", Applet{ .name = "od", .main = od_main, .flags = .{} }) catch unreachable;
    map.put("paste", Applet{ .name = "paste", .main = paste_main, .flags = .{} }) catch unreachable;
    map.put("shred", Applet{ .name = "shred", .main = shred_main, .flags = .{} }) catch unreachable;
    map.put("shuf", Applet{ .name = "shuf", .main = shuf_main, .flags = .{} }) catch unreachable;
    map.put("split", Applet{ .name = "split", .main = split_main, .flags = .{} }) catch unreachable;
    map.put("stat", Applet{ .name = "stat", .main = stat_main, .flags = .{} }) catch unreachable;
    map.put("strings", Applet{ .name = "strings", .main = strings_main, .flags = .{} }) catch unreachable;
    map.put("tsort", Applet{ .name = "tsort", .main = tsort_main, .flags = .{} }) catch unreachable;
    map.put("unexpand", Applet{ .name = "unexpand", .main = unexpand_main, .flags = .{} }) catch unreachable;
    map.put("yes", Applet{ .name = "yes", .main = yes_main, .flags = .{} }) catch unreachable;
    map.put("zcat", Applet{ .name = "zcat", .main = zcat_main, .flags = .{} }) catch unreachable;
    map.put("zcmp", Applet{ .name = "zcmp", .main = zcmp_main, .flags = .{} }) catch unreachable;
    map.put("zdiff", Applet{ .name = "zdiff", .main = zdiff_main, .flags = .{} }) catch unreachable;
    map.put("zgrep", Applet{ .name = "zgrep", .main = zgrep_main, .flags = .{} }) catch unreachable;
    map.put("zless", Applet{ .name = "zless", .main = zless_main, .flags = .{} }) catch unreachable;
    map.put("zmore", Applet{ .name = "zmore", .main = zmore_main, .flags = .{} }) catch unreachable;
    map.put("znew", Applet{ .name = "znew", .main = znew_main, .flags = .{} }) catch unreachable;
    map.put("mkfifo", Applet{ .name = "mkfifo", .main = mkfifo_main, .flags = .{} }) catch unreachable;
    map.put("mknod", Applet{ .name = "mknod", .main = mknod_main, .flags = .{} }) catch unreachable;
    map.put("mktemp", Applet{ .name = "mktemp", .main = mktemp_main, .flags = .{} }) catch unreachable;
    map.put("realpath", Applet{ .name = "realpath", .main = realpath_main, .flags = .{} }) catch unreachable;
    map.put("nohup", Applet{ .name = "nohup", .main = nohup_main, .flags = .{} }) catch unreachable;
    map.put("numfmt", Applet{ .name = "numfmt", .main = numfmt_main, .flags = .{} }) catch unreachable;
    map.put("crc32", Applet{ .name = "crc32", .main = crc32_main, .flags = .{} }) catch unreachable;
    map.put("sha512sum", Applet{ .name = "sha512sum", .main = sha512sum_main, .flags = .{} }) catch unreachable;
    map.put("xz", Applet{ .name = "xz", .main = xz_main, .flags = .{} }) catch unreachable;
    map.put("xzcat", Applet{ .name = "xzcat", .main = xzcat_main, .flags = .{} }) catch unreachable;
    map.put("unxz", Applet{ .name = "unxz", .main = unxz_main, .flags = .{} }) catch unreachable;
    map.put("lzma", Applet{ .name = "lzma", .main = lzma_main, .flags = .{} }) catch unreachable;
    map.put("lzop", Applet{ .name = "lzop", .main = lzop_main, .flags = .{} }) catch unreachable;
    map.put("lzopcat", Applet{ .name = "lzopcat", .main = lzopcat_main, .flags = .{} }) catch unreachable;
    map.put("unlzma", Applet{ .name = "unlzma", .main = unlzma_main, .flags = .{} }) catch unreachable;
    map.put("zlib", Applet{ .name = "zlib", .main = zlib_main, .flags = .{} }) catch unreachable;
    map.put("zlib1g", Applet{ .name = "zlib1g", .main = zlib1g_main, .flags = .{} }) catch unreachable;
    map.put("uncompress", Applet{ .name = "uncompress", .main = uncompress_main, .flags = .{} }) catch unreachable;
    map.put("lzopuncompress", Applet{ .name = "lzopuncompress", .main = lzopuncompress_main, .flags = .{} }) catch unreachable;

    // === Util-linux ===
    map.put("dmesg", Applet{ .name = "dmesg", .main = dmesg_main, .flags = .{} }) catch unreachable;
    map.put("mount", Applet{ .name = "mount", .main = mount_main, .flags = .{} }) catch unreachable;
    map.put("umount", Applet{ .name = "umount", .main = umount_main, .flags = .{} }) catch unreachable;
    map.put("fdisk", Applet{ .name = "fdisk", .main = fdisk_main, .flags = .{} }) catch unreachable;
    map.put("blkid", Applet{ .name = "blkid", .main = blkid_main, .flags = .{} }) catch unreachable;
    map.put("fallocate", Applet{ .name = "fallocate", .main = fallocate_main, .flags = .{} }) catch unreachable;
    map.put("flock", Applet{ .name = "flock", .main = flock_main, .flags = .{} }) catch unreachable;
    map.put("fstrim", Applet{ .name = "fstrim", .main = fstrim_main, .flags = .{} }) catch unreachable;
    map.put("hwclock", Applet{ .name = "hwclock", .main = hwclock_main, .flags = .{} }) catch unreachable;
    map.put("ionice", Applet{ .name = "ionice", .main = ionice_main, .flags = .{} }) catch unreachable;
    map.put("last", Applet{ .name = "last", .main = last_main, .flags = .{} }) catch unreachable;
    map.put("lsblk", Applet{ .name = "lsblk", .main = lsblk_main, .flags = .{} }) catch unreachable;
    map.put("mdev", Applet{ .name = "mdev", .main = mdev_main, .flags = .{} }) catch unreachable;
    map.put("mkhomedir_helper", Applet{ .name = "mkhomedir_helper", .main = mkhomedir_helper_main, .flags = .{} }) catch unreachable;
    map.put("more", Applet{ .name = "more", .main = more_main, .flags = .{} }) catch unreachable;
    map.put("mountpoint", Applet{ .name = "mountpoint", .main = mountpoint_main, .flags = .{} }) catch unreachable;
    map.put("nsenter", Applet{ .name = "nsenter", .main = nsenter_main, .flags = .{} }) catch unreachable;
    map.put("pivot_root", Applet{ .name = "pivot_root", .main = pivot_root_main, .flags = .{} }) catch unreachable;
    map.put("readprofile", Applet{ .name = "readprofile", .main = readprofile_main, .flags = .{} }) catch unreachable;
    map.put("renice", Applet{ .name = "renice", .main = renice_main, .flags = .{} }) catch unreachable;
    map.put("switch_root", Applet{ .name = "switch_root", .main = switch_root_main, .flags = .{} }) catch unreachable;
    map.put("taskset", Applet{ .name = "taskset", .main = taskset_main, .flags = .{} }) catch unreachable;
    map.put("unshare", Applet{ .name = "unshare", .main = unshare_main, .flags = .{} }) catch unreachable;
    map.put("setsid", Applet{ .name = "setsid", .main = setsid_main, .flags = .{} }) catch unreachable;
    map.put("chrt", Applet{ .name = "chrt", .main = chrt_main, .flags = .{} }) catch unreachable;
    map.put("lsusb", Applet{ .name = "lsusb", .main = lsusb_main, .flags = .{} }) catch unreachable;
    map.put("uevent", Applet{ .name = "uevent", .main = uevent_main, .flags = .{} }) catch unreachable;
    map.put("acpid", Applet{ .name = "acpid", .main = acpid_main, .flags = .{} }) catch unreachable;
    map.put("eject", Applet{ .name = "eject", .main = eject_main, .flags = .{} }) catch unreachable;
    map.put("swaplabel", Applet{ .name = "swaplabel", .main = swaplabel_main, .flags = .{} }) catch unreachable;
    map.put("rdate", Applet{ .name = "rdate", .main = rdate_main, .flags = .{} }) catch unreachable;
    map.put("fbset", Applet{ .name = "fbset", .main = fbset_main, .flags = .{} }) catch unreachable;
    map.put("fdformat", Applet{ .name = "fdformat", .main = fdformat_main, .flags = .{} }) catch unreachable;
    map.put("script", Applet{ .name = "script", .main = script_main, .flags = .{} }) catch unreachable;
    map.put("scriptreplay", Applet{ .name = "scriptreplay", .main = scriptreplay_main, .flags = .{} }) catch unreachable;
    map.put("losetup", Applet{ .name = "losetup", .main = losetup_main, .flags = .{} }) catch unreachable;
    map.put("freeramdisk", Applet{ .name = "freeramdisk", .main = freeramdisk_main, .flags = .{} }) catch unreachable;
    map.put("mkswap", Applet{ .name = "mkswap", .main = mkswap_main, .flags = .{} }) catch unreachable;
    map.put("blkdiscard", Applet{ .name = "blkdiscard", .main = blkdiscard_main, .flags = .{} }) catch unreachable;
    map.put("cal", Applet{ .name = "cal", .main = cal_main, .flags = .{} }) catch unreachable;
    map.put("fatlabel", Applet{ .name = "fatlabel", .main = fatlabel_main, .flags = .{} }) catch unreachable;
    map.put("rev", Applet{ .name = "rev", .main = rev_main, .flags = .{} }) catch unreachable;
    map.put("rdev", Applet{ .name = "rdev", .main = rdev_main, .flags = .{} }) catch unreachable;
    map.put("fatattr", Applet{ .name = "fatattr", .main = fatattr_main, .flags = .{} }) catch unreachable;
    map.put("fsfreeze", Applet{ .name = "fsfreeze", .main = fsfreeze_main, .flags = .{} }) catch unreachable;
    map.put("nologin", Applet{ .name = "nologin", .main = nologin_main, .flags = .{} }) catch unreachable;
    map.put("wall", Applet{ .name = "wall", .main = wall_main, .flags = .{} }) catch unreachable;
    map.put("findfs", Applet{ .name = "findfs", .main = findfs_main, .flags = .{} }) catch unreachable;
    map.put("blockdev", Applet{ .name = "blockdev", .main = blockdev_main, .flags = .{} }) catch unreachable;
    map.put("ipcs", Applet{ .name = "ipcs", .main = ipcs_main, .flags = .{} }) catch unreachable;
    map.put("ipcrm", Applet{ .name = "ipcrm", .main = ipcrm_main, .flags = .{} }) catch unreachable;
    map.put("hexdump", Applet{ .name = "hexdump", .main = hexdump_main, .flags = .{} }) catch unreachable;
    map.put("lspci", Applet{ .name = "lspci", .main = lspci_main, .flags = .{} }) catch unreachable;
    map.put("last_fancy", Applet{ .name = "last_fancy", .main = last_fancy_main, .flags = .{} }) catch unreachable;
    map.put("uuidgen", Applet{ .name = "uuidgen", .main = uuidgen_main, .flags = .{} }) catch unreachable;
    map.put("mesg", Applet{ .name = "mesg", .main = mesg_main, .flags = .{} }) catch unreachable;
    map.put("setpriv", Applet{ .name = "setpriv", .main = setpriv_main, .flags = .{} }) catch unreachable;
    map.put("rtcwake", Applet{ .name = "rtcwake", .main = rtcwake_main, .flags = .{} }) catch unreachable;
    map.put("setarch", Applet{ .name = "setarch", .main = setarch_main, .flags = .{} }) catch unreachable;

    // === Networking ===
    map.put("ip", Applet{ .name = "ip", .main = ip_main, .flags = .{} }) catch unreachable;
    map.put("ping", Applet{ .name = "ping", .main = ping_main, .flags = .{} }) catch unreachable;
    map.put("ifconfig", Applet{ .name = "ifconfig", .main = ifconfig_main, .flags = .{} }) catch unreachable;
    map.put("route", Applet{ .name = "route", .main = route_main, .flags = .{} }) catch unreachable;
    map.put("wget", Applet{ .name = "wget", .main = wget_main, .flags = .{} }) catch unreachable;
    map.put("nc", Applet{ .name = "nc", .main = nc_main, .flags = .{} }) catch unreachable;
    map.put("tftp", Applet{ .name = "tftp", .main = tftp_main, .flags = .{} }) catch unreachable;
    map.put("httpd", Applet{ .name = "httpd", .main = httpd_main, .flags = .{} }) catch unreachable;
    map.put("telnet", Applet{ .name = "telnet", .main = telnet_main, .flags = .{} }) catch unreachable;
    map.put("hostname", Applet{ .name = "hostname", .main = hostname_main, .flags = .{} }) catch unreachable;
    map.put("nslookup", Applet{ .name = "nslookup", .main = nslookup_main, .flags = .{} }) catch unreachable;
    map.put("ftpgetput", Applet{ .name = "ftpgetput", .main = ftpgetput_main, .flags = .{} }) catch unreachable;
    map.put("arping", Applet{ .name = "arping", .main = arping_main, .flags = .{} }) catch unreachable;
    map.put("netstat", Applet{ .name = "netstat", .main = netstat_main, .flags = .{} }) catch unreachable;
    map.put("ether_wake", Applet{ .name = "ether_wake", .main = ether_wake_main, .flags = .{} }) catch unreachable;
    map.put("whois", Applet{ .name = "whois", .main = whois_main, .flags = .{} }) catch unreachable;
    map.put("nbd_client", Applet{ .name = "nbd_client", .main = nbd_client_main, .flags = .{} }) catch unreachable;
    map.put("zcip", Applet{ .name = "zcip", .main = zcip_main, .flags = .{} }) catch unreachable;
    map.put("ftpd", Applet{ .name = "ftpd", .main = ftpd_main, .flags = .{} }) catch unreachable;
    map.put("isrv", Applet{ .name = "isrv", .main = isrv_main, .flags = .{} }) catch unreachable;
    map.put("isrv_identd", Applet{ .name = "isrv_identd", .main = isrv_identd_main, .flags = .{} }) catch unreachable;
    map.put("nc_bloaty", Applet{ .name = "nc_bloaty", .main = nc_bloaty_main, .flags = .{} }) catch unreachable;
    map.put("tc", Applet{ .name = "tc", .main = tc_main, .flags = .{} }) catch unreachable;
    map.put("dnsd", Applet{ .name = "dnsd", .main = dnsd_main, .flags = .{} }) catch unreachable;
    map.put("inetd", Applet{ .name = "inetd", .main = inetd_main, .flags = .{} }) catch unreachable;
    map.put("ifenslave", Applet{ .name = "ifenslave", .main = ifenslave_main, .flags = .{} }) catch unreachable;
    map.put("vconfig", Applet{ .name = "vconfig", .main = vconfig_main, .flags = .{} }) catch unreachable;
    map.put("brctl", Applet{ .name = "brctl", .main = brctl_main, .flags = .{} }) catch unreachable;
    map.put("ipcalc", Applet{ .name = "ipcalc", .main = ipcalc_main, .flags = .{} }) catch unreachable;
    map.put("traceroute", Applet{ .name = "traceroute", .main = traceroute_main, .flags = .{} }) catch unreachable;
    map.put("telnetd", Applet{ .name = "telnetd", .main = telnetd_main, .flags = .{} }) catch unreachable;
    map.put("pscan", Applet{ .name = "pscan", .main = pscan_main, .flags = .{} }) catch unreachable;
    map.put("slattach", Applet{ .name = "slattach", .main = slattach_main, .flags = .{} }) catch unreachable;
    map.put("tunctl", Applet{ .name = "tunctl", .main = tunctl_main, .flags = .{} }) catch unreachable;
    map.put("nameif", Applet{ .name = "nameif", .main = nameif_main, .flags = .{} }) catch unreachable;
    map.put("ifplugd", Applet{ .name = "ifplugd", .main = ifplugd_main, .flags = .{} }) catch unreachable;
    map.put("ntpd", Applet{ .name = "ntpd", .main = ntpd_main, .flags = .{} }) catch unreachable;
    map.put("arp", Applet{ .name = "arp", .main = arp_main, .flags = .{} }) catch unreachable;
    map.put("ifupdown", Applet{ .name = "ifupdown", .main = ifupdown_main, .flags = .{} }) catch unreachable;
    map.put("interface", Applet{ .name = "interface", .main = interface_main, .flags = .{} }) catch unreachable;
    map.put("ssl_client", Applet{ .name = "ssl_client", .main = ssl_client_main, .flags = .{} }) catch unreachable;
    map.put("ssl_server", Applet{ .name = "ssl_server", .main = ssl_server_main, .flags = .{} }) catch unreachable;
    map.put("tls", Applet{ .name = "tls", .main = tls_main, .flags = .{} }) catch unreachable;
    map.put("tls_aes", Applet{ .name = "tls_aes", .main = tls_aes_main, .flags = .{} }) catch unreachable;
    map.put("tls_aesgcm", Applet{ .name = "tls_aesgcm", .main = tls_aesgcm_main, .flags = .{} }) catch unreachable;
    map.put("tls_fe", Applet{ .name = "tls_fe", .main = tls_fe_main, .flags = .{} }) catch unreachable;
    map.put("tls_pstm", Applet{ .name = "tls_pstm", .main = tls_pstm_main, .flags = .{} }) catch unreachable;
    map.put("tls_pstm_mul_comba", Applet{ .name = "tls_pstm_mul_comba", .main = tls_pstm_mul_comba_main, .flags = .{} }) catch unreachable;
    map.put("tls_pstm_sqr_comba", Applet{ .name = "tls_pstm_sqr_comba", .main = tls_pstm_sqr_comba_main, .flags = .{} }) catch unreachable;
    map.put("tls_pstm_montgomery_reduce", Applet{ .name = "tls_pstm_montgomery_reduce", .main = tls_pstm_montgomery_reduce_main, .flags = .{} }) catch unreachable;
    map.put("tls_rsa", Applet{ .name = "tls_rsa", .main = tls_rsa_main, .flags = .{} }) catch unreachable;
    map.put("tls_sp_c32", Applet{ .name = "tls_sp_c32", .main = tls_sp_c32_main, .flags = .{} }) catch unreachable;
    map.put("httpd_indexcgi", Applet{ .name = "httpd_indexcgi", .main = httpd_indexcgi_main, .flags = .{} }) catch unreachable;
    map.put("httpd_ssi", Applet{ .name = "httpd_ssi", .main = httpd_ssi_main, .flags = .{} }) catch unreachable;
    map.put("httpd_ratelimit_cgi", Applet{ .name = "httpd_ratelimit_cgi", .main = httpd_ratelimit_cgi_main, .flags = .{} }) catch unreachable;
    map.put("tcpudp", Applet{ .name = "tcpudp", .main = tcpudp_main, .flags = .{} }) catch unreachable;
    map.put("tcpudp_perhost", Applet{ .name = "tcpudp_perhost", .main = tcpudp_perhost_main, .flags = .{} }) catch unreachable;
    // === Miscutils ===
    map.put("inotifyd", Applet{ .name = "inotifyd", .main = inotifyd_main, .flags = .{} }) catch unreachable;
    map.put("watchdog", Applet{ .name = "watchdog", .main = watchdog_main, .flags = .{} }) catch unreachable;
    map.put("hexedit", Applet{ .name = "hexedit", .main = hexedit_main, .flags = .{} }) catch unreachable;
    map.put("dc", Applet{ .name = "dc", .main = dc_main, .flags = .{} }) catch unreachable;
    map.put("ubirename", Applet{ .name = "ubirename", .main = ubirename_main, .flags = .{} }) catch unreachable;
    map.put("time", Applet{ .name = "time", .main = time_main, .flags = .{} }) catch unreachable;
    map.put("setserial", Applet{ .name = "setserial", .main = setserial_main, .flags = .{} }) catch unreachable;
    map.put("microcom", Applet{ .name = "microcom", .main = microcom_main, .flags = .{} }) catch unreachable;
    map.put("rx", Applet{ .name = "rx", .main = rx_main, .flags = .{} }) catch unreachable;
    map.put("mt", Applet{ .name = "mt", .main = mt_main, .flags = .{} }) catch unreachable;
    map.put("runlevel", Applet{ .name = "runlevel", .main = runlevel_main, .flags = .{} }) catch unreachable;
    map.put("readahead", Applet{ .name = "readahead", .main = readahead_main, .flags = .{} }) catch unreachable;
    map.put("seedrng", Applet{ .name = "seedrng", .main = seedrng_main, .flags = .{} }) catch unreachable;
    map.put("raidautorun", Applet{ .name = "raidautorun", .main = raidautorun_main, .flags = .{} }) catch unreachable;
    map.put("bbconfig", Applet{ .name = "bbconfig", .main = bbconfig_main, .flags = .{} }) catch unreachable;
    map.put("ascii", Applet{ .name = "ascii", .main = ascii_main, .flags = .{} }) catch unreachable;
    map.put("makedevs", Applet{ .name = "makedevs", .main = makedevs_main, .flags = .{} }) catch unreachable;
    map.put("bc", Applet{ .name = "bc", .main = bc_main, .flags = .{} }) catch unreachable;
    map.put("flash_eraseall", Applet{ .name = "flash_eraseall", .main = flash_eraseall_main, .flags = .{} }) catch unreachable;
    map.put("tree", Applet{ .name = "tree", .main = tree_main, .flags = .{} }) catch unreachable;
    map.put("lsscsi", Applet{ .name = "lsscsi", .main = lsscsi_main, .flags = .{} }) catch unreachable;
    map.put("crontab", Applet{ .name = "crontab", .main = crontab_main, .flags = .{} }) catch unreachable;
    map.put("volname", Applet{ .name = "volname", .main = volname_main, .flags = .{} }) catch unreachable;
    map.put("flashcp", Applet{ .name = "flashcp", .main = flashcp_main, .flags = .{} }) catch unreachable;
    map.put("flash_lock_unlock", Applet{ .name = "flash_lock_unlock", .main = flash_lock_unlock_main, .flags = .{} }) catch unreachable;
    map.put("i2c_tools", Applet{ .name = "i2c_tools", .main = i2c_tools_main, .flags = .{} }) catch unreachable;
    map.put("mim", Applet{ .name = "mim", .main = mim_main, .flags = .{} }) catch unreachable;
    map.put("beep", Applet{ .name = "beep", .main = beep_main, .flags = .{} }) catch unreachable;
    map.put("partprobe", Applet{ .name = "partprobe", .main = partprobe_main, .flags = .{} }) catch unreachable;
    map.put("fbsplash", Applet{ .name = "fbsplash", .main = fbsplash_main, .flags = .{} }) catch unreachable;
    map.put("hdparm", Applet{ .name = "hdparm", .main = hdparm_main, .flags = .{} }) catch unreachable;
    map.put("devmem", Applet{ .name = "devmem", .main = devmem_main, .flags = .{} }) catch unreachable;
    map.put("ts", Applet{ .name = "ts", .main = ts_main, .flags = .{} }) catch unreachable;
    map.put("adjtimex", Applet{ .name = "adjtimex", .main = adjtimex_main, .flags = .{} }) catch unreachable;
    map.put("ttysize", Applet{ .name = "ttysize", .main = ttysize_main, .flags = .{} }) catch unreachable;
    map.put("getfattr", Applet{ .name = "getfattr", .main = getfattr_main, .flags = .{} }) catch unreachable;
    map.put("rfkill", Applet{ .name = "rfkill", .main = rfkill_main, .flags = .{} }) catch unreachable;
    map.put("chat", Applet{ .name = "chat", .main = chat_main, .flags = .{} }) catch unreachable;
    map.put("man", Applet{ .name = "man", .main = man_main, .flags = .{} }) catch unreachable;
    map.put("less", Applet{ .name = "less", .main = less_main, .flags = .{} }) catch unreachable;
    map.put("ubi_tools", Applet{ .name = "ubi_tools", .main = ubi_tools_main, .flags = .{} }) catch unreachable;
    map.put("nandwrite", Applet{ .name = "nandwrite", .main = nandwrite_main, .flags = .{} }) catch unreachable;
    map.put("conspy", Applet{ .name = "conspy", .main = conspy_main, .flags = .{} }) catch unreachable;
    map.put("crond", Applet{ .name = "crond", .main = crond_main, .flags = .{} }) catch unreachable;
    map.put("devfsd", Applet{ .name = "devfsd", .main = devfsd_main, .flags = .{} }) catch unreachable;
    map.put("setfattr", Applet{ .name = "setfattr", .main = setfattr_main, .flags = .{} }) catch unreachable;
    map.put("setconsole", Applet{ .name = "setconsole", .main = setconsole_main, .flags = .{} }) catch unreachable;
    map.put("mke2fs", Applet{ .name = "mke2fs", .main = mke2fs_main, .flags = .{} }) catch unreachable;
    map.put("tune2fs", Applet{ .name = "tune2fs", .main = tune2fs_main, .flags = .{} }) catch unreachable;
    map.put("e2label", Applet{ .name = "e2label", .main = e2label_main, .flags = .{} }) catch unreachable;
    map.put("dump", Applet{ .name = "dump", .main = dump_main, .flags = .{} }) catch unreachable;
    map.put("restore", Applet{ .name = "restore", .main = restore_main, .flags = .{} }) catch unreachable;
    map.put("debugfs", Applet{ .name = "debugfs", .main = debugfs_main, .flags = .{} }) catch unreachable;

    // === Procps ===
    map.put("kill", Applet{ .name = "kill", .main = kill_main, .flags = .{} }) catch unreachable;
    map.put("killall", Applet{ .name = "killall", .main = killall_main, .flags = .{} }) catch unreachable;
    map.put("killall5", Applet{ .name = "killall5", .main = killall5_main, .flags = .{} }) catch unreachable;
    map.put("free", Applet{ .name = "free", .main = free_main, .flags = .{} }) catch unreachable;
    map.put("pwdx", Applet{ .name = "pwdx", .main = pwdx_main, .flags = .{} }) catch unreachable;
    map.put("ps", Applet{ .name = "ps", .main = ps_main, .flags = .{} }) catch unreachable;
    map.put("top", Applet{ .name = "top", .main = top_main, .flags = .{} }) catch unreachable;
    map.put("lsof", Applet{ .name = "lsof", .main = lsof_main, .flags = .{} }) catch unreachable;
    map.put("smemcap", Applet{ .name = "smemcap", .main = smemcap_main, .flags = .{} }) catch unreachable;
    map.put("powertop", Applet{ .name = "powertop", .main = powertop_main, .flags = .{} }) catch unreachable;
    map.put("watch", Applet{ .name = "watch", .main = watch_main, .flags = .{} }) catch unreachable;
    map.put("vmstat", Applet{ .name = "vmstat", .main = vmstat_main, .flags = .{} }) catch unreachable;
    map.put("iostat", Applet{ .name = "iostat", .main = iostat_main, .flags = .{} }) catch unreachable;
    map.put("fuser", Applet{ .name = "fuser", .main = fuser_main, .flags = .{} }) catch unreachable;
    map.put("pidof", Applet{ .name = "pidof", .main = pidof_main, .flags = .{} }) catch unreachable;
    map.put("pstree", Applet{ .name = "pstree", .main = pstree_main, .flags = .{} }) catch unreachable;
    map.put("nmeter", Applet{ .name = "nmeter", .main = nmeter_main, .flags = .{} }) catch unreachable;
    map.put("pgrep", Applet{ .name = "pgrep", .main = pgrep_main, .flags = .{} }) catch unreachable;
    map.put("pmap", Applet{ .name = "pmap", .main = pmap_main, .flags = .{} }) catch unreachable;
    map.put("sysctl", Applet{ .name = "sysctl", .main = sysctl_main, .flags = .{} }) catch unreachable;
    map.put("mpstat", Applet{ .name = "mpstat", .main = mpstat_main, .flags = .{} }) catch unreachable;

    // === Shell ===
    map.put("ash", Applet{ .name = "ash", .main = ash_main, .flags = .{} }) catch unreachable;
    map.put("hush", Applet{ .name = "hush", .main = hush_main, .flags = .{} }) catch unreachable;
    map.put("random", Applet{ .name = "random", .main = random_main, .flags = .{} }) catch unreachable;
    map.put("match", Applet{ .name = "match", .main = match_main, .flags = .{} }) catch unreachable;
    map.put("cttyhack", Applet{ .name = "cttyhack", .main = cttyhack_main, .flags = .{} }) catch unreachable;
    map.put("math", Applet{ .name = "math", .main = math_main, .flags = .{} }) catch unreachable;

    // === Loginutils ===
    map.put("vlock", Applet{ .name = "vlock", .main = vlock_main, .flags = .{} }) catch unreachable;
    map.put("deluser", Applet{ .name = "deluser", .main = deluser_main, .flags = .{} }) catch unreachable;
    map.put("adduser", Applet{ .name = "adduser", .main = adduser_main, .flags = .{} }) catch unreachable;
    map.put("login", Applet{ .name = "login", .main = login_main, .flags = .{} }) catch unreachable;
    map.put("addgroup", Applet{ .name = "addgroup", .main = addgroup_main, .flags = .{} }) catch unreachable;
    map.put("passwd", Applet{ .name = "passwd", .main = passwd_main, .flags = .{} }) catch unreachable;
    map.put("chpasswd", Applet{ .name = "chpasswd", .main = chpasswd_main, .flags = .{} }) catch unreachable;
    map.put("add_remove_shell", Applet{ .name = "add_remove_shell", .main = add_remove_shell_main, .flags = .{} }) catch unreachable;
    map.put("su", Applet{ .name = "su", .main = su_main, .flags = .{} }) catch unreachable;
    map.put("sulogin", Applet{ .name = "sulogin", .main = sulogin_main, .flags = .{} }) catch unreachable;
    map.put("cryptpw", Applet{ .name = "cryptpw", .main = cryptpw_main, .flags = .{} }) catch unreachable;
    map.put("mkpasswd", Applet{ .name = "mkpasswd", .main = mkpasswd_main, .flags = .{} }) catch unreachable;
    map.put("getty", Applet{ .name = "getty", .main = getty_main, .flags = .{} }) catch unreachable;

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
