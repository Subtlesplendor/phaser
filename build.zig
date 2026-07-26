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

    const test_unit_step = b.step("test-unit", "Run colocated library unit tests");
    test_unit_step.dependOn(&run_unit_tests.step);

    const example_data_module = b.createModule(.{
        .root_source_file = b.path("examples/data.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_commands_module = b.createModule(.{
        .root_source_file = b.path("src/cli/commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
        },
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "commands", .module = cli_commands_module },
        },
    });
    const cli = b.addExecutable(.{
        .name = "phaser",
        .root_module = cli_module,
    });
    b.installArtifact(cli);

    const cli_tests = b.addTest(.{ .root_module = cli_commands_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const test_cli_step = b.step("test-cli", "Run command-line client tests");
    test_cli_step.dependOn(&run_cli_tests.step);

    const suite_module = b.createModule(.{
        .root_source_file = b.path("test/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "example_data", .module = example_data_module },
            .{ .name = "commands", .module = cli_commands_module },
        },
    });
    const suite_tests = b.addTest(.{
        .root_module = suite_module,
    });
    const run_suite_tests = b.addRunArtifact(suite_tests);

    const integration_module = b.createModule(.{
        .root_source_file = b.path("test/integration/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "example_data", .module = example_data_module },
            .{ .name = "commands", .module = cli_commands_module },
        },
    });
    const integration_tests = b.addTest(.{ .root_module = integration_module });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const test_integration_step = b.step(
        "test-integration",
        "Run model and public-interface integration tests",
    );
    test_integration_step.dependOn(&run_integration_tests.step);

    const conformance_module = b.createModule(.{
        .root_source_file = b.path("test/conformance/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "example_data", .module = example_data_module },
        },
    });
    const conformance_tests = b.addTest(.{ .root_module = conformance_module });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    const test_conformance_step = b.step(
        "test-conformance",
        "Run language-neutral scientific conformance tests",
    );
    test_conformance_step.dependOn(&run_conformance_tests.step);

    const differential_module = b.createModule(.{
        .root_source_file = b.path("test/differential/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "example_data", .module = example_data_module },
        },
    });
    const differential_tests = b.addTest(.{ .root_module = differential_module });
    const run_differential_tests = b.addRunArtifact(differential_tests);
    const test_differential_step = b.step(
        "test-differential",
        "Compare independent implementations of the same quantity",
    );
    test_differential_step.dependOn(&run_differential_tests.step);

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
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_differential_tests.step);

    const fuzz_step = b.step("fuzz", "Replay every fuzz target or run with --fuzz=N");
    const fuzz_target_names = [_][]const u8{
        "foundation_capacity",
        "expression_parser",
        "scalar_model_parser",
        "value_ir_builder",
        "calculation_request_parser",
        "symbolic_exporter",
        "kernel_lowering",
        "parameter_point_parser",
    };
    for (fuzz_target_names) |target_name| {
        const filtered_tests = b.addTest(.{
            .root_module = fuzz_module,
            .filters = &.{target_name},
        });
        const run_filtered_tests = b.addRunArtifact(filtered_tests);
        fuzz_step.dependOn(&run_filtered_tests.step);
    }

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/model_inspection.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
        },
    });
    const model_inspection = b.addExecutable(.{
        .name = "phaser-model-inspection",
        .root_module = example_module,
    });
    const run_model_inspection = b.addRunArtifact(model_inspection);
    const bench_module = b.createModule(.{
        .root_source_file = b.path("tools/bench/main.zig"),
        .target = target,
        // Benchmarks measure optimized code unless told otherwise.
        .optimize = if (b.option(
            bool,
            "bench-debug",
            "Build benchmarks in the selected optimize mode instead of ReleaseFast",
        ) orelse false) optimize else .ReleaseFast,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "example_data", .module = example_data_module },
        },
    });
    const bench = b.addExecutable(.{
        .name = "phaser-bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step(
        "bench",
        "Run representative performance measurements (informational)",
    );
    bench_step.dependOn(&run_bench.step);

    const examples_step = b.step("examples", "Run public example workflows");
    examples_step.dependOn(&run_model_inspection.step);

    // Drive the installed client over the committed example inputs, so the
    // executable itself cannot silently decay.
    for ([_][]const u8{ "phi4", "multi_scalar" }) |name| {
        const run_export = b.addRunArtifact(cli);
        run_export.addArg("export");
        run_export.addFileArg(b.path(b.fmt("examples/{s}/model.json", .{name})));
        run_export.addFileArg(b.path(b.fmt("examples/{s}/request.json", .{name})));
        run_export.addArg("--target=latex");
        examples_step.dependOn(&run_export.step);

        const run_evaluate = b.addRunArtifact(cli);
        run_evaluate.addArg("evaluate");
        run_evaluate.addFileArg(b.path(b.fmt("examples/{s}/model.json", .{name})));
        run_evaluate.addFileArg(b.path(b.fmt("examples/{s}/request.json", .{name})));
        run_evaluate.addFileArg(b.path(b.fmt("examples/{s}/point.json", .{name})));
        run_evaluate.addArg("--outputs=gradient");
        run_evaluate.addArg("--scan=0:0:600:13");
        examples_step.dependOn(&run_evaluate.step);
    }
}
