const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zunic = b.dependency("zunic", .{});

    const zooi_mod = b.addModule("zooi", .{
        .root_source_file = b.path("src/zooi.zig"),
    });
    zooi_mod.addImport("zunic", zunic.module("zunic"));

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

    const wrapped_example = b.addExecutable(.{
        .name = "zooi-wrapped-list",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/wrapped_list.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wrapped_example.root_module.addImport("zooi", zooi_mod);
    b.installArtifact(wrapped_example);

    const run_step = b.step("run", "Run the example browser");
    run_step.dependOn(&b.addRunArtifact(example).step);

    const run_wrapped_step = b.step("run-wrapped", "Run the wrapped-list example");
    run_wrapped_step.dependOn(&b.addRunArtifact(wrapped_example).step);

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
        "src/viewport_test.zig",
        "src/row_index_test.zig",
        "src/variable_viewport_test.zig",
        "src/wrap_test.zig",
        "src/unicode_test.zig",
        "src/unicode/root_test.zig",
        "src/unicode/conformance_test.zig",
        "src/testing_test.zig",
        "src/terminal_test.zig",
        "src/event_test.zig",
        "examples/browser_test.zig",
        "examples/wrapped_list_test.zig",
    };
    for (roots) |root| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("zooi", zooi_mod);
        test_mod.addImport("zunic", zunic.module("zunic"));

        const tests = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The PTY suite drives the example binary that would actually ship, so it
    // needs to be told where that binary is.
    const pty_options = b.addOptions();
    pty_options.addOptionPath("browser", example.getEmittedBin());

    // link_libc on this artifact only: posix_openpt and friends have no
    // raw-syscall spelling worth maintaining for a test. The library itself
    // must not gain a libc dependency, which the `portability` CI job proves.
    const pty_mod = b.createModule(.{
        .root_source_file = b.path("test/pty_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pty_mod.addOptions("build_options", pty_options);
    const pty_tests = b.addTest(.{ .root_module = pty_mod });

    // Wrapped in a plain command rather than run as a test artifact, so the
    // build runner cannot interleave it with anything: two tests racing for a
    // controlling terminal fail in ways that look like real bugs. Side effects
    // are declared so a cached pass never stands in for a run — a suite whose
    // repeat runs are free is a suite whose flakiness stays hidden.
    const run_pty = b.addSystemCommand(&.{"env"});
    run_pty.addArtifactArg(pty_tests);
    run_pty.has_side_effects = true;
    run_pty.step.dependOn(test_step);

    // The verifier drives the library's internals rather than its public
    // module: it is checking that the syscalls underneath work on this
    // machine, which the public API deliberately hides. Kept as a standalone
    // binary because its whole value is that a user on an unusual terminal can
    // run one static executable and paste the output.
    const verify = b.addExecutable(.{
        .name = "zooi-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/verify.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // One module, because Zig gives each file to exactly one module and
    // terminal.zig already imports sys.zig.
    verify.root_module.addImport("zooi_internal", b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
    }));

    const verify_step = b.step("verify", "Build the standalone runtime verifier");
    verify_step.dependOn(&b.addInstallArtifact(verify, .{}).step);

    const pty_step = b.step("test-pty", "Run the PTY suite on its own");
    pty_step.dependOn(&run_pty.step);

    const all_step = b.step("test-all", "Run every test, PTY suite included");
    all_step.dependOn(&run_pty.step);
}
