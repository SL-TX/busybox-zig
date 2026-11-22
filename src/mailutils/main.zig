//! Task 14 — mailutils applets (reference busybox/mailutils/*.c).

pub const makemime_main = @import("makemime.zig").makemimeMain;
pub const popmaildir_main = @import("popmaildir.zig").popmaildirMain;
pub const reformime_main = @import("reformime.zig").reformimeMain;
pub const sendmail_main = @import("sendmail.zig").sendmailMain;

pub const common = @import("mail_common.zig");
