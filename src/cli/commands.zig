//! Command implementations for the Phaser command-line client.
//!
//! Commands take source bytes rather than paths and write to caller-provided
//! writers, so every command is exercised directly by tests without spawning a
//! process. File reading, argument parsing, and exit codes belong to `main.zig`.
//!
//! Output is deterministic: no timestamps, no allocation addresses, no locale
//! dependence, and no terminal-width dependence.

const std = @import("std");
const phaser = @import("phaser");

const calculation = phaser.calculation;
const kernel_module = phaser.kernel;
const symbolic = phaser.symbolic;
const Scalar = kernel_module.Scalar;

pub const Failure = error{
    InvalidModel,
    InvalidRequest,
    InvalidParameterPoint,
    DerivationFailed,
    BindingFailed,
    CompilationFailed,
    EvaluationFailed,
    InvalidArguments,
};

pub const Error = Failure || error{ OutOfMemory, WriteFailed };

/// Outputs an `evaluate` invocation may request.
pub const Outputs = enum {
    value,
    gradient,
    hessian,

    pub fn capability(self: Outputs) kernel_module.Capability {
        return switch (self) {
            .value => .value,
            .gradient => .value_gradient,
            .hessian => .value_gradient_hessian,
        };
    }
};

pub const ExportOptions = struct {
    target: symbolic.Target = .phaser,
    /// Emit each contribution separately in addition to the total.
    contributions: bool = false,
    /// Emit the gradient components.
    gradient: bool = false,
};

pub const EvaluateOptions = struct {
    outputs: Outputs = .value,
    /// Row-major background points, `point_count * coordinate_count` values.
    points: []const Scalar,
    point_count: usize,
};

fn context(allocator: std.mem.Allocator) phaser.Context {
    return switch (phaser.Context.init(allocator, .{
        .max_diagnostics = 32,
        .max_related_locations = 64,
    })) {
        .context => |value| value,
        // Both limits are nonzero constants.
        .failure => unreachable,
    };
}

fn renderDiagnostics(
    diagnostics: phaser.Diagnostics,
    errors: *std.Io.Writer,
) Error!void {
    var owned = diagnostics;
    defer owned.deinit();
    for (owned.items) |diagnostic| {
        diagnostic.render(errors) catch return error.WriteFailed;
        errors.writeByte('\n') catch return error.WriteFailed;
    }
}

fn loadModel(
    allocator: std.mem.Allocator,
    source: []const u8,
    errors: *std.Io.Writer,
) Error!phaser.Model {
    const result = phaser.loadModel(context(allocator), .{
        .source_id = phaser.SourceId.fromUsize(0) catch unreachable,
        .bytes = source,
    }, .{}) catch return error.OutOfMemory;
    return switch (result) {
        .model => |model| model,
        .diagnostics => |diagnostics| {
            try renderDiagnostics(diagnostics, errors);
            return error.InvalidModel;
        },
    };
}

fn loadRequest(
    allocator: std.mem.Allocator,
    source: []const u8,
    errors: *std.Io.Writer,
) Error!calculation.Request {
    const result = phaser.parseRequest(context(allocator), .{
        .source_id = phaser.SourceId.fromUsize(1) catch unreachable,
        .bytes = source,
    }, .{}) catch return error.OutOfMemory;
    return switch (result) {
        .request => |request| request,
        .diagnostics => |diagnostics| {
            try renderDiagnostics(diagnostics, errors);
            return error.InvalidRequest;
        },
    };
}

fn loadPoint(
    allocator: std.mem.Allocator,
    source: []const u8,
    errors: *std.Io.Writer,
) Error!calculation.ParameterPoint {
    const result = phaser.parseParameterPoint(context(allocator), .{
        .source_id = phaser.SourceId.fromUsize(2) catch unreachable,
        .bytes = source,
    }, .{}) catch return error.OutOfMemory;
    return switch (result) {
        .point => |point| point,
        .diagnostics => |diagnostics| {
            try renderDiagnostics(diagnostics, errors);
            return error.InvalidParameterPoint;
        },
    };
}

fn deriveArtifact(
    allocator: std.mem.Allocator,
    model: *const phaser.Model,
    request: *const calculation.Request,
    errors: *std.Io.Writer,
) Error!calculation.Artifact {
    const result = phaser.deriveClassicalPotential(
        context(allocator),
        model,
        request,
        .{},
    ) catch return error.OutOfMemory;
    return switch (result) {
        .artifact => |artifact| artifact,
        .diagnostics => |diagnostics| {
            try renderDiagnostics(diagnostics, errors);
            return error.DerivationFailed;
        },
    };
}

/// Prints the canonical model, its fingerprint, and its declared content.
pub fn inspect(
    allocator: std.mem.Allocator,
    model_source: []const u8,
    out: *std.Io.Writer,
    errors: *std.Io.Writer,
) Error!void {
    var model = try loadModel(allocator, model_source, errors);
    defer model.deinit();
    model.writeInspection(out) catch return error.WriteFailed;
}

/// Prints the derived potential as equations in the selected target notation.
pub fn exportSymbolic(
    allocator: std.mem.Allocator,
    model_source: []const u8,
    request_source: []const u8,
    options: ExportOptions,
    out: *std.Io.Writer,
    errors: *std.Io.Writer,
) Error!void {
    var model = try loadModel(allocator, model_source, errors);
    defer model.deinit();
    var request = try loadRequest(allocator, request_source, errors);
    defer request.deinit();
    var artifact = try deriveArtifact(allocator, &model, &request, errors);
    defer artifact.deinit();

    const render_options = symbolic.Options{ .target = options.target };

    symbolic.writeBackground(&artifact, out) catch return error.WriteFailed;

    if (options.contributions) {
        for (std.meta.tags(calculation.Role)) |role| {
            symbolic.writeContribution(
                &artifact,
                role,
                allocator,
                render_options,
                out,
            ) catch return error.WriteFailed;
            out.writeByte('\n') catch return error.WriteFailed;
        }
    }

    symbolic.writePotential(&artifact, allocator, render_options, out) catch
        return error.WriteFailed;
    out.writeByte('\n') catch return error.WriteFailed;

    if (options.gradient) {
        for (artifact.coordinates, 0..) |_, index| {
            symbolic.writeGradientComponent(
                &artifact,
                index,
                allocator,
                render_options,
                out,
            ) catch return error.WriteFailed;
            out.writeByte('\n') catch return error.WriteFailed;
        }
    }
}

/// Evaluates the potential at the supplied background points.
///
/// The output is a header of comment lines followed by one tab-separated row per
/// point, so it is readable in a terminal and directly loadable as sampled data.
pub fn evaluate(
    allocator: std.mem.Allocator,
    model_source: []const u8,
    request_source: []const u8,
    point_source: []const u8,
    options: EvaluateOptions,
    out: *std.Io.Writer,
    errors: *std.Io.Writer,
) Error!void {
    var model = try loadModel(allocator, model_source, errors);
    defer model.deinit();
    var request = try loadRequest(allocator, request_source, errors);
    defer request.deinit();
    var point = try loadPoint(allocator, point_source, errors);
    defer point.deinit();
    var artifact = try deriveArtifact(allocator, &model, &request, errors);
    defer artifact.deinit();

    var kernel = kernel_module.compile(allocator, &artifact, .{
        .capability = options.outputs.capability(),
    }) catch return error.CompilationFailed;
    defer kernel.deinit();

    var binding = kernel_module.bind(allocator, &kernel, &model, &point) catch |err| {
        errors.print("error:binding:{t}\n", .{err}) catch return error.WriteFailed;
        return error.BindingFailed;
    };
    defer binding.deinit();

    const coordinates = kernel.coordinateCount();
    if (options.points.len != options.point_count * coordinates) {
        errors.print(
            "error:arguments: expected {d} values per point\n",
            .{coordinates},
        ) catch return error.WriteFailed;
        return error.InvalidArguments;
    }

    const workspace = try allocator.alignedAlloc(
        u8,
        .of(Scalar),
        binding.workspaceLayout(options.point_count).bytes,
    );
    defer allocator.free(workspace);

    const values = try allocator.alloc(Scalar, options.point_count);
    defer allocator.free(values);
    const gradients = try allocator.alloc(
        Scalar,
        if (options.outputs == .value) 0 else options.point_count * coordinates,
    );
    defer allocator.free(gradients);
    const hessians = try allocator.alloc(
        Scalar,
        if (options.outputs == .hessian)
            options.point_count * coordinates * coordinates
        else
            0,
    );
    defer allocator.free(hessians);
    const statuses = try allocator.alloc(
        kernel_module.Status,
        options.point_count,
    );
    defer allocator.free(statuses);

    binding.evaluate(options.points, options.point_count, workspace, .{
        .values = values,
        .gradients = gradients,
        .hessians = hessians,
        .statuses = statuses,
    }) catch |err| {
        errors.print("error:evaluation:{t}\n", .{err}) catch return error.WriteFailed;
        return error.EvaluationFailed;
    };

    try writeHeader(&artifact, &kernel, &binding, options, out);
    for (0..options.point_count) |index| {
        for (options.points[index * coordinates ..][0..coordinates]) |coordinate| {
            out.print("{d}\t", .{coordinate}) catch return error.WriteFailed;
        }
        out.print("{d}", .{values[index]}) catch return error.WriteFailed;
        if (options.outputs != .value) {
            for (gradients[index * coordinates ..][0..coordinates]) |component| {
                out.print("\t{d}", .{component}) catch return error.WriteFailed;
            }
        }
        if (options.outputs == .hessian) {
            const stride = coordinates * coordinates;
            for (hessians[index * stride ..][0..stride]) |component| {
                out.print("\t{d}", .{component}) catch return error.WriteFailed;
            }
        }
        out.print("\t{s}\n", .{@tagName(statuses[index])}) catch
            return error.WriteFailed;
    }
}

fn writeHeader(
    artifact: *const calculation.Artifact,
    kernel: *const kernel_module.Kernel,
    binding: *const kernel_module.Binding,
    options: EvaluateOptions,
    out: *std.Io.Writer,
) Error!void {
    out.writeAll("# phaser evaluate classical_scalar_potential\n") catch
        return error.WriteFailed;
    out.writeAll("# model_fingerprint ") catch return error.WriteFailed;
    artifact.model_fingerprint.format(out) catch return error.WriteFailed;
    out.writeAll("\n# request_fingerprint ") catch return error.WriteFailed;
    artifact.request_fingerprint.format(out) catch return error.WriteFailed;
    out.print(
        "\n# scheme {s} reference_scale {d}\n",
        .{ @tagName(binding.scheme), binding.reference_scale },
    ) catch return error.WriteFailed;
    out.print(
        "# loop_orders 0 through 0 contributions {d}\n",
        .{artifact.contributions.len},
    ) catch return error.WriteFailed;

    // Column names, so the rows are self-describing.
    for (kernel.coordinates) |channel| {
        out.print("{s}\t", .{channel.name}) catch return error.WriteFailed;
    }
    out.writeAll("value") catch return error.WriteFailed;
    if (options.outputs != .value) {
        for (kernel.coordinates) |channel| {
            out.print("\tdV/d{s}", .{channel.name}) catch return error.WriteFailed;
        }
    }
    if (options.outputs == .hessian) {
        for (kernel.coordinates) |row| {
            for (kernel.coordinates) |column| {
                out.print(
                    "\td2V/d{s}d{s}",
                    .{ row.name, column.name },
                ) catch return error.WriteFailed;
            }
        }
    }
    out.writeAll("\tstatus\n") catch return error.WriteFailed;
}

/// Background dimension of the calculation the sources describe.
///
/// A scan needs the coordinate count before it can expand, and only the derived
/// artifact knows it.
pub fn coordinateCount(
    allocator: std.mem.Allocator,
    model_source: []const u8,
    request_source: []const u8,
    errors: *std.Io.Writer,
) Error!usize {
    var model = try loadModel(allocator, model_source, errors);
    defer model.deinit();
    var request = try loadRequest(allocator, request_source, errors);
    defer request.deinit();
    var artifact = try deriveArtifact(allocator, &model, &request, errors);
    defer artifact.deinit();
    return artifact.coordinateCount();
}

/// Expands `--scan=INDEX:FROM:TO:COUNT` into row-major background points, with
/// every other coordinate held at zero.
pub fn expandScan(
    allocator: std.mem.Allocator,
    coordinates: usize,
    index: usize,
    from: Scalar,
    to: Scalar,
    count: usize,
) error{ OutOfMemory, InvalidArguments }![]Scalar {
    if (count == 0 or index >= coordinates) return error.InvalidArguments;
    const points = try allocator.alloc(Scalar, count * coordinates);
    @memset(points, 0);
    for (0..count) |step| {
        // A single step sits at the interval start, so the spacing is defined
        // for every count.
        const fraction: Scalar = if (count == 1)
            0
        else
            @as(Scalar, @floatFromInt(step)) / @as(Scalar, @floatFromInt(count - 1));
        points[step * coordinates + index] = from + (to - from) * fraction;
    }
    return points;
}

// -- tests -----------------------------------------------------------------

test "a scan expands to evenly spaced points with others held at zero" {
    const points = try expandScan(std.testing.allocator, 2, 0, -1.0, 1.0, 5);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqual(@as(usize, 10), points.len);
    const expected = [_]Scalar{ -1.0, -0.5, 0.0, 0.5, 1.0 };
    for (expected, 0..) |value, step| {
        try std.testing.expectEqual(value, points[step * 2]);
        try std.testing.expectEqual(@as(Scalar, 0), points[step * 2 + 1]);
    }
}

test "a single step scan sits at the interval start" {
    const points = try expandScan(std.testing.allocator, 1, 0, 3.5, 9.0, 1);
    defer std.testing.allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqual(@as(Scalar, 3.5), points[0]);
}

test "an empty or out of range scan is rejected" {
    try std.testing.expectError(
        error.InvalidArguments,
        expandScan(std.testing.allocator, 2, 0, 0, 1, 0),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        expandScan(std.testing.allocator, 2, 5, 0, 1, 3),
    );
}
