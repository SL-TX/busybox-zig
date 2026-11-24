//! debianutils which — locate commands in PATH.

const std = @import("std");
const c = @import("common.zig");
const bb = c.bb;
const linux = c.linux;

fn executable(path: []const u8) bool {
    const st = c.statPath(path, true) orelse return false;
    if ((st.mode & linux.S.IFMT) != linux.S.IFREG) return false;
    return (st.mode & 0o111) != 0;
}

pub fn whichMain(argc: c_int, argv: [*][*:0]const u8) c_int {
    const allocator = std.heap.page_allocator;
    const args = c.argsFrom(allocator, argv, argc) catch return 1;
    defer allocator.free(args);
    bb.env.setProgramName(c.basename(args[0]));

    const parsed = bb.getopt.getopt32(args, "^a", &.{}) catch {
        bb.usage.die(c.basename(args[0]));
    };
    const show_all = (parsed.flags & 1) != 0;
    const rest = parsed.args;
    if (rest.len == 0) bb.usage.die(c.basename(args[0]));

    const env_path = bb.env.get("PATH") orelse "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    var status: c_int = 0;
    for (rest) |cmd| {
        var missing = true;
        if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
            if (executable(cmd)) {
                missing = false;
                c.writeAll(1, cmd);
                c.writeAll(1, "\n");
            }
        } else {
            var it = std.mem.splitScalar(u8, env_path, ':');
            while (it.next()) |dir_raw| {
                const dir = if (dir_raw.len == 0) "." else dir_raw;
                const candidate = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, cmd }) catch break;
                defer allocator.free(candidate);
                if (executable(candidate)) {
                    missing = false;
                    c.writeAll(1, candidate);
                    c.writeAll(1, "\n");
                    if (!show_all) break;
                }
            }
        }
        if (missing) status = 1;
    }
    return status;
}
