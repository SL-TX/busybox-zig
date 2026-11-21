//! e2fsprogs applets: chattr, lsattr, fsck, tune2fs.

pub const chattr_main = @import("chattr.zig").chattrMain;
pub const lsattr_main = @import("lsattr.zig").lsattrMain;
pub const fsck_main = @import("fsck.zig").fsckMain;
pub const tune2fs_main = @import("tune2fs.zig").tune2fsMain;

// Pure helpers exported for unit tests.
pub const flags = @import("flags.zig");
pub const chattr = @import("chattr.zig");
pub const tune2fs = @import("tune2fs.zig");
