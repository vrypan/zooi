const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zooi_mod = b.addModule("zooi", .{
        .root_source_file = b.path("src/zooi.zig"),
    });

    const example = b.addExecutable(.{
        .name = "zooi-browser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/browser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("zooi", zooi_mod);
    b.installArtifact(example);

    const run_step = b.step("run", "Run the example browser");
    run_step.dependOn(&b.addRunArtifact(example).step);

    const test_step = b.step("test", "Run library tests");

    // Keep the copyable consumer example compiling against the public module.
    const minimal = b.addExecutable(.{
        .name = "zooi-minimal-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/minimal/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    minimal.root_module.addImport("zooi", zooi_mod);
    test_step.dependOn(&minimal.step);

    // One test root per concern. Adding a module means adding a file here.
    const roots = [_][]const u8{
        "src/zooi_test.zig",
        "src/width_test.zig",
        "src/input_test.zig",
        "src/screen_test.zig",
        "src/terminal_test.zig",
        "src/event_test.zig",
        "examples/browser_test.zig",
    };
    for (roots) |root| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("zooi", zooi_mod);

        const tests = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
