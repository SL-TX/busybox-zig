const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the main module
    const root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the main executable
    const exe = b.addExecutable(.{
        .name = "busybox",
        .root_module = root_module,
    });

    // Add libbb_zig module
    const libbb_zig = b.addModule("libbb_zig", .{
        .root_source_file = b.path("libbb_zig/init.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add coreutils module
    const coreutils = b.addModule("coreutils", .{
        .root_source_file = b.path("coreutils/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("coreutils", coreutils);

    // Add util-linux module
    const util_linux = b.addModule("util_linux", .{
        .root_source_file = b.path("util-linux/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("util_linux", util_linux);

    // Add networking module
    const networking = b.addModule("networking", .{
        .root_source_file = b.path("networking/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("networking", networking);

    // Add miscutils module
    const miscutils = b.addModule("miscutils", .{
        .root_source_file = b.path("miscutils/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("miscutils", miscutils);

    // Add procps module
    const procps = b.addModule("procps", .{
        .root_source_file = b.path("procps/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("procps", procps);

    // Add shell module
    const shell = b.addModule("shell", .{
        .root_source_file = b.path("shell/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("shell", shell);

    // Add loginutils module
    const loginutils = b.addModule("loginutils", .{
        .root_source_file = b.path("loginutils/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("loginutils", loginutils);

    // Link libbb_zig to exe
    exe.root_module.addImport("libbb_zig", libbb_zig);

    // Install target
    b.installArtifact(exe);

    // Default step
    const run_step = b.step("run", "Run the busybox executable");
    run_step.dependOn(&b.addRunArtifact(exe).step);
}
