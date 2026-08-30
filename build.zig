const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zooi_mod = b.addModule("zooi", .{
        .root_source_file = b.path("src/zooi.zig"),
    });

    const test_step = b.step("test", "Run library tests");

    // One test root per concern. Adding a module means adding a file here.
    const roots = [_][]const u8{
        "src/zooi_test.zig",
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
