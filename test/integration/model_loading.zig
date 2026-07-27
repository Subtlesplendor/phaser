const std = @import("std");
const phaser = @import("phaser");
const example_data = @import("example_data");
const conformance_fixture_data = @import("conformance_fixture_data");
const scalar_oracle_fixture = @import("scalar_oracle_fixture");

fn context() phaser.Context {
    return switch (phaser.Context.init(std.testing.allocator, .{
        .max_diagnostics = 32,
        .max_related_locations = 64,
    })) {
        .context => |value| value,
        .failure => unreachable,
    };
}

fn load(source: []const u8) !phaser.Model {
    const result = try phaser.loadModel(context(), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = source,
    }, .{ .audit = true });
    return switch (result) {
        .model => |model| model,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            return error.InvalidFixture;
        },
    };
}

test "public loader accepts the phi4 and multi-scalar conformance models" {
    var phi4 = try load(example_data.phi4_model);
    defer phi4.deinit();
    var multi = try load(example_data.multi_scalar_model);
    defer multi.deinit();

    try std.testing.expectEqual(@as(usize, 1), phi4.real_scalars.len);
    try std.testing.expectEqual(@as(usize, 2), multi.real_scalars.len);
    try std.testing.expectEqual(@as(usize, 15), multi.parameters.len);
}

test "public loader accepts the three-scalar conformance model" {
    var model = try load(
        conformance_fixture_data.three_scalar_model,
    );
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 3), model.real_scalars.len);
    try std.testing.expectEqual(@as(usize, 6), model.parameters.len);
    const cubic = model.tensor(.scalar_cubic) orelse
        return error.MissingCubicTensor;
    try std.testing.expectEqual(@as(usize, 6), cubic.components.len);
}

test "Milestone 3 conformance fixtures remain valid language-neutral JSON" {
    const fixtures = .{
        conformance_fixture_data.phi4_fixture,
        conformance_fixture_data.multi_scalar_fixture,
        conformance_fixture_data.three_scalar_fixture,
        scalar_oracle_fixture.cases,
    };
    inline for (fixtures) |fixture| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            fixture,
            .{
                .duplicate_field_behavior = .@"error",
                .parse_numbers = false,
                .allocate = .alloc_always,
            },
        );
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
}

test "sparse symmetric tensor lookup agrees across dense permutations" {
    var model = try load(example_data.multi_scalar_model);
    defer model.deinit();

    const forward = model.scalarTensorExpression(
        .scalar_quartic,
        &.{ 0, 0, 1, 1 },
    ) orelse return error.MissingComponent;
    const permuted = model.scalarTensorExpression(
        .scalar_quartic,
        &.{ 1, 0, 1, 0 },
    ) orelse return error.MissingComponent;

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try forward.write(&first.writer);
    try permuted.write(&second.writer);
    try std.testing.expectEqualStrings(first.written(), second.written());
    try std.testing.expectEqualStrings("l2", first.written());
}

test "presentation metadata does not change the model fingerprint" {
    const with_metadata =
        \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
        \\"conventions":{"metric":"mostly_plus","scalar_representation":"real_components","fermions":"two_component_weyl"},
        \\"parameters":{"x":{"domain":"real","mass_dimension":4,"label":"display"}},"fields":{"real_scalars":[],"weyl_fermions":[],"gauge_vectors":[]},"tensors":{"vacuum_energy":{"value":"x"}}}
    ;
    const without_metadata =
        \\{"tensors":{"vacuum_energy":{"value":"x"}},"fields":{"gauge_vectors":[],"weyl_fermions":[],"real_scalars":[]},"parameters":{"x":{"mass_dimension":4,"domain":"real"}},"conventions":{"fermions":"two_component_weyl","scalar_representation":"real_components","metric":"mostly_plus"},"spacetime_dimension":4,"schema":"phaser.qft-model/0.1"}
    ;
    var first = try load(with_metadata);
    defer first.deinit();
    var second = try load(without_metadata);
    defer second.deinit();
    try std.testing.expectEqual(first.fingerprint().bytes, second.fingerprint().bytes);
}

test "public inspection output matches reviewed example goldens" {
    const cases = .{
        .{
            "phi4",
            example_data.phi4_model,
            example_data.phi4_inspection,
        },
        .{
            "multi_scalar",
            example_data.multi_scalar_model,
            example_data.multi_scalar_inspection,
        },
    };
    inline for (cases) |case| {
        var model = try load(case[1]);
        defer model.deinit();
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try output.writer.print("model {s}\n", .{case[0]});
        try model.writeInspection(&output.writer);
        try std.testing.expectEqualStrings(case[2], output.written());
    }
}

test "model owns retained data after the source buffer is released" {
    const original = example_data.phi4_model;
    const source = try std.testing.allocator.dupe(u8, original);
    const result = try phaser.loadModel(context(), .{
        .source_id = try phaser.SourceId.fromUsize(9),
        .bytes = source,
    }, .{ .audit = true });
    var model = switch (result) {
        .model => |value| value,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            std.testing.allocator.free(source);
            return error.InvalidFixture;
        },
    };
    std.testing.allocator.free(source);
    defer model.deinit();
    try std.testing.expectEqualStrings("lambda", model.parameters[0].name);
    try std.testing.expect(model.audit());
}

test "persistent budget succeeds exactly and rejects one byte less" {
    const source = example_data.phi4_model;
    var baseline = try load(source);
    const required = baseline.persistent_bytes;
    baseline.deinit();

    var exact_limits = phaser.ModelLimits{};
    exact_limits.persistent_bytes = required;
    const exact = try phaser.loadModel(context(), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = source,
    }, .{ .limits = exact_limits });
    var exact_model = switch (exact) {
        .model => |value| value,
        .diagnostics => return error.UnexpectedCapacityFailure,
    };
    exact_model.deinit();

    var insufficient_limits = phaser.ModelLimits{};
    insufficient_limits.persistent_bytes = required - 1;
    const insufficient = try phaser.loadModel(context(), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = source,
    }, .{ .limits = insufficient_limits });
    var diagnostics = switch (insufficient) {
        .diagnostics => |value| value,
        .model => |value| {
            var owned = value;
            defer owned.deinit();
            return error.ExpectedCapacityFailure;
        },
    };
    defer diagnostics.deinit();
    try std.testing.expectEqual(
        phaser.Code.capacity_exceeded,
        diagnostics.items[0].code,
    );
}

test "scratch budget limits parser allocations rather than source length alone" {
    const source = example_data.phi4_model;
    var limits = phaser.ModelLimits{};
    // The source itself fits exactly, but constructing the JSON tree requires
    // additional temporary storage and must therefore hit the live budget.
    limits.scratch_bytes = source.len;
    const result = try phaser.loadModel(context(), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = source,
    }, .{ .limits = limits });
    var diagnostics = switch (result) {
        .diagnostics => |value| value,
        .model => |value| {
            var owned = value;
            defer owned.deinit();
            return error.ExpectedCapacityFailure;
        },
    };
    defer diagnostics.deinit();
    try std.testing.expectEqual(
        phaser.Code.capacity_exceeded,
        diagnostics.items[0].code,
    );
    switch (diagnostics.items[0].detail) {
        .capacity => |detail| try std.testing.expectEqual(
            phaser.Resource.scratch_bytes,
            detail.resource,
        ),
        else => return error.ExpectedCapacityDetail,
    }
}

test "field array order changes semantic model identity" {
    const first_source =
        \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,"conventions":{"metric":"mostly_plus","scalar_representation":"real_components","fermions":"two_component_weyl"},"parameters":{},"fields":{"real_scalars":[{"id":"a"},{"id":"b"}],"weyl_fermions":[],"gauge_vectors":[]},"tensors":{}}
    ;
    const second_source =
        \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,"conventions":{"metric":"mostly_plus","scalar_representation":"real_components","fermions":"two_component_weyl"},"parameters":{},"fields":{"real_scalars":[{"id":"b"},{"id":"a"}],"weyl_fermions":[],"gauge_vectors":[]},"tensors":{}}
    ;
    var first = try load(first_source);
    defer first.deinit();
    var second = try load(second_source);
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(
        u8,
        &first.fingerprint().bytes,
        &second.fingerprint().bytes,
    ));
}
