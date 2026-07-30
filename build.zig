const std = @import("std");
const builtin = @import("builtin");

// The fuzz target names live beside the targets themselves so that the build
// graph, the corpus tool, and the targets cannot disagree about them.
const fuzz_targets = @import("test/fuzz/targets.zig");

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

    // Property-testing dependency, recorded in decision 0004. It is reachable
    // only from the Phaser-owned property harness, never from library code.
    const minish = b.dependency("minish", .{
        .target = target,
        .optimize = optimize,
    });

    const phaser_module = b.addModule("phaser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // On Windows the static library and the shared library's import library
    // would both be `phaser.lib`, and the second one installed silently
    // replaces the first -- leaving static linkage with no artifact at all. The
    // static library therefore carries a distinct name there. ELF and Mach-O
    // have no such collision (`libphaser.a` beside `libphaser.so`/`.dylib`), so
    // they keep the plain name. Recorded in Language and Interoperability
    // section 4.
    const windows_target = target.result.os.tag == .windows;
    const static_library_name = if (windows_target) "phaser_static" else "phaser";

    // The distributed library products are built position-independent, which
    // the tests and CLI do not need and so do not pay for.
    //
    // A shared library requires it. So, in practice, does the static one: every
    // current mainstream Linux distribution defaults its compiler to `-pie`, so
    // an ordinary `cc client.c libphaser.a` against a non-PIC archive fails to
    // link with "relocation R_X86_64_32S ... can not be used when making a PIE
    // object". Building the archive PIC is what makes static linkage work for a
    // consumer who has not been told to pass `-no-pie`.
    //
    // They are also stripped, which removes Zig's stack-trace symbolizer along
    // with the debug info it reads.
    //
    // That machinery has no consumer here. A C caller cannot act on a Zig stack
    // trace, and the interoperability specification requires that no Zig panic
    // cross the boundary at all. What it does have is cost: it roughly triples
    // the archive, and on Windows it reaches for `LdrRegisterDllNotification`,
    // which ntdll exports at runtime but the Windows SDK import library does
    // not, so a consumer's static link fails on a symbol belonging to a feature
    // they cannot use. Safety checks are unaffected -- ReleaseSafe still traps;
    // it simply does not symbolize.
    const library_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .strip = true,
    });

    const library = b.addLibrary(.{
        .name = static_library_name,
        .root_module = library_module,
        .linkage = .static,
    });
    // A distributed static library is linked by the consumer's toolchain, not
    // by Zig, so it has to carry the compiler-support routines Zig's own link
    // step would otherwise supply. Without this the archive references symbols
    // such as `__zig_probe_stack` and defines none of them, and a link with the
    // platform linker fails on undefined references that mention Zig internals
    // the consumer has never heard of.
    library.bundle_compiler_rt = true;
    b.installArtifact(library);

    // Both linkage modes are supported and both are tested, per decision 0014:
    // the same header and behavioral contract apply to each, and an untested
    // linkage mode is an unsupported one.
    const shared_library = b.addLibrary(.{
        .name = "phaser",
        .root_module = library_module,
        .linkage = .dynamic,
    });
    b.installArtifact(shared_library);

    // The authoritative public header. It is hand-written and reviewed as
    // source rather than generated; installing it is a copy, not a build step
    // that could disagree with the reviewed file.
    b.installFile("include/phaser.h", "include/phaser.h");

    // The Python extension, per decision 0015 and Language and
    // Interoperability section 8.
    //
    // Opt-in through `-Dpython=<interpreter>`. Without it nothing here is
    // configured, so a contributor with no Python 3.11 or later builds, tests,
    // and fuzzes everything else exactly as before. That is the boundary
    // decision 0015 promised: declining the dependency costs nothing but the
    // binding itself.
    const python_interpreter = b.option(
        []const u8,
        "python",
        "Python 3.11+ interpreter used to build and test the extension",
    );
    if (python_interpreter) |interpreter| {
        configurePythonExtension(
            b,
            target,
            optimize,
            library,
            shared_library.out_filename,
            interpreter,
        );
    }

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
    const scalar_oracle_fixture_module = b.createModule(.{
        .root_source_file = b.path(
            "test/fixtures/reference/scalar_one_loop/data.zig",
        ),
        .target = target,
        .optimize = optimize,
    });
    const conformance_fixture_data_module = b.createModule(.{
        .root_source_file = b.path("test/fixtures/conformance/data.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executable mirror of `docs/architecture/NUMERICAL_COMPARISON.md`. Test
    // tiers name a policy from it instead of carrying separately editable
    // tolerance literals, so it is imported by every tier that compares
    // approximate numbers. It depends on nothing, including Phaser itself.
    const numerical_comparison_module = b.createModule(.{
        .root_source_file = b.path("test/support/numerical_comparison.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Whether the test tiers' allocator captures an allocation backtrace, per
    // decision 0011. On by default, because that is what a person debugging a
    // leak needs. The mutation oracle turns it off in `zentinel.toml`: it re-runs
    // this suite once per mutant and reads no leak report, so it was paying for
    // backtraces nothing consumes. See `test/support/allocator.zig`.
    const capture_traces = b.option(
        bool,
        "test-allocation-traces",
        "Capture allocation backtraces in the test tiers (default true)",
    ) orelse true;
    const test_allocator_config = b.addOptions();
    test_allocator_config.addOption(bool, "capture_traces", capture_traces);

    const test_allocator_module = b.createModule(.{
        .root_source_file = b.path("test/support/allocator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = test_allocator_config.createModule() },
        },
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
            .{
                .name = "scalar_oracle_fixture",
                .module = scalar_oracle_fixture_module,
            },
            .{
                .name = "conformance_fixture_data",
                .module = conformance_fixture_data_module,
            },
            .{
                .name = "numerical_comparison",
                .module = numerical_comparison_module,
            },
            .{
                .name = "test_allocator",
                .module = test_allocator_module,
            },
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
            .{
                .name = "scalar_oracle_fixture",
                .module = scalar_oracle_fixture_module,
            },
            .{
                .name = "conformance_fixture_data",
                .module = conformance_fixture_data_module,
            },
            .{
                .name = "test_allocator",
                .module = test_allocator_module,
            },
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
            .{
                .name = "scalar_oracle_fixture",
                .module = scalar_oracle_fixture_module,
            },
            .{
                .name = "conformance_fixture_data",
                .module = conformance_fixture_data_module,
            },
            .{
                .name = "numerical_comparison",
                .module = numerical_comparison_module,
            },
            .{
                .name = "test_allocator",
                .module = test_allocator_module,
            },
        },
    });
    const conformance_tests = b.addTest(.{ .root_module = conformance_module });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    const test_conformance_step = b.step(
        "test-conformance",
        "Run language-neutral scientific conformance tests",
    );
    test_conformance_step.dependOn(&run_conformance_tests.step);

    const reference_module = b.createModule(.{
        .root_source_file = b.path("test/reference/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "numerical_comparison",
                .module = numerical_comparison_module,
            },
        },
    });
    const reference_tests = b.addTest(.{ .root_module = reference_module });
    const run_reference_tests = b.addRunArtifact(reference_tests);
    const test_reference_step = b.step(
        "test-reference",
        "Run independent test-only reference implementations",
    );
    test_reference_step.dependOn(&run_reference_tests.step);

    const property_module = b.createModule(.{
        .root_source_file = b.path("test/property/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "example_data", .module = example_data_module },
            .{ .name = "minish", .module = minish.module("minish") },
            .{
                .name = "numerical_comparison",
                .module = numerical_comparison_module,
            },
        },
    });
    const property_tests = b.addTest(.{ .root_module = property_module });
    const run_property_tests = b.addRunArtifact(property_tests);

    const property_campaign_module = b.createModule(.{
        .root_source_file = b.path("test/property/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "example_data", .module = example_data_module },
            .{ .name = "minish", .module = minish.module("minish") },
            .{
                .name = "numerical_comparison",
                .module = numerical_comparison_module,
            },
        },
    });
    const property_campaign = b.addExecutable(.{
        .name = "phaser-property",
        .root_module = property_campaign_module,
    });
    const run_property_campaign = b.addRunArtifact(property_campaign);
    if (b.args) |args| run_property_campaign.addArgs(args);

    const test_property_step = b.step(
        "test-property",
        "Run bounded property tests",
    );
    test_property_step.dependOn(&run_property_tests.step);
    test_property_step.dependOn(&run_property_campaign.step);

    const differential_module = b.createModule(.{
        .root_source_file = b.path("test/differential/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phaser", .module = phaser_module },
            .{ .name = "example_data", .module = example_data_module },
            .{
                .name = "numerical_comparison",
                .module = numerical_comparison_module,
            },
            .{
                .name = "test_allocator",
                .module = test_allocator_module,
            },
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

    const test_core_step = b.step(
        "test-core",
        "Run deterministic tests without specialized campaigns",
    );
    test_core_step.dependOn(&run_unit_tests.step);
    test_core_step.dependOn(&run_suite_tests.step);
    test_core_step.dependOn(&run_fuzz_tests.step);

    const test_step = b.step("test", "Run all bounded tests");
    test_step.dependOn(test_core_step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_reference_tests.step);
    test_step.dependOn(&run_differential_tests.step);
    test_step.dependOn(&run_property_tests.step);
    test_step.dependOn(&run_property_campaign.step);

    // The oracle the mutation campaign runs against every mutant, per decision
    // 0005. It is `test` without randomized campaigns, so it names the
    // deterministic tiers directly rather than depending on `test-core`, which
    // bundles fuzz replay in.
    //
    // Fuzzing is left out for two reasons. Seed replay would add another test
    // binary to every mutant's cold-cache compile, and each mutant already pays
    // for a full rebuild. And a mutant killed only by a corpus entry says less
    // about the deterministic suite than the same mutant surviving it. The step
    // stays a strict subset of `test`, so a mutation kill can never depend on a
    // check the pull-request suite does not also run. The property harness tests
    // remain, but the randomized property campaign does not: a mutant must not
    // be killed or survive because Minish happened to choose a different seed.
    const test_mutation_step = b.step(
        "test-mutation",
        "Deterministic oracle used by the mutation campaign",
    );
    test_mutation_step.dependOn(&run_unit_tests.step);
    test_mutation_step.dependOn(&run_suite_tests.step);
    test_mutation_step.dependOn(&run_cli_tests.step);
    test_mutation_step.dependOn(&run_reference_tests.step);
    test_mutation_step.dependOn(&run_differential_tests.step);
    test_mutation_step.dependOn(&run_property_tests.step);

    const fuzz_step = b.step("fuzz", "Replay every fuzz target or run with --fuzz=N");
    for (fuzz_targets.names) |target_name| {
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
    // A module retains its own optimization mode when imported. The benchmark
    // therefore needs benchmark-specific Phaser and fixture modules: importing
    // the ordinary modules above would silently benchmark their default Debug
    // implementations inside an optimized driver.
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization mode for benchmarks (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;
    const bench_extended = b.option(
        bool,
        "bench-extended",
        "Include cache-crossing benchmark batches (default: false)",
    ) orelse false;
    const bench_cycles_per_ns = b.option(
        f64,
        "bench-cycles-per-ns",
        "Optional measured CPU cycles per nanosecond for a derived column",
    ) orelse 0;
    const bench_options = b.addOptions();
    bench_options.addOption(bool, "extended", bench_extended);
    bench_options.addOption(f64, "cycles_per_ns", bench_cycles_per_ns);

    const bench_phaser_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const bench_numerics_module = b.createModule(.{
        .root_source_file = b.path("src/bench_numerics_root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const bench_example_data_module = b.createModule(.{
        .root_source_file = b.path("examples/data.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const bench_module = b.createModule(.{
        .root_source_file = b.path("tools/bench/main.zig"),
        .target = target,
        // ReleaseSafe is Phaser's production mode. An explicit override keeps
        // diagnostic ReleaseFast and Debug measurements available without
        // making either the benchmark's undocumented default.
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "phaser", .module = bench_phaser_module },
            .{ .name = "bench_options", .module = bench_options.createModule() },
            .{ .name = "example_data", .module = bench_example_data_module },
            .{ .name = "numerical_comparison", .module = numerical_comparison_module },
            // The dense three-by-three one-loop workload needs a model with
            // three real scalars. The conformance fixture already carries one
            // whose spectrum is exact, so the benchmark reads it rather than
            // keeping a second copy that could drift from it.
            .{
                .name = "scalar_oracle_fixture",
                .module = scalar_oracle_fixture_module,
            },
        },
    });
    const bench = b.addExecutable(.{
        .name = "phaser-bench",
        .root_module = bench_module,
    });
    bench.root_module.addCSourceFile(.{
        .file = b.path("tools/bench/direct.c"),
        .flags = &.{
            "-std=c17",
            "-O3",
            "-fno-fast-math",
            "-ffp-contract=off",
        },
    });
    bench_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        bench_module.linkSystemLibrary("m", .{ .use_pkg_config = .no });
    }
    const bench_leaves_module = b.createModule(.{
        .root_source_file = b.path("tools/bench/leaves.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "bench_numerics", .module = bench_numerics_module },
        },
    });
    const bench_leaves = b.addExecutable(.{
        .name = "phaser-bench-leaves",
        .root_module = bench_leaves_module,
    });
    const bench_tests = b.addTest(.{ .root_module = bench_module });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    const bench_leaves_tests = b.addTest(.{ .root_module = bench_leaves_module });
    const run_bench_leaves_tests = b.addRunArtifact(bench_leaves_tests);
    const test_bench_step = b.step(
        "test-bench",
        "Run benchmark-driver unit tests",
    );
    test_bench_step.dependOn(&run_bench_tests.step);
    test_bench_step.dependOn(&run_bench_leaves_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_bench_leaves_tests.step);

    const run_bench = b.addRunArtifact(bench);
    const run_bench_leaves = b.addRunArtifact(bench_leaves);
    run_bench_leaves.step.dependOn(&run_bench.step);
    const bench_step = b.step(
        "bench",
        "Run representative performance measurements (informational)",
    );
    bench_step.dependOn(&run_bench_leaves.step);

    // Corpus maintenance reads the local build cache and the committed corpus,
    // so it runs from the source directory and takes its arguments after `--`.
    const corpus_module = b.createModule(.{
        .root_source_file = b.path("tools/corpus/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "fuzz_targets",
                .module = b.createModule(.{
                    .root_source_file = b.path("test/fuzz/targets.zig"),
                }),
            },
        },
    });
    const corpus = b.addExecutable(.{
        .name = "phaser-corpus",
        .root_module = corpus_module,
    });
    const run_corpus = b.addRunArtifact(corpus);
    run_corpus.setCwd(b.path("."));
    // It reads the cache and writes staged candidates, so it is never cacheable.
    run_corpus.has_side_effects = true;
    if (b.args) |args| run_corpus.addArgs(args);
    const corpus_step = b.step(
        "corpus",
        "Inspect and stage generated fuzz corpus entries (list | stage)",
    );
    corpus_step.dependOn(&run_corpus.step);

    // Mutation testing, recorded in decision 0005. Zentinel is a standalone
    // client rather than a library: it copies the project into a per-worker
    // workspace, edits one operator in one source file, and re-runs the oracle
    // command from `zentinel.toml`. Building it from the pinned dependency
    // rather than from whatever a runner has installed keeps the tool itself
    // reproducible from the lockfile.
    //
    // The dependency is lazy, so `zig build`, `zig build test`, and every
    // pull-request job resolve nothing here. Only this step fetches it, and
    // only when it is the step that was asked for.
    const mutation_step = b.step(
        "mutation",
        "Run the mutation campaign (`-- run --changed-only`, `-- list-mutants`, ...)",
    );
    if (b.lazyDependency("zentinel", .{
        .target = target,
        // The tool is not the thing under test, and every mutant pays for its
        // speed, so it is built optimized regardless of the selected mode.
        .optimize = .ReleaseSafe,
    })) |zentinel| {
        const run_zentinel = b.addRunArtifact(zentinel.artifact("zentinel"));
        // It reads the working tree and writes reports and mutant workspaces,
        // so it runs from the source directory and is never cacheable.
        run_zentinel.setCwd(b.path("."));
        run_zentinel.has_side_effects = true;
        // A campaign is long enough that its progress must reach the terminal.
        run_zentinel.stdio = .inherit;
        if (b.args) |args| {
            run_zentinel.addArgs(args);
        } else {
            // Survivors are reported, not failed on: a surviving mutant is
            // evidence to read, and this experiment has agreed no threshold
            // yet. See decision 0005.
            run_zentinel.addArgs(&.{ "run", "--report", "text" });
        }
        mutation_step.dependOn(&run_zentinel.step);
    }

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

    // The order-one phi4 workflow the Milestone 4 plotting client consumes:
    // one export plus the three separately selected scans over the same grid.
    const one_loop_export = b.addRunArtifact(cli);
    one_loop_export.addArg("export");
    one_loop_export.addFileArg(b.path("examples/phi4/model.json"));
    one_loop_export.addFileArg(b.path("examples/phi4/request_one_loop.json"));
    one_loop_export.addArg("--target=latex");
    examples_step.dependOn(&one_loop_export.step);

    for ([_][]const u8{ "loop:0", "loop:1", "total" }) |selection| {
        const run_scan = b.addRunArtifact(cli);
        run_scan.addArg("evaluate");
        run_scan.addFileArg(b.path("examples/phi4/model.json"));
        run_scan.addFileArg(b.path("examples/phi4/request_one_loop.json"));
        run_scan.addFileArg(b.path("examples/phi4/point.json"));
        run_scan.addArg("--outputs=gradient");
        run_scan.addArg("--format=tsv");
        run_scan.addArg(b.fmt("--selection={s}", .{selection}));
        run_scan.addArg("--scan=0:0:600:13");
        examples_step.dependOn(&run_scan.step);
    }
}

/// Configures the Python extension and its test step.
///
/// The interpreter is asked for its own extension suffix, and on Windows for
/// the directory holding the Stable ABI stub, rather than either being
/// guessed. That keeps the build correct across the interpreters the runner
/// images ship and across a contributor's virtual environment.
///
/// Python's headers are not needed: the extension declares the Limited API
/// subset it uses rather than translating Python.h.
///
/// The interpreter must run on the target being built for. Everything here is
/// derived from the interpreter that is invoked, so cross-compiling the
/// extension would take the include path and the file-name suffix from the
/// host and produce a module named for the wrong platform. That is not a
/// supported configuration; each platform builds its own.
fn configurePythonExtension(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Step.Compile,
    shared_library_file: []const u8,
    interpreter: []const u8,
) void {
    const extension_module = b.createModule(.{
        .root_source_file = b.path("bindings/python/src/extension.zig"),
        .target = target,
        .optimize = optimize,
        // The extension is loaded into a process it does not control, so it is
        // position-independent for the same reason the shared library is.
        .pic = true,
    });
    extension_module.link_libc = true;

    const extension = b.addLibrary(.{
        .name = "_phaser",
        .root_module = extension_module,
        .linkage = .dynamic,
    });
    // The Phaser core is linked in statically, so the built module is
    // self-contained and needs no rpath or co-installed shared library.
    extension_module.linkLibrary(library);

    // A CPython extension leaves the interpreter's own symbols undefined and
    // has them resolved at load time by the process that imports it. Windows
    // cannot do that and links the Stable ABI stub instead.
    //
    // `python3.lib` is the stub for the Limited API, as distinct from
    // `python3X.lib`, which pins one minor version and would defeat the point
    // of building against a stable ABI. It sits in `libs/` beside the
    // interpreter's installation, which is asked for rather than assumed --
    // a virtual environment reports the base installation's path, which is
    // where the import libraries actually live.
    if (target.result.os.tag == .windows) {
        const libs_directory = std.mem.trim(u8, b.run(&.{
            interpreter,
            "-c",
            "import os, sys; print(os.path.join(sys.base_prefix, 'libs'))",
        }), " \r\n");
        extension_module.addLibraryPath(.{ .cwd_relative = libs_directory });
        extension_module.linkSystemLibrary("python3", .{});
    } else {
        extension.linker_allow_shlib_undefined = true;
    }

    // Python requires the file name to be the module name plus the
    // interpreter's suffix, so the artifact is installed under that name
    // rather than the platform's ordinary library name.
    const suffix = std.mem.trim(u8, b.run(&.{
        interpreter,
        "-c",
        "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))",
    }), " \r\n");
    const module_name = b.fmt("_phaser{s}", .{suffix});

    const install_extension = b.addInstallFileWithDir(
        extension.getEmittedBin(),
        .{ .custom = "python/phaser" },
        module_name,
    );

    const install_package = b.addInstallFileWithDir(
        b.path("bindings/python/src/phaser/__init__.py"),
        .{ .custom = "python/phaser" },
        "__init__.py",
    );

    const python_step = b.step("python", "Build the Python extension");
    python_step.dependOn(&install_extension.step);
    python_step.dependOn(&install_package.step);

    const test_python_step = b.step(
        "test-python",
        "Run the Python binding tests",
    );

    // Both suites are exercised by an ordinary Python program, because that is
    // the only way to check what an importing interpreter actually sees.
    //
    // The ctypes suite additionally needs the shared library, since that is
    // what it loads: it is an independent consumer of the ABI rather than a
    // second view of the extension, and loading the same artifact a C client
    // would is the whole point of keeping it.
    const python_suites = [_][]const u8{
        "bindings/python/test/test_extension.py",
        "bindings/python/test/test_ctypes_abi.py",
    };
    for (python_suites) |suite| {
        const run_suite = b.addSystemCommand(&.{ interpreter, suite });
        run_suite.setEnvironmentVariable(
            "PYTHONPATH",
            b.getInstallPath(.{ .custom = "python" }, ""),
        );
        // Windows installs a DLL beside the executables and leaves only its
        // import library in lib/, so the artifact the ctypes client loads is
        // not in the same place on every platform.
        const shared_directory: std.Build.InstallDir =
            if (target.result.os.tag == .windows) .bin else .lib;
        run_suite.setEnvironmentVariable(
            "PHASER_SHARED_LIBRARY",
            b.getInstallPath(shared_directory, shared_library_file),
        );
        // The committed example inputs and their golden command-line output.
        // Comparing against those files is how the binding's numbers are
        // checked against the same values the CLI and the C ABI are checked
        // against, rather than against a second copy of them.
        run_suite.setEnvironmentVariable(
            "PHASER_EXAMPLES",
            b.pathFromRoot("examples"),
        );
        run_suite.step.dependOn(python_step);
        run_suite.step.dependOn(b.getInstallStep());
        // Nothing is cached: the check is that this interpreter can import and
        // drive what was just built.
        run_suite.has_side_effects = true;
        test_python_step.dependOn(&run_suite.step);
    }
}
