//! Differential comparison of exact symbolic derivatives against numerical
//! finite differences.
//!
//! Required by `docs/calculations/EFFECTIVE_POTENTIAL.md` §15: analytic or
//! automatic derivatives agree with independent finite differences at
//! well-conditioned test points.
//!
//! This is the most independent check the derivative path has. Every other
//! derivative test compares one Phaser construction against another Phaser
//! construction; this one compares against differences of evaluated values,
//! which share no differentiation code at all. A sign error, a missing product
//! term, or a wrong orbit coefficient would survive the structural tests only if
//! it were replicated in the hand-written reference — it cannot survive this.
//!
//! Finite differences are used here as a test oracle only. They are never a
//! derivative capability the library falls back to.

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

const Subject = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,
    kernel: kernel_module.Kernel,
    binding: kernel_module.Binding,
    workspace: []align(@alignOf(Scalar)) u8,
    coordinates: usize,

    fn init(model_source: []const u8, point_source: []const u8) !Subject {
        var model = switch (try phaser.loadModel(testContext(), .{
            .source_id = try phaser.SourceId.fromUsize(0),
            .bytes = model_source,
        }, .{})) {
            .model => |loaded| loaded,
            .diagnostics => |diagnostics| {
                var owned = diagnostics;
                owned.deinit();
                return error.InvalidModel;
            },
        };
        errdefer model.deinit();

        var request = switch (try phaser.parseRequest(testContext(), .{
            .source_id = try phaser.SourceId.fromUsize(1),
            .bytes = example_data.phi4_request,
        }, .{})) {
            .request => |parsed| parsed,
            .diagnostics => |diagnostics| {
                var owned = diagnostics;
                owned.deinit();
                return error.InvalidRequest;
            },
        };
        errdefer request.deinit();

        var artifact = switch (try phaser.deriveClassicalPotential(
            testContext(),
            &model,
            &request,
            .{},
        )) {
            .artifact => |derived| derived,
            .diagnostics => |diagnostics| {
                var owned = diagnostics;
                owned.deinit();
                return error.DerivationFailed;
            },
        };
        errdefer artifact.deinit();

        var kernel = try kernel_module.compile(std.testing.allocator, &artifact, .{
            .capability = .value_gradient_hessian,
        });
        errdefer kernel.deinit();

        var point = switch (try phaser.parseParameterPoint(testContext(), .{
            .source_id = try phaser.SourceId.fromUsize(2),
            .bytes = point_source,
        }, .{})) {
            .point => |parsed| parsed,
            .diagnostics => |diagnostics| {
                var owned = diagnostics;
                owned.deinit();
                return error.InvalidParameterPoint;
            },
        };
        defer point.deinit();

        var binding = try kernel_module.bind(
            std.testing.allocator,
            &kernel,
            &model,
            &point,
        );
        errdefer binding.deinit();

        const workspace = try std.testing.allocator.alignedAlloc(
            u8,
            .of(Scalar),
            binding.workspaceLayout(1).bytes,
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

    fn deinit(self: *Subject) void {
        std.testing.allocator.free(self.workspace);
        self.binding.deinit();
        self.kernel.deinit();
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }

    fn value(self: *Subject, point: []const Scalar) !Scalar {
        var values: [1]Scalar = undefined;
        var statuses: [1]kernel_module.Status = undefined;
        try self.binding.evaluate(point, 1, self.workspace, .{
            .values = &values,
            .statuses = &statuses,
        });
        if (statuses[0] != .ok) return error.PointNotOk;
        return values[0];
    }

    fn derivatives(
        self: *Subject,
        point: []const Scalar,
        gradient: []Scalar,
        hessian: []Scalar,
    ) !void {
        var values: [1]Scalar = undefined;
        var statuses: [1]kernel_module.Status = undefined;
        try self.binding.evaluate(point, 1, self.workspace, .{
            .values = &values,
            .gradients = gradient,
            .hessians = hessian,
            .statuses = &statuses,
        });
        if (statuses[0] != .ok) return error.PointNotOk;
    }
};

/// Central-difference step for a first derivative.
///
/// Truncation error grows as the square of the step while roundoff falls as its
/// inverse, so the balance sits at the cube root of the machine epsilon.
fn stepFirst(magnitude: Scalar) Scalar {
    const scale = @max(@abs(magnitude), 1.0);
    return scale * std.math.pow(Scalar, std.math.floatEps(Scalar), 1.0 / 3.0);
}

/// Central-difference step for a second derivative.
///
/// A second difference divides by the square of the step, so roundoff falls only
/// as its inverse square and the balance moves to the fourth root of the machine
/// epsilon. Using the first-derivative step here costs four orders of magnitude
/// of accuracy in the reference, which is enough to swamp the comparison.
fn stepSecond(magnitude: Scalar) Scalar {
    const scale = @max(@abs(magnitude), 1.0);
    return scale * std.math.pow(Scalar, std.math.floatEps(Scalar), 1.0 / 4.0);
}

fn centralFirst(
    subject: *Subject,
    point: []const Scalar,
    index: usize,
    scratch: []Scalar,
) !Scalar {
    const h = stepFirst(point[index]);
    @memcpy(scratch, point);
    scratch[index] = point[index] + h;
    const forward = try subject.value(scratch);
    scratch[index] = point[index] - h;
    const backward = try subject.value(scratch);
    return (forward - backward) / (2 * h);
}

fn centralSecond(
    subject: *Subject,
    point: []const Scalar,
    row: usize,
    column: usize,
    scratch: []Scalar,
) !Scalar {
    const hr = stepSecond(point[row]);
    if (row == column) {
        @memcpy(scratch, point);
        scratch[row] = point[row] + hr;
        const forward = try subject.value(scratch);
        scratch[row] = point[row] - hr;
        const backward = try subject.value(scratch);
        @memcpy(scratch, point);
        const middle = try subject.value(scratch);
        return (forward - 2 * middle + backward) / (hr * hr);
    }

    const hc = stepSecond(point[column]);
    var total: Scalar = 0;
    for ([_]Scalar{ 1, -1 }) |row_sign| {
        for ([_]Scalar{ 1, -1 }) |column_sign| {
            @memcpy(scratch, point);
            scratch[row] = point[row] + row_sign * hr;
            scratch[column] = point[column] + column_sign * hc;
            total += row_sign * column_sign * try subject.value(scratch);
        }
    }
    return total / (4 * hr * hc);
}

/// Compares exact and numerical derivatives at one point.
///
/// The tolerance accommodates error on the reference side, which is the inexact
/// one. With a step chosen for each derivative order the reference is accurate to
/// roughly eight significant figures, so a tolerance near 1e-7 still rejects any
/// plausible structural error: a wrong orbit coefficient or a dropped product
/// rule term shifts a derivative by a factor, not by a part in ten million.
fn expectAgreementAt(subject: *Subject, point: []const Scalar) !void {
    const n = subject.coordinates;
    const gradient = try std.testing.allocator.alloc(Scalar, n);
    defer std.testing.allocator.free(gradient);
    const hessian = try std.testing.allocator.alloc(Scalar, n * n);
    defer std.testing.allocator.free(hessian);
    const scratch = try std.testing.allocator.alloc(Scalar, n);
    defer std.testing.allocator.free(scratch);

    try subject.derivatives(point, gradient, hessian);

    for (0..n) |index| {
        const numerical = try centralFirst(subject, point, index, scratch);
        try std.testing.expectApproxEqRel(numerical, gradient[index], 1e-7);
    }
    for (0..n) |row| {
        for (0..n) |column| {
            const numerical = try centralSecond(subject, point, row, column, scratch);
            try std.testing.expectApproxEqRel(
                numerical,
                hessian[row * n + column],
                1e-7,
            );
        }
    }
}

test "the phi4 gradient and Hessian agree with finite differences" {
    var subject = try Subject.init(example_data.phi4_model, example_data.phi4_point);
    defer subject.deinit();

    // Points away from the stationary point at phi ~ 424.6, so the relative
    // comparison is well conditioned.
    for ([_]Scalar{ 25.0, 100.0, 200.0, 600.0, -150.0 }) |phi| {
        try expectAgreementAt(&subject, &.{phi});
    }
}

test "the multi-scalar gradient and Hessian agree with finite differences" {
    var subject = try Subject.init(
        example_data.multi_scalar_model,
        example_data.multi_scalar_point,
    );
    defer subject.deinit();

    // Mixed partials are exercised here: every one of these points has both
    // coordinates nonzero, so the off-diagonal Hessian entries are nontrivial.
    const points = [_][2]Scalar{
        .{ 100.0, 50.0 },
        .{ 300.0, -200.0 },
        .{ -75.0, 125.0 },
        .{ 20.0, 20.0 },
    };
    for (points) |point| {
        try expectAgreementAt(&subject, &point);
    }
}

test "finite differences confirm the orbit coefficients numerically" {
    // The orbit rule is checked structurally elsewhere against transcribed
    // fixture identities. This confirms it through a completely different route:
    // if the h^2 s^2 coefficient were 1/24 instead of 1/4, the mixed partial
    // would be wrong by a factor of six and the comparison below would fail.
    var subject = try Subject.init(
        example_data.multi_scalar_model,
        example_data.multi_scalar_point,
    );
    defer subject.deinit();

    const point = [_]Scalar{ 150.0, 90.0 };
    var gradient: [2]Scalar = undefined;
    var hessian: [4]Scalar = undefined;
    try subject.derivatives(&point, &gradient, &hessian);

    var scratch: [2]Scalar = undefined;
    const numerical_mixed = try centralSecond(&subject, &point, 0, 1, &scratch);
    try std.testing.expectApproxEqRel(numerical_mixed, hessian[1], 1e-7);

    // The exact mixed partial of the tree potential, assembled independently
    // from the model's declared parameter values:
    //   d2V/dh ds = m_hs2 + b h + c s + l3 h^2 / 2 + l2 h s + l1 s^2 / 2
    const h = point[0];
    const s = point[1];
    const b: Scalar = -5.0;
    const c: Scalar = 2.5;
    const l1: Scalar = 0.05;
    const l2: Scalar = 0.1;
    const l3: Scalar = -0.02;
    const m_hs2: Scalar = 500.0;
    const expected = m_hs2 + b * h + c * s +
        l3 * h * h / 2 + l2 * h * s + l1 * s * s / 2;
    try std.testing.expectApproxEqRel(expected, hessian[1], 1e-12);
}

test "the Hessian is symmetric under numerical comparison" {
    var subject = try Subject.init(
        example_data.multi_scalar_model,
        example_data.multi_scalar_point,
    );
    defer subject.deinit();

    const point = [_]Scalar{ 210.0, -60.0 };
    var gradient: [2]Scalar = undefined;
    var hessian: [4]Scalar = undefined;
    try subject.derivatives(&point, &gradient, &hessian);

    // Interning makes this an identifier equality upstream, but the requirement
    // is on the produced numbers, so it is asserted on the numbers.
    try std.testing.expectEqual(hessian[1], hessian[2]);
}
