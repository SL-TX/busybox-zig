//! util-linux applet implementations (system utilities).

const std = @import("std");
const linux = std.os.linux;
const text = @import("text.zig");
const files = @import("files.zig");
const system = @import("system.zig");
const sched = @import("sched.zig");
const pdisk = @import("priv_disk.zig");
const psystem = @import("priv_system.zig");
const pns = @import("priv_namespace.zig");

pub const init = struct {
    pub fn init() void {}
};

fn out(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}

fn argsFrom(argv: [*][*:0]const u8, argc: c_int) []const []const u8 {
    const a = std.heap.page_allocator.alloc([]const u8, @intCast(argc)) catch return &.{};
    for (0..@as(usize, @intCast(argc))) |i| a[i] = std.mem.span(argv[i]);
    return a;
}

fn zstr(a: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    const owned = try std.mem.concatWithSentinel(a, u8, &.{s}, 0);
    return owned.ptr;
}

fn readWholeFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const p = try zstr(a, path);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try result.appendSlice(a, buf[0..n]);
    }
    return result.toOwnedSlice(a);
}

pub fn mount_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return psystem.mount_main(argc, argv);
}

pub fn umount_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return psystem.umount_main(argc, argv);
}

pub fn dmesg_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return system.dmesg_main(argc, argv);
}

pub fn blkid_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return files.blkid_main(argc, argv);
}

pub const blkidDetect = files.blkidDetect;
pub const BlkidInfo = files.BlkidInfo;
pub const padRight = system.padRight;

// ---------------------------------------------------------------------------
// Task 10a — safe util-linux applets. Implementations live in sibling files;
// these are the single canonical <name>_main entry points in this module.
// ---------------------------------------------------------------------------
pub const acpid_main = system.acpid_main;
pub const blkdiscard_main = files.blkdiscard_main;
pub const blockdev_main = system.blockdev_main;
pub const cal_main = text.cal_main;
pub const eject_main = files.eject_main;
pub const fallocate_main = files.fallocate_main;
pub const fatattr_main = files.fatattr_main;
pub const fatlabel_main = files.fatlabel_main;
pub const fdflush_main = files.fdflush_main;
pub const flock_main = files.flock_main;
pub const freeramdisk_main = files.freeramdisk_main;
pub const fsfreeze_main = files.fsfreeze_main;
pub const fstrim_main = files.fstrim_main;
pub const getopt_main = text.getopt_main;
pub const hd_main = text.hd_main;
pub const hexdump_main = text.hexdump_main;
pub const hwclock_main = system.hwclock_main;
pub const ionice_main = sched.ionice_main;
pub const ipcrm_main = system.ipcrm_main;
pub const ipcs_main = system.ipcs_main;
pub const last_main = system.last_main;
pub const linux32_main = sched.linux32_main;
pub const linux64_main = sched.linux64_main;
pub const lsblk_main = system.lsblk_main;
pub const lspci_main = system.lspci_main;
pub const lsusb_main = system.lsusb_main;
pub const mesg_main = system.mesg_main;
pub const more_main = text.more_main;
pub const mountpoint_main = files.mountpoint_main;
pub const nologin_main = system.nologin_main;
pub const readprofile_main = system.readprofile_main;
pub const renice_main = sched.renice_main;
pub const rev_main = text.rev_main;
pub const rtcwake_main = system.rtcwake_main;
pub const script_main = system.script_main;
pub const scriptreplay_main = system.scriptreplay_main;
pub const setarch_main = sched.setarch_main;
pub const setpriv_main = sched.setpriv_main;
pub const setsid_main = sched.setsid_main;
pub const swaplabel_main = files.swaplabel_main;
pub const taskset_main = sched.taskset_main;
pub const uevent_main = system.uevent_main;
pub const uuidgen_main = sched.uuidgen_main;
pub const wall_main = system.wall_main;
pub const xxd_main = text.xxd_main;

// ---------------------------------------------------------------------------
// Task 10b — privileged/destructive util-linux sub-wave.
// mkfs.reiser is compiled out in both the reference and our defconfig
// (CONFIG_MKFS_REISER=n), so it intentionally stays on stubMain/"not found".
// ---------------------------------------------------------------------------
pub const chrt_main = pdisk.chrt_main;
pub const fbset_main = pdisk.fbset_main;
pub const fdformat_main = pdisk.fdformat_main;
pub const fdisk_main = pdisk.fdisk_main;
pub const findfs_main = pdisk.findfs_main;
pub const fsck_minix_main = pdisk.fsck_minix_main;
pub const losetup_main = pdisk.losetup_main;
pub const mdev_main = psystem.mdev_main;
pub const mkdosfs_main = pdisk.mkdosfs_main;
pub const mke2fs_main = pdisk.mke2fs_main;
pub const mkfs_ext2_main = pdisk.mkfs_ext2_main;
pub const mkfs_minix_main = pdisk.mkfs_minix_main;
pub const mkfs_vfat_main = pdisk.mkfs_vfat_main;
pub const mkswap_main = pdisk.mkswap_main;
pub const nsenter_main = pns.nsenter_main;
pub const pivot_root_main = pns.pivot_root_main;
pub const rdate_main = pns.rdate_main;
pub const rdev_main = psystem.rdev_main;
pub const run_init_main = pns.run_init_main;
pub const swapoff_main = psystem.swapoff_main;
pub const swapon_main = psystem.swapon_main;
pub const switch_root_main = pns.switch_root_main;
pub const unshare_main = pns.unshare_main;
