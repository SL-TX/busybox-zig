//! Task 20 — archival applets. Pure Zig implementations built on the Task 19
//! libbb compression/archive helpers.

const std = @import("std");
const decompress = @import("decompress.zig");
const archive_cmds = @import("archive_cmds.zig");
const unzip_cmd = @import("unzip_cmd.zig");
const tarcmd = @import("tarcmd.zig");

pub const init = struct {
    pub fn init() void {}
};

pub const gzip_main = decompress.gzipMain;
pub const gunzip_main = decompress.gunzipMain;
pub const zcat_main = decompress.zcatMain;
pub const bzip2_main = decompress.bzip2Main;
pub const bunzip2_main = decompress.bunzip2Main;
pub const bzcat_main = decompress.bzcatMain;
pub const xz_main = decompress.xzMain;
pub const unxz_main = decompress.unxzMain;
pub const xzcat_main = decompress.xzcatMain;
pub const lzma_main = decompress.lzmaMain;
pub const unlzma_main = decompress.unlzmaMain;
pub const lzcat_main = decompress.lzcatMain;
pub const lzop_main = decompress.lzopMain;
pub const unlzop_main = decompress.unlzopMain;
pub const lzopcat_main = decompress.lzopcatMain;
pub const uncompress_main = decompress.uncompressMain;
pub const ar_main = archive_cmds.arMain;
pub const cpio_main = archive_cmds.cpioMain;
pub const dpkg_main = archive_cmds.dpkgMain;
pub const dpkg_deb_main = archive_cmds.dpkgDebMain;
pub const rpm_main = archive_cmds.rpmMain;
pub const rpm2cpio_main = archive_cmds.rpm2cpioMain;
pub const unzip_main = unzip_cmd.unzipMain;
pub const tar_main = tarcmd.tarMain;
