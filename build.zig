const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .Debug,
    });
    
    const exe = b.addExecutable(.{
        .name = "wijic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    
    b.installArtifact(exe);
    
    const test_exe = b.addExecutable(.{
        .name = "wijic-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    
    b.installArtifact(test_exe);
    
    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    
    const run_test_exe = b.addRunArtifact(test_exe);
    run_test_exe.addArtifactArg(exe);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
    
    const run_exe_step = b.step("test", "Run the test");
    run_exe_step.dependOn(&run_test_exe.step);
}