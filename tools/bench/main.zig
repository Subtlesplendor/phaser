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
const bench_options = @import("bench_options");
const example_data = @import("example_data");
const generated_aot = @import("generated_aot");
const oracle_fixture = @import("scalar_oracle_fixture");
const numerical_comparison = @import("numerical_comparison");

const calculation = phaser.calculation;
const kernel_module = phaser.kernel;
const Scalar = kernel_module.Scalar;
const Complex64 = kernel_module.Complex64;

const bounded_batch_sizes = [_]usize{ 1, 8, 64, 1024 };
const extended_batch_sizes = [_]usize{ 16 * 1024, 64 * 1024, 1024 * 1024 };
const all_batch_sizes = bounded_batch_sizes ++ extended_batch_sizes;
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

const DirectComplex64 = extern struct {
    re: Scalar,
    im: Scalar,

    fn kernel(self: DirectComplex64) Complex64 {
        return .{ .re = self.re, .im = self.im };
    }
};

const DirectLoopStatus = enum(u8) {
    ok = 0,
    non_finite = 1,
    nonconvergent = 2,
};

extern fn phaser_bench_one_loop_1x1_value(
    parameters: [*]const Scalar,
    background: [*]const Scalar,
    scale: Scalar,
    result: *DirectComplex64,
) c_int;

extern fn phaser_bench_one_loop_2x2_value(
    parameters: [*]const Scalar,
    background: [*]const Scalar,
    scale: Scalar,
    result: *DirectComplex64,
) c_int;

extern fn phaser_bench_one_loop_3x3_value(
    parameters: [*]const Scalar,
    background: [*]const Scalar,
    scale: Scalar,
    result: *DirectComplex64,
) c_int;

extern fn phaser_bench_one_loop_1x1_value_batch(
    parameters: [*]const Scalar,
    backgrounds: [*]const Scalar,
    scale: Scalar,
    point_count: c_ulonglong,
    results: [*]DirectComplex64,
    statuses: [*]u8,
) void;

extern fn phaser_bench_one_loop_2x2_value_batch(
    parameters: [*]const Scalar,
    backgrounds: [*]const Scalar,
    scale: Scalar,
    point_count: c_ulonglong,
    results: [*]DirectComplex64,
    statuses: [*]u8,
) void;

extern fn phaser_bench_one_loop_3x3_value_batch(
    parameters: [*]const Scalar,
    backgrounds: [*]const Scalar,
    scale: Scalar,
    point_count: c_ulonglong,
    results: [*]DirectComplex64,
    statuses: [*]u8,
) void;

extern fn phaser_bench_dependency_carrier(
    value: Scalar,
    base: Scalar,
    span: Scalar,
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

const DirectLoopKind = enum {
    one_by_one,
    two_by_two,
    three_by_three,

    fn evaluate(
        self: DirectLoopKind,
        parameters: [*]const Scalar,
        background: [*]const Scalar,
        scale: Scalar,
        result: *DirectComplex64,
    ) DirectLoopStatus {
        const raw = switch (self) {
            .one_by_one => phaser_bench_one_loop_1x1_value(
                parameters,
                background,
                scale,
                result,
            ),
            .two_by_two => phaser_bench_one_loop_2x2_value(
                parameters,
                background,
                scale,
                result,
            ),
            .three_by_three => phaser_bench_one_loop_3x3_value(
                parameters,
                background,
                scale,
                result,
            ),
        };
        return @enumFromInt(@as(u8, @intCast(raw)));
    }

    fn evaluateBatch(
        self: DirectLoopKind,
        parameters: [*]const Scalar,
        backgrounds: [*]const Scalar,
        scale: Scalar,
        point_count: usize,
        results: [*]DirectComplex64,
        statuses: [*]u8,
    ) void {
        const count: c_ulonglong = @intCast(point_count);
        switch (self) {
            .one_by_one => phaser_bench_one_loop_1x1_value_batch(
                parameters,
                backgrounds,
                scale,
                count,
                results,
                statuses,
            ),
            .two_by_two => phaser_bench_one_loop_2x2_value_batch(
                parameters,
                backgrounds,
                scale,
                count,
                results,
                statuses,
            ),
            .three_by_three => phaser_bench_one_loop_3x3_value_batch(
                parameters,
                backgrounds,
                scale,
                count,
                results,
                statuses,
            ),
        }
    }
};

const DirectLoopBaseline = struct {
    kind: DirectLoopKind,
    parameter_names: []const []const u8,

    fn verifyChannels(
        self: DirectLoopBaseline,
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

const phi4_one_loop_direct = DirectLoopBaseline{
    .kind = .one_by_one,
    .parameter_names = &.{ "lambda", "m2", "omega" },
};

const multi_scalar_one_loop_direct = DirectLoopBaseline{
    .kind = .two_by_two,
    .parameter_names = multi_scalar_direct.parameter_names,
};

const three_scalar_one_loop_direct = DirectLoopBaseline{
    .kind = .three_by_three,
    .parameter_names = &.{ "c111", "c112", "c113", "c122", "c123", "c133" },
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
        std.mem.doNotOptimizeAway(self.outputs.values);
        std.mem.doNotOptimizeAway(self.outputs.statuses);
    }
};

const maximum_benchmark_workers = 64;

const ParallelShape = enum {
    scalar_calls,
    batch,
};

const ParallelWorker = struct {
    binding: *const kernel_module.Binding,
    backgrounds: []const Scalar,
    coordinate_count: usize,
    shape: ParallelShape,
    repetitions: usize,
    workspace: []u8,
    values: []Scalar,
    statuses: []kernel_module.Status,
    failure: ?anyerror = null,
};

fn runParallelWorker(worker: *ParallelWorker) void {
    for (0..worker.repetitions) |_| {
        switch (worker.shape) {
            .scalar_calls => {
                for (0..worker.values.len) |point| {
                    worker.binding.evaluate(
                        worker.backgrounds[point * worker.coordinate_count ..][0..worker.coordinate_count],
                        1,
                        worker.workspace,
                        .{
                            .values = worker.values[point..][0..1],
                            .statuses = worker.statuses[point..][0..1],
                        },
                    ) catch |failure| {
                        worker.failure = failure;
                        return;
                    };
                }
            },
            .batch => {
                worker.binding.evaluate(
                    worker.backgrounds,
                    worker.values.len,
                    worker.workspace,
                    .{ .values = worker.values, .statuses = worker.statuses },
                ) catch |failure| {
                    worker.failure = failure;
                    return;
                };
            },
        }
    }
}

/// Caller-owned worker scaling. Threads are created by the benchmark harness,
/// not by Phaser, and each receives disjoint outputs plus one workspace.
const ParallelStagedRun = struct {
    binding: *const kernel_module.Binding,
    backgrounds: []const Scalar,
    point_count: usize,
    coordinate_count: usize,
    worker_count: usize,
    shape: ParallelShape,
    workspace_storage: []u8,
    workspace_stride: usize,
    values: []Scalar,
    statuses: []kernel_module.Status,

    fn unitCount(self: *const ParallelStagedRun) usize {
        return self.point_count;
    }

    fn execute(self: *const ParallelStagedRun, repetitions: usize) !void {
        std.debug.assert(self.worker_count > 0);
        std.debug.assert(self.worker_count <= maximum_benchmark_workers);
        var workers: [maximum_benchmark_workers]ParallelWorker = undefined;
        var threads: [maximum_benchmark_workers]std.Thread = undefined;
        var started: usize = 0;
        for (0..self.worker_count) |worker_index| {
            const chunk = try kernel_module.chunkForWorker(
                self.point_count,
                self.worker_count,
                worker_index,
            );
            const workspace_start = worker_index * self.workspace_stride;
            workers[worker_index] = .{
                .binding = self.binding,
                .backgrounds = self.backgrounds[chunk.start * self.coordinate_count ..][0 .. chunk.len * self.coordinate_count],
                .coordinate_count = self.coordinate_count,
                .shape = self.shape,
                .repetitions = repetitions,
                .workspace = self.workspace_storage[workspace_start..][0..self.workspace_stride],
                .values = self.values[chunk.start..chunk.end()],
                .statuses = self.statuses[chunk.start..chunk.end()],
            };
            threads[worker_index] = std.Thread.spawn(
                .{},
                runParallelWorker,
                .{&workers[worker_index]},
            ) catch |failure| {
                for (threads[0..started]) |thread| thread.join();
                return failure;
            };
            started += 1;
        }
        for (threads[0..started]) |thread| thread.join();
        for (workers[0..started]) |worker| {
            if (worker.failure) |failure| return failure;
        }
        std.mem.doNotOptimizeAway(self.values);
        std.mem.doNotOptimizeAway(self.statuses);
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
        std.mem.doNotOptimizeAway(self.outputs.values);
        std.mem.doNotOptimizeAway(self.outputs.statuses);
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
        std.mem.doNotOptimizeAway(self.outputs.values);
        std.mem.doNotOptimizeAway(self.outputs.statuses);
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

const AotRun = struct {
    bound: *const generated_aot.Bound,
    backgrounds: []const Scalar,
    point_count: usize,
    values: []Scalar,
    statuses: []generated_aot.Status,

    fn unitCount(self: *const AotRun) usize {
        return self.point_count;
    }

    fn execute(self: *const AotRun, repetitions: usize) !void {
        var workspace: [0]u8 = .{};
        for (0..repetitions) |_| {
            try generated_aot.evaluateBatch(
                self.bound,
                self.backgrounds,
                self.point_count,
                &workspace,
                self.values,
                self.statuses,
            );
        }
        std.mem.doNotOptimizeAway(self.values);
        std.mem.doNotOptimizeAway(self.statuses);
    }
};

const DirectLoopRun = struct {
    baseline: DirectLoopBaseline,
    parameters: []const Scalar,
    backgrounds: []const Scalar,
    scale: Scalar,
    point_count: usize,
    coordinate_count: usize,
    sink: DirectComplex64 = .{ .re = 0, .im = 0 },

    fn unitCount(self: *const DirectLoopRun) usize {
        return self.point_count;
    }

    fn execute(self: *DirectLoopRun, repetitions: usize) !void {
        std.debug.assert(
            self.backgrounds.len == self.point_count * self.coordinate_count,
        );
        for (0..repetitions) |_| {
            for (0..self.point_count) |point_index| {
                const background =
                    self.backgrounds.ptr + point_index * self.coordinate_count;
                if (self.baseline.kind.evaluate(
                    self.parameters.ptr,
                    background,
                    self.scale,
                    &self.sink,
                ) != .ok) {
                    return error.DirectOneLoopFailed;
                }
            }
        }
        std.mem.doNotOptimizeAway(self.sink);
    }
};

const DirectLoopBatchRun = struct {
    baseline: DirectLoopBaseline,
    parameters: []const Scalar,
    backgrounds: []const Scalar,
    scale: Scalar,
    point_count: usize,
    values: []DirectComplex64,
    statuses: []u8,

    fn unitCount(self: *const DirectLoopBatchRun) usize {
        return self.point_count;
    }

    fn execute(self: *const DirectLoopBatchRun, repetitions: usize) !void {
        std.debug.assert(self.values.len == self.point_count);
        std.debug.assert(self.statuses.len == self.point_count);
        for (0..repetitions) |_| {
            self.baseline.kind.evaluateBatch(
                self.parameters.ptr,
                self.backgrounds.ptr,
                self.scale,
                self.point_count,
                self.values.ptr,
                self.statuses.ptr,
            );
        }
        std.mem.doNotOptimizeAway(self.values);
        std.mem.doNotOptimizeAway(self.statuses);
    }
};

const CarrierRun = struct {
    state: Scalar,
    base: Scalar,
    span: Scalar,

    fn unitCount(_: *const CarrierRun) usize {
        return 1;
    }

    fn execute(self: *CarrierRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            self.state = phaser_bench_dependency_carrier(
                self.state,
                self.base,
                self.span,
            );
        }
        std.mem.doNotOptimizeAway(self.state);
    }
};

const StagedDependentRun = struct {
    binding: *const kernel_module.Binding,
    background: []Scalar,
    workspace: []u8,
    values: []Scalar,
    statuses: []kernel_module.Status,
    base: Scalar,
    span: Scalar,

    fn unitCount(_: *const StagedDependentRun) usize {
        return 1;
    }

    fn execute(self: *StagedDependentRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            try self.binding.evaluate(
                self.background,
                1,
                self.workspace,
                .{ .values = self.values, .statuses = self.statuses },
            );
            if (self.statuses[0] != .ok) return error.DependentEvaluationFailed;
            self.background[0] = phaser_bench_dependency_carrier(
                self.values[0],
                self.base,
                self.span,
            );
        }
        std.mem.doNotOptimizeAway(self.background);
        std.mem.doNotOptimizeAway(self.values);
    }
};

const DirectDependentRun = struct {
    baseline: DirectBaseline,
    parameters: []const Scalar,
    background: []Scalar,
    base: Scalar,
    span: Scalar,
    sink: Scalar = 0,

    fn unitCount(_: *const DirectDependentRun) usize {
        return 1;
    }

    fn execute(self: *DirectDependentRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            self.sink = self.baseline.kind.evaluate(
                self.parameters.ptr,
                self.background.ptr,
            );
            self.background[0] = phaser_bench_dependency_carrier(
                self.sink,
                self.base,
                self.span,
            );
        }
        std.mem.doNotOptimizeAway(self.background);
        std.mem.doNotOptimizeAway(self.sink);
    }
};

const AotDependentRun = struct {
    bound: *const generated_aot.Bound,
    background: []Scalar,
    values: []Scalar,
    statuses: []generated_aot.Status,
    base: Scalar,
    span: Scalar,

    fn unitCount(_: *const AotDependentRun) usize {
        return 1;
    }

    fn execute(self: *AotDependentRun, repetitions: usize) !void {
        var workspace: [0]u8 = .{};
        for (0..repetitions) |_| {
            try generated_aot.evaluateScalar(
                self.bound,
                self.background,
                &workspace,
                self.values,
                self.statuses,
            );
            if (self.statuses[0] != .ok) return error.DependentEvaluationFailed;
            self.background[0] = phaser_bench_dependency_carrier(
                self.values[0],
                self.base,
                self.span,
            );
        }
        std.mem.doNotOptimizeAway(self.background);
        std.mem.doNotOptimizeAway(self.values);
    }
};

const AotBindRun = struct {
    parameters: []const Scalar,
    sink: generated_aot.Bound,

    fn unitCount(_: *const AotBindRun) usize {
        return 1;
    }

    fn execute(self: *AotBindRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            self.sink = try generated_aot.bind(self.parameters);
        }
        std.mem.doNotOptimizeAway(self.sink);
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

const ValidationRun = struct {
    kernel: *const kernel_module.Kernel,
    parameters: []const Scalar,
    scales: []const Scalar,
    workspace: []u8,

    fn unitCount(_: *const ValidationRun) usize {
        return 1;
    }

    fn execute(self: *const ValidationRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            try self.kernel.evaluate(
                .{
                    .parameters = self.parameters,
                    .scales = self.scales,
                    .backgrounds = &.{},
                },
                0,
                self.workspace,
                .{ .values = &.{}, .statuses = &.{} },
            );
        }
        std.mem.doNotOptimizeAway(self.workspace);
    }
};

const ParameterStageRun = struct {
    program: *const kernel_module.Program,
    parameters: []const Scalar,
    scales: []const Scalar,
    frame: []align(@alignOf(Scalar)) u8,
    scratch: []u8,
    sink: kernel_module.Status = .ok,

    fn unitCount(_: *const ParameterStageRun) usize {
        return 1;
    }

    fn execute(self: *ParameterStageRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            self.sink = kernel_module.runParameterStage(
                self.program,
                .{
                    .parameters = self.parameters,
                    .scales = self.scales,
                    .backgrounds = &.{},
                },
                self.frame,
                self.scratch,
            );
        }
        std.mem.doNotOptimizeAway(self.frame);
        std.mem.doNotOptimizeAway(self.sink);
    }
};

const PublicationRun = struct {
    candidates: []const Complex64,
    values: []Complex64,
    statuses: []kernel_module.Status,

    fn unitCount(self: *const PublicationRun) usize {
        return self.candidates.len;
    }

    fn execute(self: *const PublicationRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            for (self.candidates, self.values, self.statuses) |
                candidate,
                *value,
                *status,
            | {
                if (candidate.isFinite()) {
                    status.* = .ok;
                    value.* = candidate;
                } else {
                    status.* = .non_finite;
                }
            }
        }
        std.mem.doNotOptimizeAway(self.values);
        std.mem.doNotOptimizeAway(self.statuses);
    }
};

const Measurement = struct {
    repetitions: usize,
    units_per_repetition: usize,
    median_picoseconds_per_unit: u64,
    minimum_picoseconds_per_unit: u64,
    maximum_picoseconds_per_unit: u64,
};

const RuntimeMetadata = struct {
    model: []const u8,
    point_set: []const u8,
    contribution: []const u8,
    capability: []const u8,
    backend: []const u8,
    shape: []const u8,
    points: usize,
    workspace_bytes: usize,
    workspace_alignment: usize,
    buffer_bytes: usize,
    binding_reused: bool,
    workers: usize = 1,
};

pub fn main(init: std.process.Init) !void {
    if (!std.math.isFinite(bench_options.cycles_per_ns) or
        bench_options.cycles_per_ns < 0)
    {
        return error.InvalidBenchmarkCyclesPerNanosecond;
    }

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &file_writer.interface;

    try writePreamble(out);
    if (bench_options.aot_only) {
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
        try out.flush();
        return;
    }
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
    try reportPublicationLeaf(init.gpa, init.io, out);
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
    try out.print("# extended {s}\n", .{if (bench_options.extended) "yes" else "no"});
    if (bench_options.cycles_per_ns > 0) {
        try out.print(
            "# derived_cycles_per_ns {d:.6} (user supplied)\n",
            .{bench_options.cycles_per_ns},
        );
    } else {
        try out.writeAll("# derived_cycles disabled\n");
    }
    try out.print(
        "# optimized_interpreter block_width {d}\n",
        .{kernel_module.optimizedBlockWidth},
    );
    try out.writeAll(
        \\# direct_c flags: -O3 -fno-fast-math -ffp-contract=off
        \\# scalar_throughput means independent reciprocal throughput.
        \\# dependent_scalar_latency carries each result into the next input.
        \\# Nanoseconds are primary; any cycle values are user-supplied derivatives.
        \\# backend aot_prototype is generated only for phi4 tree-level value.
        \\#
        \\# Timings are informational. They are not a merge gate and a hosted
        \\# runner is too noisy for small differences to be meaningful.
        \\
    );
}

fn largestBatchSize() usize {
    if (bench_options.extended) {
        return extended_batch_sizes[extended_batch_sizes.len - 1];
    }
    return bounded_batch_sizes[bounded_batch_sizes.len - 1];
}

fn selectedBatchSizes() []const usize {
    return if (bench_options.extended)
        all_batch_sizes[0..]
    else
        bounded_batch_sizes[0..];
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
    var optimized_value_kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value,
        .backend = .optimized_interpreter,
    });
    defer optimized_value_kernel.deinit();
    var optimized_fused_kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value_gradient_hessian,
        .backend = .optimized_interpreter,
    });
    defer optimized_fused_kernel.deinit();

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
    var optimized_value_binding = try kernel_module.bind(
        allocator,
        &optimized_value_kernel,
        &model,
        &point,
    );
    defer optimized_value_binding.deinit();
    var optimized_fused_binding = try kernel_module.bind(
        allocator,
        &optimized_fused_kernel,
        &model,
        &point,
    );
    defer optimized_fused_binding.deinit();
    try direct.verifyChannels(&value_kernel);
    const has_aot = std.mem.eql(u8, name, "phi4");
    const aot_bound: ?generated_aot.Bound = if (has_aot) blk: {
        try generated_aot.validateIdentity(
            value_kernel.model_fingerprint,
            value_kernel.request_fingerprint,
        );
        break :blk try generated_aot.bind(value_binding.parameters);
    } else null;

    const coordinates = value_kernel.coordinateCount();
    try reportProgram(out, "value", &value_kernel.program);
    try reportProgram(out, "fused", &fused_kernel.program);

    const largest = largestBatchSize();
    const points = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(points);
    for (points, 0..) |*slot, index| {
        slot.* = 10.0 + @as(Scalar, @floatFromInt(index % 97));
    }

    const value_layout = value_binding.workspaceLayout(largest);
    const fused_layout = fused_binding.workspaceLayout(largest);
    const optimized_value_layout = optimized_value_binding.workspaceLayout(largest);
    const optimized_fused_layout = optimized_fused_binding.workspaceLayout(largest);
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
    const optimized_workspace = try allocator.alignedAlloc(
        u8,
        .of(@Vector(2, Scalar)),
        @max(optimized_value_layout.bytes, optimized_fused_layout.bytes),
    );
    defer allocator.free(optimized_workspace);
    const parallel_workspace_stride = std.mem.alignForward(
        usize,
        optimized_value_layout.bytes,
        optimized_value_layout.alignment,
    );
    const parallel_workspace = try allocator.alignedAlloc(
        u8,
        .of(@Vector(2, Scalar)),
        try std.math.mul(
            usize,
            parallel_workspace_stride,
            maximum_benchmark_workers,
        ),
    );
    defer allocator.free(parallel_workspace);

    const values = try allocator.alloc(Scalar, largest);
    defer allocator.free(values);
    const fused_values = try allocator.alloc(Scalar, largest);
    defer allocator.free(fused_values);
    const optimized_values = try allocator.alloc(Scalar, largest);
    defer allocator.free(optimized_values);
    const optimized_fused_values = try allocator.alloc(Scalar, largest);
    defer allocator.free(optimized_fused_values);
    const direct_values = try allocator.alloc(Scalar, largest);
    defer allocator.free(direct_values);
    const aot_values = try allocator.alloc(Scalar, largest);
    defer allocator.free(aot_values);
    const gradients = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(gradients);
    const optimized_gradients = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(optimized_gradients);
    const hessians = try allocator.alloc(
        Scalar,
        largest * coordinates * coordinates,
    );
    defer allocator.free(hessians);
    const optimized_hessians = try allocator.alloc(
        Scalar,
        largest * coordinates * coordinates,
    );
    defer allocator.free(optimized_hessians);
    const statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(statuses);
    const fused_statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(fused_statuses);
    const optimized_statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(optimized_statuses);
    const optimized_fused_statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(optimized_fused_statuses);
    const aot_statuses = try allocator.alloc(generated_aot.Status, largest);
    defer allocator.free(aot_statuses);

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
    try optimized_value_binding.evaluate(points, largest, optimized_workspace, .{
        .values = optimized_values,
        .statuses = optimized_statuses,
    });
    try optimized_fused_binding.evaluate(points, largest, optimized_workspace, .{
        .values = optimized_fused_values,
        .gradients = optimized_gradients,
        .hessians = optimized_hessians,
        .statuses = optimized_fused_statuses,
    });
    direct.kind.evaluateBatch(
        value_binding.parameters.ptr,
        points.ptr,
        largest,
        direct_values.ptr,
    );
    if (aot_bound) |*bound| {
        var no_workspace: [0]u8 = .{};
        try generated_aot.evaluateBatch(
            bound,
            points,
            largest,
            &no_workspace,
            aot_values,
            aot_statuses,
        );
    }
    for (0..largest) |index| {
        if (statuses[index] != .ok or fused_statuses[index] != .ok) {
            return error.StatusVerificationFailed;
        }
        if (optimized_statuses[index] != statuses[index] or
            optimized_fused_statuses[index] != fused_statuses[index] or
            optimized_values[index] != values[index] or
            optimized_fused_values[index] != fused_values[index])
        {
            return error.OptimizedVerificationFailed;
        }
        const gradient_start = index * coordinates;
        const hessian_start = index * coordinates * coordinates;
        if (!std.mem.eql(
            Scalar,
            gradients[gradient_start..][0..coordinates],
            optimized_gradients[gradient_start..][0..coordinates],
        ) or !std.mem.eql(
            Scalar,
            hessians[hessian_start..][0 .. coordinates * coordinates],
            optimized_hessians[hessian_start..][0 .. coordinates * coordinates],
        )) {
            return error.OptimizedVerificationFailed;
        }
        if (values[index] != fused_values[index]) {
            return error.FusedValueVerificationFailed;
        }
        if (aot_bound != null and
            (@intFromEnum(aot_statuses[index]) != @intFromEnum(statuses[index]) or
                @as(u64, @bitCast(aot_values[index])) !=
                    @as(u64, @bitCast(values[index]))))
        {
            return error.AotVerificationFailed;
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

    try writeRuntimeHeader(out);

    var direct_scalar = DirectRun{
        .baseline = direct,
        .parameters = value_binding.parameters,
        .backgrounds = points[0..coordinates],
        .point_count = 1,
        .coordinate_count = coordinates,
    };
    try reportRuntimeMeasurement(out, .{
        .model = name,
        .point_set = "varied_scan",
        .contribution = "total",
        .capability = "value",
        .backend = "direct_c",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = 0,
        .workspace_alignment = 1,
        .buffer_bytes = directTreeBufferBytes(1, coordinates, direct.parameter_names.len),
        .binding_reused = true,
    }, try measure(io, &direct_scalar));

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
    try reportRuntimeMeasurement(out, .{
        .model = name,
        .point_set = "varied_scan",
        .contribution = "total",
        .capability = "value",
        .backend = "reference_interpreter",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = value_layout.bytes,
        .workspace_alignment = value_layout.alignment,
        .buffer_bytes = realBufferBytes(1, coordinates, .value, 0),
        .binding_reused = true,
    }, try measure(io, &scalar_value));

    var optimized_scalar_value = StagedRun{
        .binding = &optimized_value_binding,
        .backgrounds = points[0..coordinates],
        .point_count = 1,
        .workspace = optimized_workspace,
        .outputs = .{
            .values = optimized_values[0..1],
            .statuses = optimized_statuses[0..1],
        },
    };
    try reportRuntimeMeasurement(out, .{
        .model = name,
        .point_set = "varied_scan",
        .contribution = "total",
        .capability = "value",
        .backend = "optimized_interpreter",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = optimized_value_layout.bytes,
        .workspace_alignment = optimized_value_layout.alignment,
        .buffer_bytes = realBufferBytes(1, coordinates, .value, 0),
        .binding_reused = true,
    }, try measure(io, &optimized_scalar_value));
    if (aot_bound) |*bound| {
        var aot_scalar = AotRun{
            .bound = bound,
            .backgrounds = points[0..coordinates],
            .point_count = 1,
            .values = aot_values[0..1],
            .statuses = aot_statuses[0..1],
        };
        try reportRuntimeMeasurement(out, .{
            .model = name,
            .point_set = "varied_scan",
            .contribution = "total",
            .capability = "value",
            .backend = "aot_prototype",
            .shape = "scalar_throughput",
            .points = 1,
            .workspace_bytes = 0,
            .workspace_alignment = 1,
            .buffer_bytes = realBufferBytes(1, coordinates, .value, 0),
            .binding_reused = true,
        }, try measure(io, &aot_scalar));
    }

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
    try reportRuntimeMeasurement(out, .{
        .model = name,
        .point_set = "varied_scan",
        .contribution = "total",
        .capability = "value_gradient_hessian",
        .backend = "reference_interpreter",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = fused_layout.bytes,
        .workspace_alignment = fused_layout.alignment,
        .buffer_bytes = realBufferBytes(
            1,
            coordinates,
            .value_gradient_hessian,
            0,
        ),
        .binding_reused = true,
    }, try measure(io, &scalar_fused));

    var optimized_scalar_fused = StagedRun{
        .binding = &optimized_fused_binding,
        .backgrounds = points[0..coordinates],
        .point_count = 1,
        .workspace = optimized_workspace,
        .outputs = .{
            .values = optimized_fused_values[0..1],
            .gradients = optimized_gradients[0..coordinates],
            .hessians = optimized_hessians[0 .. coordinates * coordinates],
            .statuses = optimized_fused_statuses[0..1],
        },
    };
    try reportRuntimeMeasurement(out, .{
        .model = name,
        .point_set = "varied_scan",
        .contribution = "total",
        .capability = "value_gradient_hessian",
        .backend = "optimized_interpreter",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = optimized_fused_layout.bytes,
        .workspace_alignment = optimized_fused_layout.alignment,
        .buffer_bytes = realBufferBytes(
            1,
            coordinates,
            .value_gradient_hessian,
            0,
        ),
        .binding_reused = true,
    }, try measure(io, &optimized_scalar_fused));

    const dependent_phaser_background = try allocator.dupe(
        Scalar,
        points[0..coordinates],
    );
    defer allocator.free(dependent_phaser_background);
    const dependent_optimized_background = try allocator.dupe(
        Scalar,
        points[0..coordinates],
    );
    defer allocator.free(dependent_optimized_background);
    const dependent_direct_background = try allocator.dupe(
        Scalar,
        points[0..coordinates],
    );
    defer allocator.free(dependent_direct_background);
    const dependent_aot_background = try allocator.dupe(
        Scalar,
        points[0..coordinates],
    );
    defer allocator.free(dependent_aot_background);
    const carrier_base: Scalar = 10;
    const carrier_span: Scalar = 90;
    var carrier = CarrierRun{
        .state = points[0],
        .base = carrier_base,
        .span = carrier_span,
    };
    const carrier_measurement = try measure(io, &carrier);

    var staged_dependent = StagedDependentRun{
        .binding = &value_binding,
        .background = dependent_phaser_background,
        .workspace = workspace,
        .values = values[0..1],
        .statuses = statuses[0..1],
        .base = carrier_base,
        .span = carrier_span,
    };
    const staged_latency = try measure(io, &staged_dependent);
    try reportRuntimeMeasurement(out, .{
        .model = name,
        .point_set = "carrier_scan",
        .contribution = "total",
        .capability = "value",
        .backend = "reference_interpreter",
        .shape = "dependent_scalar_latency",
        .points = 1,
        .workspace_bytes = value_layout.bytes,
        .workspace_alignment = value_layout.alignment,
        .buffer_bytes = realBufferBytes(1, coordinates, .value, 0),
        .binding_reused = true,
    }, staged_latency);

    var optimized_dependent = StagedDependentRun{
        .binding = &optimized_value_binding,
        .background = dependent_optimized_background,
        .workspace = optimized_workspace,
        .values = optimized_values[0..1],
        .statuses = optimized_statuses[0..1],
        .base = carrier_base,
        .span = carrier_span,
    };
    try reportRuntimeMeasurement(out, .{
        .model = name,
        .point_set = "carrier_scan",
        .contribution = "total",
        .capability = "value",
        .backend = "optimized_interpreter",
        .shape = "dependent_scalar_latency",
        .points = 1,
        .workspace_bytes = optimized_value_layout.bytes,
        .workspace_alignment = optimized_value_layout.alignment,
        .buffer_bytes = realBufferBytes(1, coordinates, .value, 0),
        .binding_reused = true,
    }, try measure(io, &optimized_dependent));
    if (aot_bound) |*bound| {
        var aot_dependent = AotDependentRun{
            .bound = bound,
            .background = dependent_aot_background,
            .values = aot_values[0..1],
            .statuses = aot_statuses[0..1],
            .base = carrier_base,
            .span = carrier_span,
        };
        try reportRuntimeMeasurement(out, .{
            .model = name,
            .point_set = "carrier_scan",
            .contribution = "total",
            .capability = "value",
            .backend = "aot_prototype",
            .shape = "dependent_scalar_latency",
            .points = 1,
            .workspace_bytes = 0,
            .workspace_alignment = 1,
            .buffer_bytes = realBufferBytes(1, coordinates, .value, 0),
            .binding_reused = true,
        }, try measure(io, &aot_dependent));
    }

    var direct_dependent = DirectDependentRun{
        .baseline = direct,
        .parameters = value_binding.parameters,
        .background = dependent_direct_background,
        .base = carrier_base,
        .span = carrier_span,
    };
    const direct_latency = try measure(io, &direct_dependent);
    try reportRuntimeMeasurement(out, .{
        .model = name,
        .point_set = "carrier_scan",
        .contribution = "total",
        .capability = "value",
        .backend = "direct_c",
        .shape = "dependent_scalar_latency",
        .points = 1,
        .workspace_bytes = 0,
        .workspace_alignment = 1,
        .buffer_bytes = directTreeBufferBytes(1, coordinates, direct.parameter_names.len),
        .binding_reused = true,
    }, direct_latency);
    try reportLatencyCarrier(
        out,
        name,
        carrier_measurement,
        staged_latency,
        direct_latency,
    );

    for (selectedBatchSizes()) |size| {
        var direct_batch = DirectBatchRun{
            .baseline = direct,
            .parameters = value_binding.parameters,
            .backgrounds = points[0 .. size * coordinates],
            .point_count = size,
            .values = direct_values[0..size],
        };
        try reportRuntimeMeasurement(out, .{
            .model = name,
            .point_set = "varied_scan",
            .contribution = "total",
            .capability = "value",
            .backend = "direct_c",
            .shape = "batch_throughput",
            .points = size,
            .workspace_bytes = 0,
            .workspace_alignment = 1,
            .buffer_bytes = directTreeBufferBytes(
                size,
                coordinates,
                direct.parameter_names.len,
            ),
            .binding_reused = true,
        }, try measure(io, &direct_batch));

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
        try reportRuntimeMeasurement(out, .{
            .model = name,
            .point_set = "varied_scan",
            .contribution = "total",
            .capability = "value",
            .backend = "reference_interpreter",
            .shape = "batch_throughput",
            .points = size,
            .workspace_bytes = value_layout.bytes,
            .workspace_alignment = value_layout.alignment,
            .buffer_bytes = realBufferBytes(size, coordinates, .value, 0),
            .binding_reused = true,
        }, try measure(io, &staged));

        var optimized_staged = StagedRun{
            .binding = &optimized_value_binding,
            .backgrounds = points[0 .. size * coordinates],
            .point_count = size,
            .workspace = optimized_workspace,
            .outputs = .{
                .values = optimized_values[0..size],
                .statuses = optimized_statuses[0..size],
            },
        };
        try reportRuntimeMeasurement(out, .{
            .model = name,
            .point_set = "varied_scan",
            .contribution = "total",
            .capability = "value",
            .backend = "optimized_interpreter",
            .shape = "batch_throughput",
            .points = size,
            .workspace_bytes = optimized_value_layout.bytes,
            .workspace_alignment = optimized_value_layout.alignment,
            .buffer_bytes = realBufferBytes(size, coordinates, .value, 0),
            .binding_reused = true,
        }, try measure(io, &optimized_staged));
        if (aot_bound) |*bound| {
            var aot_batch = AotRun{
                .bound = bound,
                .backgrounds = points[0 .. size * coordinates],
                .point_count = size,
                .values = aot_values[0..size],
                .statuses = aot_statuses[0..size],
            };
            try reportRuntimeMeasurement(out, .{
                .model = name,
                .point_set = "varied_scan",
                .contribution = "total",
                .capability = "value",
                .backend = "aot_prototype",
                .shape = "batch_throughput",
                .points = size,
                .workspace_bytes = 0,
                .workspace_alignment = 1,
                .buffer_bytes = realBufferBytes(size, coordinates, .value, 0),
                .binding_reused = true,
            }, try measure(io, &aot_batch));
        }

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
        try reportRuntimeMeasurement(out, .{
            .model = name,
            .point_set = "varied_scan",
            .contribution = "total",
            .capability = "value",
            .backend = "reference_interpreter",
            .shape = "batch_throughput",
            .points = size,
            .workspace_bytes = value_layout.bytes,
            .workspace_alignment = value_layout.alignment,
            .buffer_bytes = realBufferBytes(
                size,
                coordinates,
                .value,
                value_binding.parameters.len + value_binding.scales.len,
            ),
            .binding_reused = false,
        }, try measure(io, &unstaged));

        var fused = StagedRun{
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
        try reportRuntimeMeasurement(out, .{
            .model = name,
            .point_set = "varied_scan",
            .contribution = "total",
            .capability = "value_gradient_hessian",
            .backend = "reference_interpreter",
            .shape = "batch_throughput",
            .points = size,
            .workspace_bytes = fused_layout.bytes,
            .workspace_alignment = fused_layout.alignment,
            .buffer_bytes = realBufferBytes(
                size,
                coordinates,
                .value_gradient_hessian,
                0,
            ),
            .binding_reused = true,
        }, try measure(io, &fused));

        var optimized_fused = StagedRun{
            .binding = &optimized_fused_binding,
            .backgrounds = points[0 .. size * coordinates],
            .point_count = size,
            .workspace = optimized_workspace,
            .outputs = .{
                .values = optimized_fused_values[0..size],
                .gradients = optimized_gradients[0 .. size * coordinates],
                .hessians = optimized_hessians[0 .. size * coordinates * coordinates],
                .statuses = optimized_fused_statuses[0..size],
            },
        };
        try reportRuntimeMeasurement(out, .{
            .model = name,
            .point_set = "varied_scan",
            .contribution = "total",
            .capability = "value_gradient_hessian",
            .backend = "optimized_interpreter",
            .shape = "batch_throughput",
            .points = size,
            .workspace_bytes = optimized_fused_layout.bytes,
            .workspace_alignment = optimized_fused_layout.alignment,
            .buffer_bytes = realBufferBytes(
                size,
                coordinates,
                .value_gradient_hessian,
                0,
            ),
            .binding_reused = true,
        }, try measure(io, &optimized_fused));
    }

    const detected_workers = std.Thread.getCpuCount() catch 1;
    const oversubscribed_workers = if (detected_workers <= maximum_benchmark_workers / 2)
        detected_workers * 2
    else
        maximum_benchmark_workers;
    var worker_counts: [3]usize = undefined;
    var worker_count_len: usize = 0;
    for ([_]usize{
        2,
        @min(detected_workers, maximum_benchmark_workers),
        oversubscribed_workers,
    }) |candidate| {
        if (candidate <= 1 or candidate > largest) continue;
        var duplicate = false;
        for (worker_counts[0..worker_count_len]) |existing| {
            duplicate = duplicate or existing == candidate;
        }
        if (!duplicate) {
            worker_counts[worker_count_len] = candidate;
            worker_count_len += 1;
        }
    }
    for ([_]ParallelShape{ .scalar_calls, .batch }) |parallel_shape| {
        for (worker_counts[0..worker_count_len]) |workers| {
            var parallel = ParallelStagedRun{
                .binding = &optimized_value_binding,
                .backgrounds = points,
                .point_count = largest,
                .coordinate_count = coordinates,
                .worker_count = workers,
                .shape = parallel_shape,
                .workspace_storage = parallel_workspace[0 .. parallel_workspace_stride * workers],
                .workspace_stride = parallel_workspace_stride,
                .values = optimized_values,
                .statuses = optimized_statuses,
            };
            try reportRuntimeMeasurement(out, .{
                .model = name,
                .point_set = "varied_scan",
                .contribution = "total",
                .capability = "value",
                .backend = "optimized_interpreter",
                .shape = switch (parallel_shape) {
                    .scalar_calls => "caller_parallel_scalar",
                    .batch => "caller_parallel_batch",
                },
                .points = largest,
                .workspace_bytes = parallel_workspace_stride * workers,
                .workspace_alignment = optimized_value_layout.alignment,
                .buffer_bytes = realBufferBytes(largest, coordinates, .value, 0),
                .binding_reused = true,
                .workers = workers,
            }, try measure(io, &parallel));
        }
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
    if (aot_bound) |bound| {
        var aot_binding = AotBindRun{
            .parameters = value_binding.parameters,
            .sink = bound,
        };
        try reportControlMeasurement(
            out,
            "aot_binding",
            try measure(io, &aot_binding),
        );
    }

    try out.writeAll(
        "\nleaf\tshape\tmedian ns/unit\tmin ns/unit\tmax ns/unit\trepetitions\tunits/repetition\n",
    );
    var validation = ValidationRun{
        .kernel = &value_kernel,
        .parameters = value_binding.parameters,
        .scales = value_binding.scales,
        .workspace = workspace,
    };
    try reportLeafMeasurement(
        out,
        "complete_call_validation",
        "zero_point_valid_call",
        try measure(io, &validation),
    );

    const parameter_frame = try allocator.alignedAlloc(
        u8,
        .of(Scalar),
        value_kernel.program.frame_bytes,
    );
    defer allocator.free(parameter_frame);
    const parameter_scratch = try allocator.alignedAlloc(
        u8,
        .of(Scalar),
        value_kernel.program.scratch_bytes,
    );
    defer allocator.free(parameter_scratch);
    var parameter_stage = ParameterStageRun{
        .program = &value_kernel.program,
        .parameters = value_binding.parameters,
        .scales = value_binding.scales,
        .frame = parameter_frame,
        .scratch = parameter_scratch,
    };
    try reportLeafMeasurement(
        out,
        "parameter_stage_execution",
        "validated_program",
        try measure(io, &parameter_stage),
    );

    const diagnostic_batch = bounded_batch_sizes[
        bounded_batch_sizes.len - 1
    ];
    var background_stage = StagedRun{
        .binding = &value_binding,
        .backgrounds = points[0 .. diagnostic_batch * coordinates],
        .point_count = diagnostic_batch,
        .workspace = workspace,
        .outputs = .{
            .values = values[0..diagnostic_batch],
            .statuses = statuses[0..diagnostic_batch],
        },
    };
    try reportLeafMeasurement(
        out,
        "bound_background_stage",
        "points=1024_includes_call_validation_and_publication",
        try measure(io, &background_stage),
    );
}

const PointSet = enum {
    positive_scan,
    branch_scan,
};

const OneLoopCase = enum {
    one_by_one,
    two_by_two,
    three_by_three,

    fn fillPoint(
        self: OneLoopCase,
        set: PointSet,
        index: usize,
        point: []Scalar,
    ) void {
        switch (self) {
            .one_by_one => {
                point[0] = switch (set) {
                    .positive_scan => 1.25 +
                        @as(Scalar, @floatFromInt(index % 257)) / 128.0,
                    .branch_scan => ([_]Scalar{
                        0, 0.5, 1, 1.5, -0.5, -1, -1.5,
                    })[index % 7],
                };
            },
            .two_by_two => switch (set) {
                .positive_scan => {
                    point[0] = 280 +
                        @as(Scalar, @floatFromInt(index % 257)) * 0.5;
                    point[1] = 40 +
                        @as(Scalar, @floatFromInt((index * 17) % 193)) * 0.25;
                },
                .branch_scan => {
                    point[0] = -60 +
                        @as(Scalar, @floatFromInt(index % 241)) * 0.5;
                    point[1] = -45 +
                        @as(Scalar, @floatFromInt((index * 29) % 181)) * 0.5;
                },
            },
            .three_by_three => {
                point[0] = switch (set) {
                    .positive_scan => 0.25 +
                        @as(Scalar, @floatFromInt(index % 257)) / 64.0,
                    .branch_scan => ([_]Scalar{
                        -2, -1, -0.5, 0, 0.5, 1, 2,
                    })[index % 7],
                };
            },
        }
    }

    fn spectrum(
        self: OneLoopCase,
        parameters: []const Scalar,
        background: []const Scalar,
        storage: *[3]Scalar,
    ) []const Scalar {
        switch (self) {
            .one_by_one => {
                storage[0] = parameters[1] +
                    (0.5 * parameters[0]) * background[0] * background[0];
                return storage[0..1];
            },
            .two_by_two => {
                const h = background[0];
                const s = background[1];
                const hh =
                    parameters[9] +
                    parameters[0] * h +
                    parameters[1] * s +
                    (0.5 * parameters[7]) * h * h +
                    (parameters[6] * h) * s +
                    (0.5 * parameters[5]) * s * s;
                const hs =
                    parameters[10] +
                    parameters[1] * h +
                    parameters[2] * s +
                    (0.5 * parameters[6]) * h * h +
                    (parameters[5] * h) * s +
                    (0.5 * parameters[4]) * s * s;
                const ss =
                    parameters[11] +
                    parameters[2] * h +
                    parameters[3] * s +
                    (0.5 * parameters[5]) * h * h +
                    (parameters[4] * h) * s +
                    (0.5 * parameters[8]) * s * s;
                const middle = 0.5 * (hh + ss);
                const radius = std.math.hypot(0.5 * (hh - ss), hs);
                storage[0] = middle - radius;
                storage[1] = middle + radius;
                return storage[0..2];
            },
            .three_by_three => {
                const b = background[0];
                if (b >= 0) {
                    storage.* = .{ 9 * b, 36 * b, 81 * b };
                } else {
                    storage.* = .{ 81 * b, 36 * b, 9 * b };
                }
                return storage[0..3];
            },
        }
    }
};

/// Representative scalar one-loop matrix sizes. Each uses varied positive and
/// branch-covering scans; the 2x2 fixture fills the gap between the direct 1x1
/// path and cyclic-Jacobi 3x3 path.
const OneLoopWorkload = struct {
    name: []const u8,
    case: OneLoopCase,
    model_source: []const u8,
    request_source: []const u8,
    point_source: []const u8,
    direct: DirectLoopBaseline,
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

const multi_scalar_one_loop_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
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

/// `m2 = -1`, `lambda = 2`, so the one-by-one spectrum `phi^2 - 1`
/// crosses the negative, exact-zero, and positive branches in one fixed model.
const phi4_one_loop_point =
    \\{"schema":"phaser.parameter-point/0.1",
    \\"units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":2.0},
    \\"values":{"lambda":2.0,"m2":-1.0,"omega":0.0}}
;

const one_loop_workloads = [_]OneLoopWorkload{
    .{
        .name = "phi4_one_loop_1x1",
        .case = .one_by_one,
        .model_source = example_data.phi4_model,
        .request_source = example_data.phi4_one_loop_request,
        .point_source = phi4_one_loop_point,
        .direct = phi4_one_loop_direct,
        .scale = 2,
    },
    .{
        .name = "multi_scalar_one_loop_2x2",
        .case = .two_by_two,
        .model_source = example_data.multi_scalar_model,
        .request_source = multi_scalar_one_loop_request,
        .point_source = example_data.multi_scalar_point,
        .direct = multi_scalar_one_loop_direct,
        .scale = 125,
    },
    .{
        .name = "three_scalar_one_loop_3x3",
        .case = .three_by_three,
        .model_source = oracle_fixture.three_scalar_model,
        .request_source = three_scalar_slice_request,
        .point_source = three_scalar_point,
        .direct = three_scalar_one_loop_direct,
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
    var optimized_value_kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value,
        .selection = .{ .role = .scalar_one_loop },
        .backend = .optimized_interpreter,
    });
    defer optimized_value_kernel.deinit();
    var optimized_fused_kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value_gradient_hessian,
        .selection = .{ .role = .scalar_one_loop },
        .backend = .optimized_interpreter,
    });
    defer optimized_fused_kernel.deinit();

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
    var optimized_value_binding = try kernel_module.bind(
        allocator,
        &optimized_value_kernel,
        &model,
        &point,
    );
    defer optimized_value_binding.deinit();
    var optimized_fused_binding = try kernel_module.bind(
        allocator,
        &optimized_fused_kernel,
        &model,
        &point,
    );
    defer optimized_fused_binding.deinit();
    try workload.direct.verifyChannels(&value_kernel);
    if (value_binding.scales.len != 1 or value_binding.scales[0] != workload.scale) {
        return error.OneLoopScaleMismatch;
    }

    const coordinates = value_kernel.coordinateCount();
    try reportProgram(out, "value", &value_kernel.program);
    try reportProgram(out, "fused", &fused_kernel.program);

    const largest = largestBatchSize();
    const positive_points = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(positive_points);
    const branch_points = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(branch_points);
    fillOneLoopPoints(workload.case, .positive_scan, coordinates, positive_points);
    fillOneLoopPoints(workload.case, .branch_scan, coordinates, branch_points);

    const value_layout = value_binding.workspaceLayout(largest);
    const fused_layout = fused_binding.workspaceLayout(largest);
    const optimized_value_layout = optimized_value_binding.workspaceLayout(largest);
    const optimized_fused_layout = optimized_fused_binding.workspaceLayout(largest);
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
    const optimized_workspace = try allocator.alignedAlloc(
        u8,
        .of(@Vector(2, Scalar)),
        @max(optimized_value_layout.bytes, optimized_fused_layout.bytes),
    );
    defer allocator.free(optimized_workspace);

    const values = try allocator.alloc(Complex64, largest);
    defer allocator.free(values);
    const fused_values = try allocator.alloc(Complex64, largest);
    defer allocator.free(fused_values);
    const optimized_values = try allocator.alloc(Complex64, largest);
    defer allocator.free(optimized_values);
    const optimized_fused_values = try allocator.alloc(Complex64, largest);
    defer allocator.free(optimized_fused_values);
    const gradients = try allocator.alloc(Complex64, largest * coordinates);
    defer allocator.free(gradients);
    const optimized_gradients = try allocator.alloc(Complex64, largest * coordinates);
    defer allocator.free(optimized_gradients);
    const hessians = try allocator.alloc(
        Complex64,
        largest * coordinates * coordinates,
    );
    defer allocator.free(hessians);
    const optimized_hessians = try allocator.alloc(
        Complex64,
        largest * coordinates * coordinates,
    );
    defer allocator.free(optimized_hessians);
    const statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(statuses);
    const fused_statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(fused_statuses);
    const optimized_statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(optimized_statuses);
    const optimized_fused_statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(optimized_fused_statuses);
    const direct_values = try allocator.alloc(DirectComplex64, largest);
    defer allocator.free(direct_values);
    const direct_statuses = try allocator.alloc(u8, largest);
    defer allocator.free(direct_statuses);

    try value_binding.evaluateComplex(positive_points, largest, workspace, .{
        .values = values,
        .statuses = statuses,
    });
    try fused_binding.evaluateComplex(positive_points, largest, workspace, .{
        .values = fused_values,
        .gradients = gradients,
        .hessians = hessians,
        .statuses = fused_statuses,
    });
    try optimized_value_binding.evaluateComplex(
        positive_points,
        largest,
        optimized_workspace,
        .{
            .values = optimized_values,
            .statuses = optimized_statuses,
        },
    );
    try optimized_fused_binding.evaluateComplex(
        positive_points,
        largest,
        optimized_workspace,
        .{
            .values = optimized_fused_values,
            .gradients = optimized_gradients,
            .hessians = optimized_hessians,
            .statuses = optimized_fused_statuses,
        },
    );
    workload.direct.kind.evaluateBatch(
        value_binding.parameters.ptr,
        positive_points.ptr,
        workload.scale,
        largest,
        direct_values.ptr,
        direct_statuses.ptr,
    );
    try verifyOneLoopBatch(
        workload,
        value_binding.parameters,
        positive_points,
        coordinates,
        values,
        statuses,
        direct_values,
        direct_statuses,
        fused_values,
        fused_statuses,
    );
    if (!complexSlicesEqual(values, optimized_values) or
        !complexSlicesEqual(fused_values, optimized_fused_values) or
        !complexSlicesEqual(gradients, optimized_gradients) or
        !complexSlicesEqual(hessians, optimized_hessians) or
        !std.mem.eql(kernel_module.Status, statuses, optimized_statuses) or
        !std.mem.eql(
            kernel_module.Status,
            fused_statuses,
            optimized_fused_statuses,
        ))
    {
        return error.OptimizedVerificationFailed;
    }

    try value_binding.evaluateComplex(branch_points, largest, workspace, .{
        .values = values,
        .statuses = statuses,
    });
    try optimized_value_binding.evaluateComplex(
        branch_points,
        largest,
        optimized_workspace,
        .{
            .values = optimized_values,
            .statuses = optimized_statuses,
        },
    );
    if (!complexSlicesEqual(values, optimized_values) or
        !std.mem.eql(kernel_module.Status, statuses, optimized_statuses))
    {
        return error.OptimizedVerificationFailed;
    }
    workload.direct.kind.evaluateBatch(
        value_binding.parameters.ptr,
        branch_points.ptr,
        workload.scale,
        largest,
        direct_values.ptr,
        direct_statuses.ptr,
    );
    try verifyOneLoopBatch(
        workload,
        value_binding.parameters,
        branch_points,
        coordinates,
        values,
        statuses,
        direct_values,
        direct_statuses,
        null,
        null,
    );

    try writeRuntimeHeader(out);

    var direct_scalar = DirectLoopRun{
        .baseline = workload.direct,
        .parameters = value_binding.parameters,
        .backgrounds = positive_points[0..coordinates],
        .scale = workload.scale,
        .point_count = 1,
        .coordinate_count = coordinates,
    };
    try reportRuntimeMeasurement(out, .{
        .model = workload.name,
        .point_set = "positive_scan",
        .contribution = "scalar_one_loop",
        .capability = "value",
        .backend = "direct_c",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = 0,
        .workspace_alignment = 1,
        .buffer_bytes = directLoopBufferBytes(
            1,
            coordinates,
            workload.direct.parameter_names.len,
        ),
        .binding_reused = true,
    }, try measure(io, &direct_scalar));

    var scalar_value = ComplexStagedRun{
        .binding = &value_binding,
        .backgrounds = positive_points[0..coordinates],
        .point_count = 1,
        .workspace = workspace,
        .outputs = .{ .values = values[0..1], .statuses = statuses[0..1] },
    };
    try reportRuntimeMeasurement(out, .{
        .model = workload.name,
        .point_set = "positive_scan",
        .contribution = "scalar_one_loop",
        .capability = "value",
        .backend = "reference_interpreter",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = value_layout.bytes,
        .workspace_alignment = value_layout.alignment,
        .buffer_bytes = complexBufferBytes(1, coordinates, .value),
        .binding_reused = true,
    }, try measure(io, &scalar_value));

    var optimized_scalar_value = ComplexStagedRun{
        .binding = &optimized_value_binding,
        .backgrounds = positive_points[0..coordinates],
        .point_count = 1,
        .workspace = optimized_workspace,
        .outputs = .{
            .values = optimized_values[0..1],
            .statuses = optimized_statuses[0..1],
        },
    };
    try reportRuntimeMeasurement(out, .{
        .model = workload.name,
        .point_set = "positive_scan",
        .contribution = "scalar_one_loop",
        .capability = "value",
        .backend = "optimized_interpreter",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = optimized_value_layout.bytes,
        .workspace_alignment = optimized_value_layout.alignment,
        .buffer_bytes = complexBufferBytes(1, coordinates, .value),
        .binding_reused = true,
    }, try measure(io, &optimized_scalar_value));

    var scalar_fused = ComplexStagedRun{
        .binding = &fused_binding,
        .backgrounds = positive_points[0..coordinates],
        .point_count = 1,
        .workspace = workspace,
        .outputs = .{
            .values = fused_values[0..1],
            .gradients = gradients[0..coordinates],
            .hessians = hessians[0 .. coordinates * coordinates],
            .statuses = fused_statuses[0..1],
        },
    };
    try reportRuntimeMeasurement(out, .{
        .model = workload.name,
        .point_set = "positive_scan",
        .contribution = "scalar_one_loop",
        .capability = "value_gradient_hessian",
        .backend = "reference_interpreter",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = fused_layout.bytes,
        .workspace_alignment = fused_layout.alignment,
        .buffer_bytes = complexBufferBytes(
            1,
            coordinates,
            .value_gradient_hessian,
        ),
        .binding_reused = true,
    }, try measure(io, &scalar_fused));

    var optimized_scalar_fused = ComplexStagedRun{
        .binding = &optimized_fused_binding,
        .backgrounds = positive_points[0..coordinates],
        .point_count = 1,
        .workspace = optimized_workspace,
        .outputs = .{
            .values = optimized_fused_values[0..1],
            .gradients = optimized_gradients[0..coordinates],
            .hessians = optimized_hessians[0 .. coordinates * coordinates],
            .statuses = optimized_fused_statuses[0..1],
        },
    };
    try reportRuntimeMeasurement(out, .{
        .model = workload.name,
        .point_set = "positive_scan",
        .contribution = "scalar_one_loop",
        .capability = "value_gradient_hessian",
        .backend = "optimized_interpreter",
        .shape = "scalar_throughput",
        .points = 1,
        .workspace_bytes = optimized_fused_layout.bytes,
        .workspace_alignment = optimized_fused_layout.alignment,
        .buffer_bytes = complexBufferBytes(
            1,
            coordinates,
            .value_gradient_hessian,
        ),
        .binding_reused = true,
    }, try measure(io, &optimized_scalar_fused));

    for ([_]PointSet{ .positive_scan, .branch_scan }) |set| {
        const points = switch (set) {
            .positive_scan => positive_points,
            .branch_scan => branch_points,
        };
        for (selectedBatchSizes()) |size| {
            var direct_batch = DirectLoopBatchRun{
                .baseline = workload.direct,
                .parameters = value_binding.parameters,
                .backgrounds = points[0 .. size * coordinates],
                .scale = workload.scale,
                .point_count = size,
                .values = direct_values[0..size],
                .statuses = direct_statuses[0..size],
            };
            try reportRuntimeMeasurement(out, .{
                .model = workload.name,
                .point_set = @tagName(set),
                .contribution = "scalar_one_loop",
                .capability = "value",
                .backend = "direct_c",
                .shape = "batch_throughput",
                .points = size,
                .workspace_bytes = 0,
                .workspace_alignment = 1,
                .buffer_bytes = directLoopBufferBytes(
                    size,
                    coordinates,
                    workload.direct.parameter_names.len,
                ),
                .binding_reused = true,
            }, try measure(io, &direct_batch));

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
            try reportRuntimeMeasurement(out, .{
                .model = workload.name,
                .point_set = @tagName(set),
                .contribution = "scalar_one_loop",
                .capability = "value",
                .backend = "reference_interpreter",
                .shape = "batch_throughput",
                .points = size,
                .workspace_bytes = value_layout.bytes,
                .workspace_alignment = value_layout.alignment,
                .buffer_bytes = complexBufferBytes(size, coordinates, .value),
                .binding_reused = true,
            }, try measure(io, &batch_value));

            var optimized_batch_value = ComplexStagedRun{
                .binding = &optimized_value_binding,
                .backgrounds = points[0 .. size * coordinates],
                .point_count = size,
                .workspace = optimized_workspace,
                .outputs = .{
                    .values = optimized_values[0..size],
                    .statuses = optimized_statuses[0..size],
                },
            };
            try reportRuntimeMeasurement(out, .{
                .model = workload.name,
                .point_set = @tagName(set),
                .contribution = "scalar_one_loop",
                .capability = "value",
                .backend = "optimized_interpreter",
                .shape = "batch_throughput",
                .points = size,
                .workspace_bytes = optimized_value_layout.bytes,
                .workspace_alignment = optimized_value_layout.alignment,
                .buffer_bytes = complexBufferBytes(size, coordinates, .value),
                .binding_reused = true,
            }, try measure(io, &optimized_batch_value));

            if (set == .positive_scan) {
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
                try reportRuntimeMeasurement(out, .{
                    .model = workload.name,
                    .point_set = @tagName(set),
                    .contribution = "scalar_one_loop",
                    .capability = "value_gradient_hessian",
                    .backend = "reference_interpreter",
                    .shape = "batch_throughput",
                    .points = size,
                    .workspace_bytes = fused_layout.bytes,
                    .workspace_alignment = fused_layout.alignment,
                    .buffer_bytes = complexBufferBytes(
                        size,
                        coordinates,
                        .value_gradient_hessian,
                    ),
                    .binding_reused = true,
                }, try measure(io, &batch_fused));

                var optimized_batch_fused = ComplexStagedRun{
                    .binding = &optimized_fused_binding,
                    .backgrounds = points[0 .. size * coordinates],
                    .point_count = size,
                    .workspace = optimized_workspace,
                    .outputs = .{
                        .values = optimized_fused_values[0..size],
                        .gradients = optimized_gradients[0 .. size * coordinates],
                        .hessians = optimized_hessians[0 .. size * coordinates * coordinates],
                        .statuses = optimized_fused_statuses[0..size],
                    },
                };
                try reportRuntimeMeasurement(out, .{
                    .model = workload.name,
                    .point_set = @tagName(set),
                    .contribution = "scalar_one_loop",
                    .capability = "value_gradient_hessian",
                    .backend = "optimized_interpreter",
                    .shape = "batch_throughput",
                    .points = size,
                    .workspace_bytes = optimized_fused_layout.bytes,
                    .workspace_alignment = optimized_fused_layout.alignment,
                    .buffer_bytes = complexBufferBytes(
                        size,
                        coordinates,
                        .value_gradient_hessian,
                    ),
                    .binding_reused = true,
                }, try measure(io, &optimized_batch_fused));
            }
        }
    }
}

fn complexSlicesEqual(left: []const Complex64, right: []const Complex64) bool {
    return left.len == right.len and std.mem.eql(
        u8,
        std.mem.sliceAsBytes(left),
        std.mem.sliceAsBytes(right),
    );
}

fn fillOneLoopPoints(
    case: OneLoopCase,
    set: PointSet,
    coordinate_count: usize,
    points: []Scalar,
) void {
    std.debug.assert(points.len % coordinate_count == 0);
    for (0..points.len / coordinate_count) |index| {
        case.fillPoint(
            set,
            index,
            points[index * coordinate_count ..][0..coordinate_count],
        );
    }
}

fn verifyOneLoopBatch(
    workload: OneLoopWorkload,
    parameters: []const Scalar,
    points: []const Scalar,
    coordinate_count: usize,
    values: []const Complex64,
    statuses: []const kernel_module.Status,
    direct_values: []const DirectComplex64,
    direct_statuses: []const u8,
    fused_values: ?[]const Complex64,
    fused_statuses: ?[]const kernel_module.Status,
) !void {
    const point_count = values.len;
    if (statuses.len != point_count or
        direct_values.len != point_count or
        direct_statuses.len != point_count)
    {
        return error.OneLoopVerificationShapeMismatch;
    }
    if (fused_values) |fused| {
        if (fused.len != point_count or fused_statuses.?.len != point_count) {
            return error.OneLoopVerificationShapeMismatch;
        }
    }

    for (0..point_count) |index| {
        if (statuses[index] != .ok or direct_statuses[index] != 0) {
            return error.StatusVerificationFailed;
        }
        if (fused_statuses) |fused| {
            if (fused[index] != .ok) return error.StatusVerificationFailed;
            if (values[index].re != fused_values.?[index].re or
                values[index].im != fused_values.?[index].im)
            {
                return error.FusedValueVerificationFailed;
            }
        }

        const background =
            points[index * coordinate_count ..][0..coordinate_count];
        var direct_scalar = DirectComplex64{ .re = 0, .im = 0 };
        if (workload.direct.kind.evaluate(
            parameters.ptr,
            background.ptr,
            workload.scale,
            &direct_scalar,
        ) != .ok) {
            return error.DirectOneLoopFailed;
        }
        if (direct_scalar.re != direct_values[index].re or
            direct_scalar.im != direct_values[index].im)
        {
            return error.DirectBatchVerificationFailed;
        }

        var spectrum_storage: [3]Scalar = undefined;
        const eigenvalues = workload.case.spectrum(
            parameters,
            background,
            &spectrum_storage,
        );
        const expected = oneLoopClosedForm(eigenvalues, workload.scale);
        for ([_]struct { expected: Scalar, phaser: Scalar, direct: Scalar, scale: Scalar }{
            .{
                .expected = expected.value.re,
                .phaser = values[index].re,
                .direct = direct_values[index].re,
                .scale = expected.unsigned.re,
            },
            .{
                .expected = expected.value.im,
                .phaser = values[index].im,
                .direct = direct_values[index].im,
                .scale = expected.unsigned.im,
            },
        }) |component| {
            try numerical_comparison.spectral_value_known_spectrum.expectCloseAt(
                component.expected,
                component.phaser,
                .{ .magnitude = component.scale },
            );
            try numerical_comparison.spectral_value_known_spectrum.expectCloseAt(
                component.expected,
                component.direct,
                .{ .magnitude = component.scale },
            );
        }
    }
}

fn reportPublicationLeaf(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
) !void {
    try out.writeAll(
        "\n## publication leaf\n" ++
            "# Leaf rows are diagnostic and are not summed into an end-to-end estimate.\n" ++
            "leaf\tshape\tmedian ns/unit\tmin ns/unit\tmax ns/unit" ++
            "\trepetitions\tunits/repetition\n",
    );

    const publication_count = bounded_batch_sizes[
        bounded_batch_sizes.len - 1
    ];
    const candidates = try allocator.alloc(Complex64, publication_count);
    defer allocator.free(candidates);
    const published = try allocator.alloc(Complex64, publication_count);
    defer allocator.free(published);
    const statuses = try allocator.alloc(
        kernel_module.Status,
        publication_count,
    );
    defer allocator.free(statuses);
    for (candidates, 0..) |*candidate, index| {
        candidate.* = .{
            .re = @floatFromInt(index),
            .im = -@as(Scalar, @floatFromInt(index % 17)),
        };
    }
    var publication = PublicationRun{
        .candidates = candidates,
        .values = published,
        .statuses = statuses,
    };
    try publication.execute(1);
    for (candidates, published, statuses) |candidate, value, status| {
        if (status != .ok or
            candidate.re != value.re or
            candidate.im != value.im)
        {
            return error.PublicationLeafVerificationFailed;
        }
    }
    try reportLeafMeasurement(
        out,
        "finite_status_and_publication",
        "complex_value_points=1024_benchmark_adapter",
        try measure(io, &publication),
    );
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
    var parameter_counts =
        [_]usize{0} ** std.meta.fields(kernel_module.Opcode).len;
    var background_counts =
        [_]usize{0} ** std.meta.fields(kernel_module.Opcode).len;
    for (program.instructions, 0..) |instruction, index| {
        const opcode_index: usize = @intFromEnum(std.meta.activeTag(instruction));
        if (index < program.parameter_stage_count) {
            parameter_counts[opcode_index] += 1;
        } else {
            background_counts[opcode_index] += 1;
        }
    }
    try out.writeAll("program\topcode\tparameter_stage\tbackground_stage\n");
    inline for (std.meta.fields(kernel_module.Opcode), 0..) |field, index| {
        if (parameter_counts[index] != 0 or background_counts[index] != 0) {
            try out.print(
                "{s}\t{s}\t{d}\t{d}\n",
                .{
                    name,
                    field.name,
                    parameter_counts[index],
                    background_counts[index],
                },
            );
        }
    }
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
        repetitions = (try nextCalibrationRepetitions(
            elapsed,
            minimum_sample_ns,
            repetitions,
        )) orelse break;
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

fn nextCalibrationRepetitions(
    elapsed_ns: u64,
    minimum_ns: u64,
    repetitions: usize,
) !?usize {
    if (elapsed_ns >= minimum_ns) return null;
    return std.math.mul(usize, repetitions, 2) catch
        error.MeasurementRepetitionOverflow;
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

fn writeRuntimeHeader(out: *std.Io.Writer) !void {
    try out.writeAll(
        "model\tpoint_set\tcontribution\tcapability\tbackend\tshape\tpoints" ++
            "\tworkspace_bytes\tworkspace_alignment\tbuffer_bytes" ++
            "\tbinding_reused\tworkers\tmedian_ns_per_unit\tmin_ns_per_unit" ++
            "\tmax_ns_per_unit\tunits_per_second\tderived_cycles_per_unit" ++
            "\trepetitions\tunits_per_repetition\n",
    );
}

fn reportRuntimeMeasurement(
    out: *std.Io.Writer,
    metadata: RuntimeMetadata,
    measurement: Measurement,
) !void {
    try out.print(
        "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{s}\t{d}\t",
        .{
            metadata.model,
            metadata.point_set,
            metadata.contribution,
            metadata.capability,
            metadata.backend,
            metadata.shape,
            metadata.points,
            metadata.workspace_bytes,
            metadata.workspace_alignment,
            metadata.buffer_bytes,
            if (metadata.binding_reused) "yes" else "no",
            metadata.workers,
        },
    );
    try writeNanoseconds(out, measurement.median_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.minimum_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.maximum_picoseconds_per_unit);
    const units_per_second = if (measurement.median_picoseconds_per_unit == 0)
        0
    else
        1_000_000_000_000 / measurement.median_picoseconds_per_unit;
    try out.print("\t{d}\t", .{units_per_second});
    if (bench_options.cycles_per_ns > 0) {
        const nanoseconds =
            @as(Scalar, @floatFromInt(measurement.median_picoseconds_per_unit)) /
            1000.0;
        try out.print("{d:.3}", .{nanoseconds * bench_options.cycles_per_ns});
    } else {
        try out.writeByte('-');
    }
    try out.print(
        "\t{d}\t{d}\n",
        .{ measurement.repetitions, measurement.units_per_repetition },
    );
    try out.flush();
}

fn reportLatencyCarrier(
    out: *std.Io.Writer,
    model: []const u8,
    carrier: Measurement,
    staged: Measurement,
    direct: Measurement,
) !void {
    try out.writeAll(
        "# latency_components model backend total_ns carrier_ns net_ns\n",
    );
    for ([_]struct { backend: []const u8, total: Measurement }{
        .{ .backend = "reference_interpreter", .total = staged },
        .{ .backend = "direct_c", .total = direct },
    }) |entry| {
        try out.print(
            "# latency_components {s} {s} ",
            .{ model, entry.backend },
        );
        try writeNanoseconds(out, entry.total.median_picoseconds_per_unit);
        try out.writeByte(' ');
        try writeNanoseconds(out, carrier.median_picoseconds_per_unit);
        try out.writeByte(' ');
        if (entry.total.minimum_picoseconds_per_unit >
            carrier.maximum_picoseconds_per_unit)
        {
            try writeNanoseconds(
                out,
                entry.total.median_picoseconds_per_unit -
                    carrier.median_picoseconds_per_unit,
            );
        } else {
            try out.writeAll(
                "not_reported_overlapping_ranges",
            );
        }
        try out.writeByte('\n');
    }
}

fn directTreeBufferBytes(
    point_count: usize,
    coordinate_count: usize,
    parameter_count: usize,
) usize {
    return (parameter_count + point_count * coordinate_count + point_count) *
        @sizeOf(Scalar);
}

fn directLoopBufferBytes(
    point_count: usize,
    coordinate_count: usize,
    parameter_count: usize,
) usize {
    return (parameter_count + 1 + point_count * coordinate_count) *
        @sizeOf(Scalar) +
        point_count * (@sizeOf(DirectComplex64) + @sizeOf(u8));
}

fn realBufferBytes(
    point_count: usize,
    coordinate_count: usize,
    capability: kernel_module.Capability,
    extra_scalar_inputs: usize,
) usize {
    var scalar_count =
        extra_scalar_inputs + point_count * coordinate_count + point_count;
    if (capability.includesGradient()) {
        scalar_count += point_count * coordinate_count;
    }
    if (capability.includesHessian()) {
        scalar_count += point_count * coordinate_count * coordinate_count;
    }
    return scalar_count * @sizeOf(Scalar) +
        point_count * @sizeOf(kernel_module.Status);
}

fn complexBufferBytes(
    point_count: usize,
    coordinate_count: usize,
    capability: kernel_module.Capability,
) usize {
    var complex_count: usize = point_count;
    if (capability.includesGradient()) {
        complex_count += point_count * coordinate_count;
    }
    if (capability.includesHessian()) {
        complex_count += point_count * coordinate_count * coordinate_count;
    }
    return point_count * coordinate_count * @sizeOf(Scalar) +
        complex_count * @sizeOf(Complex64) +
        point_count * @sizeOf(kernel_module.Status);
}

fn reportLeafMeasurement(
    out: *std.Io.Writer,
    name: []const u8,
    shape: []const u8,
    measurement: Measurement,
) !void {
    try out.print("{s}\t{s}\t", .{ name, shape });
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

test "calibration stops at the minimum and detects repetition overflow" {
    try std.testing.expectEqual(
        @as(?usize, null),
        try nextCalibrationRepetitions(50, 50, 8),
    );
    try std.testing.expectEqual(
        @as(?usize, 16),
        try nextCalibrationRepetitions(49, 50, 8),
    );
    try std.testing.expectError(
        error.MeasurementRepetitionOverflow,
        nextCalibrationRepetitions(0, 1, std.math.maxInt(usize)),
    );
}

test "dependency carrier is deterministic and remains within its interval" {
    for ([_]Scalar{
        0,
        -0.0,
        1,
        -1,
        std.math.inf(Scalar),
        -std.math.inf(Scalar),
        std.math.nan(Scalar),
    }) |value| {
        const first = phaser_bench_dependency_carrier(value, 10, 90);
        const second = phaser_bench_dependency_carrier(value, 10, 90);
        try std.testing.expectEqual(first, second);
        try std.testing.expect(first >= 10);
        try std.testing.expect(first < 100);
    }
}

test "one-loop point sets are deterministic and positive scans stay positive" {
    var first: [2]Scalar = undefined;
    var second: [2]Scalar = undefined;
    OneLoopCase.two_by_two.fillPoint(.positive_scan, 71, &first);
    OneLoopCase.two_by_two.fillPoint(.positive_scan, 71, &second);
    try std.testing.expectEqualSlices(Scalar, &first, &second);

    const parameters = [_]Scalar{
        25,      -5,  2.5,  10, 0.05, 0.1, -0.02, 0.26, 0.3,
        -7812.5, 500, 2500, 0,  0,    0,
    };
    var spectrum_storage: [3]Scalar = undefined;
    const spectrum = OneLoopCase.two_by_two.spectrum(
        &parameters,
        &first,
        &spectrum_storage,
    );
    try std.testing.expect(spectrum[0] > 0);
    try std.testing.expect(spectrum[1] > spectrum[0]);
}

test "direct one-by-one scalar and batch paths preserve branches and zero" {
    const parameters = [_]Scalar{ 2, -1, 0 };
    const backgrounds = [_]Scalar{ 0, 1, 2 };
    var batch_values: [3]DirectComplex64 = undefined;
    var statuses: [3]u8 = undefined;
    DirectLoopKind.one_by_one.evaluateBatch(
        &parameters,
        &backgrounds,
        2,
        backgrounds.len,
        &batch_values,
        &statuses,
    );

    for (backgrounds, 0..) |background, index| {
        try std.testing.expectEqual(@as(u8, 0), statuses[index]);
        var scalar_value = DirectComplex64{ .re = 0, .im = 0 };
        try std.testing.expectEqual(
            DirectLoopStatus.ok,
            DirectLoopKind.one_by_one.evaluate(
                &parameters,
                @ptrCast(&background),
                2,
                &scalar_value,
            ),
        );
        try std.testing.expectEqual(scalar_value.re, batch_values[index].re);
        try std.testing.expectEqual(scalar_value.im, batch_values[index].im);

        const eigenvalue = -1 + background * background;
        const expected = oneLoopClosedForm(&.{eigenvalue}, 2);
        try numerical_comparison.spectral_value_known_spectrum.expectCloseAt(
            expected.value.re,
            scalar_value.re,
            .{ .magnitude = expected.unsigned.re },
        );
        try numerical_comparison.spectral_value_known_spectrum.expectCloseAt(
            expected.value.im,
            scalar_value.im,
            .{ .magnitude = expected.unsigned.im },
        );
    }
}

test "direct three-by-three baseline retains negative multiplicity" {
    const parameters = [_]Scalar{ 53, 26, -4, 44, -22, 29 };
    const background = [_]Scalar{-1};
    var direct = DirectComplex64{ .re = 0, .im = 0 };
    try std.testing.expectEqual(
        DirectLoopStatus.ok,
        DirectLoopKind.three_by_three.evaluate(
            &parameters,
            &background,
            3,
            &direct,
        ),
    );
    const expected = oneLoopClosedForm(&.{ -81, -36, -9 }, 3);
    try numerical_comparison.spectral_value_known_spectrum.expectCloseAt(
        expected.value.re,
        direct.re,
        .{ .magnitude = expected.unsigned.re },
    );
    try numerical_comparison.spectral_value_known_spectrum.expectCloseAt(
        expected.value.im,
        direct.im,
        .{ .magnitude = expected.unsigned.im },
    );
}
