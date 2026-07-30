//! Conformance of the invariant spectral derivatives against an independent
//! known-spectrum evaluator.
//!
//! The oracle differentiates the scalar function `Phi` at eigenvalues supplied
//! by hand, then combines those coefficients with the derivative matrices of a
//! model whose mass matrix is known in closed form. It builds no matrix, calls
//! no eigensolver, rotates nothing, and executes no kernel. Agreement is
//! therefore evidence about the Fréchet construction, the eigensystem reuse,
//! and the zero-mode policy rather than a restatement of them.
//!
//! Two closed forms carry most of the file:
//!
//!   * the one-scalar model, whose mass matrix `m2 + lambda phi^2 / 2` gives
//!     the ordinary chain and product rules; and
//!   * the three-scalar slice, whose mass matrix is the background times a
//!     fixed integer matrix, so `V(b) = sum_a Phi(b c_a)` differentiates term
//!     by term over the fixture's exact spectrum.

const std = @import("std");
const test_allocator = @import("test_allocator");
const phaser = @import("phaser");
const example_data = @import("example_data");
const comparison = @import("numerical_comparison");
const oracle_fixture = @import("scalar_oracle_fixture");
const oracle = @import("scalar_one_loop.zig");

const calculation = phaser.calculation;
const kernel_module = phaser.kernel;

const Scalar = kernel_module.Scalar;
const Complex64 = kernel_module.Complex64;
const Status = kernel_module.Status;

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
    return switch (try phaser.loadModel(testContext(), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = source,
    }, .{ .audit = true })) {
        .model => |loaded| loaded,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidModel;
        },
    };
}

fn parseRequest(source: []const u8) !calculation.Request {
    return switch (try phaser.parseRequest(testContext(), .{
        .source_id = try phaser.SourceId.fromUsize(1),
        .bytes = source,
    }, .{})) {
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
    return switch (try phaser.deriveEffectivePotential(
        testContext(),
        source_model,
        request,
        .{ .audit = true },
    )) {
        .artifact => |artifact| artifact,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.DerivationFailed;
        },
    };
}

/// A compiled one-loop kernel over one model, selecting the scalar one-loop
/// contribution alone so that the comparison is with the spectral formulas and
/// not with a tree part added to them.
const Harness = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,
    kernel: kernel_module.Kernel,
    workspace: []align(@alignOf(@Vector(2, Scalar))) u8,
    coordinates: usize,

    fn init(
        model_source: []const u8,
        request_source: []const u8,
        capability: kernel_module.Capability,
        point_count: usize,
    ) !Harness {
        return initBackend(
            model_source,
            request_source,
            capability,
            point_count,
            .reference_interpreter,
        );
    }

    fn initBackend(
        model_source: []const u8,
        request_source: []const u8,
        capability: kernel_module.Capability,
        point_count: usize,
        backend: kernel_module.Backend,
    ) !Harness {
        var model = try loadModel(model_source);
        errdefer model.deinit();
        var request = try parseRequest(request_source);
        errdefer request.deinit();
        var artifact = try derive(&model, &request);
        errdefer artifact.deinit();
        var kernel = try kernel_module.compile(test_allocator.allocator, &artifact, .{
            .capability = capability,
            .selection = .{ .role = .scalar_one_loop },
            .backend = backend,
        });
        errdefer kernel.deinit();

        const layout = kernel.workspaceLayout(point_count);
        const workspace = try test_allocator.allocator.alignedAlloc(
            u8,
            .of(@Vector(2, Scalar)),
            layout.bytes,
        );
        return .{
            .model = model,
            .request = request,
            .artifact = artifact,
            .kernel = kernel,
            .workspace = workspace,
            .coordinates = kernel.coordinateCount(),
        };
    }

    fn deinit(self: *Harness) void {
        test_allocator.allocator.free(self.workspace);
        self.kernel.deinit();
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }

    /// Packs named parameter values in the kernel's declared channel order.
    ///
    /// Unnamed channels stay exactly zero, so a test states only the couplings
    /// it means to vary. The result is trimmed to the declared channel count
    /// rather than to whatever the caller's buffer happens to be.
    fn parameters(
        self: *const Harness,
        buffer: []Scalar,
        names: []const []const u8,
        entries: []const Scalar,
    ) []Scalar {
        @memset(buffer, 0);
        for (names, entries) |name, entry| {
            for (self.kernel.parameters) |channel| {
                if (std.mem.eql(u8, channel.name, name)) buffer[channel.offset] = entry;
            }
        }
        return buffer[0..self.kernel.parameterCount()];
    }

    fn evaluate(
        self: *Harness,
        packed_parameters: []const Scalar,
        scale: Scalar,
        backgrounds: []const Scalar,
        outputs: kernel_module.ComplexOutputBuffers,
    ) !void {
        try self.kernel.evaluateComplex(
            .{
                .parameters = packed_parameters,
                .scales = &.{scale},
                .backgrounds = backgrounds,
            },
            outputs.statuses.len,
            self.workspace,
            outputs,
        );
    }
};

const one_loop_full_space =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

const one_loop_slice =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"component_slice","coordinates":[{"id":"b","scalar":"r"}]},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

/// The fixture's `positive_dense` couplings, whose matrix has spectrum
/// `{9, 36, 81}` at background one.
const positive_dense = [6]Scalar{ 53, 26, -4, 44, -22, 29 };
const coupling_names = [_][]const u8{ "c111", "c112", "c113", "c122", "c123", "c133" };

fn expectClose(
    policy: comparison.Policy,
    expected: oracle.Complex64,
    actual: Complex64,
    magnitude: oracle.Complex64,
) !void {
    try policy.expectCloseAt(expected.re, actual.re, .{ .magnitude = magnitude.re });
    try policy.expectCloseAt(expected.im, actual.im, .{ .magnitude = magnitude.im });
}

// -- the one-scalar closed form ---------------------------------------------

/// `V^(1)`, its gradient, and its Hessian for `M2 = m2 + lambda phi^2 / 2`.
///
/// The oracle differentiates the composition by hand:
///
///     dV/dphi   = Phi'(M2) lambda phi
///     d2V/dphi2 = Phi'(M2) lambda + Phi''(M2) (lambda phi)^2
const Phi4Reference = struct {
    gradient: oracle.Complex64,
    hessian: oracle.Complex64,
    /// Unsigned term sums, so cancellation between terms does not make the
    /// comparison artificially strict.
    gradient_magnitude: oracle.Complex64,
    hessian_magnitude: oracle.Complex64,

    fn at(
        mass_squared: Scalar,
        coupling: Scalar,
        background: Scalar,
        scale: Scalar,
    ) !Phi4Reference {
        const spectrum = mass_squared + coupling * background * background / 2.0;
        const first = oracle.oneLoopFirstSpectralDerivative(spectrum, scale);
        const second = try oracle.oneLoopSecondSpectralDerivative(spectrum, scale);
        const slope = coupling * background;

        const curvature_left = oracle.Complex64{
            .re = first.re * coupling,
            .im = first.im * coupling,
        };
        const curvature_right = oracle.Complex64{
            .re = second.re * slope * slope,
            .im = second.im * slope * slope,
        };
        return .{
            .gradient = .{ .re = first.re * slope, .im = first.im * slope },
            .hessian = .{
                .re = curvature_left.re + curvature_right.re,
                .im = curvature_left.im + curvature_right.im,
            },
            .gradient_magnitude = .{
                .re = @abs(first.re * slope),
                .im = @abs(first.im * slope),
            },
            .hessian_magnitude = .{
                .re = @abs(curvature_left.re) + @abs(curvature_right.re),
                .im = @abs(curvature_left.im) + @abs(curvature_right.im),
            },
        };
    }
};

test "the one-scalar derivatives follow the analytic chain and product rules" {
    var harness = try Harness.init(
        example_data.phi4_model,
        one_loop_full_space,
        .value_gradient_hessian,
        1,
    );
    defer harness.deinit();

    const mass_squared: Scalar = -7812.5;
    const coupling: Scalar = 0.26;
    const scale: Scalar = 125.0;
    var buffer: [3]Scalar = undefined;
    const packed_parameters = harness.parameters(
        &buffer,
        &.{ "m2", "lambda", "omega" },
        &.{ mass_squared, coupling, 0 },
    );

    // Positive, negative, and mixed-branch backgrounds. The largest makes the
    // mass squared positive again, so both branches are exercised.
    for ([_]Scalar{ 50, -50, 600, -600 }) |background| {
        var values: [1]Complex64 = undefined;
        var gradients: [1]Complex64 = undefined;
        var hessians: [1]Complex64 = undefined;
        var statuses: [1]Status = undefined;
        try harness.evaluate(packed_parameters, scale, &.{background}, .{
            .values = &values,
            .gradients = &gradients,
            .hessians = &hessians,
            .statuses = &statuses,
        });
        try std.testing.expectEqual(Status.ok, statuses[0]);

        const expected = try Phi4Reference.at(
            mass_squared,
            coupling,
            background,
            scale,
        );
        try expectClose(
            comparison.spectral_value_known_spectrum,
            expected.gradient,
            gradients[0],
            expected.gradient_magnitude,
        );
        try expectClose(
            comparison.spectral_value_known_spectrum,
            expected.hessian,
            hessians[0],
            expected.hessian_magnitude,
        );
    }
}

test "a negative one-scalar mass squared keeps the branch in both derivatives" {
    var harness = try Harness.init(
        example_data.phi4_model,
        one_loop_full_space,
        .value_gradient_hessian,
        1,
    );
    defer harness.deinit();

    var buffer: [3]Scalar = undefined;
    const packed_parameters = harness.parameters(
        &buffer,
        &.{ "m2", "lambda", "omega" },
        &.{ -4.0, 0.5, 0 },
    );

    var values: [1]Complex64 = undefined;
    var gradients: [1]Complex64 = undefined;
    var hessians: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluate(packed_parameters, 1, &.{1}, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });

    // The mass squared is -4 + 0.25 = -3.75, so every spectral coefficient sits
    // on the negative branch and carries an imaginary component. A negative
    // eigenvalue is a successful result in the derivatives too.
    try std.testing.expectEqual(Status.ok, statuses[0]);
    try std.testing.expect(gradients[0].im != 0);
    try std.testing.expect(hessians[0].im != 0);

    const expected = try Phi4Reference.at(-4.0, 0.5, 1, 1);
    try expectClose(
        comparison.spectral_value_known_spectrum,
        expected.gradient,
        gradients[0],
        expected.gradient_magnitude,
    );
    try expectClose(
        comparison.spectral_value_known_spectrum,
        expected.hessian,
        hessians[0],
        expected.hessian_magnitude,
    );
}

// -- the three-scalar closed form -------------------------------------------

/// `V(b) = sum_a Phi(b c_a)` differentiated term by term over a known spectrum.
const SliceReference = struct {
    gradient: oracle.Complex64 = .{ .re = 0, .im = 0 },
    hessian: oracle.Complex64 = .{ .re = 0, .im = 0 },
    gradient_magnitude: oracle.Complex64 = .{ .re = 0, .im = 0 },
    hessian_magnitude: oracle.Complex64 = .{ .re = 0, .im = 0 },

    /// `coefficients` is the spectrum of the fixed integer matrix, so the mass
    /// spectrum at background `b` is `b` times each of them.
    fn at(
        coefficients: []const Scalar,
        background: Scalar,
        scale: Scalar,
    ) !SliceReference {
        var result = SliceReference{};
        for (coefficients) |coefficient| {
            const eigenvalue = background * coefficient;
            const first = oracle.oneLoopFirstSpectralDerivative(eigenvalue, scale);
            result.gradient.re += first.re * coefficient;
            result.gradient.im += first.im * coefficient;
            result.gradient_magnitude.re += @abs(first.re * coefficient);
            result.gradient_magnitude.im += @abs(first.im * coefficient);

            const second = try oracle.oneLoopSecondSpectralDerivative(eigenvalue, scale);
            const weight = coefficient * coefficient;
            result.hessian.re += second.re * weight;
            result.hessian.im += second.im * weight;
            result.hessian_magnitude.re += @abs(second.re * weight);
            result.hessian_magnitude.im += @abs(second.im * weight);
        }
        return result;
    }
};

fn sliceHarness(capability: kernel_module.Capability, points: usize) !Harness {
    return Harness.init(
        oracle_fixture.three_scalar_model,
        one_loop_slice,
        capability,
        points,
    );
}

fn sliceHarnessBackend(
    capability: kernel_module.Capability,
    points: usize,
    backend: kernel_module.Backend,
) !Harness {
    return Harness.initBackend(
        oracle_fixture.three_scalar_model,
        one_loop_slice,
        capability,
        points,
        backend,
    );
}

fn expectSliceDerivatives(
    harness: *Harness,
    couplings: [6]Scalar,
    coefficients: []const Scalar,
    background: Scalar,
    scale: Scalar,
    policy: comparison.Policy,
) !void {
    var buffer: [6]Scalar = undefined;
    const packed_parameters = harness.parameters(&buffer, &coupling_names, &couplings);

    var values: [1]Complex64 = undefined;
    var gradients: [1]Complex64 = undefined;
    var hessians: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluate(packed_parameters, scale, &.{background}, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });
    try std.testing.expectEqual(Status.ok, statuses[0]);

    const expected = try SliceReference.at(coefficients, background, scale);
    try expectClose(policy, expected.gradient, gradients[0], expected.gradient_magnitude);
    try expectClose(policy, expected.hessian, hessians[0], expected.hessian_magnitude);
}

test "a dense positive spectrum agrees with the differentiated known spectrum" {
    var harness = try sliceHarness(.value_gradient_hessian, 1);
    defer harness.deinit();
    try expectSliceDerivatives(
        &harness,
        positive_dense,
        &.{ 9, 36, 81 },
        1,
        3,
        comparison.spectral_value_known_spectrum,
    );
}

test "a negative spectrum keeps its imaginary component in both derivatives" {
    var harness = try sliceHarness(.value_gradient_hessian, 1);
    defer harness.deinit();

    // Negating the background negates the matrix, and with it every eigenvalue.
    var buffer: [6]Scalar = undefined;
    const packed_parameters = harness.parameters(&buffer, &coupling_names, &positive_dense);
    var values: [1]Complex64 = undefined;
    var gradients: [1]Complex64 = undefined;
    var hessians: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluate(packed_parameters, 3, &.{-1}, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });
    try std.testing.expectEqual(Status.ok, statuses[0]);
    try std.testing.expect(gradients[0].im != 0);
    try std.testing.expect(hessians[0].im != 0);

    try expectSliceDerivatives(
        &harness,
        positive_dense,
        &.{ 9, 36, 81 },
        -1,
        3,
        comparison.spectral_value_known_spectrum,
    );
}

test "an exactly degenerate block is differentiated as one invariant coefficient" {
    var harness = try sliceHarness(.value_gradient_hessian, 1);
    defer harness.deinit();

    // A threefold degenerate matrix. Every eigenvector basis inside that block
    // is as good as any other, so a method that differentiated eigenvalue labels
    // would depend on the solver's arbitrary choice.
    try expectSliceDerivatives(
        &harness,
        .{ 7, 0, 0, 7, 0, 7 },
        &.{ 7, 7, 7 },
        2,
        1,
        comparison.spectral_value_known_spectrum,
    );
}

test "a near-degenerate pair stays within its measured policy" {
    var harness = try sliceHarness(.value_gradient_hessian, 1);
    defer harness.deinit();

    // Two eigenvalues one part in a million apart. The direct quotient would
    // cancel most of its significand here; the stable close-pair form does not.
    const separation = 0x1p-20;
    try expectSliceDerivatives(
        &harness,
        .{ 1, 0, 0, 1 + separation, 0, 4 },
        &.{ 1, 1 + separation, 4 },
        1,
        1,
        comparison.spectral_hessian_near_degenerate,
    );
}

test "an indefinite spectrum mixes the branches inside one derivative" {
    var harness = try sliceHarness(.value_gradient_hessian, 1);
    defer harness.deinit();
    // The coupling matrix is `diag(2, -3, 5)`, so at background two the mass
    // spectrum is `{4, -6, 10}` and one point carries both branches at once.
    try expectSliceDerivatives(
        &harness,
        .{ 2, 0, 0, -3, 0, 5 },
        &.{ 2, -3, 5 },
        2,
        1,
        comparison.spectral_value_known_spectrum,
    );
}

// -- zero modes --------------------------------------------------------------

/// A one-scalar model whose mass matrix is `g phi^2`, so the spectrum at the
/// origin is exactly zero and the first derivative matrix vanishes with it.
const quadratic_zero_mode_model =
    \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
    \\"conventions":{"metric":"mostly_plus",
    \\"scalar_representation":"real_components","fermions":"two_component_weyl"},
    \\"parameters":{"g":{"domain":"real","mass_dimension":0}},
    \\"fields":{"real_scalars":[{"id":"phi"}],"weyl_fermions":[],
    \\"gauge_vectors":[]},
    \\"tensors":{"scalar_quartic":{"components":[
    \\{"indices":["phi","phi","phi","phi"],"value":"g"}]}}}
;

/// The same model with a cubic coupling, so the mass matrix is linear in the
/// background and the zero mode does not cancel.
const linear_zero_mode_model =
    \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
    \\"conventions":{"metric":"mostly_plus",
    \\"scalar_representation":"real_components","fermions":"two_component_weyl"},
    \\"parameters":{"c":{"domain":"real","mass_dimension":1}},
    \\"fields":{"real_scalars":[{"id":"phi"}],"weyl_fermions":[],
    \\"gauge_vectors":[]},
    \\"tensors":{"scalar_cubic":{"components":[
    \\{"indices":["phi","phi","phi"],"value":"c"}]}}}
;

test "a quadratic zero mode cancels termwise and publishes a finite Hessian" {
    var harness = try Harness.init(
        quadratic_zero_mode_model,
        one_loop_full_space,
        .value_gradient_hessian,
        1,
    );
    defer harness.deinit();

    var buffer: [1]Scalar = undefined;
    const packed_parameters = harness.parameters(&buffer, &.{"g"}, &.{2.0});

    var values: [1]Complex64 = undefined;
    var gradients: [1]Complex64 = undefined;
    var hessians: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluate(packed_parameters, 1, &.{0}, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });

    // The projected zero block of the first-derivative matrix is exactly zero,
    // so the divergent coefficient is skipped before it is ever formed. The
    // published Hessian is the exact analytic limit, not a large finite number.
    try std.testing.expectEqual(Status.ok, statuses[0]);
    try std.testing.expectEqual(Complex64.zero, values[0]);
    try std.testing.expectEqual(Complex64.zero, gradients[0]);
    try std.testing.expectEqual(Complex64.zero, hessians[0]);
}

test "a linear zero mode is singular and publishes nothing at that point" {
    var harness = try Harness.init(
        linear_zero_mode_model,
        one_loop_full_space,
        .value_gradient_hessian,
        3,
    );
    defer harness.deinit();

    var buffer: [1]Scalar = undefined;
    const packed_parameters = harness.parameters(&buffer, &.{"c"}, &.{3.0});

    const sentinel = Complex64{ .re = 1234.5, .im = -1234.5 };
    var values = [_]Complex64{sentinel} ** 3;
    var gradients = [_]Complex64{sentinel} ** 3;
    var hessians = [_]Complex64{sentinel} ** 3;
    var statuses = [_]Status{.ok} ** 3;
    try harness.evaluate(packed_parameters, 1, &.{ 1, 0, 2 }, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });

    // Only the middle point sits on the zero mode, and only it fails. A failed
    // point neither publishes a partial result nor disturbs its neighbours.
    try std.testing.expectEqual(Status.ok, statuses[0]);
    try std.testing.expectEqual(Status.singular_derivative, statuses[1]);
    try std.testing.expectEqual(Status.ok, statuses[2]);
    try std.testing.expectEqual(sentinel, values[1]);
    try std.testing.expectEqual(sentinel, gradients[1]);
    try std.testing.expectEqual(sentinel, hessians[1]);
    try std.testing.expect(!std.meta.eql(sentinel, values[0]));
    try std.testing.expect(!std.meta.eql(sentinel, values[2]));
}

test "a value or gradient kernel succeeds where the fused Hessian is singular" {
    var buffer: [1]Scalar = undefined;

    var gradient_only = try Harness.init(
        linear_zero_mode_model,
        one_loop_full_space,
        .value_gradient,
        1,
    );
    defer gradient_only.deinit();
    const packed_parameters = gradient_only.parameters(&buffer, &.{"c"}, &.{3.0});

    var values: [1]Complex64 = undefined;
    var gradients: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try gradient_only.evaluate(packed_parameters, 1, &.{0}, .{
        .values = &values,
        .gradients = &gradients,
        .statuses = &statuses,
    });

    // The gradient applies the exact limit `Phi'(0) = 0` and is finite. Only
    // the second derivative diverges, so a narrower capability is a different
    // program with a different status boundary rather than a relaxed one.
    try std.testing.expectEqual(Status.ok, statuses[0]);
    try std.testing.expectEqual(Complex64.zero, values[0]);
    try std.testing.expectEqual(Complex64.zero, gradients[0]);
}

// -- structural properties ---------------------------------------------------

test "the published Hessian is symmetric across a two-coordinate model" {
    var harness = try Harness.init(
        example_data.multi_scalar_model,
        one_loop_full_space,
        .value_gradient_hessian,
        1,
    );
    defer harness.deinit();
    try std.testing.expectEqual(@as(usize, 2), harness.coordinates);

    var buffer: [16]Scalar = undefined;
    const packed_parameters = harness.parameters(
        &buffer,
        &.{ "m_h2", "m_s2", "m_hs2", "lh", "ls", "l2", "b" },
        &.{ -3000.0, 900.0, 120.0, 0.3, 0.4, 0.15, 55.0 },
    );

    var values: [1]Complex64 = undefined;
    var gradients: [2]Complex64 = undefined;
    var hessians: [4]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluate(packed_parameters, 125, &.{ 40, 25 }, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });

    try std.testing.expectEqual(Status.ok, statuses[0]);
    // Mixed partials agree exactly. They are one interned symbolic value, and
    // the numerical operation evaluates every dense entry from the formula
    // rather than copying one triangle onto the other.
    try std.testing.expectEqual(hessians[1], hessians[2]);
    try std.testing.expect(hessians[0].re != hessians[3].re);
}

test "a fused kernel agrees bitwise with separate value and gradient kernels" {
    var fused = try sliceHarness(.value_gradient_hessian, 1);
    defer fused.deinit();
    var separate = try sliceHarness(.value_gradient, 1);
    defer separate.deinit();
    var value_only = try sliceHarness(.value, 1);
    defer value_only.deinit();

    var buffer: [6]Scalar = undefined;
    const packed_parameters = fused.parameters(&buffer, &coupling_names, &positive_dense);

    var fused_values: [1]Complex64 = undefined;
    var fused_gradients: [1]Complex64 = undefined;
    var fused_hessians: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try fused.evaluate(packed_parameters, 3, &.{2}, .{
        .values = &fused_values,
        .gradients = &fused_gradients,
        .hessians = &fused_hessians,
        .statuses = &statuses,
    });

    var separate_values: [1]Complex64 = undefined;
    var separate_gradients: [1]Complex64 = undefined;
    try separate.evaluate(packed_parameters, 3, &.{2}, .{
        .values = &separate_values,
        .gradients = &separate_gradients,
        .statuses = &statuses,
    });

    var only_values: [1]Complex64 = undefined;
    try value_only.evaluate(packed_parameters, 3, &.{2}, .{
        .values = &only_values,
        .statuses = &statuses,
    });

    // The three programs share their instructions for the outputs they have in
    // common, so agreement is bitwise rather than within a tolerance.
    try std.testing.expectEqual(fused_values[0], separate_values[0]);
    try std.testing.expectEqual(fused_values[0], only_values[0]);
    try std.testing.expectEqual(fused_gradients[0], separate_gradients[0]);
}

test "batch derivative evaluation agrees with scalar evaluation point by point" {
    const backgrounds = [_]Scalar{ -2, -0.5, 0.5, 1, 3 };
    var batched = try sliceHarness(.value_gradient_hessian, backgrounds.len);
    defer batched.deinit();

    var buffer: [6]Scalar = undefined;
    const packed_parameters = batched.parameters(
        &buffer,
        &coupling_names,
        &positive_dense,
    );

    var values: [backgrounds.len]Complex64 = undefined;
    var gradients: [backgrounds.len]Complex64 = undefined;
    var hessians: [backgrounds.len]Complex64 = undefined;
    var statuses: [backgrounds.len]Status = undefined;
    try batched.evaluate(packed_parameters, 3, &backgrounds, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });

    var single = try sliceHarness(.value_gradient_hessian, 1);
    defer single.deinit();
    for (backgrounds, 0..) |background, index| {
        var one_value: [1]Complex64 = undefined;
        var one_gradient: [1]Complex64 = undefined;
        var one_hessian: [1]Complex64 = undefined;
        var one_status: [1]Status = undefined;
        try single.evaluate(packed_parameters, 3, &.{background}, .{
            .values = &one_value,
            .gradients = &one_gradient,
            .hessians = &one_hessian,
            .statuses = &one_status,
        });
        try std.testing.expectEqual(one_status[0], statuses[index]);
        try std.testing.expectEqual(one_value[0], values[index]);
        try std.testing.expectEqual(one_gradient[0], gradients[index]);
        try std.testing.expectEqual(one_hessian[0], hessians[index]);
    }
}

test "optimized blocked fused derivatives are bitwise identical to reference" {
    const backgrounds = [_]Scalar{ -2, -0.5, 0.5, 1, 3 };
    var reference_harness = try sliceHarnessBackend(
        .value_gradient_hessian,
        backgrounds.len,
        .reference_interpreter,
    );
    defer reference_harness.deinit();
    var optimized_harness = try sliceHarnessBackend(
        .value_gradient_hessian,
        backgrounds.len,
        .optimized_interpreter,
    );
    defer optimized_harness.deinit();

    var reference_buffer: [6]Scalar = undefined;
    const reference_parameters = reference_harness.parameters(
        &reference_buffer,
        &coupling_names,
        &positive_dense,
    );
    var optimized_buffer: [6]Scalar = undefined;
    const optimized_parameters = optimized_harness.parameters(
        &optimized_buffer,
        &coupling_names,
        &positive_dense,
    );
    var reference_values: [backgrounds.len]Complex64 = undefined;
    var reference_gradients: [backgrounds.len]Complex64 = undefined;
    var reference_hessians: [backgrounds.len]Complex64 = undefined;
    var reference_statuses: [backgrounds.len]Status = undefined;
    var optimized_values: [backgrounds.len]Complex64 = undefined;
    var optimized_gradients: [backgrounds.len]Complex64 = undefined;
    var optimized_hessians: [backgrounds.len]Complex64 = undefined;
    var optimized_statuses: [backgrounds.len]Status = undefined;

    try reference_harness.evaluate(reference_parameters, 3, &backgrounds, .{
        .values = &reference_values,
        .gradients = &reference_gradients,
        .hessians = &reference_hessians,
        .statuses = &reference_statuses,
    });
    try optimized_harness.evaluate(optimized_parameters, 3, &backgrounds, .{
        .values = &optimized_values,
        .gradients = &optimized_gradients,
        .hessians = &optimized_hessians,
        .statuses = &optimized_statuses,
    });

    try std.testing.expectEqualSlices(Status, &reference_statuses, &optimized_statuses);
    try std.testing.expectEqualSlices(Complex64, &reference_values, &optimized_values);
    try std.testing.expectEqualSlices(Complex64, &reference_gradients, &optimized_gradients);
    try std.testing.expectEqualSlices(Complex64, &reference_hessians, &optimized_hessians);
}

test "derivative evaluation allocates nothing and fits the queried workspace" {
    var harness = try sliceHarness(.value_gradient_hessian, 4);
    defer harness.deinit();

    var buffer: [6]Scalar = undefined;
    const packed_parameters = harness.parameters(
        &buffer,
        &coupling_names,
        &positive_dense,
    );
    var values: [4]Complex64 = undefined;
    var gradients: [4]Complex64 = undefined;
    var hessians: [4]Complex64 = undefined;
    var statuses: [4]Status = undefined;
    const outputs = kernel_module.ComplexOutputBuffers{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    };
    const inputs = kernel_module.Inputs{
        .parameters = packed_parameters,
        .scales = &.{3},
        .backgrounds = &.{ 1, 2, 3, 4 },
    };

    // Evaluation takes no allocator: the rotated derivative matrices, the
    // representative spectrum, the divided differences, and the candidate
    // outputs all come from the queried workspace.
    const layout = harness.kernel.workspaceLayout(4);
    try harness.kernel.evaluateComplex(inputs, 4, harness.workspace, outputs);
    for (statuses) |status| try std.testing.expectEqual(Status.ok, status);

    // One byte less fails before any slot is written.
    try std.testing.expectError(error.WorkspaceTooSmall, harness.kernel.evaluateComplex(
        inputs,
        4,
        harness.workspace[0 .. layout.bytes - 1],
        outputs,
    ));
}

test "the fused Hessian needs more workspace than the value alone" {
    var value_only = try sliceHarness(.value, 1);
    defer value_only.deinit();
    var fused = try sliceHarness(.value_gradient_hessian, 1);
    defer fused.deinit();

    // The derivative operation adds rotated matrices and a divided-difference
    // triangle to the frame the value already needed, and the query reports it
    // rather than leaving the caller to infer a size from output shapes.
    try std.testing.expect(
        fused.kernel.workspaceLayout(1).bytes >
            value_only.kernel.workspaceLayout(1).bytes,
    );
}
