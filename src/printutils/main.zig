//! printutils applets (lpd, lpq, lpr).

const lpd = @import("lpd.zig");
const lpr = @import("lpr.zig");

pub fn lpd_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return lpd.lpdMain(argc, argv);
}

pub fn lpq_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return lpr.lprMain(argc, argv);
}

pub fn lpr_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return lpr.lprMain(argc, argv);
}
