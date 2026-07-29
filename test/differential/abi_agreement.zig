//! Differential comparison of the C ABI against the Zig core and against
//! committed command-line output.
//!
//! Milestone 4 Phase A requires that direct Zig, C, and command-line results
//! agree on the models and parameter points the examples already commit. The
//! three paths are compared here on exactly that data.
//!
//! The comparison is bitwise, not approximate, and deliberately so. These are
//! not three implementations of one calculation that might reasonably differ in
//! the last place: they are one implementation reached through three surfaces.
//! Any difference at all means a surface transformed a result on its way out,
//! which is the failure this check exists to find. A tolerance would hide
//! exactly the defect worth catching -- a projected imaginary part, a widened
//! or narrowed float, a status silently rewritten.
//!
//! `examples/phi4/scan_total.tsv` is command-line output, produced by
//! `phaser evaluate` and compared byte for byte by
//! `test/integration/cli_examples.zig`. Reading it here makes the command-line
//! path a real third party rather than an assumed one.

const std = @import("std");
const test_allocator = @import("test_allocator");
const phaser = @import("phaser");
const example_data = @import("example_data");

const calculation = phaser.calculation;
const kernel_module = phaser.kernel;

// --- The C view of the ABI -------------------------------------------------
//
// Declared as a C caller declares it, so this test reaches the same symbols a
// C client links against rather than the Zig functions behind them.

const PhaserContext = opaque {};
const PhaserModel = opaque {};
const PhaserRequest = opaque {};
const PhaserArtifact = opaque {};
const PhaserKernel = opaque {};
const PhaserPoint = opaque {};
const PhaserBinding = opaque {};
const PhaserDiagnostics = opaque {};

const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    invalid_source = 2,
    unsupported = 3,
    limit_exceeded = 4,
    insufficient_space = 5,
    out_of_memory = 6,
    internal = 7,
};

const Complex = extern struct { re: f64, im: f64 };

const ComplexOutputs = extern struct {
    struct_size: u32,
    abi_version: u32,
    values: ?[*]Complex,
    value_count: usize,
    gradients: ?[*]Complex,
    gradient_count: usize,
    hessians: ?[*]Complex,
    hessian_count: usize,
    statuses: ?[*]i32,
    status_count: usize,
};

extern fn phaser_context_create(
    options: ?*const anyopaque,
    out_context: ?*?*PhaserContext,
) callconv(.c) Status;
extern fn phaser_context_destroy(context: ?*PhaserContext) callconv(.c) void;
extern fn phaser_model_load(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_model: ?*?*PhaserModel,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_model_destroy(model: ?*PhaserModel) callconv(.c) void;
extern fn phaser_request_parse(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_request: ?*?*PhaserRequest,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_request_destroy(request: ?*PhaserRequest) callconv(.c) void;
extern fn phaser_artifact_derive(
    context: ?*PhaserContext,
    model: ?*const PhaserModel,
    request: ?*const PhaserRequest,
    out_artifact: ?*?*PhaserArtifact,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_artifact_destroy(artifact: ?*PhaserArtifact) callconv(.c) void;
extern fn phaser_kernel_compile(
    context: ?*PhaserContext,
    artifact: ?*const PhaserArtifact,
    options: ?*const anyopaque,
    out_kernel: ?*?*PhaserKernel,
) callconv(.c) Status;
extern fn phaser_kernel_destroy(kernel: ?*PhaserKernel) callconv(.c) void;
extern fn phaser_point_parse(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_point: ?*?*PhaserPoint,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_point_destroy(point: ?*PhaserPoint) callconv(.c) void;
extern fn phaser_binding_create(
    context: ?*PhaserContext,
    kernel: ?*const PhaserKernel,
    model: ?*const PhaserModel,
    point: ?*const PhaserPoint,
    out_binding: ?*?*PhaserBinding,
) callconv(.c) Status;
extern fn phaser_binding_destroy(binding: ?*PhaserBinding) callconv(.c) void;
extern fn phaser_binding_workspace(
    binding: ?*const PhaserBinding,
    point_count: usize,
    out_bytes: ?*usize,
    out_alignment: ?*usize,
) callconv(.c) Status;
extern fn phaser_evaluate_complex(
    binding: ?*const PhaserBinding,
    backgrounds: ?[*]const f64,
    background_count: usize,
    point_count: usize,
    workspace: ?[*]u8,
    workspace_bytes: usize,
    outputs: ?*ComplexOutputs,
) callconv(.c) Status;

// --- The committed command-line output -------------------------------------

/// One row of `examples/phi4/scan_total.tsv`.
const ScanRow = struct {
    phi: f64,
    value: Complex,
    gradient: Complex,
    status: []const u8,
};

/// Parses the committed scan.
///
/// The command line writes shortest round-tripping decimals, so parsing returns
/// exactly the `f64` that was evaluated. That is what makes a bitwise
/// comparison against this file meaningful rather than merely close.
fn parseScan(allocator: std.mem.Allocator, text: []const u8) ![]ScanRow {
    var rows: std.ArrayList(ScanRow) = .empty;
    errdefer rows.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "phi\t")) continue; // column header

        var fields = std.mem.splitScalar(u8, line, '\t');
        const phi = fields.next() orelse return error.MalformedScan;
        const value_re = fields.next() orelse return error.MalformedScan;
        const value_im = fields.next() orelse return error.MalformedScan;
        const gradient_re = fields.next() orelse return error.MalformedScan;
        const gradient_im = fields.next() orelse return error.MalformedScan;
        const status = fields.next() orelse return error.MalformedScan;

        try rows.append(allocator, .{
            .phi = try std.fmt.parseFloat(f64, phi),
            .value = .{
                .re = try std.fmt.parseFloat(f64, value_re),
                .im = try std.fmt.parseFloat(f64, value_im),
            },
            .gradient = .{
                .re = try std.fmt.parseFloat(f64, gradient_re),
                .im = try std.fmt.parseFloat(f64, gradient_im),
            },
            .status = std.mem.trimEnd(u8, status, "\r"),
        });
    }
    return rows.toOwnedSlice(allocator);
}

// --- The two live paths ----------------------------------------------------

const Evaluated = struct {
    values: []Complex,
    gradients: []Complex,
    statuses: []i32,

    fn deinit(self: *Evaluated, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        allocator.free(self.gradients);
        allocator.free(self.statuses);
    }
};

/// Evaluates the committed phi4 one-loop calculation through the C ABI.
fn evaluateThroughAbi(
    allocator: std.mem.Allocator,
    backgrounds: []const f64,
) !Evaluated {
    var context: ?*PhaserContext = null;
    try std.testing.expectEqual(Status.ok, phaser_context_create(null, &context));
    defer phaser_context_destroy(context);

    var model: ?*PhaserModel = null;
    try std.testing.expectEqual(Status.ok, phaser_model_load(
        context,
        example_data.phi4_model.ptr,
        example_data.phi4_model.len,
        &model,
        null,
    ));
    defer phaser_model_destroy(model);

    var request: ?*PhaserRequest = null;
    try std.testing.expectEqual(Status.ok, phaser_request_parse(
        context,
        example_data.phi4_one_loop_request.ptr,
        example_data.phi4_one_loop_request.len,
        &request,
        null,
    ));
    defer phaser_request_destroy(request);

    var artifact: ?*PhaserArtifact = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_derive(context, model, request, &artifact, null),
    );
    defer phaser_artifact_destroy(artifact);

    var kernel: ?*PhaserKernel = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_compile(context, artifact, null, &kernel),
    );
    defer phaser_kernel_destroy(kernel);

    var point: ?*PhaserPoint = null;
    try std.testing.expectEqual(Status.ok, phaser_point_parse(
        context,
        example_data.phi4_point.ptr,
        example_data.phi4_point.len,
        &point,
        null,
    ));
    defer phaser_point_destroy(point);

    var binding: ?*PhaserBinding = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_binding_create(context, kernel, model, point, &binding),
    );
    defer phaser_binding_destroy(binding);

    const point_count = backgrounds.len;
    var required: usize = 0;
    var alignment: usize = 0;
    try std.testing.expectEqual(Status.ok, phaser_binding_workspace(
        binding,
        point_count,
        &required,
        &alignment,
    ));
    try std.testing.expect(alignment <= 64);
    const workspace = try allocator.alignedAlloc(u8, .@"64", required);
    defer allocator.free(workspace);

    const values = try allocator.alloc(Complex, point_count);
    errdefer allocator.free(values);
    const gradients = try allocator.alloc(Complex, point_count);
    errdefer allocator.free(gradients);
    const hessians = try allocator.alloc(Complex, point_count);
    defer allocator.free(hessians);
    const statuses = try allocator.alloc(i32, point_count);
    errdefer allocator.free(statuses);

    var outputs = ComplexOutputs{
        .struct_size = @sizeOf(ComplexOutputs),
        .abi_version = 0,
        .values = values.ptr,
        .value_count = point_count,
        .gradients = gradients.ptr,
        .gradient_count = point_count,
        .hessians = hessians.ptr,
        .hessian_count = point_count,
        .statuses = statuses.ptr,
        .status_count = point_count,
    };
    try std.testing.expectEqual(Status.ok, phaser_evaluate_complex(
        binding,
        backgrounds.ptr,
        backgrounds.len,
        point_count,
        workspace.ptr,
        workspace.len,
        &outputs,
    ));

    return .{ .values = values, .gradients = gradients, .statuses = statuses };
}

/// Evaluates the same calculation through the Zig core, sharing no code with
/// the path above beyond the core itself.
fn evaluateThroughCore(
    allocator: std.mem.Allocator,
    backgrounds: []const f64,
) !Evaluated {
    const context = switch (phaser.Context.init(allocator, .{
        .max_diagnostics = 16,
        .max_related_locations = 32,
    })) {
        .context => |value| value,
        .failure => return error.TestUnexpectedResult,
    };

    var load = switch (try phaser.loadModel(
        context,
        .{ .source_id = try phaser.SourceId.fromUsize(0), .bytes = example_data.phi4_model },
        .{},
    )) {
        .model => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer load.deinit();

    var request = switch (try calculation.parseRequest(
        context,
        .{
            .source_id = try phaser.SourceId.fromUsize(0),
            .bytes = example_data.phi4_one_loop_request,
        },
        .{},
    )) {
        .request => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer request.deinit();

    var artifact = switch (try calculation.deriveEffectivePotential(
        context,
        &load,
        &request,
        .{},
    )) {
        .artifact => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer artifact.deinit();

    var kernel = try kernel_module.compile(allocator, &artifact, .{});
    defer kernel.deinit();

    var point = switch (try calculation.parseParameterPoint(
        context,
        .{ .source_id = try phaser.SourceId.fromUsize(0), .bytes = example_data.phi4_point },
        .{},
    )) {
        .point => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer point.deinit();

    var binding = try kernel_module.bind(allocator, &kernel, &load, &point);
    defer binding.deinit();

    const point_count = backgrounds.len;
    const layout = binding.workspaceLayout(point_count);
    const workspace = try allocator.alignedAlloc(u8, .@"64", layout.bytes);
    defer allocator.free(workspace);

    const core_values = try allocator.alloc(kernel_module.Complex64, point_count);
    defer allocator.free(core_values);
    const core_gradients = try allocator.alloc(kernel_module.Complex64, point_count);
    defer allocator.free(core_gradients);
    const core_hessians = try allocator.alloc(kernel_module.Complex64, point_count);
    defer allocator.free(core_hessians);
    const core_statuses = try allocator.alloc(kernel_module.Status, point_count);
    defer allocator.free(core_statuses);

    try binding.evaluateComplex(backgrounds, point_count, workspace, .{
        .values = core_values,
        .gradients = core_gradients,
        .hessians = core_hessians,
        .statuses = core_statuses,
    });

    const values = try allocator.alloc(Complex, point_count);
    errdefer allocator.free(values);
    const gradients = try allocator.alloc(Complex, point_count);
    errdefer allocator.free(gradients);
    const statuses = try allocator.alloc(i32, point_count);
    errdefer allocator.free(statuses);

    for (core_values, core_gradients, core_statuses, 0..) |value, gradient, status, index| {
        values[index] = .{ .re = value.re, .im = value.im };
        gradients[index] = .{ .re = gradient.re, .im = gradient.im };
        statuses[index] = @intFromEnum(status);
    }

    return .{ .values = values, .gradients = gradients, .statuses = statuses };
}

test "the C ABI, the Zig core, and committed command-line output agree bitwise" {
    const allocator = test_allocator.allocator;

    const rows = try parseScan(allocator, example_data.phi4_total_scan);
    defer allocator.free(rows);
    try std.testing.expect(rows.len > 1);

    const backgrounds = try allocator.alloc(f64, rows.len);
    defer allocator.free(backgrounds);
    for (rows, 0..) |row, index| backgrounds[index] = row.phi;

    var through_abi = try evaluateThroughAbi(allocator, backgrounds);
    defer through_abi.deinit(allocator);
    var through_core = try evaluateThroughCore(allocator, backgrounds);
    defer through_core.deinit(allocator);

    var saw_complex = false;
    var saw_real = false;

    for (rows, 0..) |row, index| {
        // The ABI against the core: one implementation reached two ways.
        try std.testing.expectEqual(through_core.values[index].re, through_abi.values[index].re);
        try std.testing.expectEqual(through_core.values[index].im, through_abi.values[index].im);
        try std.testing.expectEqual(
            through_core.gradients[index].re,
            through_abi.gradients[index].re,
        );
        try std.testing.expectEqual(
            through_core.gradients[index].im,
            through_abi.gradients[index].im,
        );
        try std.testing.expectEqual(through_core.statuses[index], through_abi.statuses[index]);

        // And both against what the command line committed.
        try std.testing.expectEqual(row.value.re, through_abi.values[index].re);
        try std.testing.expectEqual(row.value.im, through_abi.values[index].im);
        try std.testing.expectEqual(row.gradient.re, through_abi.gradients[index].re);
        try std.testing.expectEqual(row.gradient.im, through_abi.gradients[index].im);

        // The status name the command line prints, against the number the ABI
        // publishes. `ok` is zero in both.
        try std.testing.expectEqualStrings("ok", row.status);
        try std.testing.expectEqual(@as(i32, 0), through_abi.statuses[index]);

        if (through_abi.values[index].im != 0.0) saw_complex = true;
        if (through_abi.values[index].im == 0.0) saw_real = true;
    }

    // The scan crosses the sign change of the field-dependent mass-squared, so
    // it exercises both branches. Without this the comparison could pass on a
    // range where the imaginary part happened to be uniformly zero, which would
    // not test the thing most likely to be damaged in transit.
    try std.testing.expect(saw_complex);
    try std.testing.expect(saw_real);
}
