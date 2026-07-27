//! Integration coverage from a loaded model into the derived Typed Value IR.
//!
//! These tests use only the public interface, and they consume the same example
//! models the conformance fixtures reference.

const std = @import("std");
const test_allocator = @import("test_allocator");
const phaser = @import("phaser");
const example_data = @import("example_data");

const value = phaser.value;

fn loadModel(source: []const u8) !phaser.Model {
    const context = switch (phaser.Context.init(test_allocator.allocator, .{
        .max_diagnostics = 16,
        .max_related_locations = 32,
    })) {
        .context => |value_context| value_context,
        .failure => return error.InvalidContext,
    };
    const result = try phaser.loadModel(context, .{
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

test "model expressions import into one shared value arena" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();

    var builder = try value.Builder.init(test_allocator.allocator, .{});
    errdefer builder.deinit();

    // Every model expression lands in the same arena, so shared structure is
    // shared storage rather than a per-expression copy.
    var roots: [8]value.ValueId = undefined;
    var count: usize = 0;
    for (model.expressions()) |*item| {
        roots[count] = try value.importExpression(&builder, item);
        count += 1;
    }
    try std.testing.expectEqual(model.expressions().len, count);

    var graph = try builder.finish();
    defer graph.deinit();
    try std.testing.expect(graph.audit());

    for (roots[0..count]) |root| {
        try std.testing.expect(root.toUsize() < graph.values.len);
    }
}

test "importing the same expression twice yields one identifier" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();

    var builder = try value.Builder.init(test_allocator.allocator, .{});
    defer builder.deinit();

    const quartic = model.scalarTensorExpression(.scalar_quartic, &.{ 0, 0, 0, 0 }).?;
    const first = try value.importExpression(&builder, quartic);
    const nodes_after_first = builder.nodeCount();
    const second = try value.importExpression(&builder, quartic);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(nodes_after_first, builder.nodeCount());
}

test "the multi-scalar mass tensor imports with its declared dimensions" {
    var model = try loadModel(example_data.multi_scalar_model);
    defer model.deinit();

    var builder = try value.Builder.init(test_allocator.allocator, .{});
    defer builder.deinit();

    // Every scalar_mass_squared component carries mass dimension 2.
    for ([_][2]u32{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |indices| {
        const component = model.scalarTensorExpression(
            .scalar_mass_squared,
            &indices,
        ).?;
        const imported = try value.importExpression(&builder, component);
        try std.testing.expectEqual(@as(i32, 2), builder.massDimension(imported));
    }
}

test "a background-dependent potential differentiates to its exact gradient" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();

    var builder = try value.Builder.init(test_allocator.allocator, .{});
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const mass_squared = try value.importExpression(
        &builder,
        model.scalarTensorExpression(.scalar_mass_squared, &.{ 0, 0 }).?,
    );
    const quartic = try value.importExpression(
        &builder,
        model.scalarTensorExpression(.scalar_quartic, &.{ 0, 0, 0, 0 }).?,
    );

    // The orbit coefficients of the classical-potential specification: a rank-2
    // component with one repeated index divides by 2!, a rank-4 by 4!.
    const potential = try builder.add(&.{
        try builder.divide(
            try builder.multiply(&.{ mass_squared, try builder.power(phi, 2) }),
            try builder.integer(2, 0),
        ),
        try builder.divide(
            try builder.multiply(&.{ quartic, try builder.power(phi, 4) }),
            try builder.integer(24, 0),
        ),
    });
    try std.testing.expectEqual(@as(i32, 4), builder.massDimension(potential));

    const background = value.Background{ .order = &.{0}, .mass_dimension = 1 };
    const derived = try value.differentiate(&builder, potential, background, 0);

    // m2 phi + (lambda / 6) phi^3, the fixture's tree_gradient identity.
    const expected = try builder.add(&.{
        try builder.multiply(&.{ mass_squared, phi }),
        try builder.divide(
            try builder.multiply(&.{ quartic, try builder.power(phi, 3) }),
            try builder.integer(6, 0),
        ),
    });
    try std.testing.expectEqual(expected, derived);
    try std.testing.expectEqual(@as(i32, 3), builder.massDimension(derived));
}
