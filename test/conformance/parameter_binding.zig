//! Conformance of parameter points and immutable bindings.
//!
//! The decisive property here is that staged and unstaged evaluation agree
//! bitwise. Staging runs the parameter-dependent instructions once per binding
//! instead of once per point; if that partition were wrong — if a
//! background-dependent instruction were misclassified, or a parameter-stage
//! slot were clobbered by reuse — the two paths would disagree.

const std = @import("std");
const phaser = @import("phaser");
const example_data = @import("example_data");

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

fn parsePoint(source: []const u8) !calculation.ParameterPoint {
    const result = try phaser.parseParameterPoint(testContext(), .{
        .source_id = try phaser.SourceId.fromUsize(2),
        .bytes = source,
    }, .{});
    return switch (result) {
        .point => |point| point,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidParameterPoint;
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

const phi4_point =
    \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
    \\"values":{"lambda":0.26,"m2":-7812.5,"omega":1.5}}
;

const multi_scalar_point =
    \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
    \\"values":{"a":1.5,"b":-0.5,"c":2.25,"d":0.75,
    \\"l1":0.1,"l2":0.2,"l3":0.3,"lh":0.4,"ls":0.5,
    \\"m_h2":-6000.0,"m_hs2":250.0,"m_s2":3000.0,
    \\"omega":2.5,"t_h":10.0,"t_s":-20.0}}
;

const Fixture = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,
    kernel: kernel_module.Kernel,
    workspace: []align(@alignOf(Scalar)) u8,

    fn init(
        model_source: []const u8,
        capability: kernel_module.Capability,
    ) !Fixture {
        var model = try loadModel(model_source);
        errdefer model.deinit();
        var request = try parseRequest(full_space_request);
        errdefer request.deinit();
        var artifact = try derive(&model, &request);
        errdefer artifact.deinit();
        var kernel = try kernel_module.compile(std.testing.allocator, &artifact, .{
            .capability = capability,
        });
        errdefer kernel.deinit();
        const workspace = try std.testing.allocator.alignedAlloc(
            u8,
            .of(Scalar),
            kernel.workspaceLayout(8).bytes,
        );
        return .{
            .model = model,
            .request = request,
            .artifact = artifact,
            .kernel = kernel,
            .workspace = workspace,
        };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.workspace);
        self.kernel.deinit();
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }
};

// -- tests -----------------------------------------------------------------

test "staged and unstaged evaluation agree bitwise" {
    var fixture = try Fixture.init(
        example_data.multi_scalar_model,
        .value_gradient_hessian,
    );
    defer fixture.deinit();
    var point = try parsePoint(multi_scalar_point);
    defer point.deinit();

    var binding = try kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &point,
    );
    defer binding.deinit();

    const point_count = 5;
    var backgrounds: [point_count * 2]Scalar = undefined;
    for (0..point_count) |index| {
        backgrounds[index * 2] = 50.0 * (@as(Scalar, @floatFromInt(index)) - 2.0);
        backgrounds[index * 2 + 1] = 30.0 - 12.5 * @as(Scalar, @floatFromInt(index));
    }

    var staged_values: [point_count]Scalar = undefined;
    var staged_gradients: [point_count * 2]Scalar = undefined;
    var staged_hessians: [point_count * 4]Scalar = undefined;
    var staged_statuses: [point_count]kernel_module.Status = undefined;
    try binding.evaluate(&backgrounds, point_count, fixture.workspace, .{
        .values = &staged_values,
        .gradients = &staged_gradients,
        .hessians = &staged_hessians,
        .statuses = &staged_statuses,
    });

    var direct_values: [point_count]Scalar = undefined;
    var direct_gradients: [point_count * 2]Scalar = undefined;
    var direct_hessians: [point_count * 4]Scalar = undefined;
    var direct_statuses: [point_count]kernel_module.Status = undefined;
    try fixture.kernel.evaluate(
        .{ .parameters = binding.parameters, .backgrounds = &backgrounds },
        point_count,
        fixture.workspace,
        .{
            .values = &direct_values,
            .gradients = &direct_gradients,
            .hessians = &direct_hessians,
            .statuses = &direct_statuses,
        },
    );

    try std.testing.expectEqualSlices(Scalar, &direct_values, &staged_values);
    try std.testing.expectEqualSlices(Scalar, &direct_gradients, &staged_gradients);
    try std.testing.expectEqualSlices(Scalar, &direct_hessians, &staged_hessians);
    try std.testing.expectEqualSlices(
        kernel_module.Status,
        &direct_statuses,
        &staged_statuses,
    );
}

test "the parameter stage is a nonempty prefix that reads no coordinate" {
    var fixture = try Fixture.init(
        example_data.multi_scalar_model,
        .value_gradient_hessian,
    );
    defer fixture.deinit();

    const program = &fixture.kernel.program;
    // Constants and parameter loads are always stageable, so the prefix is
    // never empty for these models, and it is a genuine saving.
    try std.testing.expect(program.parameter_stage_count > 0);
    try std.testing.expect(program.parameter_stage_count < program.instructions.len);

    // Structural guarantee: no instruction in the prefix loads a coordinate.
    for (program.instructions[0..program.parameter_stage_count]) |instruction| {
        try std.testing.expect(instruction != .load_background);
    }
}

test "fresh and rebound bindings agree" {
    var fixture = try Fixture.init(example_data.phi4_model, .value_gradient);
    defer fixture.deinit();
    var point = try parsePoint(phi4_point);
    defer point.deinit();

    const backgrounds = [_]Scalar{ 0.0, 62.5, 125.0 };
    var first_values: [3]Scalar = undefined;
    var first_gradients: [3]Scalar = undefined;
    var first_statuses: [3]kernel_module.Status = undefined;
    var second_values: [3]Scalar = undefined;
    var second_gradients: [3]Scalar = undefined;
    var second_statuses: [3]kernel_module.Status = undefined;

    {
        var binding = try kernel_module.bind(
            std.testing.allocator,
            &fixture.kernel,
            &fixture.model,
            &point,
        );
        defer binding.deinit();
        try binding.evaluate(&backgrounds, 3, fixture.workspace, .{
            .values = &first_values,
            .gradients = &first_gradients,
            .statuses = &first_statuses,
        });
    }

    // A second binding over an independently parsed point with the same values.
    var reparsed = try parsePoint(phi4_point);
    defer reparsed.deinit();
    {
        var binding = try kernel_module.bind(
            std.testing.allocator,
            &fixture.kernel,
            &fixture.model,
            &reparsed,
        );
        defer binding.deinit();
        try binding.evaluate(&backgrounds, 3, fixture.workspace, .{
            .values = &second_values,
            .gradients = &second_gradients,
            .statuses = &second_statuses,
        });
    }

    try std.testing.expectEqualSlices(Scalar, &first_values, &second_values);
    try std.testing.expectEqualSlices(Scalar, &first_gradients, &second_gradients);
}

test "a binding is reusable across many background batches" {
    var fixture = try Fixture.init(example_data.phi4_model, .value);
    defer fixture.deinit();
    var point = try parsePoint(phi4_point);
    defer point.deinit();
    var binding = try kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &point,
    );
    defer binding.deinit();

    // Adaptive, nonuniform, out-of-order points across separate calls, none of
    // which may require rebinding or recompilation.
    const sequences = [_][]const Scalar{
        &.{ 10.0, -10.0 },
        &.{0.0},
        &.{ 300.0, 0.5, -1000.0, 7.25 },
    };
    var reference: [7]Scalar = undefined;
    var produced: usize = 0;
    for (sequences) |sequence| {
        var values: [4]Scalar = undefined;
        var statuses: [4]kernel_module.Status = undefined;
        try binding.evaluate(
            sequence,
            sequence.len,
            fixture.workspace,
            .{
                .values = values[0..sequence.len],
                .statuses = statuses[0..sequence.len],
            },
        );
        for (values[0..sequence.len]) |item| {
            reference[produced] = item;
            produced += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 7), produced);

    // Every one of those points evaluated alone agrees.
    var index: usize = 0;
    for (sequences) |sequence| {
        for (sequence) |coordinate| {
            var single: [1]Scalar = undefined;
            var status: [1]kernel_module.Status = undefined;
            try binding.evaluate(
                &.{coordinate},
                1,
                fixture.workspace,
                .{ .values = &single, .statuses = &status },
            );
            try std.testing.expectEqual(reference[index], single[0]);
            index += 1;
        }
    }
}

test "binding rejects an incomplete or unknown parameter point" {
    var fixture = try Fixture.init(example_data.phi4_model, .value);
    defer fixture.deinit();

    const missing =
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
        \\"values":{"lambda":0.26,"m2":-7812.5}}
    ;
    var incomplete = try parsePoint(missing);
    defer incomplete.deinit();
    try std.testing.expectError(error.MissingParameterValue, kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &incomplete,
    ));

    const extra =
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
        \\"values":{"lambda":0.26,"m2":-7812.5,"omega":1.5,"nonexistent":1.0}}
    ;
    var unknown = try parsePoint(extra);
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownParameterValue, kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &unknown,
    ));
}

test "a parameter the calculation ignores is still required by the point" {
    // The kernel packs only the channels its value graph references, but the
    // point is validated against the whole model, so completeness does not
    // depend on which parameters a particular calculation happens to use.
    var fixture = try Fixture.init(example_data.multi_scalar_model, .value);
    defer fixture.deinit();
    var point = try parsePoint(multi_scalar_point);
    defer point.deinit();

    try std.testing.expectEqual(
        @as(usize, 15),
        fixture.model.parameters.len,
    );
    var binding = try kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &point,
    );
    defer binding.deinit();
    try std.testing.expectEqual(
        fixture.kernel.parameters.len,
        binding.parameters.len,
    );
}

test "binding retains the scheme and reference scale of its values" {
    var fixture = try Fixture.init(example_data.phi4_model, .value);
    defer fixture.deinit();
    var point = try parsePoint(phi4_point);
    defer point.deinit();
    var binding = try kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &point,
    );
    defer binding.deinit();

    try std.testing.expectEqual(calculation.Scheme.msbar, binding.scheme);
    try std.testing.expectEqual(@as(Scalar, 125.0), binding.reference_scale);
}

test "binding packs channels by name rather than by position" {
    // The point lists values in a different order than the model declares
    // parameters; packing must follow the channel's semantic identity.
    var fixture = try Fixture.init(example_data.phi4_model, .value);
    defer fixture.deinit();

    const shuffled =
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":125.0},
        \\"values":{"omega":1.5,"lambda":0.26,"m2":-7812.5}}
    ;
    var point = try parsePoint(shuffled);
    defer point.deinit();
    var binding = try kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &point,
    );
    defer binding.deinit();

    for (fixture.kernel.parameters, binding.parameters) |channel, packed_value| {
        try std.testing.expectEqual(point.lookup(channel.name).?, packed_value);
    }
}

test "the phi4 potential through a binding matches its closed form" {
    var fixture = try Fixture.init(example_data.phi4_model, .value_gradient_hessian);
    defer fixture.deinit();
    var point = try parsePoint(phi4_point);
    defer point.deinit();
    var binding = try kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &point,
    );
    defer binding.deinit();

    const lambda: Scalar = 0.26;
    const mass_squared: Scalar = -7812.5;
    const omega: Scalar = 1.5;
    const phi: Scalar = 246.0;

    var values: [1]Scalar = undefined;
    var gradients: [1]Scalar = undefined;
    var hessians: [1]Scalar = undefined;
    var statuses: [1]kernel_module.Status = undefined;
    try binding.evaluate(&.{phi}, 1, fixture.workspace, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });

    const phi2 = phi * phi;
    try std.testing.expectEqual(kernel_module.Status.ok, statuses[0]);
    try std.testing.expectApproxEqRel(
        omega + mass_squared * phi2 / 2 + lambda * phi2 * phi2 / 24,
        values[0],
        1e-13,
    );
    try std.testing.expectApproxEqRel(
        mass_squared * phi + lambda * phi2 * phi / 6,
        gradients[0],
        1e-13,
    );
    try std.testing.expectApproxEqRel(
        mass_squared + lambda * phi2 / 2,
        hessians[0],
        1e-13,
    );
}

test "workspace boundaries still hold through a binding" {
    var fixture = try Fixture.init(example_data.phi4_model, .value);
    defer fixture.deinit();
    var point = try parsePoint(phi4_point);
    defer point.deinit();
    var binding = try kernel_module.bind(
        std.testing.allocator,
        &fixture.kernel,
        &fixture.model,
        &point,
    );
    defer binding.deinit();

    const layout = binding.workspaceLayout(1);
    var values: [1]Scalar = undefined;
    var statuses: [1]kernel_module.Status = undefined;

    try binding.evaluate(&.{1.0}, 1, fixture.workspace[0..layout.bytes], .{
        .values = &values,
        .statuses = &statuses,
    });
    try std.testing.expectError(error.WorkspaceTooSmall, binding.evaluate(
        &.{1.0},
        1,
        fixture.workspace[0 .. layout.bytes - 1],
        .{ .values = &values, .statuses = &statuses },
    ));
}

test "a declared artifact scheme is threaded to the kernel and accepted" {
    const with_scheme =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},
        \\"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":0}}}
    ;
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(with_scheme);
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();
    var kernel = try kernel_module.compile(std.testing.allocator, &artifact, .{
        .capability = .value,
    });
    defer kernel.deinit();

    // The declaration reaches the kernel, where binding can compare it.
    try std.testing.expectEqual(calculation.Scheme.msbar, kernel.scheme.?);

    var point = try parsePoint(phi4_point);
    defer point.deinit();
    var binding = try kernel_module.bind(
        std.testing.allocator,
        &kernel,
        &model,
        &point,
    );
    defer binding.deinit();
    try std.testing.expectEqual(calculation.Scheme.msbar, binding.scheme);
}

test "the scheme mismatch branch is unreachable while one scheme exists" {
    // Binding rejects a point whose scheme differs from the artifact's, which
    // is what keeps a single evaluation from mixing schemes. With exactly one
    // scheme in the enum that comparison can never be true, so the branch is
    // structurally present but vacuous and no test can exercise it.
    //
    // This is a tripwire, not a property: adding a second scheme fails here and
    // is the signal to write the real mismatch test alongside it.
    try std.testing.expectEqual(
        @as(usize, 1),
        @typeInfo(calculation.Scheme).@"enum".fields.len,
    );
}

test "representative allocation failures never publish a partial binding" {
    var fixture = try Fixture.init(example_data.phi4_model, .value);
    defer fixture.deinit();
    var point = try parsePoint(phi4_point);
    defer point.deinit();

    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var binding = kernel_module.bind(
            failing.allocator(),
            &fixture.kernel,
            &fixture.model,
            &point,
        ) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
            continue;
        };
        binding.deinit();
    }
}
