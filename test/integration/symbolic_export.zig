//! Integration coverage for symbolic export, from a model file through a
//! derived artifact to rendered equations.
//!
//! The expected strings below are golden files in the sense of
//! `DEVELOPMENT_WORKFLOW.md`: a change to any of them must be explained, not
//! regenerated. They are readable enough that a reviewer can check the exact
//! coefficients against the fixture identities by eye, which is the point of
//! this milestone's export surface.

const std = @import("std");
const test_allocator = @import("test_allocator");
const phaser = @import("phaser");
const example_data = @import("example_data");

const symbolic = phaser.symbolic;
const calculation = phaser.calculation;

fn testContext() phaser.Context {
    return switch (phaser.Context.init(test_allocator.allocator, .{
        .max_diagnostics = 16,
        .max_related_locations = 32,
    })) {
        .context => |context| context,
        .failure => unreachable,
    };
}

fn loadModel(source: []const u8) !phaser.Model {
    const result = try phaser.loadModel(testContext(), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = source,
    }, .{ .audit = true });
    return switch (result) {
        .model => |loaded| loaded,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidModel;
        },
    };
}

fn parseRequest(source: []const u8) !calculation.Request {
    const result = try phaser.parseRequest(testContext(), .{
        .source_id = try phaser.SourceId.fromUsize(1),
        .bytes = source,
    }, .{});
    return switch (result) {
        .request => |request| request,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidRequest;
        },
    };
}

fn derive(
    source_model: *const phaser.Model,
    request: *const calculation.Request,
) !calculation.Artifact {
    const result = try phaser.deriveClassicalPotential(
        testContext(),
        source_model,
        request,
        .{ .audit = true },
    );
    return switch (result) {
        .artifact => |artifact| artifact,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.DerivationFailed;
        },
    };
}

const full_space_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},
    \\"orders":{"loop":{"through":0}}}
;

fn renderPotential(
    artifact: *const calculation.Artifact,
    target: symbolic.Target,
) !std.Io.Writer.Allocating {
    var output: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    errdefer output.deinit();
    try symbolic.writePotential(
        artifact,
        test_allocator.allocator,
        .{ .target = target },
        &output.writer,
    );
    return output;
}

test "the phi4 potential renders in Phaser notation" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var output = try renderPotential(&artifact, .phaser);
    defer output.deinit();

    // omega + (m2 / 2) phi^2 + (lambda / 24) phi^4, with the coefficients the
    // orbit rule produces for a single scalar.
    try std.testing.expectEqualStrings(
        "V^(0)(phi) = omega + 1/2 * m2 * phi^2 + 1/24 * lambda * phi^4",
        output.written(),
    );
}

test "the phi4 potential renders as a MathJax fragment" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var output = try renderPotential(&artifact, .latex);
    defer output.deinit();

    try std.testing.expectEqualStrings(
        "V^{(0)}(\\mathrm{phi}) = \\mathrm{omega}" ++
            " + \\frac{1}{2}\\,\\mathrm{m2}\\,\\mathrm{phi}^{2}" ++
            " + \\frac{1}{24}\\,\\mathrm{lambda}\\,\\mathrm{phi}^{4}",
        output.written(),
    );
}

test "the phi4 gradient renders with its exact coefficients" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var output: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer output.deinit();
    try symbolic.writeGradientComponent(
        &artifact,
        0,
        test_allocator.allocator,
        .{ .target = .phaser },
        &output.writer,
    );

    // The fixture tree_gradient: m2 * phi + (lambda / 6) * phi^3.
    try std.testing.expectEqualStrings(
        "dV/dphi = m2 * phi + 1/6 * lambda * phi^3",
        output.written(),
    );
}

test "a structurally absent contribution renders as an explicit zero" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var output: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer output.deinit();
    try symbolic.writeContribution(
        &artifact,
        .scalar_cubic,
        test_allocator.allocator,
        .{ .target = .phaser },
        &output.writer,
    );

    try std.testing.expectEqualStrings(
        "V^(0)[scalar_cubic](phi) = 0  [structurally absent: tensor_absent]",
        output.written(),
    );
}

test "the multi-scalar quartic contribution shows its orbit coefficients" {
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var output: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer output.deinit();
    try symbolic.writeContribution(
        &artifact,
        .scalar_quartic,
        test_allocator.allocator,
        .{ .target = .phaser },
        &output.writer,
    );

    // Every distinct orbit multiplicity appears once, so this line is a direct
    // reading of the coefficient rule: 1/24, 1/6, 1/4, 1/6, 1/24.
    const text = output.written();
    for ([_][]const u8{ "1/24", "1/6", "1/4" }) |coefficient| {
        try std.testing.expect(std.mem.indexOf(u8, text, coefficient) != null);
    }
    // The naive 1/r! rule would put every quartic term over 24.
    try std.testing.expect(std.mem.indexOf(u8, text, "1/4 *") != null);
}

test "a component slice discloses its embedding and fluctuation sector" {
    const slice_request =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"x","scalar":"h"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(slice_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var output: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer output.deinit();
    try symbolic.writeBackground(&artifact, &output.writer);

    const text = output.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "component_slice") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "x -> scalar 0") != null);
    // The export must not imply the unselected scalar left the calculation.
    try std.testing.expect(
        std.mem.indexOf(u8, text, "remains a fluctuation field") != null,
    );
}

test "the artifact summary is bounded and reports its counts" {
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var output: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer output.deinit();
    try symbolic.writeSummary(
        &artifact,
        test_allocator.allocator,
        .{ .target = .phaser, .max_preview_nodes = 4 },
        &output.writer,
    );

    const text = output.written();
    // A tree-only artifact (loop order 0, as this one is) is exactly the
    // classical scalar potential, named as such rather than as the general
    // calculation.
    try std.testing.expect(
        std.mem.indexOf(u8, text, "calculation classical_scalar_potential\n") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "contributions 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "structural_absences 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "loop_orders 0 through 0") != null);
    // Over the preview budget, so the equation is replaced by a visible notice.
    try std.testing.expect(
        std.mem.indexOf(u8, text, "omitted from preview") != null,
    );
}

test "exported Phaser notation round trips for a parameter-only value" {
    // Derived potentials contain background coordinates, which the model
    // expression language does not have, so no round trip is promised for
    // them. A model tensor component is parameter-only, and that subset is
    // deliberately re-parseable.
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();

    var builder = try phaser.value.Builder.init(test_allocator.allocator, .{});
    const component = model.scalarTensorExpression(
        .scalar_mass_squared,
        &.{ 0, 1 },
    ).?;
    const imported = try phaser.value.importExpression(&builder, component);
    var graph = try builder.finish();
    defer graph.deinit();

    const text = try symbolic.renderAlloc(
        &graph,
        imported,
        test_allocator.allocator,
        .{ .target = .phaser },
    );
    defer test_allocator.allocator.free(text);

    const parameters = [_]phaser.expression.Parameter{
        .{ .name = "m_hs2", .id = 10, .mass_dimension = 2 },
    };
    const reparsed = try phaser.expression.parse(
        test_allocator.allocator,
        try phaser.SourceId.fromUsize(2),
        text,
        &parameters,
        .{ .required_dimension = 2 },
    );
    switch (reparsed) {
        .expression => |parsed| {
            var owned = parsed;
            owned.deinit();
        },
        .failure => return error.RoundTripFailed,
    }
}

test "rendering the same artifact twice is byte identical" {
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var first = try renderPotential(&artifact, .latex);
    defer first.deinit();
    var second = try renderPotential(&artifact, .latex);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.written(), second.written());
}

test "independently derived artifacts render identically" {
    // Two derivations allocate different arenas. Because operand order is
    // content-derived, their rendered equations must still agree byte for byte.
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();

    var first_artifact = try derive(&model, &request);
    defer first_artifact.deinit();
    var second_artifact = try derive(&model, &request);
    defer second_artifact.deinit();

    var first = try renderPotential(&first_artifact, .latex);
    defer first.deinit();
    var second = try renderPotential(&second_artifact, .latex);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.written(), second.written());
}

// -- order one --------------------------------------------------------------

const one_loop_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

fn deriveOneLoop(
    source_model: *const phaser.Model,
    request: *const calculation.Request,
) !calculation.Artifact {
    const result = try phaser.deriveEffectivePotential(
        testContext(),
        source_model,
        request,
        .{ .audit = true },
    );
    return switch (result) {
        .artifact => |artifact| artifact,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.DerivationFailed;
        },
    };
}

const OneLoopFixture = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,

    fn init(source: []const u8) !OneLoopFixture {
        var model = try loadModel(source);
        errdefer model.deinit();
        var request = try parseRequest(one_loop_request);
        errdefer request.deinit();
        const artifact = try deriveOneLoop(&model, &request);
        return .{ .model = model, .request = request, .artifact = artifact };
    }

    fn deinit(self: *OneLoopFixture) void {
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }
};

test "the phi4 order-one potential renders in Phaser notation" {
    var fixture = try OneLoopFixture.init(example_data.phi4_model);
    defer fixture.deinit();

    var output = try renderPotential(&fixture.artifact, .phaser);
    defer output.deinit();

    // The heading names the truncation and the scale dependence, the tree terms
    // keep their exact coefficients, and the loop term keeps its named spectral
    // operation over the field-dependent mass matrix `m2 + (lambda/2) phi^2`.
    try std.testing.expectEqualStrings(
        "V^(<=1)(phi; muR) = omega + 1/2 * m2 * phi^2 + 1/24 * lambda * phi^4" ++
            " + scalar_one_loop([[m2 + 1/2 * lambda * phi^2]]; muR)",
        output.written(),
    );
}

test "the phi4 order-one contribution renders with its loop-order heading" {
    var fixture = try OneLoopFixture.init(example_data.phi4_model);
    defer fixture.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try symbolic.writeContribution(
        &fixture.artifact,
        .scalar_one_loop,
        std.testing.allocator,
        .{ .target = .phaser },
        &output.writer,
    );
    try std.testing.expectEqualStrings(
        "V^(1)[scalar_one_loop](phi; muR) = " ++
            "scalar_one_loop([[m2 + 1/2 * lambda * phi^2]]; muR)",
        output.written(),
    );
}

test "the phi4 order-one gradient keeps the invariant spectral derivative" {
    var fixture = try OneLoopFixture.init(example_data.phi4_model);
    defer fixture.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try symbolic.writeGradientComponent(
        &fixture.artifact,
        0,
        std.testing.allocator,
        .{ .target = .phaser },
        &output.writer,
    );
    // The loop term is the background derivative of the invariant spectral
    // value, not a derivative of a sorted eigenvalue.
    try std.testing.expectEqualStrings(
        "dV/dphi = m2 * phi + 1/6 * lambda * phi^3" ++
            " + d[scalar_one_loop([[m2 + 1/2 * lambda * phi^2]]; muR)]/dphi",
        output.written(),
    );
}

test "the phi4 order-one potential renders as a MathJax fragment" {
    var fixture = try OneLoopFixture.init(example_data.phi4_model);
    defer fixture.deinit();

    var output = try renderPotential(&fixture.artifact, .latex);
    defer output.deinit();

    try std.testing.expectEqualStrings(
        "V^{(\\leq 1)}(\\mathrm{phi}; \\mathrm{muR}) = \\mathrm{omega}" ++
            " + \\frac{1}{2}\\,\\mathrm{m2}\\,\\mathrm{phi}^{2}" ++
            " + \\frac{1}{24}\\,\\mathrm{lambda}\\,\\mathrm{phi}^{4}" ++
            " + \\mathrm{Tr}\\,\\Phi^{(1)}_{\\mathrm{scalar}}\\!\\left(" ++
            "\\left(\\begin{array}{c}\\mathrm{m2}" ++
            " + \\frac{1}{2}\\,\\mathrm{lambda}\\,\\mathrm{phi}^{2}" ++
            "\\end{array}\\right); \\mathrm{muR}\\right)",
        output.written(),
    );
}

test "an order-one export is deterministic and carries no delimiters" {
    var fixture = try OneLoopFixture.init(example_data.multi_scalar_model);
    defer fixture.deinit();

    var first = try renderPotential(&fixture.artifact, .latex);
    defer first.deinit();
    var second = try renderPotential(&fixture.artifact, .latex);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.written(), second.written());

    for ([_][]const u8{ "$", "\\(", "\\[", "\\begin{document}", "\\usepackage" }) |forbidden| {
        try std.testing.expect(
            std.mem.indexOf(u8, first.written(), forbidden) == null,
        );
    }
    // A 2x2 fluctuation matrix is rendered as a matrix, not diagonalized.
    try std.testing.expect(
        std.mem.indexOf(u8, first.written(), "\\begin{array}{cc}") != null,
    );
}

test "a complete order-one export fails rather than truncating" {
    var fixture = try OneLoopFixture.init(example_data.phi4_model);
    defer fixture.deinit();

    // The byte budget governs the rendered value, so it is measured against the
    // value alone rather than against the heading the artifact view adds.
    const complete = try symbolic.renderAlloc(
        &fixture.artifact.graph,
        fixture.artifact.total,
        std.testing.allocator,
        .{ .target = .phaser },
    );
    defer std.testing.allocator.free(complete);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try symbolic.writeValue(
        &fixture.artifact.graph,
        fixture.artifact.total,
        std.testing.allocator,
        .{ .target = .phaser, .max_bytes = complete.len },
        &output.writer,
    );
    try std.testing.expectEqualStrings(complete, output.written());

    // One byte less fails, and publishes nothing.
    var truncated: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer truncated.deinit();
    try std.testing.expectError(error.OutputCapacityExceeded, symbolic.writeValue(
        &fixture.artifact.graph,
        fixture.artifact.total,
        std.testing.allocator,
        .{ .target = .phaser, .max_bytes = complete.len - 1 },
        &truncated.writer,
    ));
    try std.testing.expectEqualStrings("", truncated.written());
}
