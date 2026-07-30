//! Conformance of the numerical order-one value path against an independent
//! known-spectrum evaluator.
//!
//! The oracle is `scalar_one_loop.zig`, which sums the principal-branch scalar
//! contribution over an eigenvalue multiset supplied by hand. It builds no
//! matrix, calls no eigensolver, lowers no Typed Value IR, and executes no
//! kernel, so agreement is evidence about assembly, diagonalization, and the
//! spectral sum rather than a restatement of them.
//!
//! The dense three-by-three spectra come from the fixture, which records
//! matrices whose characteristic polynomials factor over the integers. Their
//! eigenvalues are therefore exact inputs to the oracle rather than something
//! the eigensolver was asked for.

const std = @import("std");
const test_allocator = @import("test_allocator");
const phaser = @import("phaser");
const example_data = @import("example_data");
const oracle_fixture = @import("scalar_oracle_fixture");
const oracle = @import("scalar_one_loop.zig");

const value = phaser.value;
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
        .{ .audit = true, .derivatives = .none },
    )) {
        .artifact => |artifact| artifact,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.DerivationFailed;
        },
    };
}

/// A compiled order-one value kernel over the three-scalar fixture model,
/// whose background slice `(r,s,t) = (b,0,0)` makes the mass matrix `b` times
/// the fixture's recorded integer matrix.
const Harness = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,
    kernel: kernel_module.Kernel,
    workspace: []align(@alignOf(@Vector(2, Scalar))) u8,

    const slice_request =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[{"id":"b","scalar":"r"}]},
        \\"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":1}}}
    ;

    fn init(selection: kernel_module.Selection) !Harness {
        return initBackend(selection, .reference_interpreter);
    }

    fn initBackend(
        selection: kernel_module.Selection,
        backend: kernel_module.Backend,
    ) !Harness {
        var model = try loadModel(oracle_fixture.three_scalar_model);
        errdefer model.deinit();
        var request = try parseRequest(slice_request);
        errdefer request.deinit();
        var artifact = try derive(&model, &request);
        errdefer artifact.deinit();
        var kernel = try kernel_module.compile(test_allocator.allocator, &artifact, .{
            .capability = .value,
            .selection = selection,
            .backend = backend,
        });
        errdefer kernel.deinit();

        const layout = kernel.workspaceLayout(1);
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
        };
    }

    fn deinit(self: *Harness) void {
        test_allocator.allocator.free(self.workspace);
        self.kernel.deinit();
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }

    /// Packs the six cubic couplings in the model's canonical parameter order.
    fn parameters(self: *const Harness, entries: [6]Scalar) [6]Scalar {
        var packed_values: [6]Scalar = undefined;
        const names = [_][]const u8{ "c111", "c112", "c113", "c122", "c123", "c133" };
        for (names, entries) |name, entry| {
            for (self.kernel.parameters) |channel| {
                if (std.mem.eql(u8, channel.name, name)) {
                    packed_values[channel.offset] = entry;
                }
            }
        }
        return packed_values;
    }

    fn evaluateAt(
        self: *Harness,
        couplings: [6]Scalar,
        scale: Scalar,
        backgrounds: []const Scalar,
        values: []Complex64,
        statuses: []Status,
    ) !void {
        const packed_values = self.parameters(couplings);
        try self.kernel.evaluateComplex(
            .{
                .parameters = &packed_values,
                .scales = &.{scale},
                .backgrounds = backgrounds,
            },
            values.len,
            self.workspace,
            .{ .values = values, .statuses = statuses },
        );
    }
};

/// The fixture's `positive_dense` couplings, whose matrix has spectrum
/// `{9, 36, 81}` at background one.
const positive_dense = [6]Scalar{ 53, 26, -4, 44, -22, 29 };

/// The fixture's `exact_zero_mode` couplings, whose matrix has spectrum
/// `{0, 2, 4}` at background one.
const exact_zero_mode = [6]Scalar{ 1, 1, 0, 1, 0, 4 };

fn expectAgreesWithSpectrum(
    actual: Complex64,
    eigenvalues: []const Scalar,
    scale: Scalar,
) !void {
    const expected = oracle.spectralSumAt(eigenvalues, scale);
    try oracle.expectComplexApprox(
        expected.value,
        .{ .re = actual.re, .im = actual.im },
        expected.unsigned_scale,
    );
}

test "a dense positive spectrum agrees with the known-spectrum evaluator" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluateAt(positive_dense, 3, &.{1}, &values, &statuses);

    try std.testing.expectEqual(Status.ok, statuses[0]);
    try expectAgreesWithSpectrum(values[0], &.{ 9, 36, 81 }, 3);
    // Every eigenvalue is positive, so the principal branch contributes no
    // imaginary part at all.
    try std.testing.expectEqual(@as(Scalar, 0), values[0].im);
}

test "an exact zero mode contributes exactly nothing and stays ok" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluateAt(exact_zero_mode, 1, &.{1}, &values, &statuses);

    // The analytic zero-mode limit is used before any logarithm is formed, so
    // a zero eigenvalue is a successful result rather than a non-finite one.
    try std.testing.expectEqual(Status.ok, statuses[0]);
    try expectAgreesWithSpectrum(values[0], &.{ 0, 2, 4 }, 1);
    try expectAgreesWithSpectrum(values[0], &.{ 2, 4 }, 1);
}

test "a negative spectrum keeps its principal-branch imaginary component" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    // Negating the background negates the matrix and therefore every
    // eigenvalue, which turns the positive case into a wholly negative one.
    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluateAt(positive_dense, 3, &.{-1}, &values, &statuses);

    // A negative mass-squared eigenvalue is a valid input, not a failure.
    try std.testing.expectEqual(Status.ok, statuses[0]);
    try expectAgreesWithSpectrum(values[0], &.{ -9, -36, -81 }, 3);
    try std.testing.expect(values[0].im > 0);
}

test "an indefinite spectrum mixes the branches within one point" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    // diag(2, -3, 5) scaled by the background, built directly as a diagonal
    // coupling matrix so that its spectrum is exact.
    const indefinite = [6]Scalar{ 2, 0, 0, -3, 0, 5 };
    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluateAt(indefinite, 1, &.{2}, &values, &statuses);

    try std.testing.expectEqual(Status.ok, statuses[0]);
    try expectAgreesWithSpectrum(values[0], &.{ 4, -6, 10 }, 1);
    try std.testing.expect(values[0].im > 0);
}

test "a repeated eigenvalue keeps its multiplicity" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    const degenerate = [6]Scalar{ 7, 0, 0, 7, 0, 7 };
    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluateAt(degenerate, 1, &.{1}, &values, &statuses);

    try std.testing.expectEqual(Status.ok, statuses[0]);
    try expectAgreesWithSpectrum(values[0], &.{ 7, 7, 7 }, 1);

    // Threefold degeneracy is exactly three times the single contribution, not
    // once.
    const single = oracle.oneLoopEigenvalue(7, 1);
    try oracle.expectComplexApprox(
        .{ .re = 3.0 * single.re, .im = 3.0 * single.im },
        .{ .re = values[0].re, .im = values[0].im },
        .{ .re = 3.0 * @abs(single.re), .im = 3.0 * @abs(single.im) },
    );
}

test "a near-degenerate spectrum stays within its measured policy" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    const separation = 0x1p-20;
    const near = [6]Scalar{ 1, 0, 0, 1 + separation, 0, 4 };
    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluateAt(near, 1, &.{1}, &values, &statuses);

    try std.testing.expectEqual(Status.ok, statuses[0]);
    try expectAgreesWithSpectrum(values[0], &.{ 1, 1 + separation, 4 }, 1);
}

test "the scale enters through its own channel and shifts the value exactly" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    var first: [1]Complex64 = undefined;
    var second: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try harness.evaluateAt(exact_zero_mode, 1, &.{1}, &first, &statuses);
    try harness.evaluateAt(exact_zero_mode, 2, &.{1}, &second, &statuses);

    // Doubling the scale subtracts `Tr[M^2 M^2] log(4) / (64 pi^2)` from the
    // real part. With spectrum {0, 2, 4} that is (4 + 16) log(4) / (64 pi^2).
    const expected = -(4.0 + 16.0) * @log(4.0) /
        (64.0 * std.math.pi * std.math.pi);
    const difference = second[0].re - first[0].re;
    try oracle.expectComplexApprox(
        .{ .re = expected, .im = 0 },
        .{ .re = difference, .im = second[0].im - first[0].im },
        .{ .re = @abs(first[0].re) + @abs(second[0].re), .im = 0 },
    );
}

test "an invalid scale is a call-level error before any point runs" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    const packed_values = harness.parameters(positive_dense);
    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    for ([_]Scalar{ 0, -1, std.math.inf(Scalar), std.math.nan(Scalar) }) |scale| {
        try std.testing.expectError(error.InvalidScale, harness.kernel.evaluateComplex(
            .{
                .parameters = &packed_values,
                .scales = &.{scale},
                .backgrounds = &.{1},
            },
            1,
            harness.workspace,
            .{ .values = &values, .statuses = &statuses },
        ));
    }
}

test "calling the real method on a complex kernel is a call-level error" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    const packed_values = harness.parameters(positive_dense);
    var values = [_]Scalar{std.math.nan(Scalar)};
    var statuses = [_]Status{.non_finite};
    try std.testing.expectError(error.ResultTypeMismatch, harness.kernel.evaluate(
        .{
            .parameters = &packed_values,
            .scales = &.{1},
            .backgrounds = &.{1},
        },
        1,
        harness.workspace,
        .{ .values = &values, .statuses = &statuses },
    ));

    // The result type is checked before anything is written, so the caller's
    // buffers are untouched.
    try std.testing.expect(std.math.isNan(values[0]));
    try std.testing.expectEqual(Status.non_finite, statuses[0]);
}

test "batch evaluation agrees with scalar evaluation point by point" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    const backgrounds = [_]Scalar{ -2, -0.5, 0, 0.5, 1, 3 };
    var batch: [backgrounds.len]Complex64 = undefined;
    var batch_statuses: [backgrounds.len]Status = undefined;
    try harness.evaluateAt(positive_dense, 3, &backgrounds, &batch, &batch_statuses);

    for (backgrounds, 0..) |background, index| {
        var single: [1]Complex64 = undefined;
        var single_status: [1]Status = undefined;
        try harness.evaluateAt(
            positive_dense,
            3,
            &.{background},
            &single,
            &single_status,
        );
        try std.testing.expectEqual(single_status[0], batch_statuses[index]);
        // Same kernel, same inputs, same order: bitwise identity, not merely
        // agreement within a tolerance.
        try std.testing.expectEqual(single[0].re, batch[index].re);
        try std.testing.expectEqual(single[0].im, batch[index].im);
    }
}

test "optimized blocked one-loop execution is bitwise identical to reference" {
    var reference_harness = try Harness.initBackend(
        .{ .role = .scalar_one_loop },
        .reference_interpreter,
    );
    defer reference_harness.deinit();
    var optimized_harness = try Harness.initBackend(
        .{ .role = .scalar_one_loop },
        .optimized_interpreter,
    );
    defer optimized_harness.deinit();

    const backgrounds = [_]Scalar{ -2, -0.5, 0, 1, 3 };
    var reference_values: [backgrounds.len]Complex64 = undefined;
    var optimized_values: [backgrounds.len]Complex64 = undefined;
    var reference_statuses: [backgrounds.len]Status = undefined;
    var optimized_statuses: [backgrounds.len]Status = undefined;
    try reference_harness.evaluateAt(
        positive_dense,
        3,
        &backgrounds,
        &reference_values,
        &reference_statuses,
    );
    try optimized_harness.evaluateAt(
        positive_dense,
        3,
        &backgrounds,
        &optimized_values,
        &optimized_statuses,
    );

    try std.testing.expectEqualSlices(Status, &reference_statuses, &optimized_statuses);
    try std.testing.expectEqualSlices(Complex64, &reference_values, &optimized_values);
}

test "repeated evaluation of one kernel is bitwise reproducible" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    var first: [2]Complex64 = undefined;
    var second: [2]Complex64 = undefined;
    var statuses: [2]Status = undefined;
    try harness.evaluateAt(positive_dense, 3, &.{ 1, -1 }, &first, &statuses);
    try harness.evaluateAt(positive_dense, 3, &.{ 1, -1 }, &second, &statuses);
    try std.testing.expectEqualSlices(Complex64, &first, &second);
}

test "the selected total promotes its tree part exactly" {
    var loop = try Harness.init(.{ .role = .scalar_one_loop });
    defer loop.deinit();
    var tree = try Harness.init(.{ .loop_order = 0 });
    defer tree.deinit();
    var total = try Harness.init(.total);
    defer total.deinit();

    // The tree order of this model is real; the complete truncation is complex
    // and equals the promoted tree value plus the loop value.
    try std.testing.expectEqual(
        kernel_module.ResultType.real64,
        tree.kernel.resultType(),
    );
    try std.testing.expectEqual(
        kernel_module.ResultType.complex64,
        total.kernel.resultType(),
    );

    var loop_values: [1]Complex64 = undefined;
    var total_values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try loop.evaluateAt(positive_dense, 3, &.{1}, &loop_values, &statuses);
    try total.evaluateAt(positive_dense, 3, &.{1}, &total_values, &statuses);

    const packed_values = tree.parameters(positive_dense);
    var tree_values: [1]Scalar = undefined;
    try tree.kernel.evaluate(
        .{
            .parameters = &packed_values,
            .scales = &.{},
            .backgrounds = &.{1},
        },
        1,
        tree.workspace,
        .{ .values = &tree_values, .statuses = &statuses },
    );

    try std.testing.expectEqual(tree_values[0] + loop_values[0].re, total_values[0].re);
    try std.testing.expectEqual(loop_values[0].im, total_values[0].im);
}

test "staged and unstaged execution agree bitwise" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    var point = try parsePoint(three_scalar_point);
    defer point.deinit();
    var binding = try kernel_module.bind(
        test_allocator.allocator,
        &harness.kernel,
        &harness.model,
        &point,
    );
    defer binding.deinit();

    const backgrounds = [_]Scalar{ 1, -1, 0 };
    const couplings = [6]Scalar{ 53, 26, -4, 44, -22, 29 };

    var staged: [backgrounds.len]Complex64 = undefined;
    var staged_statuses: [backgrounds.len]Status = undefined;
    const layout = binding.workspaceLayout(backgrounds.len);
    const workspace = try test_allocator.allocator.alignedAlloc(
        u8,
        .of(Scalar),
        layout.bytes,
    );
    defer test_allocator.allocator.free(workspace);
    try binding.evaluateComplex(
        &backgrounds,
        backgrounds.len,
        workspace,
        .{ .values = &staged, .statuses = &staged_statuses },
    );

    var direct: [backgrounds.len]Complex64 = undefined;
    var direct_statuses: [backgrounds.len]Status = undefined;
    try harness.evaluateAt(
        couplings,
        binding.reference_scale,
        &backgrounds,
        &direct,
        &direct_statuses,
    );

    // The binding runs the parameter stage once and restores its frame per
    // call, so the instructions, their order, and their inputs are the same.
    try std.testing.expectEqualSlices(Status, &direct_statuses, &staged_statuses);
    try std.testing.expectEqualSlices(Complex64, &direct, &staged);
}

/// The fixture's `positive_dense` couplings as a parameter point, with a
/// reference scale of three.
const three_scalar_point =
    \\{"schema":"phaser.parameter-point/0.1",
    \\"units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":3.0},
    \\"values":{"c111":53.0,"c112":26.0,"c113":-4.0,
    \\"c122":44.0,"c123":-22.0,"c133":29.0}}
;

fn parsePoint(source: []const u8) !calculation.ParameterPoint {
    return switch (try phaser.parseParameterPoint(testContext(), .{
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

test "evaluation performs no allocation" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    // Evaluation takes no allocator: every temporary, matrix, eigensystem, and
    // eigensolver scratch byte comes from the queried workspace. Asserting the
    // signature is the check, and this exercise proves the workspace is
    // genuinely sufficient for the structured operations.
    const packed_values = harness.parameters(positive_dense);
    var values: [3]Complex64 = undefined;
    var statuses: [3]Status = undefined;
    try harness.kernel.evaluateComplex(
        .{
            .parameters = &packed_values,
            .scales = &.{3},
            .backgrounds = &.{ 1, 2, 3 },
        },
        3,
        harness.workspace,
        .{ .values = &values, .statuses = &statuses },
    );
    for (statuses) |status| try std.testing.expectEqual(Status.ok, status);
}

test "workspace is sufficient at exactly the queried size and rejected below it" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    const packed_values = harness.parameters(positive_dense);
    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    const inputs = kernel_module.Inputs{
        .parameters = &packed_values,
        .scales = &.{3},
        .backgrounds = &.{1},
    };
    const buffers = kernel_module.ComplexOutputBuffers{
        .values = &values,
        .statuses = &statuses,
    };

    const layout = harness.kernel.workspaceLayout(1);
    try std.testing.expect(layout.bytes > 0);
    try harness.kernel.evaluateComplex(inputs, 1, harness.workspace, buffers);

    // One byte less fails before any slot is written.
    try std.testing.expectError(error.WorkspaceTooSmall, harness.kernel.evaluateComplex(
        inputs,
        1,
        harness.workspace[0 .. layout.bytes - 1],
        buffers,
    ));

    // A misaligned workspace is detected rather than assumed away.
    const oversized = try test_allocator.allocator.alignedAlloc(
        u8,
        .of(Scalar),
        layout.bytes + @alignOf(Scalar),
    );
    defer test_allocator.allocator.free(oversized);
    try std.testing.expectError(error.WorkspaceMisaligned, harness.kernel.evaluateComplex(
        inputs,
        1,
        oversized[1..],
        buffers,
    ));
}

test "workspace covers the matrix, eigensystem, and solver scratch exactly" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    // Three scalars: a packed upper triangle of six entries, an eigensystem of
    // three eigenvalues plus a three-by-three eigenvector matrix, and the
    // solver's own scratch. The query accounts for all of it rather than
    // returning an estimate.
    const program = &harness.kernel.program;
    var matrix_bytes: usize = 0;
    var eigensystem_bytes: usize = 0;
    for (program.temporaries) |temporary| {
        switch (temporary.kind) {
            .real_symmetric_matrix => matrix_bytes += temporary.bytes,
            .real_eigensystem => eigensystem_bytes += temporary.bytes,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 6 * @sizeOf(Scalar)), matrix_bytes);
    try std.testing.expectEqual(@as(usize, (3 + 9) * @sizeOf(Scalar)), eigensystem_bytes);
    try std.testing.expect(program.scratch_bytes > 0);
    try std.testing.expectEqual(
        program.scratch_offset + program.scratch_bytes,
        harness.kernel.workspaceLayout(1).bytes,
    );
}

test "a failed point publishes nothing and leaves its neighbours intact" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},
        \\"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":1}}}
    );
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();
    var kernel = try kernel_module.compile(test_allocator.allocator, &artifact, .{
        .capability = .value,
        .selection = .{ .role = .scalar_one_loop },
    });
    defer kernel.deinit();

    const layout = kernel.workspaceLayout(3);
    const workspace = try test_allocator.allocator.alignedAlloc(
        u8,
        .of(Scalar),
        layout.bytes,
    );
    defer test_allocator.allocator.free(workspace);

    // A non-finite background makes the middle point's mass matrix non-finite.
    const sentinel = Complex64{ .re = -12345, .im = -54321 };
    var values = [_]Complex64{sentinel} ** 3;
    var statuses: [3]Status = undefined;
    const parameters = try packPhi4(&kernel);
    try kernel.evaluateComplex(
        .{
            .parameters = &parameters,
            .scales = &.{1},
            .backgrounds = &.{ 1, std.math.inf(Scalar), 2 },
        },
        3,
        workspace,
        .{ .values = &values, .statuses = &statuses },
    );

    try std.testing.expectEqual(Status.ok, statuses[0]);
    try std.testing.expectEqual(Status.non_finite, statuses[1]);
    try std.testing.expectEqual(Status.ok, statuses[2]);

    // Publication is point-atomic: the failed point wrote nothing at all, and
    // it did not disturb either neighbour.
    try std.testing.expectEqual(sentinel, values[1]);
    try std.testing.expect(values[0].re != sentinel.re);
    try std.testing.expect(values[2].re != sentinel.re);

    // Its neighbours are exactly what they are when evaluated alone.
    var alone: [1]Complex64 = undefined;
    var alone_status: [1]Status = undefined;
    try kernel.evaluateComplex(
        .{
            .parameters = &parameters,
            .scales = &.{1},
            .backgrounds = &.{2},
        },
        1,
        workspace,
        .{ .values = &alone, .statuses = &alone_status },
    );
    try std.testing.expectEqual(alone[0].re, values[2].re);
}

/// `m2 = 1`, `lambda = 2`, `omega = 0` in the kernel's channel order.
fn packPhi4(kernel: *const kernel_module.Kernel) ![3]Scalar {
    var parameters = [_]Scalar{0} ** 3;

    for (kernel.parameters) |channel| {
        if (std.mem.eql(u8, channel.name, "m2")) parameters[channel.offset] = 1;
        if (std.mem.eql(u8, channel.name, "lambda")) parameters[channel.offset] = 2;
    }
    return parameters;
}

test "the phi4 one-by-one spectrum agrees with its exact fixture values" {
    var model = try loadModel(example_data.phi4_model);
    defer model.deinit();
    var request = try parseRequest(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},
        \\"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":1}}}
    );
    defer request.deinit();
    var artifact = try derive(&model, &request);
    defer artifact.deinit();
    var kernel = try kernel_module.compile(test_allocator.allocator, &artifact, .{
        .capability = .value,
        .selection = .{ .role = .scalar_one_loop },
    });
    defer kernel.deinit();

    const layout = kernel.workspaceLayout(3);
    const workspace = try test_allocator.allocator.alignedAlloc(
        u8,
        .of(Scalar),
        layout.bytes,
    );
    defer test_allocator.allocator.free(workspace);

    // With `m2 = 1` and `lambda = 2` the mass matrix is `1 + phi^2`, so the
    // fixture's reference points are reached at phi = 0 and, for the zero mode,
    // at m2 = -1 and phi = 1.
    const parameters = try packPhi4(&kernel);
    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try kernel.evaluateComplex(
        .{ .parameters = &parameters, .scales = &.{1}, .backgrounds = &.{0} },
        1,
        workspace,
        .{ .values = &values, .statuses = &statuses },
    );
    try std.testing.expectEqual(Status.ok, statuses[0]);

    // The fixture's positive_mass_squared point: -3 / (128 pi^2), exactly real.
    const expected = -3.0 / (128.0 * std.math.pi * std.math.pi);
    try oracle.expectComplexApprox(
        .{ .re = expected, .im = 0 },
        .{ .re = values[0].re, .im = values[0].im },
        .{ .re = @abs(expected), .im = 0 },
    );
    try std.testing.expectEqual(@as(Scalar, 0), values[0].im);
}

test "forbidden aliasing between inputs, outputs, and workspace is rejected" {
    var harness = try Harness.init(.{ .role = .scalar_one_loop });
    defer harness.deinit();

    const packed_values = harness.parameters(positive_dense);
    var values: [1]Complex64 = undefined;
    var statuses: [1]Status = undefined;

    // Reusing the workspace as an output buffer would let one point's write
    // corrupt another point's temporaries, so it is rejected before execution.
    const overlapping = std.mem.bytesAsSlice(
        Complex64,
        harness.workspace[0..@sizeOf(Complex64)],
    );
    try std.testing.expectError(error.ForbiddenAliasing, harness.kernel.evaluateComplex(
        .{
            .parameters = &packed_values,
            .scales = &.{3},
            .backgrounds = &.{1},
        },
        1,
        harness.workspace,
        .{ .values = overlapping, .statuses = &statuses },
    ));

    // The same call with disjoint buffers succeeds, so the rejection is about
    // the overlap rather than about the shapes.
    try harness.kernel.evaluateComplex(
        .{
            .parameters = &packed_values,
            .scales = &.{3},
            .backgrounds = &.{1},
        },
        1,
        harness.workspace,
        .{ .values = &values, .statuses = &statuses },
    );
    try std.testing.expectEqual(Status.ok, statuses[0]);
}
