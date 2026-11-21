//! findutils applets (find, grep, egrep, fgrep, xargs).

const find = @import("find.zig");
const grep = @import("grep.zig");
const xargs = @import("xargs.zig");

pub fn find_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return find.findMain(argc, argv);
}
pub fn grep_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return grep.grepMain(argc, argv);
}
pub fn egrep_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return grep.grepMain(argc, argv);
}
pub fn fgrep_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return grep.grepMain(argc, argv);
}
pub fn xargs_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return xargs.xargsMain(argc, argv);
}
