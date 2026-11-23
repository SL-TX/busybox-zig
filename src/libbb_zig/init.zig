//! libbb_zig — библиотека общих функций BusyBox, портированных на Zig.
//! Импортируйте нужные подмодули отдельно:
//!   const string = @import("string.zig");
//!   const process = @import("process.zig");
//!   const io = @import("io.zig");
//!   const hash = @import("hash.zig");
//!   const socket = @import("socket.zig");
//!   const util = @import("util.zig");

pub fn init() void {}

pub const string = @import("string.zig");
pub const process = @import("process.zig");
pub const io = @import("io.zig");
pub const usage = @import("usage.zig");
pub const hash = @import("hash.zig");
pub const socket = @import("socket.zig");
pub const util = @import("util.zig");
pub const pw = @import("pw.zig");
pub const env = @import("env.zig");
pub const messages = @import("messages.zig");
pub const xfuncs = @import("xfuncs.zig");
pub const getopt = @import("getopt.zig");
pub const path = @import("path.zig");
pub const io_more = @import("io_more.zig");
pub const regex = @import("regex/regex.zig");
pub const file = @import("file.zig");
pub const copy = @import("copy.zig");
pub const recursive = @import("recursive.zig");
pub const process_more = @import("process_more.zig");
pub const identity = @import("identity.zig");
pub const utmp = @import("utmp.zig");
pub const mtab = @import("mtab.zig");

// Task 23 — libbb crypto helpers (Wave 7 prerequisites).
pub const crypto = struct {
    pub const md5 = @import("crypto/md5.zig");
    pub const sha1 = @import("crypto/sha1.zig");
    pub const sha256 = @import("crypto/sha256.zig");
    pub const sha512 = @import("crypto/sha512.zig");
    pub const sha3 = @import("crypto/sha3.zig");
    pub const hmac = @import("crypto/hmac.zig");
    pub const crc32 = @import("crypto/crc32.zig");
    pub const base64 = @import("crypto/base64.zig");
    pub const uuencode = @import("crypto/uuencode.zig");
    pub const des = @import("crypto/des.zig");
    pub const pw_encrypt = @import("crypto/pw_encrypt.zig");
};

// Task 23 — libbb login/passwd helpers (Wave 7 prerequisites).
// Task 23 — libbb SELinux helpers (Wave 7 prerequisites).
pub const selinux = @import("selinux.zig");

pub const login = struct {
    pub const passwd = @import("login/passwd.zig");
    pub const shadow = @import("login/shadow.zig");
    pub const group = @import("login/group.zig");
    pub const securetty = @import("login/securetty.zig");
    pub const update_passwd = @import("login/update_passwd.zig");
};

// Task 15 — process/terminal helpers (Wave 4 prerequisites).
pub const procps = @import("procps.zig");
pub const signals_more = @import("signals_more.zig");
pub const pty = @import("pty.zig");
pub const term = struct {
    pub const termios = @import("term/termios.zig");
    pub const console = @import("term/console.zig");
    pub const keyboard = @import("term/keyboard.zig");
    pub const fb = @import("term/fb.zig");
};

// Task 19 — compression / archive helpers (Wave 5 prerequisites).
pub const compression = struct {
    pub const gzip = @import("compression/gzip.zig");
    pub const bzip2 = @import("compression/bzip2.zig");
    pub const xz = @import("compression/xz.zig");
    pub const lzma = @import("compression/lzma.zig");
    pub const lzop = @import("compression/lzop.zig");
};
pub const archive = struct {
    pub const tar = @import("archive/tar.zig");
    pub const cpio = @import("archive/cpio.zig");
    pub const rpm = @import("archive/rpm.zig");
    pub const dpkg = @import("archive/dpkg.zig");
};

// Wave 3 networking helpers.
pub const dns = @import("net/dns.zig");
pub const http = @import("net/http.zig");
pub const dhcp = @import("net/dhcp.zig");
pub const tls = @import("net/tls/tls.zig");
