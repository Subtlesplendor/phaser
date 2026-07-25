const std = @import("std");
const builtin = @import("builtin");

const required_zig_version = std.SemanticVersion{
    .major = 0,
    .minor = 16,
    .patch = 0,
};

pub fn build(b: *std.Build) void {
    comptime {
        if (builtin.zig_version.order(required_zig_version) != .eq) {
            @compileError("Phaser requires exactly Zig 0.16.0; see .zigversion");
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const phaser_module = b.addModule("phaser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "phaser",
        .root_module = phaser_module,
        .linkage = .static,
    });
    b.installArtifact(library);

    const unit_tests = b.addTest(.{
        .root_module = phaser_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_unit_step = b.step("test-unit", "Run colocated foundation unit tests");
    test_unit_step.dependOn(&run_unit_tests.step);

    const suite_module = b.createModule(.{
        .root_source_file = b.path("test/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
        },
    });
    const suite_tests = b.addTest(.{
        .root_module = suite_module,
    });
    const run_suite_tests = b.addRunArtifact(suite_tests);

    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("test/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
        },
    });
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_module,
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    const test_step = b.step("test", "Run all bounded deterministic tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_suite_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);

    const fuzz_step = b.step("fuzz", "Replay seeds or run with --fuzz=N");
    fuzz_step.dependOn(&run_fuzz_tests.step);
}
