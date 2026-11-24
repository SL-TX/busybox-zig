//! klibc applets (nuke, resume).

const nuke = @import("nuke.zig");
const resume_mod = @import("resume.zig");

pub fn nuke_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return nuke.nukeMain(argc, argv);
}

pub fn resume_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return resume_mod.resumeMain(argc, argv);
}
