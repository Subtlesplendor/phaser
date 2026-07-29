//! Exact symbolic differentiation of the Typed Value IR.
//!
//! Selected in decision 0003. Derivatives are ordinary nodes in the same arena,
//! so they are interned, exportable, and lowered by the same path as values.
//!
//! The pass is a single forward sweep over the value array. Every operand
//! refers to a strictly earlier node, so one sweep in index order visits each
//! node after its children. This is the forward-mode recurrence evaluated on
//! symbols: one directional derivative adds nodes proportional to graph size,
//! not exponentially, because the graph is interned and shared.
//!
//! One sweep produces the derivative with respect to every background
//! coordinate at once. That is not only cheaper than repeating the sweep: a
//! spectral value's derivative is the invariant gradient node of decision 0009,
//! whose operands are the mass matrix's derivative with respect to *every*
//! coordinate, so the whole-gradient sweep is what makes the spectral chain
//! expressible without recursion.

const std = @import("std");
const graph_module = @import("graph.zig");
const limits_module = @import("limits.zig");

const Builder = graph_module.Builder;
const ValueId = graph_module.ValueId;
const BuildError = graph_module.BuildError;

/// The background coordinates a derivative is taken with respect to.
pub const Background = struct {
    /// Canonical coordinate order. It participates in spectral derivative node
    /// identity, so it is passed explicitly rather than inferred from a count.
    order: []const u32,
    /// Mass dimension of every coordinate. It fixes the dimension of the exact
    /// zeros produced for coordinate-independent nodes, which is otherwise
    /// unobservable from the node alone.
    mass_dimension: i32,

    pub fn count(self: Background) usize {
        return self.order.len;
    }
};

/// Differentiates `root` with respect to every coordinate, in order.
///
/// `out` must have one slot per coordinate.
pub fn gradient(
    builder: *Builder,
    root: ValueId,
    background: Background,
    out: []ValueId,
) BuildError!void {
    std.debug.assert(out.len == background.count());
    // With no coordinates there is nothing to differentiate with respect to,
    // and sweeping anyway would build derivative nodes no caller asked for.
    if (background.count() == 0) return;

    var sweep = Sweep{ .builder = builder, .background = background };
    defer sweep.deinit();
    try sweep.run(root);
    for (out, 0..) |*slot, coordinate| {
        slot.* = try sweep.require(root, coordinate);
    }
}

/// Differentiates `root` with respect to one coordinate position.
pub fn differentiate(
    builder: *Builder,
    root: ValueId,
    background: Background,
    position: usize,
) BuildError!ValueId {
    // A caller precondition, not a validated input: every legitimate call
    // already has `position < background.count()`, so no test built from
    // legitimate usage can distinguish `<` from `<=` here -- both accept the
    // same calls a correct caller makes. The only way to exercise the
    // boundary itself is to call with `position == background.count()`,
    // which is invalid usage by definition and (as an `assert`, not a
    // catchable error) would abort the test process rather than fail a
    // single test. Kept as a guard against a future caller bug.
    std.debug.assert(position < background.count());

    var sweep = Sweep{ .builder = builder, .background = background };
    defer sweep.deinit();
    try sweep.run(root);
    return sweep.require(root, position);
}

/// Differentiates twice with respect to every ordered coordinate pair.
///
/// `out` is row-major with `count * count` slots. Mixed partials agree by
/// construction: a polynomial second derivative interns to one node either way,
/// and a spectral second derivative selects from a symmetric matrix whose
/// element access is normalized to one triangle.
pub fn hessian(
    builder: *Builder,
    root: ValueId,
    background: Background,
    out: []ValueId,
) BuildError!void {
    const count = background.count();
    std.debug.assert(out.len == count * count);

    const first = builder.allocator.alloc(ValueId, count) catch return error.OutOfMemory;
    defer builder.allocator.free(first);
    try gradient(builder, root, background, first);

    for (0..count) |row| {
        try gradient(builder, first[row], background, out[row * count ..][0..count]);
    }
}

/// One forward sweep computing every coordinate derivative of every node
/// reachable from a root.
const Sweep = struct {
    builder: *Builder,
    background: Background,
    /// Row-major `frontier * coordinate_count`. A null entry marks a node kind
    /// that has no derivative expressible as one node; reading one is the
    /// unsupported-derivative-order failure.
    derivative: []?ValueId = &.{},
    reachable: []bool = &.{},
    frontier: usize = 0,
    scratch: std.ArrayList(ValueId) = .empty,
    operands: std.ArrayList(ValueId) = .empty,

    fn deinit(self: *Sweep) void {
        const allocator = self.builder.allocator;
        if (self.derivative.len != 0) allocator.free(self.derivative);
        if (self.reachable.len != 0) allocator.free(self.reachable);
        self.scratch.deinit(allocator);
        self.operands.deinit(allocator);
    }

    fn count(self: *const Sweep) usize {
        return self.background.count();
    }

    fn slot(self: *Sweep, id: ValueId, coordinate: usize) *?ValueId {
        return &self.derivative[id.toUsize() * self.count() + coordinate];
    }

    /// The derivative of an already swept node, or the failure that a node kind
    /// has no representable derivative.
    fn require(self: *Sweep, id: ValueId, coordinate: usize) BuildError!ValueId {
        return self.slot(id, coordinate).* orelse error.UnsupportedDerivativeOrder;
    }

    fn run(self: *Sweep, root: ValueId) BuildError!void {
        const allocator = self.builder.allocator;
        self.frontier = root.toUsize() + 1;

        // Restricting the sweep to the reachable set is not only an
        // optimization: an unreachable spectral result would otherwise fail the
        // whole derivation for a root that never depends on it.
        self.reachable = allocator.alloc(bool, self.frontier) catch
            return error.OutOfMemory;
        @memset(self.reachable, false);
        self.reachable[root.toUsize()] = true;
        var index = self.frontier;
        while (index > 0) {
            index -= 1;
            if (!self.reachable[index]) continue;
            const node = self.builder.values.items[index].node;
            var position: usize = 0;
            while (graph_module.childAt(node, position)) |child| : (position += 1) {
                self.reachable[child.toUsize()] = true;
            }
        }

        const slots = std.math.mul(usize, self.frontier, self.count()) catch
            return error.CapacityExceeded;
        self.derivative = allocator.alloc(?ValueId, slots) catch return error.OutOfMemory;
        @memset(self.derivative, null);

        for (0..self.frontier) |position| {
            if (!self.reachable[position]) continue;
            try self.visit(ValueId.fromUsize(position) catch unreachable);
        }
    }

    fn visit(self: *Sweep, id: ValueId) BuildError!void {
        // Copied by value. Operand slices point into the arena and stay valid
        // even when the value list reallocates during construction below.
        const item = self.builder.values.items[id.toUsize()];
        const zero_dimension = std.math.sub(
            i32,
            item.mass_dimension,
            self.background.mass_dimension,
        ) catch return error.DimensionOverflow;

        switch (item.node) {
            .rational,
            .pi,
            .sqrt_rational,
            .parameter,
            .renormalization_scale,
            => {
                const exact_zero = try self.builder.zero(zero_dimension);
                for (0..self.count()) |coordinate| {
                    self.slot(id, coordinate).* = exact_zero;
                }
            },

            .background => |input| {
                for (self.background.order, 0..) |declared, coordinate| {
                    self.slot(id, coordinate).* = if (declared == input.index)
                        try self.builder.one()
                    else
                        try self.builder.zero(zero_dimension);
                }
            },

            .add => |children| {
                for (0..self.count()) |coordinate| {
                    self.scratch.clearRetainingCapacity();
                    for (children) |child| {
                        self.scratch.append(
                            self.builder.allocator,
                            try self.require(child, coordinate),
                        ) catch return error.OutOfMemory;
                    }
                    self.slot(id, coordinate).* = try self.builder.add(self.scratch.items);
                }
            },

            // Product rule over an n-ary product: one term per factor, with
            // that factor replaced by its derivative. Factors whose derivative
            // is an exact zero collapse their whole term, and the zero terms
            // are then dropped by `add`.
            .multiply => |children| {
                for (0..self.count()) |coordinate| {
                    self.scratch.clearRetainingCapacity();
                    for (children, 0..) |_, replaced| {
                        self.operands.clearRetainingCapacity();
                        for (children, 0..) |factor, position| {
                            const contribution = if (position == replaced)
                                try self.require(factor, coordinate)
                            else
                                factor;
                            self.operands.append(
                                self.builder.allocator,
                                contribution,
                            ) catch return error.OutOfMemory;
                        }
                        self.scratch.append(
                            self.builder.allocator,
                            try self.builder.multiply(self.operands.items),
                        ) catch return error.OutOfMemory;
                    }
                    self.slot(id, coordinate).* = try self.builder.add(self.scratch.items);
                }
            },

            // (n/d)' = (n' d - n d') / d^2
            .divide => |binary| {
                const squared = try self.builder.power(binary.denominator, 2);
                for (0..self.count()) |coordinate| {
                    const left = try self.builder.multiply(&.{
                        try self.require(binary.numerator, coordinate),
                        binary.denominator,
                    });
                    const right = try self.builder.multiply(&.{
                        binary.numerator,
                        try self.require(binary.denominator, coordinate),
                    });
                    self.slot(id, coordinate).* = try self.builder.divide(
                        try self.builder.subtract(left, right),
                        squared,
                    );
                }
            },

            // (b^e)' = e b^(e-1) b'
            .power => |power_node| {
                for (0..self.count()) |coordinate| {
                    const inner = try self.require(power_node.base, coordinate);
                    self.slot(id, coordinate).* = if (self.builder.isZero(inner))
                        try self.builder.zero(zero_dimension)
                    else
                        try self.builder.multiply(&.{
                            try self.builder.integer(@intCast(power_node.exponent), 0),
                            try self.builder.power(
                                power_node.base,
                                power_node.exponent - 1,
                            ),
                            inner,
                        });
                }
            },

            // Promotion is the exact inclusion of the reals, so it commutes
            // with differentiation.
            .promote_real_to_complex => |operand| {
                for (0..self.count()) |coordinate| {
                    self.slot(id, coordinate).* = try self.builder.promoteRealToComplex(
                        try self.require(operand, coordinate),
                    );
                }
            },

            // Each stored entry differentiates in place, which preserves both
            // its position and the matrix's symmetry.
            .real_symmetric_matrix => |matrix| {
                for (0..self.count()) |coordinate| {
                    self.scratch.clearRetainingCapacity();
                    for (matrix.entries) |entry| {
                        self.scratch.append(
                            self.builder.allocator,
                            try self.require(entry, coordinate),
                        ) catch return error.OutOfMemory;
                    }
                    self.slot(id, coordinate).* = try self.builder.realSymmetricMatrix(
                        matrix.dimension,
                        self.scratch.items,
                        zero_dimension,
                    );
                }
            },

            .scalar_one_loop_spectral_value => try self.visitSpectralValue(id, item),

            // A structured spectral result has no derivative as one node. Its
            // elements do, and `element` handles them below without consulting
            // these slots.
            .scalar_one_loop_spectral_gradient, .scalar_one_loop_spectral_hessian => {},

            .element => try self.visitElement(id, item.node.element),
        }
    }

    /// The derivative of the invariant spectral value is the invariant gradient
    /// node fixed by decision 0009, never a derivative of an eigenvalue label
    /// or an eigenvector phase.
    fn visitSpectralValue(
        self: *Sweep,
        id: ValueId,
        item: graph_module.Value,
    ) BuildError!void {
        const spectral = item.node.scalar_one_loop_spectral_value;
        self.scratch.clearRetainingCapacity();
        for (0..self.count()) |coordinate| {
            self.scratch.append(
                self.builder.allocator,
                try self.require(spectral.matrix, coordinate),
            ) catch return error.OutOfMemory;
        }
        const node = try self.builder.scalarOneLoopSpectralGradient(
            id,
            self.background.order,
            self.scratch.items,
        );
        for (0..self.count()) |coordinate| {
            self.slot(id, coordinate).* = try self.builder.element(
                node,
                @intCast(coordinate),
                0,
            );
        }
    }

    fn visitElement(
        self: *Sweep,
        id: ValueId,
        selection: graph_module.Element,
    ) BuildError!void {
        switch (self.builder.value(selection.source).node) {
            .scalar_one_loop_spectral_gradient => |derivative| {
                const node = try self.spectralHessian(derivative);
                for (0..self.count()) |coordinate| {
                    self.slot(id, coordinate).* = try self.builder.element(
                        node,
                        selection.row,
                        @intCast(coordinate),
                    );
                }
            },
            // Milestone 3 implements the first two background derivatives of a
            // spectral value. A third is rejected here rather than approximated.
            .scalar_one_loop_spectral_hessian => return error.UnsupportedDerivativeOrder,
            else => {
                for (0..self.count()) |coordinate| {
                    self.slot(id, coordinate).* = try self.builder.element(
                        try self.require(selection.source, coordinate),
                        selection.row,
                        selection.column,
                    );
                }
            },
        }
    }

    /// Builds the Hessian node of a spectral gradient.
    ///
    /// The second-derivative matrices are the sweep's own derivatives of the
    /// gradient's first-derivative matrices, so no separate pass is needed.
    fn spectralHessian(
        self: *Sweep,
        derivative: graph_module.SpectralDerivative,
    ) BuildError!ValueId {
        if (!std.mem.eql(u32, derivative.coordinates, self.background.order)) {
            return error.CoordinateOrderMismatch;
        }
        self.operands.clearRetainingCapacity();
        for (derivative.first, 0..) |matrix, row| {
            for (row..self.count()) |column| {
                self.operands.append(
                    self.builder.allocator,
                    try self.require(matrix, column),
                ) catch return error.OutOfMemory;
            }
        }
        return self.builder.scalarOneLoopSpectralHessian(
            derivative.value,
            derivative.coordinates,
            derivative.first,
            self.operands.items,
        );
    }
};

// -- tests -----------------------------------------------------------------

const testing_limits = limits_module.ValueLimits{};

const one_coordinate = Background{ .order = &.{0}, .mass_dimension = 1 };
const two_coordinates = Background{ .order = &.{ 0, 1 }, .mass_dimension = 1 };

test "derivatives of coordinate-independent nodes are exactly zero" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const lambda = try builder.parameter(0, "lambda", 0);
    const derivative = try differentiate(&builder, lambda, one_coordinate, 0);
    try std.testing.expect(builder.isZero(derivative));
    try std.testing.expectEqual(@as(i32, -1), builder.massDimension(derivative));
}

test "a coordinate differentiates to exactly one" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const derivative = try differentiate(&builder, phi, one_coordinate, 0);
    try std.testing.expectEqual(try builder.one(), derivative);
}

test "an unrelated coordinate differentiates to exactly zero" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const h = try builder.background(0, "h", 1);
    const derivative = try differentiate(&builder, h, two_coordinates, 1);
    try std.testing.expect(builder.isZero(derivative));
}

/// The phi^4 tree potential and its exact gradient, from the `scalar.phi4`
/// conformance fixture:
///
///     V = omega + (m2 / 2) phi^2 + (lambda / 24) phi^4
///     V' = m2 phi + (lambda / 6) phi^3
fn buildPhi4(builder: *Builder) !struct { potential: ValueId, phi: ValueId } {
    const omega = try builder.parameter(0, "omega", 4);
    const mass_squared = try builder.parameter(1, "m2", 2);
    const lambda = try builder.parameter(2, "lambda", 0);
    const phi = try builder.background(0, "phi", 1);

    const quadratic = try builder.divide(
        try builder.multiply(&.{ mass_squared, try builder.power(phi, 2) }),
        try builder.integer(2, 0),
    );
    const quartic = try builder.divide(
        try builder.multiply(&.{ lambda, try builder.power(phi, 4) }),
        try builder.integer(24, 0),
    );
    return .{
        .potential = try builder.add(&.{ omega, quadratic, quartic }),
        .phi = phi,
    };
}

test "the phi4 gradient equals its independent reference" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const model = try buildPhi4(&builder);
    try std.testing.expectEqual(@as(i32, 4), builder.massDimension(model.potential));

    const derived = try differentiate(&builder, model.potential, one_coordinate, 0);

    const mass_squared = try builder.parameter(1, "m2", 2);
    const lambda = try builder.parameter(2, "lambda", 0);
    const expected = try builder.add(&.{
        try builder.multiply(&.{ mass_squared, model.phi }),
        try builder.divide(
            try builder.multiply(&.{ lambda, try builder.power(model.phi, 3) }),
            try builder.integer(6, 0),
        ),
    });

    // Interning makes structural equality an identifier comparison.
    try std.testing.expectEqual(expected, derived);
    try std.testing.expectEqual(@as(i32, 3), builder.massDimension(derived));
}

test "the phi4 second derivative equals its independent reference" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const model = try buildPhi4(&builder);
    var second: [1]ValueId = undefined;
    try hessian(&builder, model.potential, one_coordinate, &second);

    const mass_squared = try builder.parameter(1, "m2", 2);
    const lambda = try builder.parameter(2, "lambda", 0);
    const expected = try builder.add(&.{
        mass_squared,
        try builder.divide(
            try builder.multiply(&.{ lambda, try builder.power(model.phi, 2) }),
            try builder.integer(2, 0),
        ),
    });

    try std.testing.expectEqual(expected, second[0]);
    try std.testing.expectEqual(@as(i32, 2), builder.massDimension(second[0]));
}

test "mixed partials agree and the Hessian is symmetric" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const coupling = try builder.parameter(0, "g", 0);
    const h = try builder.background(0, "h", 1);
    const s = try builder.background(1, "s", 1);

    // g h^2 s^2, whose mixed partial is 4 g h s.
    const potential = try builder.multiply(&.{
        coupling,
        try builder.power(h, 2),
        try builder.power(s, 2),
    });

    var second: [4]ValueId = undefined;
    try hessian(&builder, potential, two_coordinates, &second);
    try std.testing.expectEqual(second[1], second[2]);

    const expected = try builder.multiply(&.{
        try builder.integer(4, 0),
        coupling,
        h,
        s,
    });
    try std.testing.expectEqual(expected, second[1]);
}

test "a constant divisor differentiates through the folded coefficient" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);

    // d/dphi (phi^3 / 6) = phi^2 / 2
    const cubic = try builder.divide(try builder.power(phi, 3), try builder.integer(6, 0));
    const derived = try differentiate(&builder, cubic, one_coordinate, 0);
    const expected = try builder.divide(
        try builder.power(phi, 2),
        try builder.integer(2, 0),
    );
    try std.testing.expectEqual(expected, derived);
}

test "a non-constant divisor follows the quotient rule literally" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const mass = try builder.parameter(0, "m", 1);

    const numerator = try builder.power(phi, 2);
    const quotient = try builder.divide(numerator, mass);
    const derived = try differentiate(&builder, quotient, one_coordinate, 0);

    // (n' d - n d') / d^2 with d' exactly zero. No common factor is cancelled
    // against a non-constant denominator, so the reference keeps that form.
    const expected = try builder.divide(
        try builder.multiply(&.{
            try differentiate(&builder, numerator, one_coordinate, 0),
            mass,
        }),
        try builder.power(mass, 2),
    );
    try std.testing.expectEqual(expected, derived);
}

test "differentiating a shared subgraph twice reuses one derivative" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const cubic = try builder.power(phi, 3);

    const before = builder.nodeCount();
    const first = try differentiate(&builder, cubic, one_coordinate, 0);
    const middle = builder.nodeCount();
    const second = try differentiate(&builder, cubic, one_coordinate, 0);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(middle, builder.nodeCount());
    try std.testing.expect(middle > before);
}

test "derivative graph growth stays proportional to the source graph" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const model = try buildPhi4(&builder);
    const source_nodes = builder.nodeCount();
    _ = try differentiate(&builder, model.potential, one_coordinate, 0);
    const added = builder.nodeCount() - source_nodes;

    // Decision 0003 records that one directional derivative adds nodes
    // proportional to graph size. A small constant factor is the claim under
    // test; an exponential expansion would fail here first.
    try std.testing.expect(added <= 4 * source_nodes);
}

// -- spectral derivatives ---------------------------------------------------

const SpectralFixture = struct {
    scale: ValueId,
    matrix: ValueId,
    value: ValueId,
    coordinates: [2]ValueId,
};

/// A two-coordinate mass matrix whose entries depend on both backgrounds, so
/// that every first- and second-derivative matrix is nonzero.
fn buildSpectral(builder: *Builder) !SpectralFixture {
    const h = try builder.background(0, "h", 1);
    const s = try builder.background(1, "s", 1);
    const coupling = try builder.parameter(0, "g", 0);

    const hh = try builder.multiply(&.{ coupling, try builder.power(h, 2) });
    const hs = try builder.multiply(&.{ coupling, h, s });
    const ss = try builder.multiply(&.{ coupling, try builder.power(s, 2) });

    const matrix = try builder.realSymmetricMatrix(
        2,
        &.{ hh, hs, ss },
        graph_module.mass_squared_dimension,
    );
    const scale = try builder.renormalizationScale(0, "muR");
    return .{
        .scale = scale,
        .matrix = matrix,
        .value = try builder.scalarOneLoopSpectralValue(matrix, scale),
        .coordinates = .{ h, s },
    };
}

test "a spectral value differentiates to the invariant gradient node" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const fixture = try buildSpectral(&builder);
    var first: [2]ValueId = undefined;
    try gradient(&builder, fixture.value, two_coordinates, &first);

    // Each component selects from one shared gradient node, so the derivative
    // is the invariant spectral operation rather than a derivative of an
    // eigenvalue label.
    const component = builder.value(first[0]).node.element;
    try std.testing.expectEqual(@as(u32, 0), component.row);
    const node = builder.value(component.source).node.scalar_one_loop_spectral_gradient;
    try std.testing.expectEqual(fixture.value, node.value);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, node.coordinates);
    try std.testing.expectEqual(
        component.source,
        builder.value(first[1]).node.element.source,
    );

    // Its first-derivative operands are the differentiated mass matrices, in
    // canonical coordinate order and still real symmetric matrices.
    for (node.first, 0..) |matrix, coordinate| {
        try std.testing.expect(builder.valueType(matrix).shape.matrix.symmetric);
        try std.testing.expectEqual(@as(u32, 2), builder.valueType(matrix).shape.matrix.dimension);
        try std.testing.expectEqual(@as(i32, 1), builder.massDimension(matrix));
        var expected: [2]ValueId = undefined;
        try gradient(&builder, fixture.matrix, two_coordinates, &expected);
        try std.testing.expectEqual(expected[coordinate], matrix);
    }
    try std.testing.expectEqual(@as(i32, 3), builder.massDimension(first[0]));
}

test "a spectral gradient differentiates to the invariant Hessian node" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const fixture = try buildSpectral(&builder);
    var second: [4]ValueId = undefined;
    try hessian(&builder, fixture.value, two_coordinates, &second);

    // Mixed partials agree as identifiers, because the Hessian node is a
    // symmetric matrix whose element access is normalized to one triangle.
    // Symmetry is therefore established, not manufactured by copying.
    try std.testing.expectEqual(second[1], second[2]);

    const node = builder.value(builder.value(second[0]).node.element.source)
        .node.scalar_one_loop_spectral_hessian;
    try std.testing.expectEqual(fixture.value, node.value);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, node.coordinates);
    try std.testing.expectEqual(@as(usize, 3), node.second.len);
    for (node.second) |matrix| {
        try std.testing.expectEqual(@as(i32, 0), builder.massDimension(matrix));
    }
    try std.testing.expectEqual(@as(i32, 2), builder.massDimension(second[0]));
}

test "a third spectral derivative is rejected rather than approximated" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const fixture = try buildSpectral(&builder);
    var second: [4]ValueId = undefined;
    try hessian(&builder, fixture.value, two_coordinates, &second);

    // Milestone 3 implements the first two background derivatives. A third has
    // no implemented invariant operation, so it fails instead of falling back
    // to finite differences.
    try std.testing.expectError(
        error.UnsupportedDerivativeOrder,
        differentiate(&builder, second[0], two_coordinates, 0),
    );
}

test "the scale input is not a background coordinate" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const fixture = try buildSpectral(&builder);
    const derivative = try differentiate(&builder, fixture.scale, two_coordinates, 0);
    try std.testing.expect(builder.isZero(derivative));
    try std.testing.expectEqual(@as(i32, 0), builder.massDimension(derivative));
}

test "a promoted real term differentiates through the promotion" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const h = try builder.background(0, "h", 1);
    const tree = try builder.multiply(&.{
        try builder.parameter(0, "g", 2),
        try builder.power(h, 2),
    });
    const promoted = try builder.promoteRealToComplex(tree);
    const derivative = try differentiate(&builder, promoted, two_coordinates, 0);

    // Promotion is the exact inclusion of the reals, so it commutes with
    // differentiation.
    try std.testing.expectEqual(
        try builder.promoteRealToComplex(try differentiate(&builder, tree, two_coordinates, 0)),
        derivative,
    );
}

test "an unreachable spectral result does not fail an unrelated derivative" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const fixture = try buildSpectral(&builder);
    var second: [4]ValueId = undefined;
    try hessian(&builder, fixture.value, two_coordinates, &second);

    // The Hessian components above are in the arena but are not reachable from
    // this root. Differentiating it must not consult them.
    const unrelated = try builder.power(fixture.coordinates[0], 3);
    const derivative = try differentiate(&builder, unrelated, two_coordinates, 0);
    try std.testing.expectEqual(
        try builder.multiply(&.{
            try builder.integer(3, 0),
            try builder.power(fixture.coordinates[0], 2),
        }),
        derivative,
    );
}
