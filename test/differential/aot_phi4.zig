//! Differential contract for the generated phi4 tree-value evaluator.

const std = @import("std");
const phaser = @import("phaser");
const generated = @import("generated_aot");
const example_data = @import("example_data");

const Scalar = phaser.kernel.Scalar;
const Status = phaser.kernel.Status;

const Fixture = struct {
    model: phaser.Model,
    request: phaser.CalculationRequest,
    artifact: phaser.PotentialArtifact,
    kernel: phaser.kernel.Kernel,
    point: phaser.ParameterPoint,
    binding: phaser.kernel.Binding,
    aot_bound: generated.Bound,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var model = try loadModel(allocator);
        errdefer model.deinit();
        var request = try loadRequest(allocator);
        errdefer request.deinit();
        var artifact = try derive(allocator, &model, &request);
        errdefer artifact.deinit();
        var kernel = try phaser.kernel.compile(allocator, &artifact, .{
            .capability = .value,
            .selection = .{ .loop_order = 0 },
        });
        errdefer kernel.deinit();
        var point = try loadPoint(allocator);
        errdefer point.deinit();
        var binding = try phaser.kernel.bind(allocator, &kernel, &model, &point);
        errdefer binding.deinit();

        try generated.validateIdentity(
            kernel.model_fingerprint,
            kernel.request_fingerprint,
        );
        const aot_bound = try generated.bind(binding.parameters);
        return .{
            .model = model,
            .request = request,
            .artifact = artifact,
            .kernel = kernel,
            .point = point,
            .binding = binding,
            .aot_bound = aot_bound,
        };
    }

    fn deinit(self: *Fixture) void {
        self.binding.deinit();
        self.point.deinit();
        self.kernel.deinit();
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
        self.* = undefined;
    }
};

test "generated scalar and batch paths are bitwise equal to the reference" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();

    const backgrounds = [_]Scalar{
        -100.0,
        -2.0,
        -0.0,
        0.0,
        std.math.floatMin(f64),
        0.125,
        3.0,
        100.0,
        1.0e100,
        std.math.inf(f64),
        std.math.nan(f64),
    };
    try compareBatch(&fixture, &backgrounds);

    for (backgrounds) |background| {
        var reference_value = [_]Scalar{0x1.5a5a5a5a5a5a5p+100};
        var reference_status: [1]Status = undefined;
        var generated_value = reference_value;
        var generated_status: [1]generated.Status = undefined;
        const reference_layout = fixture.binding.workspaceLayout(1);
        const workspace = try std.testing.allocator.alignedAlloc(
            u8,
            .@"64",
            reference_layout.bytes,
        );
        defer std.testing.allocator.free(workspace);
        try fixture.binding.evaluate(&.{background}, 1, workspace, .{
            .values = &reference_value,
            .gradients = &.{},
            .hessians = &.{},
            .statuses = &reference_status,
        });
        var no_workspace: [0]u8 = .{};
        try generated.evaluateScalar(
            &fixture.aot_bound,
            &.{background},
            &no_workspace,
            &generated_value,
            &generated_status,
        );
        try expectPointEqual(
            reference_value[0],
            reference_status[0],
            generated_value[0],
            generated_status[0],
        );
    }
}

test "generated checked boundary rejects shape alias and identity mismatches" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 0), generated.workspaceLayout(4096).bytes);
    try std.testing.expectEqual(@as(usize, 1), generated.workspaceLayout(4096).alignment);
    try std.testing.expectError(error.ShapeMismatch, generated.bind(&.{ 1.0, 2.0 }));

    var no_workspace: [0]u8 = .{};
    var storage = [_]Scalar{ 1.0, 2.0 };
    var status: [1]generated.Status = undefined;
    try std.testing.expectError(
        error.ForbiddenAliasing,
        generated.evaluateBatch(
            &fixture.aot_bound,
            storage[0..1],
            1,
            &no_workspace,
            storage[0..1],
            &status,
        ),
    );
    try std.testing.expectError(
        error.ShapeMismatch,
        generated.evaluateBatch(
            &fixture.aot_bound,
            storage[0..1],
            2,
            &no_workspace,
            storage[0..1],
            &status,
        ),
    );

    var wrong_model = fixture.kernel.model_fingerprint;
    wrong_model[0] ^= 1;
    try std.testing.expectError(
        error.IdentityMismatch,
        generated.validateIdentity(
            wrong_model,
            fixture.kernel.request_fingerprint,
        ),
    );
}

test "generated batches are reproducible across partitions" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();

    var backgrounds: [67]Scalar = undefined;
    for (&backgrounds, 0..) |*background, index| {
        background.* = @as(Scalar, @floatFromInt(index)) * 0.125 - 4.0;
    }
    var complete_values: [backgrounds.len]Scalar = undefined;
    var complete_statuses: [backgrounds.len]generated.Status = undefined;
    var partition_values: [backgrounds.len]Scalar = undefined;
    var partition_statuses: [backgrounds.len]generated.Status = undefined;
    var no_workspace: [0]u8 = .{};

    try generated.evaluateBatch(
        &fixture.aot_bound,
        &backgrounds,
        backgrounds.len,
        &no_workspace,
        &complete_values,
        &complete_statuses,
    );
    var start: usize = 0;
    for ([_]usize{ 1, 4, 7, 16, 32, 7 }) |count| {
        try generated.evaluateBatch(
            &fixture.aot_bound,
            backgrounds[start .. start + count],
            count,
            &no_workspace,
            partition_values[start .. start + count],
            partition_statuses[start .. start + count],
        );
        start += count;
    }
    try std.testing.expectEqual(backgrounds.len, start);
    try std.testing.expectEqualSlices(Scalar, &complete_values, &partition_values);
    try std.testing.expectEqualSlices(
        generated.Status,
        &complete_statuses,
        &partition_statuses,
    );
}

fn compareBatch(fixture: *Fixture, backgrounds: []const Scalar) !void {
    const count = backgrounds.len;
    const sentinel: Scalar = 0x1.5a5a5a5a5a5a5p+100;
    const reference_values = try std.testing.allocator.alloc(Scalar, count);
    defer std.testing.allocator.free(reference_values);
    const generated_values = try std.testing.allocator.alloc(Scalar, count);
    defer std.testing.allocator.free(generated_values);
    @memset(reference_values, sentinel);
    @memset(generated_values, sentinel);
    const reference_statuses = try std.testing.allocator.alloc(Status, count);
    defer std.testing.allocator.free(reference_statuses);
    const generated_statuses = try std.testing.allocator.alloc(generated.Status, count);
    defer std.testing.allocator.free(generated_statuses);

    const reference_layout = fixture.binding.workspaceLayout(count);
    const workspace = try std.testing.allocator.alignedAlloc(
        u8,
        .@"64",
        reference_layout.bytes,
    );
    defer std.testing.allocator.free(workspace);
    try fixture.binding.evaluate(backgrounds, count, workspace, .{
        .values = reference_values,
        .gradients = &.{},
        .hessians = &.{},
        .statuses = reference_statuses,
    });
    var no_workspace: [0]u8 = .{};
    try generated.evaluateBatch(
        &fixture.aot_bound,
        backgrounds,
        count,
        &no_workspace,
        generated_values,
        generated_statuses,
    );

    for (
        reference_values,
        reference_statuses,
        generated_values,
        generated_statuses,
    ) |reference_value, reference_status, generated_value, generated_status| {
        try expectPointEqual(
            reference_value,
            reference_status,
            generated_value,
            generated_status,
        );
    }
}

fn expectPointEqual(
    reference_value: Scalar,
    reference_status: Status,
    generated_value: Scalar,
    generated_status: generated.Status,
) !void {
    try std.testing.expectEqual(
        @intFromEnum(reference_status),
        @intFromEnum(generated_status),
    );
    try std.testing.expectEqual(
        @as(u64, @bitCast(reference_value)),
        @as(u64, @bitCast(generated_value)),
    );
}

fn context(allocator: std.mem.Allocator) phaser.Context {
    return switch (phaser.Context.init(allocator, .{
        .max_diagnostics = 16,
        .max_related_locations = 32,
    })) {
        .context => |value| value,
        .failure => unreachable,
    };
}

fn loadModel(allocator: std.mem.Allocator) !phaser.Model {
    return switch (try phaser.loadModel(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = example_data.phi4_model,
    }, .{})) {
        .model => |value| value,
        .diagnostics => error.InvalidModel,
    };
}

fn loadRequest(allocator: std.mem.Allocator) !phaser.CalculationRequest {
    return switch (try phaser.parseRequest(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(1),
        .bytes = example_data.phi4_request,
    }, .{})) {
        .request => |value| value,
        .diagnostics => error.InvalidRequest,
    };
}

fn loadPoint(allocator: std.mem.Allocator) !phaser.ParameterPoint {
    return switch (try phaser.parseParameterPoint(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(2),
        .bytes = example_data.phi4_point,
    }, .{})) {
        .point => |value| value,
        .diagnostics => error.InvalidPoint,
    };
}

fn derive(
    allocator: std.mem.Allocator,
    model: *const phaser.Model,
    request: *const phaser.CalculationRequest,
) !phaser.PotentialArtifact {
    return switch (try phaser.deriveEffectivePotential(
        context(allocator),
        model,
        request,
        .{ .derivatives = .none },
    )) {
        .artifact => |value| value,
        .diagnostics => error.DerivationFailed,
    };
}
