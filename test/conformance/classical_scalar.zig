//! Conformance of the derived classical scalar potential against the exact
//! identities stated by the Milestone 2 fixtures.
//!
//! The references below are transcribed by hand from the fixture
//! `exact_identities` entries and constructed through an independent sequence
//! of builder calls. Nothing in the derivation path produces them, so agreement
//! is evidence about the orbit-coefficient rule rather than a restatement of
//! the implementation.
//!
//! The fixture writes grouped numerators over a shared denominator, for example
//! `(lh*h^4 + 4*l3*h^3*s + 6*l2*h^2*s^2 + 4*l1*h*s^3 + ls*s^4)/24`. The value
//! IR does not distribute a constant over a sum, so each monomial is written
//! here with its own reduced coefficient, obtained by dividing the fixture
//! numerator by the fixture denominator.

const std = @import("std");
const test_allocator = @import("test_allocator");
const phaser = @import("phaser");
const example_data = @import("example_data");

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
    \\"orders":{"loop":{"through":0}}}
;

// -- phi4 ------------------------------------------------------------------

/// Model parameters are ordered alphabetically by the loader: lambda, m2, omega.
const phi4_lambda = 0;
const phi4_mass_squared = 1;
const phi4_omega = 2;

/// `omega + (m2 / 2) * phi^2 + (lambda / 24) * phi^4`
fn buildPhi4Reference(builder: *value.Builder) !value.ValueId {
    const omega = try builder.parameter(phi4_omega, "omega", 4);
    const mass_squared = try builder.parameter(phi4_mass_squared, "m2", 2);
    const lambda = try builder.parameter(phi4_lambda, "lambda", 0);
    const phi = try builder.background(0, "phi", 1);

    return builder.add(&.{
        omega,
        try builder.divide(
            try builder.multiply(&.{ mass_squared, try builder.power(phi, 2) }),
            try builder.integer(2, 0),
        ),
        try builder.divide(
            try builder.multiply(&.{ lambda, try builder.power(phi, 4) }),
            try builder.integer(24, 0),
        ),
    });
}

test "the phi4 tree potential matches its fixture identity" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const reference_root = try buildPhi4Reference(&reference);
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    try expectSameValue(
        &artifact.graph,
        artifact.total,
        &reference_graph,
        reference_root,
    );
}

test "the phi4 gradient and Hessian match their fixture identities" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const mass_squared = try reference.parameter(phi4_mass_squared, "m2", 2);
    const lambda = try reference.parameter(phi4_lambda, "lambda", 0);
    const phi = try reference.background(0, "phi", 1);

    // `m2 * phi + (lambda / 6) * phi^3`
    const gradient = try reference.add(&.{
        try reference.multiply(&.{ mass_squared, phi }),
        try reference.divide(
            try reference.multiply(&.{ lambda, try reference.power(phi, 3) }),
            try reference.integer(6, 0),
        ),
    });
    // `m2 + (lambda / 2) * phi^2`
    const hessian = try reference.add(&.{
        mass_squared,
        try reference.divide(
            try reference.multiply(&.{ lambda, try reference.power(phi, 2) }),
            try reference.integer(2, 0),
        ),
    });
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), artifact.gradient.len);
    try std.testing.expectEqual(@as(usize, 1), artifact.hessian.len);
    try expectSameValue(&artifact.graph, artifact.gradient[0], &reference_graph, gradient);
    try expectSameValue(&artifact.graph, artifact.hessian[0], &reference_graph, hessian);
}

test "the phi4 model records its absent tensor kinds structurally" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    // The model declares vacuum energy, mass squared, and quartic only.
    try std.testing.expectEqual(@as(usize, 3), artifact.contributions.len);
    try std.testing.expectEqual(
        calculation.AbsenceReason.tensor_absent,
        artifact.absence(.scalar_tadpole).?.reason,
    );
    try std.testing.expectEqual(
        calculation.AbsenceReason.tensor_absent,
        artifact.absence(.scalar_cubic).?.reason,
    );

    // The background-independent vacuum energy is retained by default.
    const vacuum = artifact.contribution(.vacuum_energy).?;
    try std.testing.expect(!vacuum.depends_on_background);
    try std.testing.expect(artifact.contribution(.scalar_quartic).?.depends_on_background);
}

// -- multi-scalar ----------------------------------------------------------

/// Alphabetical loader order:
/// a, b, c, d, l1, l2, l3, lh, ls, m_h2, m_hs2, m_s2, omega, t_h, t_s
const ms = struct {
    const a = 0;
    const b = 1;
    const c = 2;
    const d = 3;
    const l1 = 4;
    const l2 = 5;
    const l3 = 6;
    const lh = 7;
    const ls = 8;
    const m_h2 = 9;
    const m_hs2 = 10;
    const m_s2 = 11;
    const omega = 12;
    const t_h = 13;
    const t_s = 14;
};

/// The `scalar.multi_scalar` fixture `tree_potential`, with each grouped
/// numerator reduced against its denominator:
///
///     omega + t_h h + t_s s
///     + m_h2 h^2 / 2 + m_hs2 h s + m_s2 s^2 / 2
///     + a h^3 / 6 + b h^2 s / 2 + c h s^2 / 2 + d s^3 / 6
///     + lh h^4 / 24 + l3 h^3 s / 6 + l2 h^2 s^2 / 4
///     + l1 h s^3 / 6 + ls s^4 / 24
fn buildMultiScalarReference(builder: *value.Builder) !value.ValueId {
    const h = try builder.background(0, "h", 1);
    const s = try builder.background(1, "s", 1);

    const Term = struct {
        parameter_id: u32,
        name: []const u8,
        dimension: i32,
        h_power: u32,
        s_power: u32,
        denominator: i64,
    };
    const terms = [_]Term{
        .{ .parameter_id = ms.omega, .name = "omega", .dimension = 4, .h_power = 0, .s_power = 0, .denominator = 1 },
        .{ .parameter_id = ms.t_h, .name = "t_h", .dimension = 3, .h_power = 1, .s_power = 0, .denominator = 1 },
        .{ .parameter_id = ms.t_s, .name = "t_s", .dimension = 3, .h_power = 0, .s_power = 1, .denominator = 1 },
        .{ .parameter_id = ms.m_h2, .name = "m_h2", .dimension = 2, .h_power = 2, .s_power = 0, .denominator = 2 },
        .{ .parameter_id = ms.m_hs2, .name = "m_hs2", .dimension = 2, .h_power = 1, .s_power = 1, .denominator = 1 },
        .{ .parameter_id = ms.m_s2, .name = "m_s2", .dimension = 2, .h_power = 0, .s_power = 2, .denominator = 2 },
        .{ .parameter_id = ms.a, .name = "a", .dimension = 1, .h_power = 3, .s_power = 0, .denominator = 6 },
        .{ .parameter_id = ms.b, .name = "b", .dimension = 1, .h_power = 2, .s_power = 1, .denominator = 2 },
        .{ .parameter_id = ms.c, .name = "c", .dimension = 1, .h_power = 1, .s_power = 2, .denominator = 2 },
        .{ .parameter_id = ms.d, .name = "d", .dimension = 1, .h_power = 0, .s_power = 3, .denominator = 6 },
        .{ .parameter_id = ms.lh, .name = "lh", .dimension = 0, .h_power = 4, .s_power = 0, .denominator = 24 },
        .{ .parameter_id = ms.l3, .name = "l3", .dimension = 0, .h_power = 3, .s_power = 1, .denominator = 6 },
        .{ .parameter_id = ms.l2, .name = "l2", .dimension = 0, .h_power = 2, .s_power = 2, .denominator = 4 },
        .{ .parameter_id = ms.l1, .name = "l1", .dimension = 0, .h_power = 1, .s_power = 3, .denominator = 6 },
        .{ .parameter_id = ms.ls, .name = "ls", .dimension = 0, .h_power = 0, .s_power = 4, .denominator = 24 },
    };

    var addends: [terms.len]value.ValueId = undefined;
    for (terms, &addends) |term, *slot| {
        var factors: [3]value.ValueId = undefined;
        var count: usize = 0;
        factors[count] = try builder.parameter(term.parameter_id, term.name, term.dimension);
        count += 1;
        if (term.h_power != 0) {
            factors[count] = try builder.power(h, term.h_power);
            count += 1;
        }
        if (term.s_power != 0) {
            factors[count] = try builder.power(s, term.s_power);
            count += 1;
        }
        const product = try builder.multiply(factors[0..count]);
        slot.* = if (term.denominator == 1)
            product
        else
            try builder.divide(product, try builder.integer(term.denominator, 0));
    }
    return builder.add(&addends);
}

test "the multi-scalar tree potential matches its fixture identity" {
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const reference_root = try buildMultiScalarReference(&reference);
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    try expectSameValue(
        &artifact.graph,
        artifact.total,
        &reference_graph,
        reference_root,
    );

    // Every tensor kind is present in this model, so nothing is absent.
    try std.testing.expectEqual(@as(usize, 5), artifact.contributions.len);
    try std.testing.expectEqual(@as(usize, 0), artifact.absences.len);
}

test "off-diagonal orbit coefficients are not the diagonal rule" {
    // The φ⁴ model cannot distinguish 1 / prod(m_v!) from 1 / r!, because every
    // single-scalar component is diagonal. This asserts the separation directly
    // on the multi-scalar model, where the two rules differ by the multinomial
    // factor.
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const h = try reference.background(0, "h", 1);
    const s = try reference.background(1, "s", 1);
    const l2 = try reference.parameter(ms.l2, "l2", 0);

    // Correct: l2 h^2 s^2 / 4. The naive 1 / r! rule would give / 24.
    const correct = try reference.divide(
        try reference.multiply(&.{
            l2,
            try reference.power(h, 2),
            try reference.power(s, 2),
        }),
        try reference.integer(4, 0),
    );
    const naive = try reference.divide(
        try reference.multiply(&.{
            l2,
            try reference.power(h, 2),
            try reference.power(s, 2),
        }),
        try reference.integer(24, 0),
    );
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();
    try std.testing.expect(correct != naive);

    var quartic_text: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer quartic_text.deinit();
    try artifact.graph.writeValueCanonical(
        artifact.contribution(.scalar_quartic).?.value,
        test_allocator.allocator,
        &quartic_text.writer,
    );
    var naive_text: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer naive_text.deinit();
    try reference_graph.writeValueCanonical(
        naive,
        test_allocator.allocator,
        &naive_text.writer,
    );
    try std.testing.expect(
        !std.mem.eql(u8, quartic_text.written(), naive_text.written()),
    );
}

// -- component slices ------------------------------------------------------

test "a component slice fixes unselected backgrounds to exactly zero" {
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

    try std.testing.expectEqual(@as(usize, 1), artifact.coordinateCount());

    // Restricting to h = x, s = 0 leaves the pure-h monomials:
    // omega + t_h x + m_h2 x^2 / 2 + a x^3 / 6 + lh x^4 / 24
    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const x = try reference.background(0, "x", 1);
    const reference_root = try reference.add(&.{
        try reference.parameter(ms.omega, "omega", 4),
        try reference.multiply(&.{ try reference.parameter(ms.t_h, "t_h", 3), x }),
        try reference.divide(
            try reference.multiply(&.{
                try reference.parameter(ms.m_h2, "m_h2", 2),
                try reference.power(x, 2),
            }),
            try reference.integer(2, 0),
        ),
        try reference.divide(
            try reference.multiply(&.{
                try reference.parameter(ms.a, "a", 1),
                try reference.power(x, 3),
            }),
            try reference.integer(6, 0),
        ),
        try reference.divide(
            try reference.multiply(&.{
                try reference.parameter(ms.lh, "lh", 0),
                try reference.power(x, 4),
            }),
            try reference.integer(24, 0),
        ),
    });
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    try expectSameValue(
        &artifact.graph,
        artifact.total,
        &reference_graph,
        reference_root,
    );
}

test "a slice selecting no surviving component records a structural absence" {
    // Slicing multi_scalar to s alone keeps only pure-s monomials. Every mixed
    // component contains h, whose background is structurally zero.
    const slice_request =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"y","scalar":"s"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(slice_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    // Each kind still has one surviving pure-s component, so nothing vanishes
    // entirely here; what matters is that mixed monomials are gone.
    try std.testing.expectEqual(@as(usize, 5), artifact.contributions.len);

    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const y = try reference.background(0, "y", 1);
    const expected_cubic = try reference.divide(
        try reference.multiply(&.{
            try reference.parameter(ms.d, "d", 1),
            try reference.power(y, 3),
        }),
        try reference.integer(6, 0),
    );
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    try expectSameValue(
        &artifact.graph,
        artifact.contribution(.scalar_cubic).?.value,
        &reference_graph,
        expected_cubic,
    );
}

test "restricted derivatives satisfy the embedding chain rule" {
    // For a linear embedding the restricted gradient is B^T applied to the full
    // gradient. With a one-coordinate slice selecting h, that is the full
    // h-derivative evaluated at s = 0, which equals the derivative of the
    // restricted potential.
    const slice_request =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"h","scalar":"h"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(slice_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    // t_h + m_h2 h + a h^2 / 2 + lh h^3 / 6
    var reference = try value.Builder.init(test_allocator.allocator, .{});
    const h = try reference.background(0, "h", 1);
    const expected = try reference.add(&.{
        try reference.parameter(ms.t_h, "t_h", 3),
        try reference.multiply(&.{ try reference.parameter(ms.m_h2, "m_h2", 2), h }),
        try reference.divide(
            try reference.multiply(&.{
                try reference.parameter(ms.a, "a", 1),
                try reference.power(h, 2),
            }),
            try reference.integer(2, 0),
        ),
        try reference.divide(
            try reference.multiply(&.{
                try reference.parameter(ms.lh, "lh", 0),
                try reference.power(h, 3),
            }),
            try reference.integer(6, 0),
        ),
    });
    var reference_graph = try reference.finish();
    defer reference_graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), artifact.gradient.len);
    try expectSameValue(
        &artifact.graph,
        artifact.gradient[0],
        &reference_graph,
        expected,
    );
}

test "the Hessian is symmetric and ordered by coordinate" {
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();

    try std.testing.expectEqual(@as(usize, 2), artifact.coordinateCount());
    try std.testing.expectEqual(@as(usize, 4), artifact.hessian.len);
    // Interning makes mixed-partial equality an identifier comparison.
    try std.testing.expectEqual(artifact.hessian[1], artifact.hessian[2]);
}

test "derivation is deterministic across repeated runs" {
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();
    var request = try parseRequest(full_space_request);
    defer request.deinit();

    var first = try derive(&model, &request);
    defer first.deinit();
    var second = try derive(&model, &request);
    defer second.deinit();

    var first_text: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer first_text.deinit();
    var second_text: std.Io.Writer.Allocating = .init(test_allocator.allocator);
    defer second_text.deinit();
    try first.graph.writeCanonical(&first_text.writer);
    try second.graph.writeCanonical(&second_text.writer);
    try std.testing.expectEqualStrings(first_text.written(), second_text.written());

    try std.testing.expectEqualSlices(
        u8,
        &first.request_fingerprint.bytes,
        &second.request_fingerprint.bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first.model_fingerprint.bytes,
        &second.model_fingerprint.bytes,
    );
}
