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
