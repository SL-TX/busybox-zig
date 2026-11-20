const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Kconfig-style applet flags (config.NAME gates registry entries).
    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the main executable
    const exe = b.addExecutable(.{
        .name = "busybox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add libbb_zig module
    const libbb_zig = b.addModule("libbb_zig", .{
        .root_source_file = b.path("src/libbb_zig/init.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add coreutils module
    const coreutils = b.addModule("coreutils", .{
        .root_source_file = b.path("src/coreutils/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    coreutils.addImport("libbb_zig", libbb_zig);
    exe.root_module.addImport("coreutils", coreutils);
    exe.root_module.addImport("config", config_mod);

    // Add util-linux module
    const util_linux = b.addModule("util_linux", .{
        .root_source_file = b.path("src/util-linux/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    util_linux.addImport("libbb_zig", libbb_zig);
    exe.root_module.addImport("util_linux", util_linux);

    // Add networking module
    const networking = b.addModule("networking", .{
        .root_source_file = b.path("src/networking/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    networking.addImport("libbb_zig", libbb_zig);
    exe.root_module.addImport("networking", networking);

    // Add miscutils module
    const miscutils = b.addModule("miscutils", .{
        .root_source_file = b.path("src/miscutils/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    miscutils.addImport("libbb_zig", libbb_zig);
    exe.root_module.addImport("miscutils", miscutils);

    // Add procps module
    const procps = b.addModule("procps", .{
        .root_source_file = b.path("src/procps/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("procps", procps);

    // Add shell module
    const shell = b.addModule("shell", .{
        .root_source_file = b.path("src/shell/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("shell", shell);

    // Add loginutils module
    const loginutils = b.addModule("loginutils", .{
        .root_source_file = b.path("src/loginutils/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    loginutils.addImport("libbb_zig", libbb_zig);
    exe.root_module.addImport("loginutils", loginutils);

    // Small applets from the remaining categories that are in the registry.
    const remaining = b.addModule("remaining", .{
        .root_source_file = b.path("src/remaining/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("remaining", remaining);

    // Link libbb_zig to exe
    exe.root_module.addImport("libbb_zig", libbb_zig);

    // Install target
    b.installArtifact(exe);

    // Default step
    const run_step = b.step("run", "Run the busybox executable");
    run_step.dependOn(&b.addRunArtifact(exe).step);

    // Test harness — wires the same modules as the executable.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("coreutils", coreutils);
    test_module.addImport("config", config_mod);
    test_module.addImport("util_linux", util_linux);
    test_module.addImport("networking", networking);
    test_module.addImport("miscutils", miscutils);
    test_module.addImport("procps", procps);
    test_module.addImport("shell", shell);
    loginutils.addImport("libbb_zig", libbb_zig);
    test_module.addImport("loginutils", loginutils);
    test_module.addImport("libbb_zig", libbb_zig);
    test_module.addImport("remaining", remaining);
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
