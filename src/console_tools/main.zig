//! console-tools applet implementations (Task 18).
//! No C code, no delegation: console/VT operations are real ioctl wrappers.

const std = @import("std");

pub const init = struct {
    pub fn init() void {}
};

pub const common = @import("common.zig");
pub const simple = @import("simple.zig");
pub const keyboard = @import("keyboard.zig");
pub const font = @import("font.zig");
pub const openvt = @import("openvt.zig");

pub const chvt_main = simple.chvtMain;
pub const clear_main = simple.clearMain;
pub const deallocvt_main = simple.deallocvtMain;
pub const dumpkmap_main = simple.dumpkmapMain;
pub const fgconsole_main = simple.fgconsoleMain;
pub const reset_main = simple.resetMain;
pub const resize_main = simple.resizeMain;
pub const setconsole_main = simple.setconsoleMain;
pub const setkeycodes_main = simple.setkeycodesMain;
pub const setlogcons_main = simple.setlogconsMain;

pub const kbd_mode_main = keyboard.kbdModeMain;
pub const loadkmap_main = keyboard.loadkmapMain;
pub const showkey_main = keyboard.showkeyMain;

pub const loadfont_main = font.loadfontMain;
pub const setfont_main = font.setfontMain;
pub const openvt_main = openvt.openvtMain;
