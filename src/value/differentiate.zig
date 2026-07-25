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

const std = @import("std");
const graph_module = @import("graph.zig");
const limits_module = @import("limits.zig");

const Builder = graph_module.Builder;
const ValueId = graph_module.ValueId;
const BuildError = graph_module.BuildError;

/// Differentiates `root` with respect to background coordinate `coordinate`.
///
/// `coordinate_dimension` is the mass dimension of that coordinate. It fixes
/// the dimension of the exact zeros produced for coordinate-independent nodes,
/// which is otherwise unobservable from the node alone.
pub fn differentiate(
    builder: *Builder,
    root: ValueId,
    coordinate: u32,
    coordinate_dimension: i32,
) BuildError!ValueId {
    const count = root.toUsize() + 1;

    // Snapshot the frontier. Construction appends new nodes beyond `count`;
    // those are already derivatives and are never revisited by this sweep.
    var derivative = builder.allocator.alloc(ValueId, count) catch
        return error.OutOfMemory;
    defer builder.allocator.free(derivative);

    var factors = std.ArrayList(ValueId).empty;
    defer factors.deinit(builder.allocator);
    var terms = std.ArrayList(ValueId).empty;
    defer terms.deinit(builder.allocator);

    for (0..count) |index| {
        // Copied by value. Operand slices point into the arena and stay valid
        // even when the value list reallocates during construction below.
        const item = builder.values.items[index];
        const zero_dimension = std.math.sub(
            i32,
            item.mass_dimension,
            coordinate_dimension,
        ) catch return error.DimensionOverflow;

        derivative[index] = switch (item.node) {
            .rational, .pi, .sqrt_rational, .parameter => try builder.zero(zero_dimension),

            .background => |background| if (background.index == coordinate)
                try builder.one()
            else
                try builder.zero(zero_dimension),

            .add => |children| blk: {
                terms.clearRetainingCapacity();
                for (children) |child| {
                    terms.append(builder.allocator, derivative[child.toUsize()]) catch
                        return error.OutOfMemory;
                }
                break :blk try builder.add(terms.items);
            },

            // Product rule over an n-ary product: one term per factor, with
            // that factor replaced by its derivative. Factors whose derivative
            // is an exact zero collapse their whole term, and the zero terms
            // are then dropped by `add`.
            .multiply => |children| blk: {
                terms.clearRetainingCapacity();
                for (children, 0..) |_, replaced| {
                    factors.clearRetainingCapacity();
                    for (children, 0..) |factor, position| {
                        const contribution = if (position == replaced)
                            derivative[factor.toUsize()]
                        else
                            factor;
                        factors.append(builder.allocator, contribution) catch
                            return error.OutOfMemory;
                    }
                    terms.append(
                        builder.allocator,
                        try builder.multiply(factors.items),
                    ) catch return error.OutOfMemory;
                }
                break :blk try builder.add(terms.items);
            },

            // (n/d)' = (n' d - n d') / d^2
            .divide => |binary| blk: {
                const numerator = binary.numerator;
                const denominator = binary.denominator;
                const left = try builder.multiply(&.{
                    derivative[numerator.toUsize()],
                    denominator,
                });
                const right = try builder.multiply(&.{
                    numerator,
                    derivative[denominator.toUsize()],
                });
                break :blk try builder.divide(
                    try builder.subtract(left, right),
                    try builder.power(denominator, 2),
                );
            },

            // (b^e)' = e b^(e-1) b'
            .power => |power_node| blk: {
                const base = power_node.base;
                const inner = derivative[base.toUsize()];
                if (builder.isZero(inner)) break :blk try builder.zero(zero_dimension);
                break :blk try builder.multiply(&.{
                    try builder.integer(@intCast(power_node.exponent), 0),
                    try builder.power(base, power_node.exponent - 1),
                    inner,
                });
            },
        };
    }

    return derivative[root.toUsize()];
}

/// Differentiates with respect to every coordinate in order.
///
/// Results are written into `out`, which must have one slot per coordinate.
pub fn gradient(
    builder: *Builder,
    root: ValueId,
    coordinate_dimension: i32,
    out: []ValueId,
) BuildError!void {
    for (out, 0..) |*slot, coordinate| {
        slot.* = try differentiate(
            builder,
            root,
            @intCast(coordinate),
            coordinate_dimension,
        );
    }
}

/// Differentiates twice with respect to every ordered coordinate pair.
///
/// `out` is row-major with `count * count` slots. Only the lower triangle is
/// differentiated; the transpose is filled by symmetry of mixed partials, which
/// interning makes an identifier assignment rather than a repeated derivation.
pub fn hessian(
    builder: *Builder,
    root: ValueId,
    coordinate_dimension: i32,
    count: usize,
    out: []ValueId,
) BuildError!void {
    std.debug.assert(out.len == count * count);

    const first = builder.allocator.alloc(ValueId, count) catch return error.OutOfMemory;
    defer builder.allocator.free(first);
    try gradient(builder, root, coordinate_dimension, first);

    for (0..count) |row| {
        for (0..row + 1) |column| {
            const second = try differentiate(
                builder,
                first[row],
                @intCast(column),
                coordinate_dimension,
            );
            out[row * count + column] = second;
            out[column * count + row] = second;
        }
    }
}

// -- tests -----------------------------------------------------------------

const testing_limits = limits_module.ValueLimits{};

test "derivatives of coordinate-independent nodes are exactly zero" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const lambda = try builder.parameter(0, "lambda", 0);
    const derivative = try differentiate(&builder, lambda, 0, 1);
    try std.testing.expect(builder.isZero(derivative));
    try std.testing.expectEqual(@as(i32, -1), builder.massDimension(derivative));
}

test "a coordinate differentiates to exactly one" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const derivative = try differentiate(&builder, phi, 0, 1);
    try std.testing.expectEqual(try builder.one(), derivative);
}

test "an unrelated coordinate differentiates to exactly zero" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const h = try builder.background(0, "h", 1);
    const derivative = try differentiate(&builder, h, 1, 1);
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

    const derived = try differentiate(&builder, model.potential, 0, 1);

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
    try hessian(&builder, model.potential, 1, 1, &second);

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
    try hessian(&builder, potential, 1, 2, &second);
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
    const derived = try differentiate(&builder, cubic, 0, 1);
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
    const derived = try differentiate(&builder, quotient, 0, 1);

    // (n' d - n d') / d^2 with d' exactly zero. No common factor is cancelled
    // against a non-constant denominator, so the reference keeps that form.
    const expected = try builder.divide(
        try builder.multiply(&.{
            try differentiate(&builder, numerator, 0, 1),
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
    const first = try differentiate(&builder, cubic, 0, 1);
    const middle = builder.nodeCount();
    const second = try differentiate(&builder, cubic, 0, 1);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(middle, builder.nodeCount());
    try std.testing.expect(middle > before);
}

test "derivative graph growth stays proportional to the source graph" {
    var builder = try Builder.init(std.testing.allocator, testing_limits);
    defer builder.deinit();

    const model = try buildPhi4(&builder);
    const source_nodes = builder.nodeCount();
    _ = try differentiate(&builder, model.potential, 0, 1);
    const added = builder.nodeCount() - source_nodes;

    // Decision 0003 records that one directional derivative adds nodes
    // proportional to graph size. A small constant factor is the claim under
    // test; an exponential expansion would fail here first.
    try std.testing.expect(added <= 4 * source_nodes);
}
