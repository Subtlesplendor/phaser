//! Conformance of the derived order-one artifact against the exact identities
//! stated by the Milestone 3 fixtures.
//!
//! The mass-matrix references below are transcribed by hand from the fixture
//! `exact_identities` entries and built through an independent sequence of
//! builder calls. The derivation path does not produce them, so agreement is
//! evidence about the fluctuation-Hessian rule rather than a restatement of the
//! implementation.
//!
//! This tier is symbolic. It compares structure, provenance, and dimensions; it
//! evaluates nothing numerically, because Milestone 3 delivers the symbolic
//! order-one calculation before its numerical backend.

const std = @import("std");
const test_allocator = @import("test_allocator");
const phaser = @import("phaser");
const example_data = @import("example_data");
const fixture_data = @import("conformance_fixture_data");

const value = phaser.value;
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

/// Compares a derived value against an independently built reference in a
/// different arena, through the arena-independent canonical value encoding.
fn expectSameValue(
    derived_graph: *const value.Graph,
    derived_root: value.ValueId,
    reference_graph: *const value.Graph,
    reference_root: value.ValueId,
) !void {
    var derived_text: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer derived_text.deinit();
    var reference_text: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer reference_text.deinit();

    try derived_graph.writeValueCanonical(
        derived_root,
        test_allocator.allocator,
        &derived_text.writer,
    );
    try reference_graph.writeValueCanonical(
        reference_root,
        test_allocator.allocator,
        &reference_text.writer,
    );
    try std.testing.expectEqualStrings(reference_text.written(), derived_text.written());
}

const full_space_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

const Fixture = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,

    fn init(model_source: []const u8, request_source: []const u8) !Fixture {
        var model = try loadModel(model_source);
        errdefer model.deinit();
        var request = try parseRequest(request_source);
        errdefer request.deinit();
        const artifact = try derive(&model, &request);
        return .{ .model = model, .request = request, .artifact = artifact };
    }

    fn deinit(self: *Fixture) void {
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }

    /// The mass matrix the one-loop contribution was built over.
    fn massMatrix(self: *const Fixture) value.SymmetricMatrix {
        const contribution = self.artifact.contribution(.scalar_one_loop).?;
        const spectral = self.artifact.graph.value(contribution.value)
            .node.scalar_one_loop_spectral_value;
        return self.artifact.graph.value(spectral.matrix).node.real_symmetric_matrix;
    }
};

test "the phi4 mass matrix equals its exact fixture identity" {
    var fixture = try Fixture.init(example_data.phi4_model, full_space_request);
    defer fixture.deinit();

    const matrix = fixture.massMatrix();
    try std.testing.expectEqual(@as(u32, 1), matrix.dimension);

    // `m2 + (lambda / 2) * phi^2`, the fixture's field_dependent_mass_squared.
    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const phi = try reference.background(0, "phi", 1);
    const expected = try reference.add(&.{
        try reference.parameter(1, "m2", 2),
        try reference.divide(
            try reference.multiply(&.{
                try reference.parameter(0, "lambda", 0),
                try reference.power(phi, 2),
            }),
            try reference.integer(2, 0),
        ),
    });
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    try expectSameValue(
        &fixture.artifact.graph,
        matrix.entries[0],
        &reference_graph,
        expected,
    );
}

test "the multi-scalar mass matrix equals its exact fixture identities" {
    var fixture = try Fixture.init(example_data.multi_scalar_model, full_space_request);
    defer fixture.deinit();

    const matrix = fixture.massMatrix();
    try std.testing.expectEqual(@as(u32, 2), matrix.dimension);

    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const h = try reference.background(0, "h", 1);
    const s = try reference.background(1, "s", 1);
    const a = try reference.parameter(0, "a", 1);
    const b = try reference.parameter(1, "b", 1);
    const c = try reference.parameter(2, "c", 1);
    const d = try reference.parameter(3, "d", 1);
    const l1 = try reference.parameter(4, "l1", 0);
    const l2 = try reference.parameter(5, "l2", 0);
    const l3 = try reference.parameter(6, "l3", 0);
    const lh = try reference.parameter(7, "lh", 0);
    const ls = try reference.parameter(8, "ls", 0);
    const m_h2 = try reference.parameter(9, "m_h2", 2);
    const m_hs2 = try reference.parameter(10, "m_hs2", 2);
    const m_s2 = try reference.parameter(11, "m_s2", 2);

    const half = struct {
        fn of(builder: *value.Builder, factors: []const value.ValueId) !value.ValueId {
            return builder.divide(
                try builder.multiply(factors),
                try builder.integer(2, 0),
            );
        }
    }.of;

    // mass_hh = m_h2 + a*h + b*s + (lh/2)*h^2 + l3*h*s + (l2/2)*s^2
    const hh = try reference.add(&.{
        m_h2,
        try reference.multiply(&.{ a, h }),
        try reference.multiply(&.{ b, s }),
        try half(&reference, &.{ lh, try reference.power(h, 2) }),
        try reference.multiply(&.{ l3, h, s }),
        try half(&reference, &.{ l2, try reference.power(s, 2) }),
    });
    // mass_hs = m_hs2 + b*h + c*s + (l3/2)*h^2 + l2*h*s + (l1/2)*s^2
    const hs = try reference.add(&.{
        m_hs2,
        try reference.multiply(&.{ b, h }),
        try reference.multiply(&.{ c, s }),
        try half(&reference, &.{ l3, try reference.power(h, 2) }),
        try reference.multiply(&.{ l2, h, s }),
        try half(&reference, &.{ l1, try reference.power(s, 2) }),
    });
    // mass_ss = m_s2 + c*h + d*s + (l2/2)*h^2 + l1*h*s + (ls/2)*s^2
    const ss = try reference.add(&.{
        m_s2,
        try reference.multiply(&.{ c, h }),
        try reference.multiply(&.{ d, s }),
        try half(&reference, &.{ l2, try reference.power(h, 2) }),
        try reference.multiply(&.{ l1, h, s }),
        try half(&reference, &.{ ls, try reference.power(s, 2) }),
    });
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    const graph = &fixture.artifact.graph;
    try expectSameValue(graph, matrix.entries[0], &reference_graph, hh);
    try expectSameValue(graph, matrix.entries[1], &reference_graph, hs);
    try expectSameValue(graph, matrix.entries[2], &reference_graph, ss);
}

const three_scalar_slice_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"component_slice","coordinates":[{"id":"b","scalar":"r"}]},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

test "a component slice keeps every scalar in the fluctuation matrix" {
    var fixture = try Fixture.init(
        fixture_data.three_scalar_model,
        three_scalar_slice_request,
    );
    defer fixture.deinit();

    // One background coordinate, three fluctuation directions. Restricting the
    // background does not remove unselected scalar fluctuations.
    try std.testing.expectEqual(@as(usize, 1), fixture.artifact.coordinateCount());
    const matrix = fixture.massMatrix();
    try std.testing.expectEqual(@as(u32, 3), matrix.dimension);

    // The fixture identity on this slice is
    // `b * ((c111,c112,c113),(c112,c122,c123),(c113,c123,c133))`.
    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const b = try reference.background(0, "b", 1);
    const names = [_][]const u8{ "c111", "c112", "c113", "c122", "c123", "c133" };
    var expected: [6]value.ValueId = undefined;
    for (names, &expected, 0..) |name, *slot, index| {
        slot.* = try reference.multiply(&.{
            try reference.parameter(@intCast(index), name, 1),
            b,
        });
    }
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    const graph = &fixture.artifact.graph;
    // Stored upper triangle order is (0,0) (0,1) (0,2) (1,1) (1,2) (2,2), which
    // is the fixture's c111 c112 c113 c122 c123 c133.
    for (expected, 0..) |reference_root, index| {
        try expectSameValue(graph, matrix.entries[index], &reference_graph, reference_root);
    }
}

test "a slice-independent gradient still uses every fluctuation direction" {
    var fixture = try Fixture.init(
        fixture_data.three_scalar_model,
        three_scalar_slice_request,
    );
    defer fixture.deinit();

    const contribution = fixture.artifact.contribution(.scalar_one_loop).?;
    try std.testing.expectEqual(@as(usize, 1), contribution.gradient.len);
    try std.testing.expectEqual(@as(usize, 1), contribution.hessian.len);

    const graph = &fixture.artifact.graph;
    const component = graph.value(contribution.gradient[0]).node.element;
    const node = graph.value(component.source).node.scalar_one_loop_spectral_gradient;
    try std.testing.expectEqual(@as(usize, 1), node.first.len);
    // The derivative matrix is over the full fluctuation space, not over the
    // single selected background direction.
    try std.testing.expectEqual(
        @as(u32, 3),
        graph.valueType(node.first[0]).shape.matrix.dimension,
    );
}

test "the one-loop contribution records its complete scientific contract" {
    var fixture = try Fixture.init(example_data.phi4_model, full_space_request);
    defer fixture.deinit();

    const contribution = fixture.artifact.contribution(.scalar_one_loop).?;
    try std.testing.expectEqual(@as(u32, 1), contribution.loop_order);
    try std.testing.expectEqual(calculation.ResultType.complex64, contribution.result_type);
    try std.testing.expect(contribution.depends_on_scale);
    try std.testing.expect(contribution.depends_on_background);

    const provenance = contribution.provenance;
    try std.testing.expectEqualStrings(
        "scalar-vacuum-msbar/1",
        provenance.formula_version.?.text(),
    );
    try std.testing.expectEqualStrings("arg(-pi,pi]", provenance.branch.?.text());
    try std.testing.expectEqual(calculation.Scheme.msbar, provenance.scheme.?);
    try std.testing.expectEqual(@as(u32, 1), provenance.multiplicity);
    try std.testing.expectEqual(
        calculation.Provenance.Precision.binary64,
        provenance.precision,
    );
    try std.testing.expectEqual(
        calculation.Provenance.Resummation.none,
        provenance.resummation,
    );

    // The exported metadata carries the same contract, so a reader never has to
    // infer a convention from the value graph.
    var text: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer text.deinit();
    try phaser.symbolic.writeProvenance(&fixture.artifact, &text.writer);
    for ([_][]const u8{
        "loop_orders 0 through 1",
        "result_type complex64",
        "scheme msbar",
        "renormalization_scale muR",
        "formula=scalar-vacuum-msbar/1",
        "branch=arg(-pi,pi]",
        "multiplicity=1",
        "precision=binary64",
        "resummation=none",
    }) |required| {
        try std.testing.expect(std.mem.indexOf(u8, text.written(), required) != null);
    }
}

test "selected totals agree with summing the selected contributions" {
    var fixture = try Fixture.init(example_data.multi_scalar_model, full_space_request);
    defer fixture.deinit();

    const artifact = &fixture.artifact;
    try std.testing.expectEqual(@as(usize, 2), artifact.loop_totals.len);

    const tree = artifact.loopTotal(0).?;
    const loop = artifact.loopTotal(1).?;
    try std.testing.expectEqual(calculation.ResultType.real64, tree.result_type);
    try std.testing.expectEqual(calculation.ResultType.complex64, loop.result_type);
    try std.testing.expectEqual(calculation.ResultType.complex64, artifact.result_type);

    // The complete total sums exactly the derived contributions, each real one
    // entering through the explicit inclusion into `Complex64`. The graph is
    // interned, so membership is an identifier comparison.
    const operands = artifact.graph.value(artifact.total).node.add;
    try std.testing.expectEqual(artifact.contributions.len, operands.len);
    for (artifact.contributions) |contribution| {
        var found = false;
        for (operands) |operand| {
            const term = switch (artifact.graph.value(operand).node) {
                .promote_real_to_complex => |promoted| promoted,
                else => operand,
            };
            if (term == contribution.value) found = true;
        }
        try std.testing.expect(found);
    }

    // A role total is the contribution's own selection, and selection does not
    // mutate the artifact.
    const role = artifact.roleTotal(.scalar_one_loop).?;
    try std.testing.expectEqual(
        artifact.contribution(.scalar_one_loop).?.value,
        role.value,
    );
    try std.testing.expectEqual(loop.value, role.value);
    try std.testing.expect(artifact.audit());

    // A loop order outside the truncation has no precomputed selection.
    try std.testing.expectEqual(@as(?calculation.Selection, null), artifact.loopTotal(2));
}

test "contribution order is deterministic and ascending in loop order" {
    var first = try Fixture.init(example_data.multi_scalar_model, full_space_request);
    defer first.deinit();
    var second = try Fixture.init(example_data.multi_scalar_model, full_space_request);
    defer second.deinit();

    try std.testing.expectEqual(
        first.artifact.contributions.len,
        second.artifact.contributions.len,
    );
    var previous: ?calculation.Role = null;
    for (first.artifact.contributions, second.artifact.contributions) |left, right| {
        try std.testing.expectEqual(left.role, right.role);
        try std.testing.expectEqual(left.loop_order, right.loop_order);
        if (previous) |earlier| {
            try std.testing.expect(@intFromEnum(earlier) < @intFromEnum(left.role));
            try std.testing.expect(earlier.loopOrder() <= left.role.loopOrder());
        }
        previous = left.role;
    }
    try std.testing.expectEqual(calculation.Role.scalar_one_loop, previous.?);
}

test "a tree request derives no one-loop contribution and no scale" {
    const tree_request =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},
        \\"environment":{"kind":"vacuum"},
        \\"orders":{"loop":{"through":0}}}
    ;
    var fixture = try Fixture.init(example_data.phi4_model, tree_request);
    defer fixture.deinit();

    const artifact = &fixture.artifact;
    try std.testing.expectEqual(@as(u32, 0), artifact.loop_order);
    try std.testing.expectEqual(calculation.ResultType.real64, artifact.result_type);
    try std.testing.expectEqual(@as(?value.ValueId, null), artifact.scale);

    // Above the truncation is neither derived nor structurally absent: it was
    // not requested, which is a different statement.
    try std.testing.expect(artifact.contribution(.scalar_one_loop) == null);
    try std.testing.expect(artifact.absence(.scalar_one_loop) == null);
    try std.testing.expect(!artifact.roleIsRequested(.scalar_one_loop));
}

test "an order-one value compiles while its derivatives remain unavailable" {
    var fixture = try Fixture.init(example_data.phi4_model, full_space_request);
    defer fixture.deinit();

    // The value capability is lowered, and the kernel declares the complex
    // result type its selection implies.
    var kernel = try phaser.compileKernel(
        test_allocator.allocator,
        &fixture.artifact,
        .{ .capability = .value },
    );
    defer kernel.deinit();
    try std.testing.expectEqual(
        phaser.kernel.ResultType.complex64,
        kernel.resultType(),
    );

    // The invariant spectral derivatives are a separate numerical operation.
    // Requesting them fails rather than evaluating a potential without them.
    try std.testing.expectError(
        error.UnsupportedOperation,
        phaser.compileKernel(
            test_allocator.allocator,
            &fixture.artifact,
            .{ .capability = .value_gradient },
        ),
    );

    // A tree-only selection of the same artifact stays real, so the result type
    // follows the selection rather than the model.
    var tree = try phaser.compileKernel(test_allocator.allocator, &fixture.artifact, .{
        .capability = .value_gradient_hessian,
        .selection = .{ .loop_order = 0 },
    });
    defer tree.deinit();
    try std.testing.expectEqual(phaser.kernel.ResultType.real64, tree.resultType());
}
