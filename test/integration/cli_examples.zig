//! Golden coverage for the command-line workflows.
//!
//! The committed files under `examples/` are the deliverable the roadmap asks
//! for: equations and sampled potential data that the first Python notebook will
//! consume. These tests assert that the client still produces them byte for
//! byte, so a change to any of them has to be explained rather than
//! regenerated.
//!
//! Commands are called directly rather than through a spawned process, so the
//! comparison covers the output itself and not the shell.

const std = @import("std");
const test_allocator = @import("test_allocator");
const commands = @import("commands");
const example_data = @import("example_data");

fn renderExport(
    model_source: []const u8,
    request_source: []const u8,
    options: commands.ExportOptions,
) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    errdefer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();
    try commands.exportSymbolic(
        test_allocator.allocator,
        model_source,
        request_source,
        options,
        &out.writer,
        &errors.writer,
    );
    try std.testing.expectEqualStrings("", errors.written());
    return out;
}

fn renderEvaluate(
    model_source: []const u8,
    request_source: []const u8,
    point_source: []const u8,
    outputs: commands.Outputs,
    coordinates: usize,
) !std.Io.Writer.Allocating {
    const points = try commands.expandScan(
        test_allocator.allocator,
        coordinates,
        0,
        0,
        600,
        13,
    );
    defer test_allocator.allocator.free(points);

    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    errdefer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();
    try commands.evaluate(
        test_allocator.allocator,
        model_source,
        request_source,
        point_source,
        .{
            .outputs = outputs,
            .format = .tsv,
            .points = points,
            .point_count = 13,
        },
        &out.writer,
        &errors.writer,
    );
    try std.testing.expectEqualStrings("", errors.written());
    return out;
}

test "the phi4 equation workflow reproduces its golden output" {
    var out = try renderExport(
        example_data.phi4_model,
        example_data.phi4_request,
        .{ .target = .phaser, .contributions = true, .gradient = true },
    );
    defer out.deinit();
    try std.testing.expectEqualStrings(example_data.phi4_equations, out.written());
}

test "the phi4 LaTeX workflow reproduces its golden output" {
    var out = try renderExport(
        example_data.phi4_model,
        example_data.phi4_request,
        .{ .target = .latex },
    );
    defer out.deinit();
    try std.testing.expectEqualStrings(
        example_data.phi4_equations_latex,
        out.written(),
    );
}

test "the phi4 scan reproduces its golden sampled data" {
    var out = try renderEvaluate(
        example_data.phi4_model,
        example_data.phi4_request,
        example_data.phi4_point,
        .hessian,
        1,
    );
    defer out.deinit();
    try std.testing.expectEqualStrings(example_data.phi4_scan, out.written());
}

test "the multi-scalar equation workflow reproduces its golden output" {
    var out = try renderExport(
        example_data.multi_scalar_model,
        example_data.multi_scalar_request,
        .{ .target = .phaser, .contributions = true, .gradient = true },
    );
    defer out.deinit();
    try std.testing.expectEqualStrings(
        example_data.multi_scalar_equations,
        out.written(),
    );
}

test "the multi-scalar LaTeX workflow reproduces its golden output" {
    var out = try renderExport(
        example_data.multi_scalar_model,
        example_data.multi_scalar_request,
        .{ .target = .latex },
    );
    defer out.deinit();
    try std.testing.expectEqualStrings(
        example_data.multi_scalar_equations_latex,
        out.written(),
    );
}

test "the multi-scalar scan reproduces its golden sampled data" {
    var out = try renderEvaluate(
        example_data.multi_scalar_model,
        example_data.multi_scalar_request,
        example_data.multi_scalar_point,
        .gradient,
        2,
    );
    defer out.deinit();
    try std.testing.expectEqualStrings(example_data.multi_scalar_scan, out.written());
}

test "the default evaluation format aligns exact values for human readers" {
    const points = [_]f64{ 0, 50, 600 };
    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();

    try commands.evaluate(
        test_allocator.allocator,
        example_data.phi4_model,
        example_data.phi4_request,
        example_data.phi4_point,
        .{ .outputs = .hessian, .points = &points, .point_count = points.len },
        &out.writer,
        &errors.writer,
    );
    try std.testing.expectEqualStrings("", errors.written());

    const expected_table =
        \\phi               value             dV/dphi  d2V/dphidphi  status
        \\---  ------------------  ------------------  ------------  ------
        \\  0                   0                   0       -7812.5      ok
        \\ 50  -9697916.666666666  -385208.3333333333       -7487.5      ok
        \\600            -2250000             4672500       38987.5      ok
        \\
    ;
    try std.testing.expect(std.mem.endsWith(u8, out.written(), expected_table));
}

test "the inspect workflow reproduces its golden output" {
    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();
    try commands.inspect(
        test_allocator.allocator,
        example_data.phi4_model,
        &out.writer,
        &errors.writer,
    );
    // The committed inspection golden carries a leading model banner that the
    // example program adds, so compare the body the command itself emits.
    try std.testing.expect(std.mem.indexOf(
        u8,
        example_data.phi4_inspection,
        out.written(),
    ) != null);
}

test "the sampled data brackets the symmetry breaking minimum" {
    // The gradient changes sign inside the scanned interval, which is the
    // feature the notebook plot is meant to show. Asserting it here keeps the
    // example scientifically meaningful rather than merely reproducible.
    var negative = false;
    var positive_after_negative = false;
    var lines = std.mem.splitScalar(u8, example_data.phi4_scan, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var columns = std.mem.splitScalar(u8, line, '\t');
        _ = columns.next();
        _ = columns.next();
        const gradient_text = columns.next() orelse continue;
        const gradient = std.fmt.parseFloat(f64, gradient_text) catch continue;
        if (gradient < 0) negative = true;
        if (negative and gradient > 0) positive_after_negative = true;
    }
    try std.testing.expect(negative);
    try std.testing.expect(positive_after_negative);
}

test "an invalid model reports diagnostics and fails" {
    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();

    try std.testing.expectError(error.InvalidModel, commands.inspect(
        test_allocator.allocator,
        "{ not json",
        &out.writer,
        &errors.writer,
    ));
    // Failure is reported as structured diagnostics, not free text.
    try std.testing.expect(std.mem.startsWith(u8, errors.written(), "error:"));
    try std.testing.expectEqualStrings("", out.written());
}

test "an unsupported request reports its own diagnostic" {
    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();

    const two_loop =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},
        \\"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":2}}}
    ;
    try std.testing.expectError(error.InvalidRequest, commands.exportSymbolic(
        test_allocator.allocator,
        example_data.phi4_model,
        two_loop,
        .{},
        &out.writer,
        &errors.writer,
    ));
    try std.testing.expect(
        std.mem.indexOf(u8, errors.written(), "unsupported_loop_order") != null,
    );
}

const phi4_one_loop_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

test "an order-one export shows the spectral operation and its scale" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();

    try commands.exportSymbolic(
        std.testing.allocator,
        example_data.phi4_model,
        phi4_one_loop_request,
        .{ .contributions = true },
        &out.writer,
        &errors.writer,
    );

    const text = out.written();
    // The one-loop contribution keeps its spectral operation and mass matrix
    // rather than being diagonalized or expanded.
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "V^(1)[scalar_one_loop](phi; muR) = scalar_one_loop([[m2 + 1/2 * lambda * phi^2]]; muR)",
    ) != null);
    // The truncated total names its truncation and its scale dependence.
    try std.testing.expect(std.mem.indexOf(u8, text, "V^(<=1)(phi; muR) = ") != null);
    try std.testing.expectEqualStrings("", errors.written());
}

test "an order-one evaluation reports that the table has no complex columns" {
    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();

    // The order-one value is numerically available through the library's
    // `Complex64` evaluation method. What this client still lacks is a tabular
    // rendering with separate real and imaginary columns, so it reports a
    // result-type mismatch rather than printing a real projection of a complex
    // result.
    const points = [_]f64{0};
    try std.testing.expectError(error.EvaluationFailed, commands.evaluate(
        test_allocator.allocator,
        example_data.phi4_model,
        phi4_one_loop_request,
        example_data.phi4_point,
        .{ .points = &points, .point_count = 1 },
        &out.writer,
        &errors.writer,
    ));
    try std.testing.expectEqualStrings("", out.written());
}

test "a parameter point missing a value is rejected before evaluation" {
    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();

    const incomplete =
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
        \\"values":{"lambda":0.26}}
    ;
    const points = [_]f64{0.0};
    try std.testing.expectError(error.BindingFailed, commands.evaluate(
        test_allocator.allocator,
        example_data.phi4_model,
        example_data.phi4_request,
        incomplete,
        .{ .outputs = .value, .points = &points, .point_count = 1 },
        &out.writer,
        &errors.writer,
    ));
    try std.testing.expect(
        std.mem.indexOf(u8, errors.written(), "MissingParameterValue") != null,
    );
}
