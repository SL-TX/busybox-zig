//! modutils applets: depmod, insmod, lsmod, modinfo, modprobe, rmmod.

pub const depmod_main = @import("depmod.zig").depmodMain;
pub const insmod_main = @import("insmod.zig").insmodMain;
pub const lsmod_main = @import("lsmod.zig").lsmodMain;
pub const modinfo_main = @import("modinfo.zig").modinfoMain;
pub const modprobe_main = @import("modprobe.zig").modprobeMain;
pub const rmmod_main = @import("rmmod.zig").rmmodMain;

// Pure helpers exported for unit tests.
pub const common = @import("common.zig");
pub const rmmod = @import("rmmod.zig");
