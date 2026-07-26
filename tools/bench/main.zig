//! Representative performance measurements for the Milestone 2 hot paths.
//!
//! Required by the milestone gate in `docs/architecture/IMPLEMENTATION_ROADMAP.md`
//! §2. Per `DEVELOPMENT_WORKFLOW.md` §11 these measurements are informational on
//! a hosted runner, they are not a merge gate, and outputs are verified before
//! anything is timed.
//!
//! The report also records the derivative-graph node counts that decision 0003
//! committed to measuring, so its revisit trigger rests on data.

const std = @import("std");
const phaser = @import("phaser");
const example_data = @import("example_data");

const calculation = phaser.calculation;
const kernel_module = phaser.kernel;
const Scalar = kernel_module.Scalar;

/// Repetition counts chosen so each measurement runs long enough to be
/// meaningful without making the whole report slow.
const scalar_repetitions = 20_000;
const batch_sizes = [_]usize{ 1, 8, 64, 1024 };
const derivation_repetitions = 200;

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

    fn reset(self: *Timer) void {
        self.start = std.Io.Timestamp.now(self.io, .awake);
    }

    fn read(self: *const Timer) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake);
        const elapsed = now.nanoseconds - self.start.nanoseconds;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }
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
        example_data.phi4_point,
    );
    try reportModel(
        init.gpa,
        init.io,
        out,
        "multi_scalar",
        example_data.multi_scalar_model,
        example_data.multi_scalar_point,
    );
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
    try out.print("# zig {f}\n", .{builtin.zig_version});
    try out.writeAll(
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

fn loadRequest(allocator: std.mem.Allocator) !calculation.Request {
    return switch (try phaser.parseRequest(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(1),
        .bytes = example_data.phi4_request,
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
    return switch (try phaser.deriveClassicalPotential(
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

    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "phi4", .source = example_data.phi4_model },
        .{ .name = "multi_scalar", .source = example_data.multi_scalar_model },
    }) |entry| {
        var model = try loadModel(allocator, entry.source);
        defer model.deinit();
        var request = try loadRequest(allocator);
        defer request.deinit();

        var counts: [3]usize = undefined;
        for ([_]calculation.Derivatives{ .none, .gradient, .gradient_hessian }, 0..) |kind, index| {
            var artifact = try derive(allocator, &model, &request, kind);
            defer artifact.deinit();
            counts[index] = artifact.graph.values.len;
        }
        var coordinates: usize = 0;
        {
            var artifact = try derive(allocator, &model, &request, .none);
            defer artifact.deinit();
            coordinates = artifact.coordinateCount();
        }
        try out.print(
            "{s}\t{d}\t{d}\t{d}\t{d}\n",
            .{ entry.name, coordinates, counts[0], counts[1], counts[2] },
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
    point_source: []const u8,
) !void {
    try out.print("\n## {s}\n", .{name});

    var model = try loadModel(allocator, model_source);
    defer model.deinit();
    var request = try loadRequest(allocator);
    defer request.deinit();
    var artifact = try derive(allocator, &model, &request, .gradient_hessian);
    defer artifact.deinit();
    var kernel = try kernel_module.compile(allocator, &artifact, .{
        .capability = .value_gradient_hessian,
    });
    defer kernel.deinit();

    var point = switch (try phaser.parseParameterPoint(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(2),
        .bytes = point_source,
    }, .{})) {
        .point => |value| value,
        .diagnostics => return error.InvalidParameterPoint,
    };
    defer point.deinit();

    var binding = try kernel_module.bind(allocator, &kernel, &model, &point);
    defer binding.deinit();

    const coordinates = kernel.coordinateCount();
    try out.print(
        "instructions {d}\ttemporary_slots {d}\tparameter_stage {d}\n",
        .{
            kernel.program.instructions.len,
            kernel.program.temporary_count,
            kernel.program.parameter_stage_count,
        },
    );

    // Verify before timing, per the performance workflow: a fast wrong answer is
    // not a measurement of anything useful.
    const largest = batch_sizes[batch_sizes.len - 1];
    const points = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(points);
    for (points, 0..) |*slot, index| {
        slot.* = 10.0 + @as(Scalar, @floatFromInt(index % 97));
    }
    const workspace = try allocator.alignedAlloc(
        u8,
        .of(Scalar),
        binding.workspaceLayout(largest).bytes,
    );
    defer allocator.free(workspace);
    const values = try allocator.alloc(Scalar, largest);
    defer allocator.free(values);
    const gradients = try allocator.alloc(Scalar, largest * coordinates);
    defer allocator.free(gradients);
    const hessians = try allocator.alloc(Scalar, largest * coordinates * coordinates);
    defer allocator.free(hessians);
    const statuses = try allocator.alloc(kernel_module.Status, largest);
    defer allocator.free(statuses);

    try binding.evaluate(points, largest, workspace, .{
        .values = values,
        .gradients = gradients,
        .hessians = hessians,
        .statuses = statuses,
    });
    for (statuses) |status| {
        if (status != .ok) return error.VerificationFailed;
    }
    const reference = values[0];

    // Scalar evaluation, the path an adaptive minimizer uses.
    var timer = Timer.begin(io);
    for (0..scalar_repetitions) |_| {
        try binding.evaluate(points[0..coordinates], 1, workspace, .{
            .values = values[0..1],
            .statuses = statuses[0..1],
        });
    }
    const scalar_ns = timer.read();
    if (values[0] != reference) return error.VerificationFailed;
    try out.print(
        "scalar_value\t{d} ns/point\n",
        .{scalar_ns / scalar_repetitions},
    );

    // Batch evaluation at several sizes, staged through the binding.
    try out.writeAll("batch_size\tstaged ns/point\tunstaged ns/point\n");
    for (batch_sizes) |size| {
        const repetitions = @max(scalar_repetitions / size, 8);

        timer.reset();
        for (0..repetitions) |_| {
            try binding.evaluate(points[0 .. size * coordinates], size, workspace, .{
                .values = values[0..size],
                .statuses = statuses[0..size],
            });
        }
        const staged = timer.read() / (repetitions * size);

        timer.reset();
        for (0..repetitions) |_| {
            try kernel.evaluate(
                .{ .parameters = binding.parameters, .backgrounds = points[0 .. size * coordinates] },
                size,
                workspace,
                .{ .values = values[0..size], .statuses = statuses[0..size] },
            );
        }
        const unstaged = timer.read() / (repetitions * size);

        try out.print("{d}\t{d}\t{d}\n", .{ size, staged, unstaged });
    }

    // Fused derivative evaluation.
    timer.reset();
    for (0..scalar_repetitions) |_| {
        try binding.evaluate(points[0..coordinates], 1, workspace, .{
            .values = values[0..1],
            .gradients = gradients[0..coordinates],
            .hessians = hessians[0 .. coordinates * coordinates],
            .statuses = statuses[0..1],
        });
    }
    const fused_ns = timer.read();
    try out.print(
        "scalar_value_gradient_hessian\t{d} ns/point\n",
        .{fused_ns / scalar_repetitions},
    );

    // Control-plane work, which happens once rather than per point.
    timer.reset();
    for (0..derivation_repetitions) |_| {
        var repeated = try derive(allocator, &model, &request, .gradient_hessian);
        repeated.deinit();
    }
    const derivation_ns = timer.read();
    try out.print(
        "derivation\t{d} ns\n",
        .{derivation_ns / derivation_repetitions},
    );

    timer.reset();
    for (0..derivation_repetitions) |_| {
        var repeated = try kernel_module.compile(allocator, &artifact, .{
            .capability = .value_gradient_hessian,
        });
        repeated.deinit();
    }
    const lowering_ns = timer.read();
    try out.print("lowering\t{d} ns\n", .{lowering_ns / derivation_repetitions});

    timer.reset();
    for (0..derivation_repetitions) |_| {
        var repeated = try kernel_module.bind(allocator, &kernel, &model, &point);
        repeated.deinit();
    }
    const binding_ns = timer.read();
    try out.print("binding\t{d} ns\n", .{binding_ns / derivation_repetitions});
}
