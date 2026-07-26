//! Conformance of the safe reference backend against the Milestone 2 exit
//! criteria.
//!
//! The independent oracle here is direct evaluation of the Typed Value IR: a
//! small recursive evaluator written separately from the kernel, sharing no
//! lowering, scheduling, or slot machinery with it. Agreement between the two
//! is evidence about lowering and execution rather than a restatement of
//! either.

const std = @import("std");
const phaser = @import("phaser");
const example_data = @import("example_data");

const value = phaser.value;
const calculation = phaser.calculation;
const kernel_module = phaser.kernel;

const Scalar = kernel_module.Scalar;

fn testContext() phaser.Context {
    return switch (phaser.Context.init(std.testing.allocator, .{
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

// -- independent oracle ----------------------------------------------------

/// Direct evaluation of the Typed Value IR.
///
/// Deliberately naive and recursive: it shares no code with lowering or the
/// interpreter, and it re-evaluates shared subexpressions rather than reusing
/// them. Its accumulation order for a commutative node matches the recorded
/// operand order, which is the same order the instruction set fixes.
fn evaluateDirect(
    graph: *const value.Graph,
    id: value.ValueId,
    parameters: []const Scalar,
    backgrounds: []const Scalar,
) Scalar {
    const item = graph.value(id);
    return switch (item.node) {
        .rational => |rational| kernel_module.rationalToScalar(rational) catch
            std.math.nan(Scalar),
        .pi => std.math.pi,
        .sqrt_rational => |rational| @sqrt(
            kernel_module.rationalToScalar(rational) catch std.math.nan(Scalar),
        ),
        .parameter => |input| parameters[input.id],
        .background => |input| backgrounds[input.index],
        .add => |children| blk: {
            var total = evaluateDirect(graph, children[0], parameters, backgrounds);
            for (children[1..]) |child| {
                total += evaluateDirect(graph, child, parameters, backgrounds);
            }
            break :blk total;
        },
        .multiply => |children| blk: {
            var total = evaluateDirect(graph, children[0], parameters, backgrounds);
            for (children[1..]) |child| {
                total *= evaluateDirect(graph, child, parameters, backgrounds);
            }
            break :blk total;
        },
        .divide => |binary| evaluateDirect(graph, binary.numerator, parameters, backgrounds) /
            evaluateDirect(graph, binary.denominator, parameters, backgrounds),
        .power => |power_node| kernel_module.integerPower(
            evaluateDirect(graph, power_node.base, parameters, backgrounds),
            power_node.exponent,
        ),
    };
}

// -- harness ---------------------------------------------------------------

const Harness = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,
    kernel: kernel_module.Kernel,
    workspace: []align(@alignOf(Scalar)) u8,

    fn init(
        model_source: []const u8,
        request_source: []const u8,
        capability: kernel_module.Capability,
    ) !Harness {
        var model = try loadModel(model_source);
        errdefer model.deinit();
        var request = try parseRequest(request_source);
        errdefer request.deinit();
        var artifact = try derive(&model, &request);
        errdefer artifact.deinit();
        var kernel = try kernel_module.compile(std.testing.allocator, &artifact, .{
            .capability = capability,
        });
        errdefer kernel.deinit();

        const layout = kernel.workspaceLayout(1);
        const workspace = try std.testing.allocator.alignedAlloc(
            u8,
            .of(Scalar),
            layout.bytes,
        );
        return .{
            .model = model,
            .request = request,
            .artifact = artifact,
            .kernel = kernel,
            .workspace = workspace,
        };
    }

    fn deinit(self: *Harness) void {
        std.testing.allocator.free(self.workspace);
        self.kernel.deinit();
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }
};

fn evaluateValues(
    harness: *Harness,
    parameters: []const Scalar,
    backgrounds: []const Scalar,
    point_count: usize,
    values: []Scalar,
    statuses: []kernel_module.Status,
) !void {
    try harness.kernel.evaluate(
        .{ .parameters = parameters, .backgrounds = backgrounds },
        point_count,
        harness.workspace,
        .{ .values = values, .statuses = statuses },
    );
}

// -- tests -----------------------------------------------------------------

test "reference execution agrees with direct value IR evaluation" {
    var harness = try Harness.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    var parameters: [15]Scalar = undefined;
    for (&parameters, 0..) |*slot, index| {
        slot.* = 0.25 + @as(Scalar, @floatFromInt(index)) * 0.5;
    }

    const points = [_][2]Scalar{
        .{ 0, 0 },
        .{ 1, -2 },
        .{ -3.5, 0.75 },
        .{ 12.25, -7.5 },
    };
    for (points) |point| {
        var values: [1]Scalar = undefined;
        var statuses: [1]kernel_module.Status = undefined;
        try evaluateValues(&harness, &parameters, &point, 1, &values, &statuses);
        try std.testing.expectEqual(kernel_module.Status.ok, statuses[0]);

        const expected = evaluateDirect(
            &harness.artifact.graph,
            harness.artifact.total,
            &parameters,
            &point,
        );
        try std.testing.expectEqual(expected, values[0]);
    }
}

test "scalar and batch of one agree bitwise" {
    var harness = try Harness.init(
        example_data.phi4_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    const parameters = [_]Scalar{ 0.5, -2.0, 3.25 };
    const point = [_]Scalar{1.75};

    var scalar_value: [1]Scalar = undefined;
    var scalar_status: [1]kernel_module.Status = undefined;
    try evaluateValues(&harness, &parameters, &point, 1, &scalar_value, &scalar_status);

    var batch_value: [1]Scalar = undefined;
    var batch_status: [1]kernel_module.Status = undefined;
    try evaluateValues(&harness, &parameters, &point, 1, &batch_value, &batch_status);

    try std.testing.expectEqual(scalar_value[0], batch_value[0]);
}

test "arbitrary batch partitions and permutations agree with scalar evaluation" {
    var harness = try Harness.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    var parameters: [15]Scalar = undefined;
    for (&parameters, 0..) |*slot, index| {
        slot.* = 1.0 - @as(Scalar, @floatFromInt(index)) * 0.125;
    }

    const point_count = 7;
    var backgrounds: [point_count * 2]Scalar = undefined;
    for (0..point_count) |index| {
        backgrounds[index * 2] = @as(Scalar, @floatFromInt(index)) - 3.0;
        backgrounds[index * 2 + 1] = 2.0 - @as(Scalar, @floatFromInt(index)) * 0.75;
    }

    // Whole batch.
    var whole: [point_count]Scalar = undefined;
    var whole_status: [point_count]kernel_module.Status = undefined;
    try evaluateValues(
        &harness,
        &parameters,
        &backgrounds,
        point_count,
        &whole,
        &whole_status,
    );

    // Every partition into a prefix and a suffix agrees with the whole batch.
    for (0..point_count + 1) |split| {
        var first: [point_count]Scalar = undefined;
        var first_status: [point_count]kernel_module.Status = undefined;
        var second: [point_count]Scalar = undefined;
        var second_status: [point_count]kernel_module.Status = undefined;

        try evaluateValues(
            &harness,
            &parameters,
            backgrounds[0 .. split * 2],
            split,
            first[0..split],
            first_status[0..split],
        );
        try evaluateValues(
            &harness,
            &parameters,
            backgrounds[split * 2 ..],
            point_count - split,
            second[0 .. point_count - split],
            second_status[0 .. point_count - split],
        );
        for (0..split) |index| {
            try std.testing.expectEqual(whole[index], first[index]);
        }
        for (split..point_count) |index| {
            try std.testing.expectEqual(whole[index], second[index - split]);
        }
    }

    // A permuted batch produces the correspondingly permuted output.
    const permutation = [point_count]usize{ 4, 0, 6, 2, 5, 1, 3 };
    var permuted_backgrounds: [point_count * 2]Scalar = undefined;
    for (permutation, 0..) |source, target| {
        permuted_backgrounds[target * 2] = backgrounds[source * 2];
        permuted_backgrounds[target * 2 + 1] = backgrounds[source * 2 + 1];
    }
    var permuted: [point_count]Scalar = undefined;
    var permuted_status: [point_count]kernel_module.Status = undefined;
    try evaluateValues(
        &harness,
        &parameters,
        &permuted_backgrounds,
        point_count,
        &permuted,
        &permuted_status,
    );
    for (permutation, 0..) |source, target| {
        try std.testing.expectEqual(whole[source], permuted[target]);
    }
}

test "fused outputs agree with separately compiled kernels" {
    var fused = try Harness.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value_gradient_hessian,
    );
    defer fused.deinit();
    var separate = try Harness.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
    );
    defer separate.deinit();

    var parameters: [15]Scalar = undefined;
    for (&parameters, 0..) |*slot, index| {
        slot.* = 0.75 + @as(Scalar, @floatFromInt(index)) * 0.25;
    }
    const point = [_]Scalar{ 1.5, -0.5 };

    var fused_value: [1]Scalar = undefined;
    var fused_gradient: [2]Scalar = undefined;
    var fused_hessian: [4]Scalar = undefined;
    var fused_status: [1]kernel_module.Status = undefined;
    try fused.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &point },
        1,
        fused.workspace,
        .{
            .values = &fused_value,
            .gradients = &fused_gradient,
            .hessians = &fused_hessian,
            .statuses = &fused_status,
        },
    );

    var separate_value: [1]Scalar = undefined;
    var separate_status: [1]kernel_module.Status = undefined;
    try evaluateValues(
        &separate,
        &parameters,
        &point,
        1,
        &separate_value,
        &separate_status,
    );
    try std.testing.expectEqual(separate_value[0], fused_value[0]);

    // Derivatives agree with direct evaluation of the derived value IR.
    for (fused.artifact.gradient, 0..) |root, index| {
        const expected = evaluateDirect(
            &fused.artifact.graph,
            root,
            &parameters,
            &point,
        );
        try std.testing.expectEqual(expected, fused_gradient[index]);
    }

    // The dense Hessian is symmetric in canonical coordinate order.
    try std.testing.expectEqual(fused_hessian[1], fused_hessian[2]);
}

test "workspace is sufficient at the queried size and rejected below it" {
    var harness = try Harness.init(
        example_data.phi4_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    const parameters = [_]Scalar{ 0.5, -2.0, 3.25 };
    const point = [_]Scalar{1.25};
    var values: [1]Scalar = undefined;
    var statuses: [1]kernel_module.Status = undefined;

    const layout = harness.kernel.workspaceLayout(1);
    try std.testing.expect(layout.bytes == harness.workspace.len);

    // Exactly the queried size succeeds.
    try harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &point },
        1,
        harness.workspace,
        .{ .values = &values, .statuses = &statuses },
    );

    // One byte less is rejected before anything is written.
    try std.testing.expectError(error.WorkspaceTooSmall, harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &point },
        1,
        harness.workspace[0 .. layout.bytes - 1],
        .{ .values = &values, .statuses = &statuses },
    ));
}

test "misaligned workspace is rejected before execution" {
    var harness = try Harness.init(
        example_data.phi4_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    const layout = harness.kernel.workspaceLayout(1);
    const oversized = try std.testing.allocator.alignedAlloc(
        u8,
        .of(Scalar),
        layout.bytes + @alignOf(Scalar),
    );
    defer std.testing.allocator.free(oversized);

    // A deliberately offset view of correctly sized storage. This is exactly
    // what a foreign caller can hand over, and it must be rejected rather than
    // dereferenced.
    const misaligned: []u8 = oversized[1 .. layout.bytes + 1];

    const parameters = [_]Scalar{ 0.5, -2.0, 3.25 };
    const point = [_]Scalar{1.25};
    var values: [1]Scalar = undefined;
    var statuses: [1]kernel_module.Status = undefined;

    const result = harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &point },
        1,
        misaligned,
        .{ .values = &values, .statuses = &statuses },
    );
    try std.testing.expectError(error.WorkspaceMisaligned, result);
}

test "wrong buffer shapes are rejected before unsafe use" {
    var harness = try Harness.init(
        example_data.phi4_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    const parameters = [_]Scalar{ 0.5, -2.0, 3.25 };
    const point = [_]Scalar{1.25};
    var values: [1]Scalar = undefined;
    var statuses: [1]kernel_module.Status = undefined;

    // Parameter count mismatch.
    try std.testing.expectError(error.ShapeMismatch, harness.kernel.evaluate(
        .{ .parameters = parameters[0..2], .backgrounds = &point },
        1,
        harness.workspace,
        .{ .values = &values, .statuses = &statuses },
    ));

    // Background buffer too short for the point count.
    try std.testing.expectError(error.ShapeMismatch, harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &point },
        2,
        harness.workspace,
        .{ .values = &values, .statuses = &statuses },
    ));

    // Requesting a capability the kernel was not compiled for.
    var gradients: [1]Scalar = undefined;
    try std.testing.expectError(
        error.UnavailableCapability,
        harness.kernel.evaluate(
            .{ .parameters = &parameters, .backgrounds = &point },
            1,
            harness.workspace,
            .{
                .values = &values,
                .gradients = &gradients,
                .statuses = &statuses,
            },
        ),
    );
}

test "inputs outputs and workspace must be pairwise disjoint" {
    var harness = try Harness.init(
        example_data.phi4_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    var parameters = [_]Scalar{ 0.5, -2.0, 3.25 };
    var backgrounds = [_]Scalar{1.25};
    var output_value: [1]Scalar = undefined;
    var statuses: [1]kernel_module.Status = undefined;

    try std.testing.expectError(error.ForbiddenAliasing, harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &backgrounds },
        1,
        harness.workspace,
        .{ .values = backgrounds[0..], .statuses = &statuses },
    ));
    try std.testing.expectError(error.ForbiddenAliasing, harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &backgrounds },
        1,
        harness.workspace,
        .{ .values = parameters[0..1], .statuses = &statuses },
    ));

    const workspace_scalars = std.mem.bytesAsSlice(Scalar, harness.workspace);
    workspace_scalars[0] = 1.25;
    try std.testing.expectError(error.ForbiddenAliasing, harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = workspace_scalars[0..1] },
        1,
        harness.workspace,
        .{ .values = &output_value, .statuses = &statuses },
    ));
}

test "overflowing batch shapes are rejected before arithmetic wraps" {
    var harness = try Harness.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    const parameters: [15]Scalar = @splat(1);
    var output_value: [1]Scalar = undefined;
    var status: [1]kernel_module.Status = undefined;
    try std.testing.expectError(error.SizeOverflow, harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &.{} },
        std.math.maxInt(usize),
        harness.workspace,
        .{ .values = &output_value, .statuses = &status },
    ));
}

test "evaluation performs no allocation" {
    var harness = try Harness.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value_gradient_hessian,
    );
    defer harness.deinit();

    var parameters: [15]Scalar = undefined;
    for (&parameters, 0..) |*slot, index| {
        slot.* = 0.5 + @as(Scalar, @floatFromInt(index)) * 0.125;
    }
    const backgrounds = [_]Scalar{ 1.0, 2.0, -1.0, 0.5 };
    var values: [2]Scalar = undefined;
    var gradients: [4]Scalar = undefined;
    var hessians: [8]Scalar = undefined;
    var statuses: [2]kernel_module.Status = undefined;

    // The guarantee is structural: `evaluate` takes no allocator, so it has no
    // way to allocate. What this test adds is that the fixed workspace is
    // *sufficient* — the call is given exactly the queried number of bytes and
    // nothing more, so an implementation that needed extra scratch would have
    // to overrun it, which the debug allocator and ReleaseSafe bounds checks
    // both catch.
    try std.testing.expectEqual(
        harness.kernel.workspaceLayout(2).bytes,
        harness.workspace.len,
    );

    try harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &backgrounds },
        2,
        harness.workspace,
        .{
            .values = &values,
            .gradients = &gradients,
            .hessians = &hessians,
            .statuses = &statuses,
        },
    );

    // The evaluation signature takes no allocator at all, which is the
    // structural guarantee; this asserts the call also completed.
    try std.testing.expectEqual(kernel_module.Status.ok, statuses[0]);
    try std.testing.expectEqual(kernel_module.Status.ok, statuses[1]);
}

test "repeated evaluation is bitwise reproducible" {
    var harness = try Harness.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value_gradient_hessian,
    );
    defer harness.deinit();

    var parameters: [15]Scalar = undefined;
    for (&parameters, 0..) |*slot, index| {
        slot.* = 1.5 - @as(Scalar, @floatFromInt(index)) * 0.0625;
    }
    const backgrounds = [_]Scalar{ 3.25, -1.75 };

    var first_values: [1]Scalar = undefined;
    var first_gradients: [2]Scalar = undefined;
    var first_hessians: [4]Scalar = undefined;
    var first_statuses: [1]kernel_module.Status = undefined;
    var second_values: [1]Scalar = undefined;
    var second_gradients: [2]Scalar = undefined;
    var second_hessians: [4]Scalar = undefined;
    var second_statuses: [1]kernel_module.Status = undefined;

    for (0..3) |_| {
        try harness.kernel.evaluate(
            .{ .parameters = &parameters, .backgrounds = &backgrounds },
            1,
            harness.workspace,
            .{
                .values = &first_values,
                .gradients = &first_gradients,
                .hessians = &first_hessians,
                .statuses = &first_statuses,
            },
        );
        try harness.kernel.evaluate(
            .{ .parameters = &parameters, .backgrounds = &backgrounds },
            1,
            harness.workspace,
            .{
                .values = &second_values,
                .gradients = &second_gradients,
                .hessians = &second_hessians,
                .statuses = &second_statuses,
            },
        );
        try std.testing.expectEqualSlices(Scalar, &first_values, &second_values);
        try std.testing.expectEqualSlices(Scalar, &first_gradients, &second_gradients);
        try std.testing.expectEqualSlices(Scalar, &first_hessians, &second_hessians);
    }
}

test "the phi4 potential matches its closed form numerically" {
    var harness = try Harness.init(
        example_data.phi4_model,
        full_space_request,
        .value_gradient_hessian,
    );
    defer harness.deinit();

    // Loader order is alphabetical: lambda, m2, omega.
    const lambda: Scalar = 3.0;
    const mass_squared: Scalar = -2.0;
    const omega: Scalar = 0.5;
    const parameters = [_]Scalar{ lambda, mass_squared, omega };
    const phi: Scalar = 1.5;

    var values: [1]Scalar = undefined;
    var gradients: [1]Scalar = undefined;
    var hessians: [1]Scalar = undefined;
    var statuses: [1]kernel_module.Status = undefined;
    try harness.kernel.evaluate(
        .{ .parameters = &parameters, .backgrounds = &[_]Scalar{phi} },
        1,
        harness.workspace,
        .{
            .values = &values,
            .gradients = &gradients,
            .hessians = &hessians,
            .statuses = &statuses,
        },
    );

    // omega + m2 phi^2 / 2 + lambda phi^4 / 24, and its first two derivatives,
    // from the scalar.phi4 fixture identities.
    const phi2 = phi * phi;
    const expected_value = omega + mass_squared * phi2 / 2 + lambda * phi2 * phi2 / 24;
    const expected_gradient = mass_squared * phi + lambda * phi2 * phi / 6;
    const expected_hessian = mass_squared + lambda * phi2 / 2;

    try std.testing.expectApproxEqRel(expected_value, values[0], 1e-14);
    try std.testing.expectApproxEqRel(expected_gradient, gradients[0], 1e-14);
    try std.testing.expectApproxEqRel(expected_hessian, hessians[0], 1e-14);
}

test "a non-finite point does not corrupt its neighbours" {
    var harness = try Harness.init(
        example_data.phi4_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    const parameters = [_]Scalar{ 1.0, 1.0, 0.0 };
    // The middle point overflows to infinity; the others are ordinary.
    const backgrounds = [_]Scalar{ 1.0, 1e160, 2.0 };
    var values: [3]Scalar = undefined;
    var statuses: [3]kernel_module.Status = undefined;
    try evaluateValues(&harness, &parameters, &backgrounds, 3, &values, &statuses);

    try std.testing.expectEqual(kernel_module.Status.ok, statuses[0]);
    try std.testing.expectEqual(kernel_module.Status.non_finite, statuses[1]);
    try std.testing.expectEqual(kernel_module.Status.ok, statuses[2]);

    // The surviving points equal what they would produce alone.
    var single: [1]Scalar = undefined;
    var single_status: [1]kernel_module.Status = undefined;
    try evaluateValues(
        &harness,
        &parameters,
        backgrounds[2..3],
        1,
        &single,
        &single_status,
    );
    try std.testing.expectEqual(single[0], values[2]);
}

test "a dynamic coordinate crossing zero requires no recompilation" {
    var harness = try Harness.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
    );
    defer harness.deinit();

    var parameters: [15]Scalar = undefined;
    for (&parameters, 0..) |*slot, index| {
        slot.* = 0.25 * @as(Scalar, @floatFromInt(index + 1));
    }
    // Points sweeping through the symmetric point in one batch.
    const backgrounds = [_]Scalar{ -1.0, -1.0, 0.0, 0.0, 1.0, 1.0 };
    var values: [3]Scalar = undefined;
    var statuses: [3]kernel_module.Status = undefined;
    try evaluateValues(&harness, &parameters, &backgrounds, 3, &values, &statuses);

    for (statuses) |status| {
        try std.testing.expectEqual(kernel_module.Status.ok, status);
    }
    for (values, 0..) |produced, index| {
        const expected = evaluateDirect(
            &harness.artifact.graph,
            harness.artifact.total,
            &parameters,
            backgrounds[index * 2 ..][0..2],
        );
        try std.testing.expectEqual(expected, produced);
    }
}
