//! Representative performance measurements for Phaser's numerical lifecycle.
//!
//! Required by the milestone gate in `docs/architecture/IMPLEMENTATION_ROADMAP.md`
//! §2. Per `DEVELOPMENT_WORKFLOW.md` §11 these measurements are informational on
//! a hosted runner, they are not a merge gate, and outputs are verified before
//! anything is timed.
//!
//! Every reported runtime measurement is calibrated to a minimum wall-clock
//! duration, sampled repeatedly, and summarized by its median and range. The
//! direct C functions are independent, hand-transcribed numerical expressions
//! compiled by the pinned Zig toolchain; they do not consume Phaser's value
//! graph or lowered instruction program.

const std = @import("std");
const phaser = @import("phaser");
const example_data = @import("example_data");
const oracle_fixture = @import("scalar_oracle_fixture");
const numerical_comparison = @import("numerical_comparison");

const calculation = phaser.calculation;
const kernel_module = phaser.kernel;
const Scalar = kernel_module.Scalar;
const Complex64 = kernel_module.Complex64;

const batch_sizes = [_]usize{ 1, 8, 64, 1024 };
const measurement_sample_count = 7;
const minimum_sample_ns = 50_000_000;

comptime {
    if (measurement_sample_count < 3 or measurement_sample_count % 2 == 0) {
        @compileError("benchmark sampling requires an odd count of at least three");
    }
}

extern fn phaser_bench_phi4_value(
    parameters: [*]const Scalar,
    background: [*]const Scalar,
) Scalar;

extern fn phaser_bench_multi_scalar_value(
    parameters: [*]const Scalar,
    background: [*]const Scalar,
) Scalar;

extern fn phaser_bench_phi4_value_batch(
    parameters: [*]const Scalar,
    backgrounds: [*]const Scalar,
    point_count: c_ulonglong,
    values: [*]Scalar,
) void;

extern fn phaser_bench_multi_scalar_value_batch(
    parameters: [*]const Scalar,
    backgrounds: [*]const Scalar,
    point_count: c_ulonglong,
    values: [*]Scalar,
) void;

extern fn phaser_bench_phi4_magnitude(
    parameters: [*]const Scalar,
    background: [*]const Scalar,
) Scalar;

extern fn phaser_bench_multi_scalar_magnitude(
    parameters: [*]const Scalar,
    background: [*]const Scalar,
) Scalar;

/// Elapsed-nanosecond timer over the monotonic-while-awake clock.
///
/// `std.time.Timer` does not exist in the pinned toolchain; timing goes through
/// the `Io` clock interface.
const Timer = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    fn begin(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Timestamp.now(io, .awake) };
    }

    fn read(self: *const Timer) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake);
        const elapsed = now.nanoseconds - self.start.nanoseconds;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }
};

const DirectKind = enum {
    phi4,
    multi_scalar,

    fn evaluate(
        self: DirectKind,
        parameters: [*]const Scalar,
        background: [*]const Scalar,
    ) Scalar {
        return switch (self) {
            .phi4 => phaser_bench_phi4_value(parameters, background),
            .multi_scalar => phaser_bench_multi_scalar_value(parameters, background),
        };
    }

    fn magnitude(
        self: DirectKind,
        parameters: [*]const Scalar,
        background: [*]const Scalar,
    ) Scalar {
        return switch (self) {
            .phi4 => phaser_bench_phi4_magnitude(parameters, background),
            .multi_scalar => phaser_bench_multi_scalar_magnitude(
                parameters,
                background,
            ),
        };
    }

    fn evaluateBatch(
        self: DirectKind,
        parameters: [*]const Scalar,
        backgrounds: [*]const Scalar,
        point_count: usize,
        values: [*]Scalar,
    ) void {
        const count: c_ulonglong = @intCast(point_count);
        switch (self) {
            .phi4 => phaser_bench_phi4_value_batch(
                parameters,
                backgrounds,
                count,
                values,
            ),
            .multi_scalar => phaser_bench_multi_scalar_value_batch(
                parameters,
                backgrounds,
                count,
                values,
            ),
        }
    }
};

const DirectBaseline = struct {
    kind: DirectKind,
    parameter_names: []const []const u8,

    fn verifyChannels(
        self: DirectBaseline,
        kernel: *const kernel_module.Kernel,
    ) !void {
        if (kernel.parameters.len != self.parameter_names.len) {
            return error.DirectParameterLayoutMismatch;
        }
        for (kernel.parameters, self.parameter_names) |channel, expected| {
            if (!std.mem.eql(u8, channel.name, expected)) {
                return error.DirectParameterLayoutMismatch;
            }
        }
    }
};

const phi4_direct = DirectBaseline{
    .kind = .phi4,
    .parameter_names = &.{ "lambda", "m2", "omega" },
};

const multi_scalar_direct = DirectBaseline{
    .kind = .multi_scalar,
    .parameter_names = &.{
        "a",
        "b",
        "c",
        "d",
        "l1",
        "l2",
        "l3",
        "lh",
        "ls",
        "m_h2",
        "m_hs2",
        "m_s2",
        "omega",
        "t_h",
        "t_s",
    },
};

const StagedRun = struct {
    binding: *const kernel_module.Binding,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: kernel_module.OutputBuffers,

    fn unitCount(self: *const StagedRun) usize {
        return self.point_count;
    }

    fn execute(self: *const StagedRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            try self.binding.evaluate(
                self.backgrounds,
                self.point_count,
                self.workspace,
                self.outputs,
            );
        }
    }
};

const UnstagedRun = struct {
    kernel: *const kernel_module.Kernel,
    parameters: []const Scalar,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: kernel_module.OutputBuffers,

    fn unitCount(self: *const UnstagedRun) usize {
        return self.point_count;
    }

    fn execute(self: *const UnstagedRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            try self.kernel.evaluate(
                .{
                    .parameters = self.parameters,
                    .backgrounds = self.backgrounds,
                },
                self.point_count,
                self.workspace,
                self.outputs,
            );
        }
    }
};

/// The `Complex64` counterpart of `StagedRun`, for an order-one selection.
const ComplexStagedRun = struct {
    binding: *const kernel_module.Binding,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: kernel_module.ComplexOutputBuffers,

    fn unitCount(self: *const ComplexStagedRun) usize {
        return self.point_count;
    }

    fn execute(self: *const ComplexStagedRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            try self.binding.evaluateComplex(
                self.backgrounds,
                self.point_count,
                self.workspace,
                self.outputs,
            );
        }
    }
};

const DirectRun = struct {
    baseline: DirectBaseline,
    parameters: []const Scalar,
    backgrounds: []const Scalar,
    point_count: usize,
    coordinate_count: usize,
    sink: Scalar = 0,

    fn unitCount(self: *const DirectRun) usize {
        return self.point_count;
    }

    fn execute(self: *DirectRun, repetitions: usize) !void {
        std.debug.assert(
            self.backgrounds.len == self.point_count * self.coordinate_count,
        );
        for (0..repetitions) |_| {
            for (0..self.point_count) |point_index| {
                const background =
                    self.backgrounds.ptr + point_index * self.coordinate_count;
                self.sink = self.baseline.kind.evaluate(
                    self.parameters.ptr,
                    background,
                );
            }
        }
        std.mem.doNotOptimizeAway(self.sink);
    }
};

const DirectBatchRun = struct {
    baseline: DirectBaseline,
    parameters: []const Scalar,
    backgrounds: []const Scalar,
    point_count: usize,
    values: []Scalar,

    fn unitCount(self: *const DirectBatchRun) usize {
        return self.point_count;
    }

    fn execute(self: *const DirectBatchRun, repetitions: usize) !void {
        std.debug.assert(self.values.len == self.point_count);
        for (0..repetitions) |_| {
            self.baseline.kind.evaluateBatch(
                self.parameters.ptr,
                self.backgrounds.ptr,
                self.point_count,
                self.values.ptr,
            );
        }
        std.mem.doNotOptimizeAway(self.values);
    }
};

const DeriveRun = struct {
    allocator: std.mem.Allocator,
    model: *const phaser.Model,
    request: *const calculation.Request,

    fn unitCount(_: *const DeriveRun) usize {
        return 1;
    }

    fn execute(self: *const DeriveRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            var repeated = try derive(
                self.allocator,
                self.model,
                self.request,
                .gradient_hessian,
            );
            repeated.deinit();
        }
    }
};

const LowerRun = struct {
    allocator: std.mem.Allocator,
    artifact: *const calculation.Artifact,

    fn unitCount(_: *const LowerRun) usize {
        return 1;
    }

    fn execute(self: *const LowerRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            var repeated = try kernel_module.compile(
                self.allocator,
                self.artifact,
                .{ .capability = .value_gradient_hessian },
            );
            repeated.deinit();
        }
    }
};

const BindRun = struct {
    allocator: std.mem.Allocator,
    kernel: *const kernel_module.Kernel,
    model: *const phaser.Model,
    point: *const calculation.ParameterPoint,

    fn unitCount(_: *const BindRun) usize {
        return 1;
    }

    fn execute(self: *const BindRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            var repeated = try kernel_module.bind(
                self.allocator,
                self.kernel,
                self.model,
                self.point,
            );
            repeated.deinit();
        }
    }
};

const Measurement = struct {
    repetitions: usize,
    units_per_repetition: usize,
    median_picoseconds_per_unit: u64,
    minimum_picoseconds_per_unit: u64,
    maximum_picoseconds_per_unit: u64,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &file_writer.interface;

    try writePreamble(out);
    try reportGraphSizes(init.gpa, out);
    try reportModel(
        init.gpa,
        init.io,
        out,
        "phi4",
        example_data.phi4_model,
        example_data.phi4_request,
        example_data.phi4_point,
        phi4_direct,
    );
    try reportModel(
        init.gpa,
        init.io,
        out,
        "multi_scalar",
        example_data.multi_scalar_model,
        example_data.multi_scalar_request,
        example_data.multi_scalar_point,
        multi_scalar_direct,
    );
    for (one_loop_workloads) |workload| {
        try reportOneLoop(init.gpa, init.io, out, workload);
    }
    try out.flush();
}

fn writePreamble(out: *std.Io.Writer) !void {
    const builtin = @import("builtin");
    try out.writeAll("# phaser benchmarks\n");
    try out.print("# build_mode {s}\n", .{@tagName(builtin.mode)});
    try out.print(
        "# target {s}-{s}\n",
        .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
    );
    try out.print("# cpu_model {s}\n", .{builtin.cpu.model.name});
    try out.print("# zig {f}\n", .{builtin.zig_version});
    try out.print(
        "# samples {d}, minimum {d} ms/sample\n",
        .{ measurement_sample_count, minimum_sample_ns / 1_000_000 },
    );
    try out.writeAll(
        \\# direct_c flags: -O3 -fno-fast-math -ffp-contract=off
        \\#
        \\# Timings are informational. They are not a merge gate and a hosted
        \\# runner is too noisy for small differences to be meaningful.
        \\
    );
}

fn context(allocator: std.mem.Allocator) phaser.Context {
    return switch (phaser.Context.init(allocator, .{
        .max_diagnostics = 16,
        .max_related_locations = 32,
    })) {
        .context => |value| value,
        .failure => unreachable,
    };
}

fn loadModel(allocator: std.mem.Allocator, source: []const u8) !phaser.Model {
    return switch (try phaser.loadModel(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = source,
    }, .{})) {
        .model => |value| value,
        .diagnostics => error.InvalidModel,
    };
}

fn loadRequest(
    allocator: std.mem.Allocator,
    source: []const u8,
) !calculation.Request {
    return switch (try phaser.parseRequest(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(1),
        .bytes = source,
    }, .{})) {
        .request => |value| value,
        .diagnostics => error.InvalidRequest,
    };
}

fn derive(
    allocator: std.mem.Allocator,
    model: *const phaser.Model,
    request: *const calculation.Request,
    derivatives: calculation.Derivatives,
) !calculation.Artifact {
    return switch (try phaser.deriveEffectivePotential(
        context(allocator),
        model,
        request,
        .{ .derivatives = derivatives },
    )) {
        .artifact => |value| value,
        .diagnostics => error.DerivationFailed,
    };
}

/// Derivative-graph growth, which decision 0003 records as the measurement its
/// revisit trigger depends on.
fn reportGraphSizes(allocator: std.mem.Allocator, out: *std.Io.Writer) !void {
    try out.writeAll("\n## derivative graph growth\n");
    try out.writeAll("model\tcoordinates\tvalue_only\tplus_gradient\tplus_hessian\n");

    for ([_]struct {
        name: []const u8,
        model_source: []const u8,
        request_source: []const u8,
    }{
        .{
            .name = "phi4",
            .model_source = example_data.phi4_model,
            .request_source = example_data.phi4_request,
        },
        .{
            .name = "multi_scalar",
            .model_source = example_data.multi_scalar_model,
            .request_source = example_data.multi_scalar_request,
        },
    }) |entry| {
        var model = try loadModel(allocator, entry.model_source);
        defer model.deinit();
        var request = try loadRequest(allocator, entry.request_source);
        defer request.deinit();

        var counts: [3]usize = undefined;
        for ([_]calculation.Derivatives{
            .none,
            .gradient,
            .gradient_hessian,
        }, 0..) |kind, index| {
            var artifact = try derive(allocator, &model, &request, kind);
            defer artifact.deinit();
            counts[index] = artifact.graph.values.len;
        }
        var artifact = try derive(allocator, &model, &request, .none);
        defer artifact.deinit();
        try out.print(
            "{s}\t{d}\t{d}\t{d}\t{d}\n",
            .{
                entry.name,
                artifact.coordinateCount(),
                counts[0],
                counts[1],
                counts[2],
            },
        );
    }
    try out.writeAll(
        \\#
        \\# Decision 0003 predicts growth proportional to graph size per
        \\# directional derivative, so plus_gradient minus value_only should scale
        \\# with the coordinate count rather than explode.
        \\
    );
}

fn reportModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    model_source: []const u8,
    request_source: []const u8,
    point_source: []const u8,
    direct: DirectBaseline,
) !void {
    try out.print("\n## {s}\n", .{name});

    var model = try loadModel(allocator, model_source);
    defer model.deinit();
    var request = try loadRequest(allocator, request_source);
    defer request.deinit();
    var artifact = try derive(allocator, &model, &request, .gradient_hessian);
    defer artifact.deinit();

    var value_kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value,
    });
    defer value_kernel.deinit();
    var fused_kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value_gradient_hessian,
    });
    defer fused_kernel.deinit();

    var point = switch (try phaser.parseParameterPoint(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(2),
        .bytes = point_source,
    }, .{})) {
        .point => |value| value,
        .diagnostics => return error.InvalidParameterPoint,
    };
    defer point.deinit();

    var value_binding = try kernel_module.bind(
        allocator,
        &value_kernel,
        &model,
        &point,
    );
    defer value_binding.deinit();
    var fused_binding = try kernel_module.bind(
        allocator,
        &fused_kernel,
        &model,
        &point,
    );
    defer fused_binding.deinit();
    try direct.verifyChannels(&value_kernel);

    const coordinates = value_kernel.coordinateCount();
    try reportProgram(out, "value", &value_kernel.program);
    try reportProgram(out, "fused", &fused_kernel.program);

    const largest = batch_sizes[batch_sizes.len - 1];
    const points = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(points);
    for (points, 0..) |*slot, index| {
        slot.* = 10.0 + @as(Scalar, @floatFromInt(index % 97));
    }

    const value_layout = value_binding.workspaceLayout(largest);
    const fused_layout = fused_binding.workspaceLayout(largest);
    const workspace_bytes = @max(value_layout.bytes, fused_layout.bytes);
    if (value_layout.alignment > @alignOf(Scalar) or
        fused_layout.alignment > @alignOf(Scalar))
    {
        return error.UnsupportedBenchmarkWorkspaceAlignment;
    }
    const workspace = try allocator.alignedAlloc(
        u8,
        .of(Scalar),
        workspace_bytes,
    );
    defer allocator.free(workspace);

    const values = try allocator.alloc(Scalar, largest);
    defer allocator.free(values);
    const fused_values = try allocator.alloc(Scalar, largest);
    defer allocator.free(fused_values);
    const direct_values = try allocator.alloc(Scalar, largest);
    defer allocator.free(direct_values);
    const gradients = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(gradients);
    const hessians = try allocator.alloc(
        Scalar,
        largest * coordinates * coordinates,
    );
    defer allocator.free(hessians);
    const statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(statuses);
    const fused_statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(fused_statuses);

    try value_binding.evaluate(points, largest, workspace, .{
        .values = values,
        .statuses = statuses,
    });
    try fused_binding.evaluate(points, largest, workspace, .{
        .values = fused_values,
        .gradients = gradients,
        .hessians = hessians,
        .statuses = fused_statuses,
    });
    direct.kind.evaluateBatch(
        value_binding.parameters.ptr,
        points.ptr,
        largest,
        direct_values.ptr,
    );
    for (0..largest) |index| {
        if (statuses[index] != .ok or fused_statuses[index] != .ok) {
            return error.StatusVerificationFailed;
        }
        if (values[index] != fused_values[index]) {
            return error.FusedValueVerificationFailed;
        }
        const background = points.ptr + index * coordinates;
        const direct_value = direct.kind.evaluate(
            value_binding.parameters.ptr,
            background,
        );
        if (direct_value != direct_values[index]) {
            return error.DirectBatchVerificationFailed;
        }
        try numerical_comparison.reordered_value_well_conditioned.expectCloseAt(
            values[index],
            direct_value,
            .{ .magnitude = direct.kind.magnitude(
                value_binding.parameters.ptr,
                background,
            ) },
        );
    }

    try out.writeAll(
        "measurement\tmedian ns/unit\tmin ns/unit\tmax ns/unit\trepetitions\tunits/repetition\n",
    );

    var direct_scalar = DirectRun{
        .baseline = direct,
        .parameters = value_binding.parameters,
        .backgrounds = points[0..coordinates],
        .point_count = 1,
        .coordinate_count = coordinates,
    };
    try reportMeasurement(
        out,
        "direct_c_scalar_value",
        try measure(io, &direct_scalar),
    );

    var direct_batch = DirectBatchRun{
        .baseline = direct,
        .parameters = value_binding.parameters,
        .backgrounds = points,
        .point_count = largest,
        .values = direct_values,
    };
    try reportMeasurement(
        out,
        "direct_c_batch_value",
        try measure(io, &direct_batch),
    );

    var scalar_value = StagedRun{
        .binding = &value_binding,
        .backgrounds = points[0..coordinates],
        .point_count = 1,
        .workspace = workspace,
        .outputs = .{
            .values = values[0..1],
            .statuses = statuses[0..1],
        },
    };
    try reportMeasurement(
        out,
        "scalar_value",
        try measure(io, &scalar_value),
    );

    var scalar_fused = StagedRun{
        .binding = &fused_binding,
        .backgrounds = points[0..coordinates],
        .point_count = 1,
        .workspace = workspace,
        .outputs = .{
            .values = fused_values[0..1],
            .gradients = gradients[0..coordinates],
            .hessians = hessians[0 .. coordinates * coordinates],
            .statuses = fused_statuses[0..1],
        },
    };
    try reportMeasurement(
        out,
        "scalar_value_gradient_hessian",
        try measure(io, &scalar_fused),
    );

    try out.writeAll(
        "\nbatch_size\tpath\tmedian ns/point\tmin ns/point\tmax ns/point\trepetitions\n",
    );
    for (batch_sizes) |size| {
        var staged = StagedRun{
            .binding = &value_binding,
            .backgrounds = points[0 .. size * coordinates],
            .point_count = size,
            .workspace = workspace,
            .outputs = .{
                .values = values[0..size],
                .statuses = statuses[0..size],
            },
        };
        try reportBatchMeasurement(
            out,
            size,
            "staged",
            try measure(io, &staged),
        );

        var unstaged = UnstagedRun{
            .kernel = &value_kernel,
            .parameters = value_binding.parameters,
            .backgrounds = points[0 .. size * coordinates],
            .point_count = size,
            .workspace = workspace,
            .outputs = .{
                .values = values[0..size],
                .statuses = statuses[0..size],
            },
        };
        try reportBatchMeasurement(
            out,
            size,
            "unstaged",
            try measure(io, &unstaged),
        );
    }

    try out.writeAll(
        "\ncontrol_plane\tmedian ns/op\tmin ns/op\tmax ns/op\trepetitions\n",
    );
    var derivation = DeriveRun{
        .allocator = allocator,
        .model = &model,
        .request = &request,
    };
    try reportControlMeasurement(
        out,
        "derivation",
        try measure(io, &derivation),
    );

    var lowering = LowerRun{
        .allocator = allocator,
        .artifact = &artifact,
    };
    try reportControlMeasurement(
        out,
        "lowering",
        try measure(io, &lowering),
    );

    var binding = BindRun{
        .allocator = allocator,
        .kernel = &fused_kernel,
        .model = &model,
        .point = &point,
    };
    try reportControlMeasurement(
        out,
        "binding",
        try measure(io, &binding),
    );
}

/// The one-loop workloads: a one-by-one mass matrix and a dense three-by-three
/// one, each timed for value only and for the fused value, gradient, and
/// Hessian.
///
/// The dense case is the one that reaches the cyclic Jacobi sweeps, so the two
/// sizes bracket the eigensolver's direct and iterative paths.
const OneLoopWorkload = struct {
    name: []const u8,
    model_source: []const u8,
    request_source: []const u8,
    point_source: []const u8,
    /// The exact spectrum of the mass matrix at background one, which the
    /// verification pass below reproduces independently of the eigensolver.
    spectrum: []const Scalar,
    /// The point file's reference scale, restated so the closed form can use it.
    scale: Scalar,
};

/// The three-scalar slice `(r,s,t) = (b,0,0)`, on which the fixture's mass
/// matrix is `b` times its recorded integer coupling matrix.
const three_scalar_slice_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"component_slice","coordinates":[{"id":"b","scalar":"r"}]},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

/// The fixture's `positive_dense` couplings, whose matrix has the exact
/// spectrum `{9, 36, 81}` at background one.
const three_scalar_point =
    \\{"schema":"phaser.parameter-point/0.1",
    \\"units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":3.0},
    \\"values":{"c111":53.0,"c112":26.0,"c113":-4.0,
    \\"c122":44.0,"c123":-22.0,"c133":29.0}}
;

/// `m2 = 1`, `lambda = 2`, so the one-by-one mass matrix is `1 + phi^2` and its
/// spectrum at background one is `{2}`.
const phi4_one_loop_point =
    \\{"schema":"phaser.parameter-point/0.1",
    \\"units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":2.0},
    \\"values":{"lambda":2.0,"m2":1.0,"omega":0.0}}
;

const one_loop_workloads = [_]OneLoopWorkload{
    .{
        .name = "phi4_one_loop_1x1",
        .model_source = example_data.phi4_model,
        .request_source = example_data.phi4_one_loop_request,
        .point_source = phi4_one_loop_point,
        .spectrum = &.{2},
        .scale = 2,
    },
    .{
        .name = "three_scalar_one_loop_3x3",
        .model_source = oracle_fixture.three_scalar_model,
        .request_source = three_scalar_slice_request,
        .point_source = three_scalar_point,
        .spectrum = &.{ 9, 36, 81 },
        .scale = 3,
    },
};

/// The principal-branch scalar one-loop sum over an explicit spectrum.
///
/// Verification only: it builds no matrix and calls no eigensolver, so
/// agreement with the kernel is evidence that the timed workload computed the
/// intended quantity rather than a cheaper one.
fn oneLoopClosedForm(eigenvalues: []const Scalar, scale: Scalar) struct {
    value: Complex64,
    unsigned: Complex64,
} {
    var total = Complex64{ .re = 0, .im = 0 };
    var unsigned = Complex64{ .re = 0, .im = 0 };
    for (eigenvalues) |eigenvalue| {
        if (eigenvalue == 0) continue;
        const square = eigenvalue * eigenvalue;
        const logarithm = @log(@abs(eigenvalue) / (scale * scale));
        const real = square * (logarithm - 1.5) /
            (64.0 * std.math.pi * std.math.pi);
        const imaginary: Scalar = if (eigenvalue < 0)
            square / (64.0 * std.math.pi)
        else
            0;
        total.re += real;
        total.im += imaginary;
        unsigned.re += @abs(real);
        unsigned.im += @abs(imaginary);
    }
    return .{ .value = total, .unsigned = unsigned };
}

fn reportOneLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    workload: OneLoopWorkload,
) !void {
    try out.print("\n## {s}\n", .{workload.name});

    var model = try loadModel(allocator, workload.model_source);
    defer model.deinit();
    var request = try loadRequest(allocator, workload.request_source);
    defer request.deinit();
    var artifact = try derive(allocator, &model, &request, .gradient_hessian);
    defer artifact.deinit();

    var value_kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value,
        .selection = .{ .role = .scalar_one_loop },
    });
    defer value_kernel.deinit();
    var fused_kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value_gradient_hessian,
        .selection = .{ .role = .scalar_one_loop },
    });
    defer fused_kernel.deinit();

    var point = switch (try phaser.parseParameterPoint(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(2),
        .bytes = workload.point_source,
    }, .{})) {
        .point => |value| value,
        .diagnostics => return error.InvalidParameterPoint,
    };
    defer point.deinit();

    var value_binding = try kernel_module.bind(
        allocator,
        &value_kernel,
        &model,
        &point,
    );
    defer value_binding.deinit();
    var fused_binding = try kernel_module.bind(
        allocator,
        &fused_kernel,
        &model,
        &point,
    );
    defer fused_binding.deinit();

    const coordinates = value_kernel.coordinateCount();
    try reportProgram(out, "value", &value_kernel.program);
    try reportProgram(out, "fused", &fused_kernel.program);

    const largest = batch_sizes[batch_sizes.len - 1];
    const points = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(points);
    // Every point is a background of one in the first coordinate, so the whole
    // batch shares the workload's exact spectrum and one closed form verifies
    // all of it.
    @memset(points, 0);
    for (0..largest) |index| points[index * coordinates] = 1;

    const value_layout = value_binding.workspaceLayout(largest);
    const fused_layout = fused_binding.workspaceLayout(largest);
    if (value_layout.alignment > @alignOf(Scalar) or
        fused_layout.alignment > @alignOf(Scalar))
    {
        return error.UnsupportedBenchmarkWorkspaceAlignment;
    }
    const workspace = try allocator.alignedAlloc(
        u8,
        .of(Scalar),
        @max(value_layout.bytes, fused_layout.bytes),
    );
    defer allocator.free(workspace);

    const values = try allocator.alloc(Complex64, largest);
    defer allocator.free(values);
    const fused_values = try allocator.alloc(Complex64, largest);
    defer allocator.free(fused_values);
    const gradients = try allocator.alloc(Complex64, largest * coordinates);
    defer allocator.free(gradients);
    const hessians = try allocator.alloc(
        Complex64,
        largest * coordinates * coordinates,
    );
    defer allocator.free(hessians);
    const statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(statuses);
    const fused_statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(fused_statuses);

    try value_binding.evaluateComplex(points, largest, workspace, .{
        .values = values,
        .statuses = statuses,
    });
    try fused_binding.evaluateComplex(points, largest, workspace, .{
        .values = fused_values,
        .gradients = gradients,
        .hessians = hessians,
        .statuses = fused_statuses,
    });

    const expected = oneLoopClosedForm(workload.spectrum, workload.scale);
    for (0..largest) |index| {
        if (statuses[index] != .ok or fused_statuses[index] != .ok) {
            return error.StatusVerificationFailed;
        }
        if (values[index].re != fused_values[index].re or
            values[index].im != fused_values[index].im)
        {
            return error.FusedValueVerificationFailed;
        }
        try numerical_comparison.spectral_value_known_spectrum.expectCloseAt(
            expected.value.re,
            values[index].re,
            .{ .magnitude = expected.unsigned.re },
        );
        try numerical_comparison.spectral_value_known_spectrum.expectCloseAt(
            expected.value.im,
            values[index].im,
            .{ .magnitude = expected.unsigned.im },
        );
    }

    try out.writeAll(
        "measurement\tmedian ns/unit\tmin ns/unit\tmax ns/unit\trepetitions\tunits/repetition\n",
    );

    var scalar_value = ComplexStagedRun{
        .binding = &value_binding,
        .backgrounds = points[0..coordinates],
        .point_count = 1,
        .workspace = workspace,
        .outputs = .{ .values = values[0..1], .statuses = statuses[0..1] },
    };
    try reportMeasurement(
        out,
        "scalar_one_loop_value",
        try measure(io, &scalar_value),
    );

    var scalar_fused = ComplexStagedRun{
        .binding = &fused_binding,
        .backgrounds = points[0..coordinates],
        .point_count = 1,
        .workspace = workspace,
        .outputs = .{
            .values = fused_values[0..1],
            .gradients = gradients[0..coordinates],
            .hessians = hessians[0 .. coordinates * coordinates],
            .statuses = fused_statuses[0..1],
        },
    };
    try reportMeasurement(
        out,
        "scalar_one_loop_value_gradient_hessian",
        try measure(io, &scalar_fused),
    );

    try out.writeAll(
        "\nbatch_size\tpath\tmedian ns/point\tmin ns/point\tmax ns/point\trepetitions\n",
    );
    for (batch_sizes) |size| {
        var batch_value = ComplexStagedRun{
            .binding = &value_binding,
            .backgrounds = points[0 .. size * coordinates],
            .point_count = size,
            .workspace = workspace,
            .outputs = .{
                .values = values[0..size],
                .statuses = statuses[0..size],
            },
        };
        try reportBatchMeasurement(
            out,
            size,
            "value",
            try measure(io, &batch_value),
        );

        var batch_fused = ComplexStagedRun{
            .binding = &fused_binding,
            .backgrounds = points[0 .. size * coordinates],
            .point_count = size,
            .workspace = workspace,
            .outputs = .{
                .values = fused_values[0..size],
                .gradients = gradients[0 .. size * coordinates],
                .hessians = hessians[0 .. size * coordinates * coordinates],
                .statuses = fused_statuses[0..size],
            },
        };
        try reportBatchMeasurement(
            out,
            size,
            "fused",
            try measure(io, &batch_fused),
        );
    }
}

fn reportProgram(
    out: *std.Io.Writer,
    name: []const u8,
    program: *const kernel_module.Program,
) !void {
    try out.print(
        "{s}_instructions {d}\t{s}_temporary_slots {d}\t{s}_parameter_stage {d}\n",
        .{
            name,
            program.instructions.len,
            name,
            program.temporaryCount(),
            name,
            program.parameter_stage_count,
        },
    );
}

fn measure(
    io: std.Io,
    run: anytype,
) !Measurement {
    const units_per_repetition = run.unitCount();
    if (units_per_repetition == 0) return error.InvalidMeasurementUnit;

    // Warm caches and lazy operating-system state before calibration.
    try run.execute(1);

    var repetitions: usize = 1;
    while (true) {
        var timer = Timer.begin(io);
        try run.execute(repetitions);
        const elapsed = timer.read();
        if (elapsed >= minimum_sample_ns) break;
        repetitions = std.math.mul(usize, repetitions, 2) catch
            return error.MeasurementRepetitionOverflow;
    }

    var samples: [measurement_sample_count]u64 = undefined;
    for (&samples) |*sample| {
        var timer = Timer.begin(io);
        try run.execute(repetitions);
        sample.* = try picosecondsPerUnit(
            timer.read(),
            repetitions,
            units_per_repetition,
        );
    }
    insertionSort(&samples);

    return .{
        .repetitions = repetitions,
        .units_per_repetition = units_per_repetition,
        .median_picoseconds_per_unit = samples[measurement_sample_count / 2],
        .minimum_picoseconds_per_unit = samples[0],
        .maximum_picoseconds_per_unit = samples[measurement_sample_count - 1],
    };
}

fn picosecondsPerUnit(
    elapsed_ns: u64,
    repetitions: usize,
    units_per_repetition: usize,
) !u64 {
    const units = std.math.mul(
        usize,
        repetitions,
        units_per_repetition,
    ) catch return error.MeasurementUnitOverflow;
    const picoseconds = std.math.mul(
        u64,
        elapsed_ns,
        1000,
    ) catch return error.MeasurementTimeOverflow;
    return picoseconds / @as(u64, @intCast(units));
}

fn insertionSort(values: []u64) void {
    for (values[1..], 1..) |value, index| {
        var position = index;
        while (position > 0 and values[position - 1] > value) {
            values[position] = values[position - 1];
            position -= 1;
        }
        values[position] = value;
    }
}

fn writeNanoseconds(out: *std.Io.Writer, picoseconds: u64) !void {
    try out.print(
        "{d}.{d:0>3}",
        .{ picoseconds / 1000, picoseconds % 1000 },
    );
}

fn reportMeasurement(
    out: *std.Io.Writer,
    name: []const u8,
    measurement: Measurement,
) !void {
    try out.print("{s}\t", .{name});
    try writeNanoseconds(out, measurement.median_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.minimum_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.maximum_picoseconds_per_unit);
    try out.print(
        "\t{d}\t{d}\n",
        .{ measurement.repetitions, measurement.units_per_repetition },
    );
    try out.flush();
}

fn reportBatchMeasurement(
    out: *std.Io.Writer,
    size: usize,
    path: []const u8,
    measurement: Measurement,
) !void {
    try out.print("{d}\t{s}\t", .{ size, path });
    try writeNanoseconds(out, measurement.median_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.minimum_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.maximum_picoseconds_per_unit);
    try out.print("\t{d}\n", .{measurement.repetitions});
    try out.flush();
}

fn reportControlMeasurement(
    out: *std.Io.Writer,
    name: []const u8,
    measurement: Measurement,
) !void {
    try out.print("{s}\t", .{name});
    try writeNanoseconds(out, measurement.median_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.minimum_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.maximum_picoseconds_per_unit);
    try out.print("\t{d}\n", .{measurement.repetitions});
    try out.flush();
}

test "the benchmark driver stays compilable from the test tier" {
    // `addTest` analyzes only what a test reaches, so nothing here referenced
    // the entry point or the report functions it calls. A renamed field in a
    // public kernel type therefore broke `zig build bench` silently: the whole
    // bounded suite passed while the driver no longer compiled. Taking the
    // entry point's address forces its body, and everything it calls, through
    // semantic analysis in `zig build test`.
    _ = &main;
}

test "measurement sample sorting preserves values and orders them" {
    var values = [_]u64{ 7, 1, 5, 3, 2, 6, 4 };
    insertionSort(&values);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5, 6, 7 }, &values);
}

test "measurement normalization accounts for repetitions and batch units" {
    try std.testing.expectEqual(
        @as(u64, 2500),
        try picosecondsPerUnit(10, 2, 2),
    );
}
