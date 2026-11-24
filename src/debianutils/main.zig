//! debianutils applets (which, pipe_progress, run-parts, start-stop-daemon).

const which = @import("which.zig");
const pipe_progress = @import("pipe_progress.zig");
const run_parts = @import("run_parts.zig");
const ssd = @import("start_stop_daemon.zig");

pub fn which_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return which.whichMain(argc, argv);
}
pub fn pipe_progress_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return pipe_progress.pipeProgressMain(argc, argv);
}
pub fn run_parts_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return run_parts.runPartsMain(argc, argv);
}
pub fn start_stop_daemon_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    return ssd.startStopDaemonMain(argc, argv);
}
