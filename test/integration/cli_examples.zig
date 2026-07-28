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

const phi4_one_loop_request = example_data.phi4_one_loop_request;

fn renderOneLoopScan(
    selection: commands.Selection,
) !std.Io.Writer.Allocating {
    const points = try commands.expandScan(
        test_allocator.allocator,
        1,
        0,
        0,
        600,
        13,
    );
    defer test_allocator.allocator.free(points);
    return renderOneLoop(.{
        .outputs = .gradient,
        .format = .tsv,
        .selection = selection,
        .points = points,
        .point_count = 13,
    });
}

test "the phi4 order-one equation workflow reproduces its golden output" {
    var out = try renderExport(
        example_data.phi4_model,
        phi4_one_loop_request,
        .{ .target = .phaser, .contributions = true, .gradient = true },
    );
    defer out.deinit();
    try std.testing.expectEqualStrings(
        example_data.phi4_one_loop_equations,
        out.written(),
    );

    var latex = try renderExport(
        example_data.phi4_model,
        phi4_one_loop_request,
        .{ .target = .latex },
    );
    defer latex.deinit();
    try std.testing.expectEqualStrings(
        example_data.phi4_one_loop_equations_latex,
        latex.written(),
    );
}

test "the three phi4 order-one scans reproduce their golden sampled data" {
    var tree = try renderOneLoopScan(.{ .loop_order = 0 });
    defer tree.deinit();
    try std.testing.expectEqualStrings(
        example_data.phi4_tree_scan,
        tree.written(),
    );

    var loop = try renderOneLoopScan(.{ .loop_order = 1 });
    defer loop.deinit();
    try std.testing.expectEqualStrings(
        example_data.phi4_one_loop_scan,
        loop.written(),
    );

    var total = try renderOneLoopScan(.total);
    defer total.deinit();
    try std.testing.expectEqualStrings(
        example_data.phi4_total_scan,
        total.written(),
    );
}

test "the sampled order-one data is the sum of its sampled parts" {
    // The three files share one background grid, so a plotting client can add
    // the curves point by point. That is only meaningful if the summed file
    // really is the sum, which is what this checks.
    var tree_rows = rowsOf(example_data.phi4_tree_scan);
    var loop_rows = rowsOf(example_data.phi4_one_loop_scan);
    var total_rows = rowsOf(example_data.phi4_total_scan);

    var seen: usize = 0;
    var branch_cut_crossed = false;
    while (tree_rows.next()) |tree_row| {
        const loop_row = loop_rows.next() orelse return error.MissingRow;
        const total_row = total_rows.next() orelse return error.MissingRow;

        // Column 0 is the background; the real tree file then has one value
        // column, and the complex files have a real/imaginary pair.
        try std.testing.expectEqualStrings(
            fieldOf(tree_row, 0),
            fieldOf(total_row, 0),
        );
        const tree_value = try parseField(tree_row, 1);
        const loop_real = try parseField(loop_row, 1);
        const loop_imaginary = try parseField(loop_row, 2);
        const total_real = try parseField(total_row, 1);
        const total_imaginary = try parseField(total_row, 2);

        // The tree part is promoted, not recomputed, so the sum is exact.
        try std.testing.expectEqual(tree_value + loop_real, total_real);
        try std.testing.expectEqual(loop_imaginary, total_imaginary);
        if (loop_imaginary != 0) branch_cut_crossed = true;
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 13), seen);
    try std.testing.expectEqual(@as(?[]const u8, null), loop_rows.next());
    try std.testing.expectEqual(@as(?[]const u8, null), total_rows.next());

    // The scanned interval spans the sign change of the field-dependent
    // mass-squared, so the sampled data exercises both principal branches
    // rather than only the real one.
    try std.testing.expect(branch_cut_crossed);
}

const RowIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn next(self: *RowIterator) ?[]const u8 {
        while (self.lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            // The single header row starts with the coordinate name.
            if (std.mem.startsWith(u8, line, "phi\t")) continue;
            return line;
        }
        return null;
    }
};

fn rowsOf(text: []const u8) RowIterator {
    return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
}

fn fieldOf(row: []const u8, index: usize) []const u8 {
    var columns = std.mem.splitScalar(u8, row, '\t');
    for (0..index) |_| _ = columns.next();
    return columns.next() orelse "";
}

fn parseField(row: []const u8, index: usize) !f64 {
    return std.fmt.parseFloat(f64, fieldOf(row, index));
}

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

fn renderOneLoop(
    options: commands.EvaluateOptions,
) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    errdefer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer errors.deinit();
    try commands.evaluate(
        test_allocator.allocator,
        example_data.phi4_model,
        phi4_one_loop_request,
        example_data.phi4_point,
        options,
        &out.writer,
        &errors.writer,
    );
    try std.testing.expectEqualStrings("", errors.written());
    return out;
}

test "an order-one evaluation reports separate real and imaginary columns" {
    const points = [_]f64{ 0, 200 };
    var out = try renderOneLoop(.{
        .outputs = .gradient,
        .format = .tsv,
        .points = &points,
        .point_count = points.len,
    });
    defer out.deinit();
    const text = out.written();

    // The complex result is reported as exact component pairs rather than as a
    // formatted `a+bi` string a downstream reader would have to split.
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "phi\tvalue.re\tvalue.im\tdV/dphi.re\tdV/dphi.im\tstatus\n",
    ) != null);

    // The header states the conventions the number depends on, so a saved file
    // is readable without the command line that produced it.
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "# phaser evaluate effective_potential\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n# selection total\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "\n# result_type complex64\n") != null,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "# contribution scalar_one_loop formula scalar-vacuum-msbar/1" ++
            " branch arg(-pi,pi] precision binary64 resummation none\n",
    ) != null);

    // At `phi = 0` this model's mass-squared is negative, so the principal
    // branch contributes a nonzero imaginary part that a real projection would
    // have silently discarded.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == 'p') continue;
        var columns = std.mem.splitScalar(u8, line, '\t');
        _ = columns.next();
        _ = columns.next();
        const imaginary = std.fmt.parseFloat(
            f64,
            columns.next() orelse return error.MissingColumn,
        ) catch return error.MissingColumn;
        try std.testing.expect(imaginary > 0);
        break;
    }
}

test "an order-one selection restricts the evaluated contributions" {
    const points = [_]f64{200};
    var total = try renderOneLoop(.{
        .format = .tsv,
        .points = &points,
        .point_count = points.len,
    });
    defer total.deinit();
    var loop = try renderOneLoop(.{
        .format = .tsv,
        .selection = .{ .loop_order = 1 },
        .points = &points,
        .point_count = points.len,
    });
    defer loop.deinit();
    var tree = try renderOneLoop(.{
        .format = .tsv,
        .selection = .{ .loop_order = 0 },
        .points = &points,
        .point_count = points.len,
    });
    defer tree.deinit();

    // A tree-level selection of an order-one request is real, so it has one
    // value column rather than a component pair.
    try std.testing.expect(
        std.mem.indexOf(u8, tree.written(), "\n# result_type real64\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, tree.written(), "phi\tvalue\tstatus\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, tree.written(), "\n# selection loop:0\n") != null,
    );
    // Selecting one loop order lists only that order's contributions.
    try std.testing.expect(
        std.mem.indexOf(u8, loop.written(), "# contribution scalar_one_loop") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, loop.written(), "# contribution scalar_quartic") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, tree.written(), "# contribution scalar_one_loop") == null,
    );

    // The complete truncation is the sum of its parts: its real component is
    // the tree value plus the loop value.
    const tree_value = try lastValue(tree.written(), 1);
    const loop_real = try lastValue(loop.written(), 1);
    const total_real = try lastValue(total.written(), 1);
    try std.testing.expectEqual(tree_value + loop_real, total_real);
}

test "a role selection names exactly one contribution" {
    const points = [_]f64{200};
    var out = try renderOneLoop(.{
        .format = .tsv,
        .selection = .{ .role = .scalar_one_loop },
        .points = &points,
        .point_count = points.len,
    });
    defer out.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "\n# selection role:scalar_one_loop\n",
    ) != null);

    var loop = try renderOneLoop(.{
        .format = .tsv,
        .selection = .{ .loop_order = 1 },
        .points = &points,
        .point_count = points.len,
    });
    defer loop.deinit();
    // This model's only order-one contribution is the scalar loop, so naming
    // the role and naming the order select the same number.
    try std.testing.expectEqual(
        try lastValue(loop.written(), 1),
        try lastValue(out.written(), 1),
    );
}

test "a failed point prints NA rather than an unpublished number" {
    // A non-finite background makes the mass matrix non-finite, so the point
    // publishes nothing at all. The row still exists, and every output column
    // says so instead of showing whatever the buffer happened to hold.
    const points = [_]f64{ 200, std.math.inf(f64) };
    var out = try renderOneLoop(.{
        .outputs = .gradient,
        .format = .tsv,
        .points = &points,
        .point_count = points.len,
    });
    defer out.deinit();
    try std.testing.expect(
        std.mem.endsWith(u8, out.written(), "\tNA\tNA\tNA\tNA\tnon_finite\n"),
    );

    var table = try renderOneLoop(.{
        .outputs = .gradient,
        .points = &points,
        .point_count = points.len,
    });
    defer table.deinit();
    // The aligned rendering keeps the column grid: every unpublished cell is
    // right-aligned `NA` in its own column rather than a collapsed row.
    const rendered = table.written();
    const last = std.mem.trimEnd(u8, rendered, "\n");
    const row = last[std.mem.lastIndexOfScalar(u8, last, '\n').? + 1 ..];
    var fields = std.mem.tokenizeScalar(u8, row, ' ');
    const expected = [_][]const u8{ "inf", "NA", "NA", "NA", "NA", "non_finite" };
    for (expected) |field| {
        try std.testing.expectEqualStrings(
            field,
            fields.next() orelse return error.MissingColumn,
        );
    }
    try std.testing.expectEqual(@as(?[]const u8, null), fields.next());
}

/// The `column`-th numerical field of the last data row of a TSV rendering.
fn lastValue(text: []const u8, column: usize) !f64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var found: ?f64 = null;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == 'p') continue;
        var columns = std.mem.splitScalar(u8, line, '\t');
        for (0..column) |_| _ = columns.next();
        const text_field = columns.next() orelse continue;
        found = std.fmt.parseFloat(f64, text_field) catch continue;
    }
    return found orelse error.MissingColumn;
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
