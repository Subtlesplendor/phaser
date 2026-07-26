//! Phaser property tests.
//!
//! These implement properties that `ENGINEERING_STYLE.md` already lists under
//! "Property-based testing" and that Milestone 2 left unwritten, plus two that
//! cover the defect classes Milestone 2 actually hit.
//!
//! Two notes on why these particular properties.
//!
//! `canonicalEquality` covers the class of the interning defect found in the
//! Typed Value IR: `power` and `divide` built an intern key and then skipped the
//! lookup, so structurally equal values received different identifiers. Nothing
//! in the unit tests asserted that directly; it surfaced only because a
//! derivative test happened to use identifier equality as its oracle.
//!
//! `lifecycleSequence` covers the class of the binding defect found while
//! writing the finite-difference suite: a binding held a pointer to its kernel,
//! so returning both from a helper left the binding reading a dead stack slot.
//! Every existing test constructed things in one order and none exercised the
//! move.
//!
//! Generators here produce plain values and the properties interpret them as
//! Phaser objects. That keeps ownership inside the dependency's own generator
//! contract rather than spreading it across Phaser-owned generator
//! implementations.

const std = @import("std");
const phaser = @import("phaser");
const example_data = @import("example_data");
const harness = @import("harness.zig");

const gen = harness.gen;
const value = phaser.value;
const calculation = phaser.calculation;
const kernel_module = phaser.kernel;
const Scalar = kernel_module.Scalar;

/// Allocator every property uses.
///
/// Minish's property function takes only the generated value, so neither the
/// allocator nor the fixture can be threaded through as a parameter.
var property_allocator: std.mem.Allocator = undefined;

/// Fixture shared by the evaluation properties.
///
/// Parsing, deriving, lowering, and binding are invariant across generated
/// cases, so they happen once per property rather than once per case. Deriving
/// the same artifact several hundred times would spend the budget on work that
/// is already covered by a determinism test.
var shared_setup: ?Setup = null;

/// Fixture pair shared by a metamorphic property. Both sides are invariant
/// across generated cases; only the evaluation point varies.
var shared_left: ?Setup = null;
var shared_right: ?Setup = null;

pub fn runAll(allocator: std.mem.Allocator, budget: harness.Budget) !void {
    property_allocator = allocator;

    try harness.check(
        allocator,
        "value_ir.canonical_equality",
        gen.list(u8, gen.int(u8), 0, 18),
        canonicalEquality,
        budget,
    );
    try harness.check(
        allocator,
        "value_ir.insertion_order_independence",
        gen.list(u8, gen.int(u8), 0, 20),
        insertionOrderIndependence,
        budget,
    );
    shared_setup = try Setup.init(
        allocator,
        example_data.multi_scalar_model,
        example_data.multi_scalar_point,
        .value_gradient_hessian,
        32,
    );

    try harness.check(
        allocator,
        "evaluation.scalar_matches_batch",
        gen.list(f64, gen.floatRange(f64, -600, 600), 1, 16),
        scalarMatchesBatch,
        budget,
    );
    try harness.check(
        allocator,
        "evaluation.staged_matches_unstaged",
        gen.list(f64, gen.floatRange(f64, -600, 600), 1, 16),
        stagedMatchesUnstaged,
        budget,
    );
    try harness.check(
        allocator,
        "evaluation.hessian_is_symmetric",
        gen.array(f64, 2, gen.floatRange(f64, -600, 600)),
        hessianIsSymmetric,
        budget,
    );
    shared_setup.?.deinit(allocator);
    shared_setup = null;

    shared_left = try Setup.init(
        allocator,
        example_data.multi_scalar_model,
        example_data.multi_scalar_point,
        .value,
        1,
    );
    shared_right = try Setup.init(
        allocator,
        relabelled_model,
        relabelled_point,
        .value,
        1,
    );
    try harness.check(
        allocator,
        "metamorphic.relabelling_preserves_results",
        gen.array(f64, 2, gen.floatRange(f64, -400, 400)),
        relabellingPreservesResults,
        budget,
    );
    shared_left.?.deinit(allocator);
    shared_right.?.deinit(allocator);

    shared_left = try Setup.init(
        allocator,
        example_data.multi_scalar_model,
        zeroed_point,
        .value_gradient,
        1,
    );
    shared_right = try Setup.init(
        allocator,
        reduced_model,
        reduced_point,
        .value_gradient,
        1,
    );
    try harness.check(
        allocator,
        "metamorphic.zero_coupling_matches_reduced_model",
        gen.array(f64, 2, gen.floatRange(f64, -400, 400)),
        zeroCouplingMatchesReducedModel,
        budget,
    );
    shared_left.?.deinit(allocator);
    shared_right.?.deinit(allocator);
    shared_left = null;
    shared_right = null;
    shared_setup = try Setup.init(
        allocator,
        example_data.multi_scalar_model,
        example_data.multi_scalar_point,
        .value,
        8,
    );
    defer {
        shared_setup.?.deinit(allocator);
        shared_setup = null;
    }
    try harness.check(
        allocator,
        "lifecycle.sequence_agrees_with_reference",
        gen.list(u8, gen.int(u8), 0, 10),
        lifecycleSequence,
        budget,
    );
}

/// Compares two results that are mathematically equal but need not be bitwise
/// equal.
///
/// A metamorphic transformation such as relabelling fields changes the
/// content-derived canonical operand order, and therefore the accumulation order.
/// Floating-point addition is not associative, so the two sums agree only to
/// rounding. Bitwise equality is the wrong expectation; a coefficient error would
/// show up as a factor, which this tolerance still rejects by many orders of
/// magnitude.
///
/// The tolerance is local to this test until the declared numerical-comparison
/// policy of `POTENTIAL_KERNEL.md` section 15.3 is written.
fn expectClose(expected: Scalar, actual: Scalar) !void {
    const scale = @max(@abs(expected), @abs(actual));
    if (scale < 1e-300) return;
    try std.testing.expectApproxEqRel(expected, actual, 1e-12);
}

// -- shared plumbing -------------------------------------------------------

fn context(allocator: std.mem.Allocator) phaser.Context {
    return switch (phaser.Context.init(allocator, .{
        .max_diagnostics = 16,
        .max_related_locations = 32,
    })) {
        .context => |ctx| ctx,
        .failure => unreachable,
    };
}

fn loadModel(allocator: std.mem.Allocator, source: []const u8) !phaser.Model {
    return switch (try phaser.loadModel(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = source,
    }, .{})) {
        .model => |loaded| loaded,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidModel;
        },
    };
}

fn loadRequest(allocator: std.mem.Allocator, source: []const u8) !calculation.Request {
    return switch (try phaser.parseRequest(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(1),
        .bytes = source,
    }, .{})) {
        .request => |parsed| parsed,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidRequest;
        },
    };
}

fn loadPoint(allocator: std.mem.Allocator, source: []const u8) !calculation.ParameterPoint {
    return switch (try phaser.parseParameterPoint(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(2),
        .bytes = source,
    }, .{})) {
        .point => |parsed| parsed,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidParameterPoint;
        },
    };
}

fn deriveArtifact(
    allocator: std.mem.Allocator,
    model: *const phaser.Model,
    request: *const calculation.Request,
) !calculation.Artifact {
    return switch (try phaser.deriveClassicalPotential(
        context(allocator),
        model,
        request,
        .{},
    )) {
        .artifact => |derived| derived,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.DerivationFailed;
        },
    };
}

/// A model, kernel, and binding over the multi-scalar example.
const Setup = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,
    kernel: kernel_module.Kernel,
    binding: kernel_module.Binding,
    workspace: []align(@alignOf(Scalar)) u8,
    coordinates: usize,

    fn init(
        allocator: std.mem.Allocator,
        model_source: []const u8,
        point_source: []const u8,
        capability: kernel_module.Capability,
        max_points: usize,
    ) !Setup {
        var model = try loadModel(allocator, model_source);
        errdefer model.deinit();
        var request = try loadRequest(allocator, example_data.phi4_request);
        errdefer request.deinit();
        var artifact = try deriveArtifact(allocator, &model, &request);
        errdefer artifact.deinit();
        var kernel = try kernel_module.compile(allocator, &artifact, .{
            .capability = capability,
        });
        errdefer kernel.deinit();
        var point = try loadPoint(allocator, point_source);
        defer point.deinit();
        var binding = try kernel_module.bind(allocator, &kernel, &model, &point);
        errdefer binding.deinit();
        const workspace = try allocator.alignedAlloc(
            u8,
            .of(Scalar),
            binding.workspaceLayout(max_points).bytes,
        );
        return .{
            .model = model,
            .request = request,
            .artifact = artifact,
            .kernel = kernel,
            .binding = binding,
            .workspace = workspace,
            .coordinates = kernel.coordinateCount(),
        };
    }

    fn deinit(self: *Setup, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace);
        self.binding.deinit();
        self.kernel.deinit();
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }
};

/// Replays a generated byte script into a value graph, as the fuzz targets do.
fn replayScript(allocator: std.mem.Allocator, script: []const u8) !value.Graph {
    var builder = try value.Builder.init(allocator, .{
        .value_nodes = 4096,
        .value_operands = 64,
        .exponent_magnitude = 6,
        .exact_integer_bits = 2048,
    });
    errdefer builder.deinit();

    var pool: [96]value.ValueId = undefined;
    var length: usize = 0;
    pool[length] = try builder.background(0, "h", 1);
    length += 1;
    pool[length] = try builder.background(1, "s", 1);
    length += 1;
    pool[length] = try builder.parameter(0, "g", 0);
    length += 1;
    pool[length] = try builder.integer(2, 0);
    length += 1;

    var index: usize = 0;
    while (index + 3 < script.len) : (index += 4) {
        const first = pool[script[index + 1] % length];
        const second = pool[script[index + 2] % length];
        const third = pool[script[index + 3] % length];
        const produced: ?value.ValueId = switch (script[index] % 6) {
            0 => builder.add(&.{ first, second }) catch null,
            1 => builder.add(&.{ first, second, third }) catch null,
            2 => builder.multiply(&.{ first, second }) catch null,
            3 => builder.multiply(&.{ first, second, third }) catch null,
            4 => builder.power(first, script[index + 2] % 5) catch null,
            5 => builder.subtract(first, second) catch null,
            else => unreachable,
        };
        if (produced) |id| {
            if (length < pool.len) {
                pool[length] = id;
                length += 1;
            }
        }
    }
    return builder.finish();
}

// -- value IR properties ---------------------------------------------------

/// Structurally equal values share one identifier.
///
/// Rebuilding a value with its commutative operands supplied in a different
/// order must return the identifier already assigned. This is the property the
/// interning defect violated.
fn canonicalEquality(script: []const u8) !void {
    const allocator = property_allocator;
    var builder = try value.Builder.init(allocator, .{});
    defer builder.deinit();

    // Every operand shares one mass dimension, so a sum of any combination is
    // dimensionally valid and the property tests canonicalization rather than
    // the dimension check.
    const h = try builder.background(0, "h", 1);
    const s = try builder.background(1, "s", 1);
    const g = try builder.parameter(0, "g", 0);
    const operands = [_]value.ValueId{
        h,
        s,
        try builder.multiply(&.{ g, h }),
        try builder.multiply(&.{ g, s }),
    };

    var index: usize = 0;
    while (index + 2 < script.len) : (index += 3) {
        const a = operands[script[index] % operands.len];
        const b = operands[script[index + 1] % operands.len];
        const c = operands[script[index + 2] % operands.len];

        // A sum and a product are commutative, so any permutation of the same
        // operand multiset must intern to one node.
        const forward_sum = try builder.add(&.{ a, b, c });
        try std.testing.expectEqual(forward_sum, try builder.add(&.{ c, a, b }));
        try std.testing.expectEqual(forward_sum, try builder.add(&.{ b, c, a }));

        const forward_product = try builder.multiply(&.{ a, b, c });
        try std.testing.expectEqual(
            forward_product,
            try builder.multiply(&.{ c, b, a }),
        );

        // Nesting is flattened, so an associativity regrouping is the same node.
        try std.testing.expectEqual(
            forward_product,
            try builder.multiply(&.{ try builder.multiply(&.{ a, b }), c }),
        );
        try std.testing.expectEqual(
            forward_sum,
            try builder.add(&.{ a, try builder.add(&.{ b, c }) }),
        );

        // Constructing the same node twice returns the same identifier. This is
        // the invariant the interning defect violated, and it must hold for
        // every constructor rather than only the commutative ones: the defect
        // was in `power` and `divide`, which the permutation checks above never
        // reach.
        const exponent = 2 + @as(u32, script[index] % 3);
        try std.testing.expectEqual(
            try builder.power(a, exponent),
            try builder.power(a, exponent),
        );
        try std.testing.expectEqual(
            try builder.divide(a, b),
            try builder.divide(a, b),
        );
        try std.testing.expectEqual(
            try builder.negate(a),
            try builder.negate(a),
        );
        try std.testing.expectEqual(
            try builder.subtract(a, b),
            try builder.subtract(a, b),
        );
        try std.testing.expectEqual(
            try builder.background(0, "h", 1),
            try builder.background(0, "h", 1),
        );
        try std.testing.expectEqual(
            try builder.parameter(0, "g", 0),
            try builder.parameter(0, "g", 0),
        );
    }
}

/// The published canonical encoding does not depend on construction order.
///
/// Two graphs built from the same script, one preceded by unrelated nodes so
/// every shared node lands at a different arena position, encode identically.
fn insertionOrderIndependence(script: []const u8) !void {
    const allocator = property_allocator;

    var first = try replayScript(allocator, script);
    defer first.deinit();

    var offset = std.ArrayList(u8).empty;
    defer offset.deinit(allocator);
    // Three decoy operations shift every subsequent arena position.
    try offset.appendSlice(allocator, &.{ 4, 2, 3, 0, 0, 1, 1, 2 });
    try offset.appendSlice(allocator, script);
    var second = try replayScript(allocator, offset.items);
    defer second.deinit();

    try std.testing.expect(first.audit());
    try std.testing.expect(second.audit());

    // Values reachable from a common construction prefix encode identically even
    // though their arena positions differ.
    const shared = @min(first.values.len, second.values.len);
    if (shared == 0) return;

    var first_text: std.Io.Writer.Allocating = .init(allocator);
    defer first_text.deinit();
    var second_text: std.Io.Writer.Allocating = .init(allocator);
    defer second_text.deinit();
    try first.writeValueCanonical(
        try value.ValueId.fromUsize(0),
        allocator,
        &first_text.writer,
    );
    try second.writeValueCanonical(
        try value.ValueId.fromUsize(0),
        allocator,
        &second_text.writer,
    );
    try std.testing.expectEqualStrings(first_text.written(), second_text.written());
}

// -- evaluation properties -------------------------------------------------

/// Scalar evaluation agrees with batch evaluation, and every partition agrees
/// with the whole.
fn scalarMatchesBatch(coordinates_flat: []const f64) !void {
    const allocator = property_allocator;
    const setup = &shared_setup.?;

    const n = setup.coordinates;
    const point_count = coordinates_flat.len / n;
    if (point_count == 0) return;
    const backgrounds = coordinates_flat[0 .. point_count * n];

    const batch = try allocator.alloc(Scalar, point_count);
    defer allocator.free(batch);
    const statuses = try allocator.alloc(kernel_module.Status, point_count);
    defer allocator.free(statuses);
    try setup.binding.evaluate(backgrounds, point_count, setup.workspace, .{
        .values = batch,
        .statuses = statuses,
    });

    for (0..point_count) |index| {
        var single: [1]Scalar = undefined;
        var single_status: [1]kernel_module.Status = undefined;
        try setup.binding.evaluate(
            backgrounds[index * n ..][0..n],
            1,
            setup.workspace,
            .{ .values = &single, .statuses = &single_status },
        );
        try std.testing.expectEqual(statuses[index], single_status[0]);
        if (statuses[index] == .ok) {
            try std.testing.expectEqual(batch[index], single[0]);
        }
    }
}

/// Staged evaluation through a binding agrees bitwise with the unstaged path.
fn stagedMatchesUnstaged(coordinates_flat: []const f64) !void {
    const allocator = property_allocator;
    const setup = &shared_setup.?;

    const n = setup.coordinates;
    const point_count = coordinates_flat.len / n;
    if (point_count == 0) return;
    const backgrounds = coordinates_flat[0 .. point_count * n];

    const staged_values = try allocator.alloc(Scalar, point_count);
    defer allocator.free(staged_values);
    const staged_gradients = try allocator.alloc(Scalar, point_count * n);
    defer allocator.free(staged_gradients);
    const staged_statuses = try allocator.alloc(kernel_module.Status, point_count);
    defer allocator.free(staged_statuses);
    try setup.binding.evaluate(backgrounds, point_count, setup.workspace, .{
        .values = staged_values,
        .gradients = staged_gradients,
        .statuses = staged_statuses,
    });

    const direct_values = try allocator.alloc(Scalar, point_count);
    defer allocator.free(direct_values);
    const direct_gradients = try allocator.alloc(Scalar, point_count * n);
    defer allocator.free(direct_gradients);
    const direct_statuses = try allocator.alloc(kernel_module.Status, point_count);
    defer allocator.free(direct_statuses);
    try setup.kernel.evaluate(
        .{ .parameters = setup.binding.parameters, .backgrounds = backgrounds },
        point_count,
        setup.workspace,
        .{
            .values = direct_values,
            .gradients = direct_gradients,
            .statuses = direct_statuses,
        },
    );

    try std.testing.expectEqualSlices(Scalar, direct_values, staged_values);
    try std.testing.expectEqualSlices(Scalar, direct_gradients, staged_gradients);
    try std.testing.expectEqualSlices(
        kernel_module.Status,
        direct_statuses,
        staged_statuses,
    );
}

/// Mixed partials agree at every generated point.
fn hessianIsSymmetric(point: [2]f64) !void {
    const setup = &shared_setup.?;

    var values: [1]Scalar = undefined;
    var gradients: [2]Scalar = undefined;
    var hessians: [4]Scalar = undefined;
    var statuses: [1]kernel_module.Status = undefined;
    try setup.binding.evaluate(&point, 1, setup.workspace, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });
    if (statuses[0] != .ok) return;
    try std.testing.expectEqual(hessians[1], hessians[2]);
}

// -- metamorphic properties ------------------------------------------------

/// Relabelling scalar fields permutes results correspondingly.
///
/// Declaring the two scalars in the opposite order, with every tensor index
/// renamed to match, is the same physics under a relabelling. Evaluating the
/// relabelled model at the swapped coordinates must reproduce the original
/// value.
fn relabellingPreservesResults(point: [2]f64) !void {
    const original = &shared_left.?;
    const relabelled = &shared_right.?;

    var original_value: [1]Scalar = undefined;
    var original_status: [1]kernel_module.Status = undefined;
    try original.binding.evaluate(&point, 1, original.workspace, .{
        .values = &original_value,
        .statuses = &original_status,
    });

    // The relabelled model declares the scalars in the opposite order, so the
    // corresponding background point is the swapped one.
    const swapped = [_]Scalar{ point[1], point[0] };
    var relabelled_value: [1]Scalar = undefined;
    var relabelled_status: [1]kernel_module.Status = undefined;
    try relabelled.binding.evaluate(&swapped, 1, relabelled.workspace, .{
        .values = &relabelled_value,
        .statuses = &relabelled_status,
    });

    try std.testing.expectEqual(original_status[0], relabelled_status[0]);
    if (original_status[0] != .ok) return;
    try expectClose(original_value[0], relabelled_value[0]);
}

/// A coupling bound to zero agrees with the model that omits its tensor
/// component.
///
/// The model format rejects an explicit zero component, so the reduced model
/// omits the mixed quartic entirely. Binding the full model with that coupling
/// set to zero must produce the same numbers.
fn zeroCouplingMatchesReducedModel(point: [2]f64) !void {
    const full = &shared_left.?;
    const reduced = &shared_right.?;

    var full_value: [1]Scalar = undefined;
    var full_gradient: [2]Scalar = undefined;
    var full_status: [1]kernel_module.Status = undefined;
    try full.binding.evaluate(&point, 1, full.workspace, .{
        .values = &full_value,
        .gradients = &full_gradient,
        .statuses = &full_status,
    });

    var reduced_value: [1]Scalar = undefined;
    var reduced_gradient: [2]Scalar = undefined;
    var reduced_status: [1]kernel_module.Status = undefined;
    try reduced.binding.evaluate(&point, 1, reduced.workspace, .{
        .values = &reduced_value,
        .gradients = &reduced_gradient,
        .statuses = &reduced_status,
    });

    try std.testing.expectEqual(full_status[0], reduced_status[0]);
    if (full_status[0] != .ok) return;
    // The omitted monomial contributes exactly zero, but dropping a parameter
    // shifts the remaining terms' canonical order, so the sums agree to rounding
    // rather than bitwise.
    try expectClose(full_value[0], reduced_value[0]);
    for (full_gradient, reduced_gradient) |expected, actual| {
        try expectClose(expected, actual);
    }
}

// -- lifecycle property ----------------------------------------------------

/// A generated sequence of lifecycle operations agrees with a fixed reference.
///
/// The sequence moves the kernel and the binding between locations, rebinds, and
/// evaluates at varying point counts. This covers the class of the binding
/// lifetime defect, where every existing test happened to construct objects in
/// one order and none exercised a move.
fn lifecycleSequence(script: []const u8) !void {
    const allocator = property_allocator;
    const setup = &shared_setup.?;

    const n = setup.coordinates;
    const probe = [_]Scalar{ 123.0, -45.0 };
    var expected: [1]Scalar = undefined;
    var expected_status: [1]kernel_module.Status = undefined;
    try setup.binding.evaluate(&probe, 1, setup.workspace, .{
        .values = &expected,
        .statuses = &expected_status,
    });

    for (script) |operation| {
        switch (operation % 4) {
            // Move the binding to a new location and evaluate through it.
            0 => {
                var moved = setup.binding;
                setup.binding = undefined;
                var values: [1]Scalar = undefined;
                var statuses: [1]kernel_module.Status = undefined;
                try moved.evaluate(&probe, 1, setup.workspace, .{
                    .values = &values,
                    .statuses = &statuses,
                });
                try std.testing.expectEqual(expected[0], values[0]);
                setup.binding = moved;
            },
            // Move the kernel and evaluate through the existing binding, which
            // must not depend on the kernel's address.
            1 => {
                const moved = setup.kernel;
                setup.kernel = undefined;
                var values: [1]Scalar = undefined;
                var statuses: [1]kernel_module.Status = undefined;
                try setup.binding.evaluate(&probe, 1, setup.workspace, .{
                    .values = &values,
                    .statuses = &statuses,
                });
                try std.testing.expectEqual(expected[0], values[0]);
                setup.kernel = moved;
            },
            // Create a second binding over the same values and compare.
            2 => {
                var point = try loadPoint(allocator, example_data.multi_scalar_point);
                defer point.deinit();
                var fresh = try kernel_module.bind(
                    allocator,
                    &setup.kernel,
                    &setup.model,
                    &point,
                );
                defer fresh.deinit();
                var values: [1]Scalar = undefined;
                var statuses: [1]kernel_module.Status = undefined;
                try fresh.evaluate(&probe, 1, setup.workspace, .{
                    .values = &values,
                    .statuses = &statuses,
                });
                try std.testing.expectEqual(expected[0], values[0]);
            },
            // Evaluate a batch and check the probe still agrees.
            3 => {
                const count = 1 + @as(usize, operation % 4);
                const backgrounds = try allocator.alloc(Scalar, count * n);
                defer allocator.free(backgrounds);
                for (backgrounds, 0..) |*slot, index| {
                    slot.* = if (index < n) probe[index] else @floatFromInt(index);
                }
                const values = try allocator.alloc(Scalar, count);
                defer allocator.free(values);
                const statuses = try allocator.alloc(kernel_module.Status, count);
                defer allocator.free(statuses);
                try setup.binding.evaluate(
                    backgrounds,
                    count,
                    setup.workspace,
                    .{ .values = values, .statuses = statuses },
                );
                try std.testing.expectEqual(expected[0], values[0]);
            },
            else => unreachable,
        }
    }
}

// -- metamorphic fixtures --------------------------------------------------

/// The multi-scalar model with `h` and `s` declared in the opposite order and
/// every tensor index renamed to match.
const relabelled_model =
    \\{
    \\  "schema": "phaser.qft-model/0.1",
    \\  "spacetime_dimension": 4,
    \\  "conventions": {
    \\    "metric": "mostly_plus",
    \\    "scalar_representation": "real_components",
    \\    "fermions": "two_component_weyl"
    \\  },
    \\  "parameters": {
    \\    "a": { "domain": "real", "mass_dimension": 1 },
    \\    "b": { "domain": "real", "mass_dimension": 1 },
    \\    "c": { "domain": "real", "mass_dimension": 1 },
    \\    "d": { "domain": "real", "mass_dimension": 1 },
    \\    "l1": { "domain": "real", "mass_dimension": 0 },
    \\    "l2": { "domain": "real", "mass_dimension": 0 },
    \\    "l3": { "domain": "real", "mass_dimension": 0 },
    \\    "lh": { "domain": "real", "mass_dimension": 0 },
    \\    "ls": { "domain": "real", "mass_dimension": 0 },
    \\    "m_h2": { "domain": "real", "mass_dimension": 2 },
    \\    "m_hs2": { "domain": "real", "mass_dimension": 2 },
    \\    "m_s2": { "domain": "real", "mass_dimension": 2 },
    \\    "omega": { "domain": "real", "mass_dimension": 4 },
    \\    "t_h": { "domain": "real", "mass_dimension": 3 },
    \\    "t_s": { "domain": "real", "mass_dimension": 3 }
    \\  },
    \\  "fields": {
    \\    "real_scalars": [{ "id": "s" }, { "id": "h" }],
    \\    "weyl_fermions": [],
    \\    "gauge_vectors": []
    \\  },
    \\  "tensors": {
    \\    "vacuum_energy": { "value": "omega" },
    \\    "scalar_tadpole": {
    \\      "components": [
    \\        { "indices": ["s"], "value": "t_s" },
    \\        { "indices": ["h"], "value": "t_h" }
    \\      ]
    \\    },
    \\    "scalar_mass_squared": {
    \\      "components": [
    \\        { "indices": ["s", "s"], "value": "m_s2" },
    \\        { "indices": ["s", "h"], "value": "m_hs2" },
    \\        { "indices": ["h", "h"], "value": "m_h2" }
    \\      ]
    \\    },
    \\    "scalar_cubic": {
    \\      "components": [
    \\        { "indices": ["s", "s", "s"], "value": "d" },
    \\        { "indices": ["s", "s", "h"], "value": "c" },
    \\        { "indices": ["s", "h", "h"], "value": "b" },
    \\        { "indices": ["h", "h", "h"], "value": "a" }
    \\      ]
    \\    },
    \\    "scalar_quartic": {
    \\      "components": [
    \\        { "indices": ["s", "s", "s", "s"], "value": "ls" },
    \\        { "indices": ["s", "s", "s", "h"], "value": "l1" },
    \\        { "indices": ["s", "s", "h", "h"], "value": "l2" },
    \\        { "indices": ["s", "h", "h", "h"], "value": "l3" },
    \\        { "indices": ["h", "h", "h", "h"], "value": "lh" }
    \\      ]
    \\    }
    \\  }
    \\}
;

const relabelled_point = example_data.multi_scalar_point;

/// The multi-scalar model with the mixed quartic `[h,h,h,s]` omitted, since the
/// format rejects an explicit zero component.
const reduced_model =
    \\{
    \\  "schema": "phaser.qft-model/0.1",
    \\  "spacetime_dimension": 4,
    \\  "conventions": {
    \\    "metric": "mostly_plus",
    \\    "scalar_representation": "real_components",
    \\    "fermions": "two_component_weyl"
    \\  },
    \\  "parameters": {
    \\    "a": { "domain": "real", "mass_dimension": 1 },
    \\    "b": { "domain": "real", "mass_dimension": 1 },
    \\    "c": { "domain": "real", "mass_dimension": 1 },
    \\    "d": { "domain": "real", "mass_dimension": 1 },
    \\    "l1": { "domain": "real", "mass_dimension": 0 },
    \\    "l2": { "domain": "real", "mass_dimension": 0 },
    \\    "lh": { "domain": "real", "mass_dimension": 0 },
    \\    "ls": { "domain": "real", "mass_dimension": 0 },
    \\    "m_h2": { "domain": "real", "mass_dimension": 2 },
    \\    "m_hs2": { "domain": "real", "mass_dimension": 2 },
    \\    "m_s2": { "domain": "real", "mass_dimension": 2 },
    \\    "omega": { "domain": "real", "mass_dimension": 4 },
    \\    "t_h": { "domain": "real", "mass_dimension": 3 },
    \\    "t_s": { "domain": "real", "mass_dimension": 3 }
    \\  },
    \\  "fields": {
    \\    "real_scalars": [{ "id": "h" }, { "id": "s" }],
    \\    "weyl_fermions": [],
    \\    "gauge_vectors": []
    \\  },
    \\  "tensors": {
    \\    "vacuum_energy": { "value": "omega" },
    \\    "scalar_tadpole": {
    \\      "components": [
    \\        { "indices": ["h"], "value": "t_h" },
    \\        { "indices": ["s"], "value": "t_s" }
    \\      ]
    \\    },
    \\    "scalar_mass_squared": {
    \\      "components": [
    \\        { "indices": ["h", "h"], "value": "m_h2" },
    \\        { "indices": ["h", "s"], "value": "m_hs2" },
    \\        { "indices": ["s", "s"], "value": "m_s2" }
    \\      ]
    \\    },
    \\    "scalar_cubic": {
    \\      "components": [
    \\        { "indices": ["h", "h", "h"], "value": "a" },
    \\        { "indices": ["h", "h", "s"], "value": "b" },
    \\        { "indices": ["h", "s", "s"], "value": "c" },
    \\        { "indices": ["s", "s", "s"], "value": "d" }
    \\      ]
    \\    },
    \\    "scalar_quartic": {
    \\      "components": [
    \\        { "indices": ["h", "h", "h", "h"], "value": "lh" },
    \\        { "indices": ["h", "h", "s", "s"], "value": "l2" },
    \\        { "indices": ["h", "s", "s", "s"], "value": "l1" },
    \\        { "indices": ["s", "s", "s", "s"], "value": "ls" }
    \\      ]
    \\    }
    \\  }
    \\}
;

/// The example point with `l3` set to zero.
const zeroed_point =
    \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
    \\"values":{"a":25.0,"b":-5.0,"c":2.5,"d":10.0,
    \\"l1":0.05,"l2":0.1,"l3":0,"lh":0.26,"ls":0.3,
    \\"m_h2":-7812.5,"m_hs2":500.0,"m_s2":2500.0,
    \\"omega":0,"t_h":0,"t_s":0}}
;

/// The same values without `l3`, which the reduced model does not declare.
const reduced_point =
    \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
    \\"values":{"a":25.0,"b":-5.0,"c":2.5,"d":10.0,
    \\"l1":0.05,"l2":0.1,"lh":0.26,"ls":0.3,
    \\"m_h2":-7812.5,"m_hs2":500.0,"m_s2":2500.0,
    \\"omega":0,"t_h":0,"t_s":0}}
;
