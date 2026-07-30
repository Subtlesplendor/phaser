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

/// Which contributions an `evaluate` invocation covers.
pub const Selection = kernel_module.Selection;

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

pub const EvaluateFormat = enum {
    /// Aligned columns intended for terminals and logs.
    table,
    /// Exact tab-separated values intended for downstream tools.
    tsv,
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
    format: EvaluateFormat = .table,
    /// Which of the artifact's contributions to evaluate.
    selection: kernel_module.Selection = .total,
    /// Row-major background points, `point_count * coordinate_count` values.
    points: []const Scalar,
    point_count: usize,
};

/// Parses `total`, `loop:<order>`, or `role:<name>` into a kernel selection.
///
/// The spelling belongs here rather than in the argument parser so that the
/// accepted vocabulary is tested directly and cannot drift from the selection
/// the library actually offers.
pub fn parseSelection(text: []const u8) error{InvalidArguments}!kernel_module.Selection {
    if (std.mem.eql(u8, text, "total")) return .total;
    if (std.mem.startsWith(u8, text, "loop:")) {
        const order = std.fmt.parseInt(u32, text["loop:".len..], 10) catch
            return error.InvalidArguments;
        return .{ .loop_order = order };
    }
    if (std.mem.startsWith(u8, text, "role:")) {
        const role = std.meta.stringToEnum(
            calculation.Role,
            text["role:".len..],
        ) orelse return error.InvalidArguments;
        return .{ .role = role };
    }
    return error.InvalidArguments;
}

/// True when `role` belongs to the contribution set `selection` names.
fn selectionCovers(
    selection: kernel_module.Selection,
    role: calculation.Role,
) bool {
    return switch (selection) {
        .total => true,
        .loop_order => |order| role.loopOrder() == order,
        .role => |selected| selected == role,
    };
}

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
    const result = phaser.deriveEffectivePotential(
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
        // Only the roles the request's truncation covers. A role above it was
        // not asked for, and reporting it would imply a decision the artifact
        // never made.
        for (std.meta.tags(calculation.Role)) |role| {
            if (!artifact.roleIsRequested(role)) continue;
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
/// The output is a header of comment lines followed by one row per point.
/// Human-readable aligned columns are the default; callers can request exact
/// tab-separated values for downstream tools.
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
        .selection = options.selection,
    }) catch return error.CompilationFailed;
    defer kernel.deinit();

    var binding = kernel_module.bind(allocator, &kernel, &model, &point) catch |err| {
        errors.print("error:binding:{t}\n", .{err}) catch return error.WriteFailed;
        return error.BindingFailed;
    };
    defer binding.deinit();

    const coordinates = kernel.coordinateCount();
    const background_values = std.math.mul(
        usize,
        options.point_count,
        coordinates,
    ) catch {
        errors.writeAll("error:arguments: point count is too large\n") catch
            return error.WriteFailed;
        return error.InvalidArguments;
    };
    if (options.points.len != background_values) {
        errors.print(
            "error:arguments: expected {d} values per point\n",
            .{coordinates},
        ) catch return error.WriteFailed;
        return error.InvalidArguments;
    }

    try writeMetadata(&artifact, &binding, &kernel, options, out);

    // The result type is a property of the selected contributions, so the
    // buffers a run needs are known before it starts. A loop-containing
    // selection is never projected onto real columns.
    switch (kernel.resultType()) {
        .real64 => try runAndWrite(
            Scalar,
            allocator,
            &kernel,
            &binding,
            options,
            out,
            errors,
        ),
        .complex64 => try runAndWrite(
            kernel_module.Complex64,
            allocator,
            &kernel,
            &binding,
            options,
            out,
            errors,
        ),
    }
}

/// Text printed where a point published no output.
///
/// Publication is point-atomic: a failed point leaves its outputs unwritten,
/// so printing anything numeric there would invent a result the kernel refused
/// to produce.
const unpublished = "NA";

/// Columns one output occupies: a complex output is reported as an exact pair
/// rather than a formatted `a+bi` string a downstream parser would have to
/// split.
fn componentCount(comptime Element: type) usize {
    return if (Element == kernel_module.Complex64) 2 else 1;
}

fn componentSuffix(comptime Element: type, component: usize) []const u8 {
    if (Element != kernel_module.Complex64) return "";
    return if (component == 0) ".re" else ".im";
}

fn componentOf(comptime Element: type, item: Element, component: usize) Scalar {
    if (Element != kernel_module.Complex64) return item;
    return if (component == 0) item.re else item.im;
}

/// Evaluates every point into `Element` buffers and writes the selected format.
fn runAndWrite(
    comptime Element: type,
    allocator: std.mem.Allocator,
    kernel: *const kernel_module.Kernel,
    binding: *kernel_module.Binding,
    options: EvaluateOptions,
    out: *std.Io.Writer,
    errors: *std.Io.Writer,
) Error!void {
    const coordinates = kernel.coordinateCount();
    // Checked above, before any buffer was sized.
    const background_values = options.point_count * coordinates;

    const workspace = try allocator.alignedAlloc(
        u8,
        .of(Scalar),
        binding.workspaceLayout(options.point_count).bytes,
    );
    defer allocator.free(workspace);

    const values = try allocator.alloc(Element, options.point_count);
    defer allocator.free(values);
    const gradients = try allocator.alloc(
        Element,
        if (options.outputs == .value) 0 else background_values,
    );
    defer allocator.free(gradients);
    const hessians = try allocator.alloc(
        Element,
        if (options.outputs == .hessian)
            std.math.mul(usize, background_values, coordinates) catch {
                errors.writeAll("error:arguments: output size is too large\n") catch
                    return error.WriteFailed;
                return error.InvalidArguments;
            }
        else
            0,
    );
    defer allocator.free(hessians);
    const statuses = try allocator.alloc(
        kernel_module.Status,
        options.point_count,
    );
    defer allocator.free(statuses);

    const outcome = if (Element == kernel_module.Complex64)
        binding.evaluateComplex(options.points, options.point_count, workspace, .{
            .values = values,
            .gradients = gradients,
            .hessians = hessians,
            .statuses = statuses,
        })
    else
        binding.evaluate(options.points, options.point_count, workspace, .{
            .values = values,
            .gradients = gradients,
            .hessians = hessians,
            .statuses = statuses,
        });
    outcome catch |err| {
        errors.print("error:evaluation:{t}\n", .{err}) catch return error.WriteFailed;
        return error.EvaluationFailed;
    };

    const rows = Rows(Element){
        .values = values,
        .gradients = gradients,
        .hessians = hessians,
        .statuses = statuses,
    };
    switch (options.format) {
        .table => try writeTable(Element, allocator, kernel, options, rows, out),
        .tsv => try writeTsv(Element, kernel, options, rows, out),
    }
}

/// One evaluated batch, in the element type the selection fixed.
fn Rows(comptime Element: type) type {
    return struct {
        values: []const Element,
        gradients: []const Element,
        hessians: []const Element,
        statuses: []const kernel_module.Status,

        /// Outputs of one point, in column order, or null where the point
        /// published nothing.
        fn value(self: @This(), index: usize) ?Element {
            if (self.statuses[index] != .ok) return null;
            return self.values[index];
        }

        fn gradient(self: @This(), index: usize, coordinates: usize) ?[]const Element {
            if (self.statuses[index] != .ok) return null;
            return self.gradients[index * coordinates ..][0..coordinates];
        }

        fn hessian(self: @This(), index: usize, coordinates: usize) ?[]const Element {
            if (self.statuses[index] != .ok) return null;
            const stride = coordinates * coordinates;
            return self.hessians[index * stride ..][0..stride];
        }
    };
}

fn writeTsv(
    comptime Element: type,
    kernel: *const kernel_module.Kernel,
    options: EvaluateOptions,
    rows: Rows(Element),
    out: *std.Io.Writer,
) Error!void {
    writeColumnNames(Element, kernel, options, "\t", out) catch
        return error.WriteFailed;

    const coordinates = kernel.coordinateCount();
    for (0..options.point_count) |index| {
        for (options.points[index * coordinates ..][0..coordinates]) |coordinate| {
            out.print("{d}\t", .{coordinate}) catch return error.WriteFailed;
        }
        try writeTsvElement(Element, rows.value(index), out, false);
        if (options.outputs != .value) {
            const components = rows.gradient(index, coordinates);
            for (0..coordinates) |position| {
                try writeTsvElement(
                    Element,
                    if (components) |slice| slice[position] else null,
                    out,
                    true,
                );
            }
        }
        if (options.outputs == .hessian) {
            const components = rows.hessian(index, coordinates);
            for (0..coordinates * coordinates) |position| {
                try writeTsvElement(
                    Element,
                    if (components) |slice| slice[position] else null,
                    out,
                    true,
                );
            }
        }
        out.print("\t{s}\n", .{@tagName(rows.statuses[index])}) catch
            return error.WriteFailed;
    }
}

fn writeTsvElement(
    comptime Element: type,
    item: ?Element,
    out: *std.Io.Writer,
    leading_separator: bool,
) Error!void {
    for (0..componentCount(Element)) |component| {
        if (leading_separator or component != 0) {
            out.writeByte('\t') catch return error.WriteFailed;
        }
        if (item) |present| {
            out.print("{d}", .{componentOf(Element, present, component)}) catch
                return error.WriteFailed;
        } else {
            out.writeAll(unpublished) catch return error.WriteFailed;
        }
    }
}

fn writeTable(
    comptime Element: type,
    allocator: std.mem.Allocator,
    kernel: *const kernel_module.Kernel,
    options: EvaluateOptions,
    rows: Rows(Element),
    out: *std.Io.Writer,
) Error!void {
    const coordinates = kernel.coordinateCount();
    const hessian_outputs = if (options.outputs == .hessian)
        std.math.mul(usize, coordinates, coordinates) catch
            return error.InvalidArguments
    else
        0;
    const gradient_outputs = if (options.outputs == .value) 0 else coordinates;
    const outputs = std.math.add(
        usize,
        1,
        std.math.add(usize, gradient_outputs, hessian_outputs) catch
            return error.InvalidArguments,
    ) catch return error.InvalidArguments;
    const output_columns = std.math.mul(usize, outputs, componentCount(Element)) catch
        return error.InvalidArguments;
    const column_count = std.math.add(
        usize,
        std.math.add(usize, coordinates, output_columns) catch
            return error.InvalidArguments,
        1,
    ) catch return error.InvalidArguments;

    const widths = try allocator.alloc(usize, column_count);
    defer allocator.free(widths);

    var column: usize = 0;
    for (kernel.coordinates) |channel| {
        widths[column] = channel.name.len;
        column += 1;
    }
    for (0..componentCount(Element)) |component| {
        widths[column] = std.fmt.count("value{s}", .{
            componentSuffix(Element, component),
        });
        column += 1;
    }
    if (options.outputs != .value) {
        for (kernel.coordinates) |channel| {
            for (0..componentCount(Element)) |component| {
                widths[column] = std.fmt.count("dV/d{s}{s}", .{
                    channel.name,
                    componentSuffix(Element, component),
                });
                column += 1;
            }
        }
    }
    if (options.outputs == .hessian) {
        for (kernel.coordinates) |row| {
            for (kernel.coordinates) |component| {
                for (0..componentCount(Element)) |part| {
                    widths[column] = std.fmt.count("d2V/d{s}d{s}{s}", .{
                        row.name,
                        component.name,
                        componentSuffix(Element, part),
                    });
                    column += 1;
                }
            }
        }
    }
    widths[column] = "status".len;
    std.debug.assert(column + 1 == column_count);

    for (0..options.point_count) |index| {
        column = 0;
        for (options.points[index * coordinates ..][0..coordinates]) |coordinate| {
            widenForNumber(&widths[column], coordinate);
            column += 1;
        }
        widenForElement(Element, widths, &column, rows.value(index));
        if (options.outputs != .value) {
            const components = rows.gradient(index, coordinates);
            for (0..coordinates) |position| {
                widenForElement(
                    Element,
                    widths,
                    &column,
                    if (components) |slice| slice[position] else null,
                );
            }
        }
        if (options.outputs == .hessian) {
            const components = rows.hessian(index, coordinates);
            for (0..coordinates * coordinates) |position| {
                widenForElement(
                    Element,
                    widths,
                    &column,
                    if (components) |slice| slice[position] else null,
                );
            }
        }
        widths[column] = @max(widths[column], @tagName(rows.statuses[index]).len);
        std.debug.assert(column + 1 == column_count);
    }

    column = 0;
    for (kernel.coordinates) |channel| {
        try writeTableSeparator(column, out);
        try writeRightAlignedText(channel.name, widths[column], out);
        column += 1;
    }
    for (0..componentCount(Element)) |component| {
        try writeTableSeparator(column, out);
        try writeRightAlignedLabel(
            widths[column],
            "value{s}",
            .{componentSuffix(Element, component)},
            out,
        );
        column += 1;
    }
    if (options.outputs != .value) {
        for (kernel.coordinates) |channel| {
            for (0..componentCount(Element)) |component| {
                try writeTableSeparator(column, out);
                try writeRightAlignedLabel(
                    widths[column],
                    "dV/d{s}{s}",
                    .{ channel.name, componentSuffix(Element, component) },
                    out,
                );
                column += 1;
            }
        }
    }
    if (options.outputs == .hessian) {
        for (kernel.coordinates) |row| {
            for (kernel.coordinates) |component| {
                for (0..componentCount(Element)) |part| {
                    try writeTableSeparator(column, out);
                    try writeRightAlignedLabel(
                        widths[column],
                        "d2V/d{s}d{s}{s}",
                        .{
                            row.name,
                            component.name,
                            componentSuffix(Element, part),
                        },
                        out,
                    );
                    column += 1;
                }
            }
        }
    }
    try writeTableSeparator(column, out);
    try writeRightAlignedText("status", widths[column], out);
    out.writeByte('\n') catch return error.WriteFailed;

    for (widths, 0..) |width, index| {
        try writeTableSeparator(index, out);
        out.splatByteAll('-', width) catch return error.WriteFailed;
    }
    out.writeByte('\n') catch return error.WriteFailed;

    for (0..options.point_count) |index| {
        column = 0;
        for (options.points[index * coordinates ..][0..coordinates]) |coordinate| {
            try writeTableSeparator(column, out);
            out.print("{d: >[1]}", .{ coordinate, widths[column] }) catch
                return error.WriteFailed;
            column += 1;
        }
        try writeTableElement(Element, widths, &column, rows.value(index), out);
        if (options.outputs != .value) {
            const components = rows.gradient(index, coordinates);
            for (0..coordinates) |position| {
                try writeTableElement(
                    Element,
                    widths,
                    &column,
                    if (components) |slice| slice[position] else null,
                    out,
                );
            }
        }
        if (options.outputs == .hessian) {
            const components = rows.hessian(index, coordinates);
            for (0..coordinates * coordinates) |position| {
                try writeTableElement(
                    Element,
                    widths,
                    &column,
                    if (components) |slice| slice[position] else null,
                    out,
                );
            }
        }
        try writeTableSeparator(column, out);
        out.print(
            "{s: >[1]}",
            .{ @tagName(rows.statuses[index]), widths[column] },
        ) catch return error.WriteFailed;
        out.writeByte('\n') catch return error.WriteFailed;
    }
}

fn widenForElement(
    comptime Element: type,
    widths: []usize,
    column: *usize,
    item: ?Element,
) void {
    for (0..componentCount(Element)) |component| {
        if (item) |present| {
            widenForNumber(
                &widths[column.*],
                componentOf(Element, present, component),
            );
        } else {
            widths[column.*] = @max(widths[column.*], unpublished.len);
        }
        column.* += 1;
    }
}

fn writeTableElement(
    comptime Element: type,
    widths: []const usize,
    column: *usize,
    item: ?Element,
    out: *std.Io.Writer,
) Error!void {
    for (0..componentCount(Element)) |component| {
        try writeTableSeparator(column.*, out);
        if (item) |present| {
            out.print("{d: >[1]}", .{
                componentOf(Element, present, component),
                widths[column.*],
            }) catch return error.WriteFailed;
        } else {
            try writeRightAlignedText(unpublished, widths[column.*], out);
        }
        column.* += 1;
    }
}

fn widenForNumber(width: *usize, value: Scalar) void {
    width.* = @max(width.*, std.fmt.count("{d}", .{value}));
}

fn writeRightAlignedLabel(
    width: usize,
    comptime format: []const u8,
    arguments: anytype,
    out: *std.Io.Writer,
) Error!void {
    const label_width = std.fmt.count(format, arguments);
    out.splatByteAll(' ', width - label_width) catch return error.WriteFailed;
    out.print(format, arguments) catch return error.WriteFailed;
}

fn writeTableSeparator(column: usize, out: *std.Io.Writer) Error!void {
    if (column != 0) out.writeAll("  ") catch return error.WriteFailed;
}

fn writeRightAlignedText(
    text: []const u8,
    width: usize,
    out: *std.Io.Writer,
) Error!void {
    out.splatByteAll(' ', width - text.len) catch return error.WriteFailed;
    out.writeAll(text) catch return error.WriteFailed;
}

fn writeMetadata(
    artifact: *const calculation.Artifact,
    binding: *const kernel_module.Binding,
    kernel: *const kernel_module.Kernel,
    options: EvaluateOptions,
    out: *std.Io.Writer,
) Error!void {
    // The banner names what was evaluated. A truncation at tree level is the
    // classical potential; anything above it is the effective potential.
    const name: []const u8 = if (artifact.loop_order == 0)
        "classical_scalar_potential"
    else
        "effective_potential";
    out.print("# phaser evaluate {s}\n", .{name}) catch return error.WriteFailed;
    out.writeAll("# model_fingerprint ") catch return error.WriteFailed;
    artifact.model_fingerprint.format(out) catch return error.WriteFailed;
    out.writeAll("\n# request_fingerprint ") catch return error.WriteFailed;
    artifact.request_fingerprint.format(out) catch return error.WriteFailed;
    out.print(
        "\n# scheme {s} reference_scale {d}\n",
        .{ @tagName(binding.scheme), binding.reference_scale },
    ) catch return error.WriteFailed;
    out.print(
        "# loop_orders 0 through {d} contributions {d}\n",
        .{ artifact.loop_order, artifact.contributions.len },
    ) catch return error.WriteFailed;

    // A complete tree-level total needs nothing further: it is the only thing
    // such a request can mean, and none of its contributions carries a formula
    // version, branch, or resummation choice to disambiguate. Every other run
    // states which contributions produced the columns and under which
    // conventions, so a saved file is readable without its command line.
    if (artifact.loop_order == 0 and isTotal(options.selection)) return;

    out.writeAll("# selection ") catch return error.WriteFailed;
    try writeSelection(options.selection, out);
    out.print(
        "\n# result_type {s}\n",
        .{@tagName(kernel.resultType())},
    ) catch return error.WriteFailed;
    for (artifact.contributions) |item| {
        if (!selectionCovers(options.selection, item.role)) continue;
        out.print(
            "# contribution {s} formula {s} branch {s} precision {s} resummation {s}\n",
            .{
                @tagName(item.role),
                if (item.provenance.formula_version) |version|
                    version.text()
                else
                    "none",
                if (item.provenance.branch) |branch| branch.text() else "none",
                @tagName(item.provenance.precision),
                @tagName(item.provenance.resummation),
            },
        ) catch return error.WriteFailed;
    }
}

fn isTotal(selection: kernel_module.Selection) bool {
    return switch (selection) {
        .total => true,
        else => false,
    };
}

fn writeSelection(
    selection: kernel_module.Selection,
    out: *std.Io.Writer,
) Error!void {
    switch (selection) {
        .total => out.writeAll("total") catch return error.WriteFailed,
        .loop_order => |order| out.print("loop:{d}", .{order}) catch
            return error.WriteFailed,
        .role => |role| out.print("role:{s}", .{@tagName(role)}) catch
            return error.WriteFailed,
    }
}

fn writeColumnNames(
    comptime Element: type,
    kernel: *const kernel_module.Kernel,
    options: EvaluateOptions,
    separator: []const u8,
    out: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var column: usize = 0;
    for (kernel.coordinates) |channel| {
        if (column != 0) try out.writeAll(separator);
        try out.writeAll(channel.name);
        column += 1;
    }
    for (0..componentCount(Element)) |component| {
        if (column != 0) try out.writeAll(separator);
        try out.print("value{s}", .{componentSuffix(Element, component)});
        column += 1;
    }
    if (options.outputs != .value) {
        for (kernel.coordinates) |channel| {
            for (0..componentCount(Element)) |component| {
                try out.writeAll(separator);
                try out.print("dV/d{s}{s}", .{
                    channel.name,
                    componentSuffix(Element, component),
                });
            }
        }
    }
    if (options.outputs == .hessian) {
        for (kernel.coordinates) |row| {
            for (kernel.coordinates) |component| {
                for (0..componentCount(Element)) |part| {
                    try out.writeAll(separator);
                    try out.print("d2V/d{s}d{s}{s}", .{
                        row.name,
                        component.name,
                        componentSuffix(Element, part),
                    });
                }
            }
        }
    }
    try out.writeAll(separator);
    try out.writeAll("status\n");
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

test "a selection names the total, one loop order, or one role" {
    try std.testing.expectEqual(
        kernel_module.Selection.total,
        try parseSelection("total"),
    );
    try std.testing.expectEqual(
        kernel_module.Selection{ .loop_order = 0 },
        try parseSelection("loop:0"),
    );
    try std.testing.expectEqual(
        kernel_module.Selection{ .loop_order = 1 },
        try parseSelection("loop:1"),
    );
    try std.testing.expectEqual(
        kernel_module.Selection{ .role = .scalar_one_loop },
        try parseSelection("role:scalar_one_loop"),
    );
}

test "an unspelled selection is rejected rather than widened" {
    // Silently falling back to the total would report a different calculation
    // than the one asked for, so every unrecognized spelling is an error.
    for ([_][]const u8{
        "",
        "loop",
        "loop:",
        "loop:-1",
        "loop:x",
        "role:",
        "role:fermion_one_loop",
        "everything",
    }) |text| {
        try std.testing.expectError(
            error.InvalidArguments,
            parseSelection(text),
        );
    }
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

// A two-scalar model, so that a stride or index computation of
// `coordinates * coordinates` (or `index * coordinates`) can diverge from a
// stray `/` in place of `*`: with one coordinate, as `test/integration`'s
// golden phi4 coverage uses throughout, `* 1` and `/ 1` coincide and the
// bug is invisible. This is colocated with `Rows`, `writeTsv`, and
// `writeTable` rather than left to `test/integration/cli_examples.zig`
// because the two live in different test binaries: a source change here is
// noticed by the wider suite, but the mutation campaign's per-mutant test
// selection tries this file's own colocated tests first and stops there if
// they already catch it.
const two_scalar_model =
    \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
    \\"conventions":{"metric":"mostly_plus",
    \\"scalar_representation":"real_components","fermions":"two_component_weyl"},
    \\"parameters":{
    \\"a":{"domain":"real","mass_dimension":1},
    \\"b":{"domain":"real","mass_dimension":1},
    \\"c":{"domain":"real","mass_dimension":1},
    \\"d":{"domain":"real","mass_dimension":1},
    \\"l1":{"domain":"real","mass_dimension":0},
    \\"l2":{"domain":"real","mass_dimension":0},
    \\"l3":{"domain":"real","mass_dimension":0},
    \\"lh":{"domain":"real","mass_dimension":0},
    \\"ls":{"domain":"real","mass_dimension":0},
    \\"m_h2":{"domain":"real","mass_dimension":2},
    \\"m_hs2":{"domain":"real","mass_dimension":2},
    \\"m_s2":{"domain":"real","mass_dimension":2},
    \\"omega":{"domain":"real","mass_dimension":4},
    \\"t_h":{"domain":"real","mass_dimension":3},
    \\"t_s":{"domain":"real","mass_dimension":3}},
    \\"fields":{"real_scalars":[{"id":"h","latex":"h"},{"id":"s","latex":"s"}],
    \\"weyl_fermions":[],"gauge_vectors":[]},
    \\"tensors":{
    \\"vacuum_energy":{"value":"omega"},
    \\"scalar_tadpole":{"components":[
    \\{"indices":["h"],"value":"t_h"},{"indices":["s"],"value":"t_s"}]},
    \\"scalar_mass_squared":{"components":[
    \\{"indices":["h","h"],"value":"m_h2"},
    \\{"indices":["h","s"],"value":"m_hs2"},
    \\{"indices":["s","s"],"value":"m_s2"}]},
    \\"scalar_cubic":{"components":[
    \\{"indices":["h","h","h"],"value":"a"},
    \\{"indices":["h","h","s"],"value":"b"},
    \\{"indices":["h","s","s"],"value":"c"},
    \\{"indices":["s","s","s"],"value":"d"}]},
    \\"scalar_quartic":{"components":[
    \\{"indices":["h","h","h","h"],"value":"lh"},
    \\{"indices":["h","h","h","s"],"value":"l3"},
    \\{"indices":["h","h","s","s"],"value":"l2"},
    \\{"indices":["h","s","s","s"],"value":"l1"},
    \\{"indices":["s","s","s","s"],"value":"ls"}]}}}
;

const two_scalar_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
;

const two_scalar_point =
    \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
    \\"values":{
    \\"a":25.0,"b":-5.0,"c":2.5,"d":10.0,
    \\"l1":0.05,"l2":0.1,"l3":-0.02,"lh":0.26,"ls":0.3,
    \\"m_h2":-7812.5,"m_hs2":500.0,"m_s2":2500.0,
    \\"omega":0,"t_h":0,"t_s":0}}
;

// Hand-derived tree-level Hessian, read off the model and point above:
//
//   V = (m_h2 h^2 + 2 m_hs2 h s + m_s2 s^2) / 2
//     + a h^3/6 + b h^2 s/2 + c h s^2/2 + d s^3/6
//     + lh h^4/24 + l3 h^3 s/6 + l2 h^2 s^2/4 + l1 h s^3/6 + ls s^4/24
//
// so d2V/dh2 = m_h2 + a h + b s + lh/2 h^2 + l3 h s + l2/2 s^2, and the other
// two components follow the same way with (h, s) and the matching
// coefficient pairs swapped.
// Deliberately different orders of magnitude between the two points (one
// digit against three, and a sign) rather than a mere swap: the table
// renderer's width-computation pass reuses `index * coordinates` on its own
// copy of the point loop, distinct from the value-writing pass's copy. A
// wrong index there stays invisible to any check of the printed values
// themselves if every point happens to need the same column width; it only
// shows up as a row whose columns were padded for the wrong point.
const two_scalar_hessian_points = [_]Scalar{ 1, 2, 100, -200 };
// h, s, dhdh, dhds, dsds. The point's own columns are checked alongside the
// Hessian: the point-extraction loop is a separate piece of code from
// `Rows.hessian` (and is itself duplicated between the table renderer's
// width-computation and value-writing passes), so a wrong index there would
// leave the Hessian columns alone and only substitute a different row's `h`
// and `s`.
const two_scalar_expected_rows = [2][5]Scalar{
    .{ 1, 2, -7797.21, 500.29, 2523.25 },
    .{ 100, -200, -612.5, -1600, 6250 },
};

fn expectRowAt(row: []const u8, expected: [5]Scalar) !void {
    // Columns: h, s, value, dV/dh, dV/ds, d2V/dhdh, d2V/dhds, d2V/dsdh,
    // d2V/dsds, status.
    var fields = std.mem.tokenizeAny(u8, row, "\t ");
    const h = try std.fmt.parseFloat(Scalar, fields.next() orelse return error.MissingColumn);
    const s = try std.fmt.parseFloat(Scalar, fields.next() orelse return error.MissingColumn);
    inline for (0..3) |_| _ = fields.next() orelse return error.MissingColumn;
    const dhdh = try std.fmt.parseFloat(Scalar, fields.next() orelse return error.MissingColumn);
    const dhds = try std.fmt.parseFloat(Scalar, fields.next() orelse return error.MissingColumn);
    const dsdh = try std.fmt.parseFloat(Scalar, fields.next() orelse return error.MissingColumn);
    const dsds = try std.fmt.parseFloat(Scalar, fields.next() orelse return error.MissingColumn);
    try std.testing.expectApproxEqAbs(expected[0], h, 1e-6);
    try std.testing.expectApproxEqAbs(expected[1], s, 1e-6);
    try std.testing.expectApproxEqAbs(expected[2], dhdh, 1e-6);
    try std.testing.expectApproxEqAbs(expected[3], dhds, 1e-6);
    try std.testing.expectApproxEqAbs(expected[3], dsdh, 1e-6);
    try std.testing.expectApproxEqAbs(expected[4], dsds, 1e-6);
}

fn dataRows(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, text, '\n');
}

fn nextDataRow(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, "\t ");
        const first = fields.next() orelse continue;
        // The header row and, for the table, its dashed separator, are not
        // numeric; only a data row starts with a parseable coordinate.
        _ = std.fmt.parseFloat(Scalar, first) catch continue;
        return line;
    }
    return null;
}

test "two-coordinate hessian values match a hand-derived formula (tsv)" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try evaluate(
        std.testing.allocator,
        two_scalar_model,
        two_scalar_request,
        two_scalar_point,
        .{
            .outputs = .hessian,
            .format = .tsv,
            .points = &two_scalar_hessian_points,
            .point_count = 2,
        },
        &out.writer,
        &errors.writer,
    );
    try std.testing.expectEqualStrings("", errors.written());

    var lines = dataRows(out.written());
    for (two_scalar_expected_rows) |expected| {
        const row = nextDataRow(&lines) orelse return error.MissingRow;
        try expectRowAt(row, expected);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), nextDataRow(&lines));
}

test "two-coordinate hessian values match a hand-derived formula (table)" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try evaluate(
        std.testing.allocator,
        two_scalar_model,
        two_scalar_request,
        two_scalar_point,
        .{
            .outputs = .hessian,
            .format = .table,
            .points = &two_scalar_hessian_points,
            .point_count = 2,
        },
        &out.writer,
        &errors.writer,
    );
    try std.testing.expectEqualStrings("", errors.written());
    const text = out.written();

    // A fixed-width table pads every column to the widest value across
    // every row, so every rendered line -- header, separator, and each data
    // row -- must come out to the same length. A width computed from the
    // wrong row (as a stray `coordinates / coordinates` collapsing to the
    // first row's data would produce) under-pads a later row instead,
    // without touching the values themselves, which a value-only comparison
    // cannot see but this invariant catches.
    var width_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var rendered_lines: usize = 0;
    var expected_len: ?usize = null;
    while (width_lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (expected_len) |len| {
            try std.testing.expectEqual(len, line.len);
        } else {
            expected_len = line.len;
        }
        rendered_lines += 1;
    }
    // Header, separator, and two data rows.
    try std.testing.expectEqual(@as(usize, 4), rendered_lines);

    var lines = dataRows(text);
    for (two_scalar_expected_rows) |expected| {
        const row = nextDataRow(&lines) orelse return error.MissingRow;
        try expectRowAt(row, expected);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), nextDataRow(&lines));
}
