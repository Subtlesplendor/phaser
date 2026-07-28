//! Conformance of the Milestone 3 fixture catalog through the production path.
//!
//! Every recorded case is driven model -> artifact -> kernel: the fixture's
//! parameters and background are bound to the public model the fixture names,
//! the request is derived, the kernel is compiled and executed, and the result
//! is compared against the independent evaluator below. Nothing here restates
//! a value the production path produced.
//!
//! The evaluator itself stays independent, and this file preserves that
//! boundary deliberately. It accepts an eigenvalue multiset supplied by hand
//! from the fixture and evaluates the principal-branch scalar sum directly. It
//! builds no matrix, calls no eigensolver, lowers no Typed Value IR, and
//! executes no kernel, so agreement is evidence about assembly,
//! diagonalization, and the spectral sum rather than a restatement of them.
//! Its `f64`, `@log`, and `@sqrt` primitives are the shared numerical boundary
//! decision 0007 records.
//!
//! Four layers of that decision's oracle appear here, each with its own
//! independent input:
//!
//!   1. the fixture's transcribed mass-matrix entries, compared against the
//!      matrix the derivation actually built;
//!   2. the fixture's exact characteristic polynomial, which fixes the
//!      spectrum without a second numerical eigensolver;
//!   3. the known-spectrum evaluator, run against kernel output; and
//!   4. seeded defects, each shown to be distinguishable by the very case the
//!      decision assigns to it.
//!
//! Sibling files import the evaluator from here rather than duplicating it.

const std = @import("std");
const test_allocator = @import("test_allocator");
const comparison = @import("numerical_comparison");
const fixture_data = @import("conformance_fixture_data");
const phaser = @import("phaser");
const example_data = @import("example_data");
const oracle_fixture = @import("scalar_oracle_fixture");

const value = phaser.value;
const calculation = phaser.calculation;
const kernel_module = phaser.kernel;

const Scalar = kernel_module.Scalar;
const Status = kernel_module.Status;

// -- independent known-spectrum evaluator ----------------------------------

pub const Complex64 = struct {
    re: f64,
    im: f64,

    fn add(self: Complex64, other: Complex64) Complex64 {
        return .{ .re = self.re + other.re, .im = self.im + other.im };
    }
};

pub fn oneLoopEigenvalue(mass_squared: f64, renormalization_scale: f64) Complex64 {
    std.debug.assert(renormalization_scale > 0);
    if (mass_squared == 0) return .{ .re = 0, .im = 0 };

    const square = mass_squared * mass_squared;
    const logarithm = @log(@abs(mass_squared) /
        (renormalization_scale * renormalization_scale));
    const normalization = 64.0 * std.math.pi * std.math.pi;
    return .{
        .re = square * (logarithm - 1.5) / normalization,
        .im = if (mass_squared < 0)
            square / (64.0 * std.math.pi)
        else
            0,
    };
}

pub fn oneLoopFirstSpectralDerivative(
    mass_squared: f64,
    renormalization_scale: f64,
) Complex64 {
    if (mass_squared == 0) return .{ .re = 0, .im = 0 };

    const logarithm = @log(@abs(mass_squared) /
        (renormalization_scale * renormalization_scale));
    const normalization = 64.0 * std.math.pi * std.math.pi;
    return .{
        .re = 2.0 * mass_squared * (logarithm - 1.0) / normalization,
        .im = if (mass_squared < 0)
            mass_squared / (32.0 * std.math.pi)
        else
            0,
    };
}

pub fn oneLoopSecondSpectralDerivative(
    mass_squared: f64,
    renormalization_scale: f64,
) error{SingularDerivative}!Complex64 {
    if (mass_squared == 0) return error.SingularDerivative;

    const logarithm = @log(@abs(mass_squared) /
        (renormalization_scale * renormalization_scale));
    const normalization = 32.0 * std.math.pi * std.math.pi;
    return .{
        .re = logarithm / normalization,
        .im = if (mass_squared < 0)
            1.0 / (32.0 * std.math.pi)
        else
            0,
    };
}

pub fn expectComplexApprox(
    expected: Complex64,
    actual: Complex64,
    scale: Complex64,
) !void {
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        expected.re,
        actual.re,
        .{ .magnitude = scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        expected.im,
        actual.im,
        .{ .magnitude = scale.im },
    );
}

pub const SpectralSum = struct {
    value: Complex64,
    unsigned_scale: Complex64,
};

pub fn spectralSumAt(
    eigenvalues: []const f64,
    renormalization_scale: f64,
) SpectralSum {
    var sum = SpectralSum{
        .value = .{ .re = 0, .im = 0 },
        .unsigned_scale = .{ .re = 0, .im = 0 },
    };
    for (eigenvalues) |eigenvalue| {
        const contribution = oneLoopEigenvalue(
            eigenvalue,
            renormalization_scale,
        );
        sum.value = sum.value.add(contribution);
        sum.unsigned_scale.re += @abs(contribution.re);
        sum.unsigned_scale.im += @abs(contribution.im);
    }
    return sum;
}

// -- fixture metadata contract ---------------------------------------------

fn requiredObject(
    object: std.json.ObjectMap,
    key: []const u8,
) !std.json.ObjectMap {
    const item = object.get(key) orelse return error.MissingFixtureField;
    return switch (item) {
        .object => |map| map,
        else => error.InvalidFixtureField,
    };
}

fn requiredArray(
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const std.json.Value {
    const item = object.get(key) orelse return error.MissingFixtureField;
    return switch (item) {
        .array => |array| array.items,
        else => error.InvalidFixtureField,
    };
}

fn requiredString(
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const u8 {
    const item = object.get(key) orelse return error.MissingFixtureField;
    return switch (item) {
        .string => |string| string,
        else => error.InvalidFixtureField,
    };
}

fn requiredNumberString(
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const u8 {
    const item = object.get(key) orelse return error.MissingFixtureField;
    return switch (item) {
        .number_string => |string| string,
        else => error.InvalidFixtureField,
    };
}

fn expectNumericalCaseContract(case: std.json.Value) !void {
    const object = switch (case) {
        .object => |map| map,
        else => return error.InvalidFixtureField,
    };
    _ = try requiredString(object, "id");
    const item = try requiredObject(object, "calculation");
    try std.testing.expectEqualStrings(
        "effective_potential",
        try requiredString(item, "kind"),
    );
    try std.testing.expectEqualStrings(
        "scalar_one_loop",
        try requiredString(item, "contribution"),
    );
    try std.testing.expectEqualStrings(
        "1",
        try requiredNumberString(item, "loop_order"),
    );
    _ = try requiredString(item, "operation");

    const precision = try requiredObject(object, "reference_precision");
    try std.testing.expectEqualStrings(
        "binary64",
        try requiredString(precision, "arithmetic"),
    );
    try std.testing.expectEqualStrings(
        "53",
        try requiredNumberString(precision, "significand_bits"),
    );
    _ = try requiredArray(precision, "shared_primitives");

    _ = try requiredString(object, "comparison_policy");
    _ = try requiredString(object, "expected_status");
    const source = try requiredObject(object, "derivation_source");
    _ = try requiredString(source, "kind");
    _ = try requiredString(source, "file");
    _ = try requiredString(source, "section");
    _ = try requiredArray(object, "manual_transformations");
}

fn expectNumericalCases(
    root: std.json.ObjectMap,
    key: []const u8,
) !void {
    const cases = root.get(key) orelse return;
    const items = switch (cases) {
        .array => |array| array.items,
        else => return error.InvalidFixtureField,
    };
    for (items) |case| try expectNumericalCaseContract(case);
}

fn expectFixtureContracts(source: []const u8) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        test_allocator.allocator,
        source,
        .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
            .allocate = .alloc_always,
        },
    );
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |map| map,
        else => return error.InvalidFixtureField,
    };
    try std.testing.expectEqualStrings(
        "phaser.conformance-fixture/0.1",
        try requiredString(root, "schema"),
    );
    try expectNumericalCases(root, "reference_points");
    try expectNumericalCases(root, "metamorphic_cases");
}

test "Milestone 3 numerical cases carry complete fixture metadata" {
    try expectFixtureContracts(fixture_data.phi4_fixture);
    try expectFixtureContracts(fixture_data.multi_scalar_fixture);
    try expectFixtureContracts(fixture_data.three_scalar_fixture);
}

// -- production path -------------------------------------------------------

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
    derivatives: calculation.Derivatives,
) !calculation.Artifact {
    return switch (try phaser.deriveEffectivePotential(
        testContext(),
        source_model,
        request,
        .{ .audit = true, .derivatives = derivatives },
    )) {
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
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

/// The three-scalar slice `(r,s,t) = (b,0,0)`, on which the fixture's mass
/// matrix is `b` times its recorded integer coupling matrix.
const three_scalar_slice_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"component_slice","coordinates":[{"id":"b","scalar":"r"}]},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

/// One named parameter value, so a case packs by model identity rather than by
/// guessing a channel offset.
const Assignment = struct { name: []const u8, value: Scalar };

/// A compiled order-one kernel over one public fixture model.
const Subject = struct {
    model: phaser.Model,
    request: calculation.Request,
    artifact: calculation.Artifact,
    kernel: kernel_module.Kernel,
    workspace: []align(@alignOf(Scalar)) u8,

    fn init(
        model_source: []const u8,
        request_source: []const u8,
        capability: kernel_module.Capability,
        selection: kernel_module.Selection,
        point_count: usize,
    ) !Subject {
        var model = try loadModel(model_source);
        errdefer model.deinit();
        var request = try parseRequest(request_source);
        errdefer request.deinit();
        var artifact = try derive(&model, &request, switch (capability) {
            .value => .none,
            .value_gradient => .gradient,
            .value_gradient_hessian => .gradient_hessian,
        });
        errdefer artifact.deinit();
        var kernel = try kernel_module.compile(test_allocator.allocator, &artifact, .{
            .capability = capability,
            .selection = selection,
        });
        errdefer kernel.deinit();

        const workspace = try test_allocator.allocator.alignedAlloc(
            u8,
            .of(Scalar),
            kernel.workspaceLayout(point_count).bytes,
        );
        return .{
            .model = model,
            .request = request,
            .artifact = artifact,
            .kernel = kernel,
            .workspace = workspace,
        };
    }

    fn deinit(self: *Subject) void {
        test_allocator.allocator.free(self.workspace);
        self.kernel.deinit();
        self.artifact.deinit();
        self.request.deinit();
        self.model.deinit();
    }

    /// Packed inputs for one call.
    ///
    /// Each channel gets its own allocation. The kernel requires inputs,
    /// outputs, and workspace to be pairwise disjoint, and two identical
    /// anonymous constants would otherwise share one address.
    const Bound = struct {
        parameters: []Scalar,
        scales: []Scalar,

        fn deinit(self: Bound) void {
            test_allocator.allocator.free(self.parameters);
            test_allocator.allocator.free(self.scales);
        }
    };

    fn bindInputs(
        self: *const Subject,
        assignments: []const Assignment,
        scale: Scalar,
    ) !Bound {
        const parameters = try self.pack(assignments);
        errdefer test_allocator.allocator.free(parameters);
        const scales = try test_allocator.allocator.alloc(
            Scalar,
            if (self.kernel.scale == null) 0 else 1,
        );
        for (scales) |*slot| slot.* = scale;
        return .{ .parameters = parameters, .scales = scales };
    }

    /// Packs named assignments into the kernel's parameter order, leaving every
    /// unnamed channel at exact zero.
    fn pack(self: *const Subject, assignments: []const Assignment) ![]Scalar {
        const packed_values = try test_allocator.allocator.alloc(
            Scalar,
            self.kernel.parameterCount(),
        );
        @memset(packed_values, 0);
        for (assignments) |assignment| {
            var found = false;
            for (self.kernel.parameters) |channel| {
                if (!std.mem.eql(u8, channel.name, assignment.name)) continue;
                packed_values[channel.offset] = assignment.value;
                found = true;
            }
            if (!found) {
                test_allocator.allocator.free(packed_values);
                return error.UnknownParameter;
            }
        }
        return packed_values;
    }

    /// Runs one batch into caller-supplied buffers.
    fn evaluateInto(
        self: *Subject,
        assignments: []const Assignment,
        scale: Scalar,
        backgrounds: []const Scalar,
        outputs: kernel_module.ComplexOutputBuffers,
    ) !void {
        const bound = try self.bindInputs(assignments, scale);
        defer bound.deinit();
        try self.kernel.evaluateComplex(
            .{
                .parameters = bound.parameters,
                .scales = bound.scales,
                .backgrounds = backgrounds,
            },
            outputs.statuses.len,
            self.workspace,
            outputs,
        );
    }

    fn evaluateValue(
        self: *Subject,
        assignments: []const Assignment,
        scale: Scalar,
        backgrounds: []const Scalar,
    ) !struct { value: Complex64, status: Status } {
        var values: [1]kernel_module.Complex64 = undefined;
        var statuses: [1]Status = undefined;
        try self.evaluateInto(assignments, scale, backgrounds, .{
            .values = &values,
            .statuses = &statuses,
        });
        return .{
            .value = .{ .re = values[0].re, .im = values[0].im },
            .status = statuses[0],
        };
    }
};

/// One recorded fixture case, transcribed from its JSON entry.
const Case = struct {
    id: []const u8,
    assignments: []const Assignment,
    backgrounds: []const Scalar,
    scale: Scalar,
    /// The fixture's `mass_matrix`, dense and row-major.
    matrix: []const Scalar,
    /// The fixture's `eigenvalues`, in the order it records them.
    eigenvalues: []const Scalar,
    policy: comparison.Policy = comparison.spectral_value_known_spectrum,
};

fn expectCaseValue(subject: *Subject, case: Case) !void {
    errdefer std.debug.print("fixture case: {s}\n", .{case.id});

    const outcome = try subject.evaluateValue(
        case.assignments,
        case.scale,
        case.backgrounds,
    );
    try std.testing.expectEqual(Status.ok, outcome.status);

    const expected = spectralSumAt(case.eigenvalues, case.scale);
    try case.policy.expectCloseAt(
        expected.value.re,
        outcome.value.re,
        .{ .magnitude = expected.unsigned_scale.re },
    );
    try case.policy.expectCloseAt(
        expected.value.im,
        outcome.value.im,
        .{ .magnitude = expected.unsigned_scale.im },
    );
}

// -- transcribed fixture catalog -------------------------------------------

/// `scalar.phi4` reference points. The model's mass matrix is the one-by-one
/// `m2 + lambda phi^2 / 2`, so the fixture's `mass_squared` is reached through
/// its recorded parameters and background rather than substituted directly.
const phi4_cases = [_]Case{
    .{
        .id = "positive_mass_squared",
        .assignments = &.{
            .{ .name = "m2", .value = 1 },
            .{ .name = "lambda", .value = 2 },
        },
        .backgrounds = &.{0},
        .scale = 1,
        .matrix = &.{1},
        .eigenvalues = &.{1},
    },
    .{
        .id = "zero_mass_squared",
        .assignments = &.{
            .{ .name = "m2", .value = -1 },
            .{ .name = "lambda", .value = 2 },
        },
        .backgrounds = &.{1},
        .scale = 1,
        .matrix = &.{0},
        .eigenvalues = &.{0},
        .policy = comparison.spectral_value_zero_mode,
    },
    .{
        .id = "negative_mass_squared",
        .assignments = &.{
            .{ .name = "m2", .value = -1 },
            .{ .name = "lambda", .value = 2 },
        },
        .backgrounds = &.{0},
        .scale = 1,
        .matrix = &.{-1},
        .eigenvalues = &.{-1},
    },
};

/// `scalar.multi_scalar` reference points. Every cubic and quartic coupling is
/// bound to exact zero at the origin, so the fixture's `mass_hh`, `mass_hs`,
/// and `mass_ss` identities collapse to the recorded mass-squared parameters.
fn multiScalarCase(
    id: []const u8,
    matrix: *const [4]Scalar,
    eigenvalues: []const Scalar,
    policy: comparison.Policy,
    assignments: *const [3]Assignment,
) Case {
    return .{
        .id = id,
        .assignments = assignments,
        .backgrounds = &.{ 0, 0 },
        .scale = 1,
        .matrix = matrix,
        .eigenvalues = eigenvalues,
        .policy = policy,
    };
}

fn multiScalarAssignments(entries: [3]Scalar) [3]Assignment {
    return .{
        .{ .name = "m_h2", .value = entries[0] },
        .{ .name = "m_hs2", .value = entries[1] },
        .{ .name = "m_s2", .value = entries[2] },
    };
}

const near_offset = 0x1p-21;
const near_separation = 0x1p-20;

const multi_scalar_assignments = [_][3]Assignment{
    multiScalarAssignments(.{ 1, 0, 4 }),
    multiScalarAssignments(.{ 2, 0, 2 }),
    multiScalarAssignments(.{ 0, 0, 4 }),
    multiScalarAssignments(.{ 1.5, 2.5, 1.5 }),
    multiScalarAssignments(.{ -2, 0, -2 }),
    multiScalarAssignments(.{ 1 + near_offset, near_offset, 1 + near_offset }),
};

const multi_scalar_cases = [_]Case{
    multiScalarCase(
        "positive_definite",
        &.{ 1, 0, 0, 4 },
        &.{ 1, 4 },
        comparison.spectral_value_known_spectrum,
        &multi_scalar_assignments[0],
    ),
    multiScalarCase(
        "positive_degeneracy",
        &.{ 2, 0, 0, 2 },
        &.{ 2, 2 },
        comparison.spectral_value_known_spectrum,
        &multi_scalar_assignments[1],
    ),
    multiScalarCase(
        "exact_zero_mode",
        &.{ 0, 0, 0, 4 },
        &.{ 0, 4 },
        comparison.spectral_value_zero_mode,
        &multi_scalar_assignments[2],
    ),
    multiScalarCase(
        "indefinite",
        &.{ 1.5, 2.5, 2.5, 1.5 },
        &.{ 4, -1 },
        comparison.spectral_value_known_spectrum,
        &multi_scalar_assignments[3],
    ),
    multiScalarCase(
        "negative_degeneracy",
        &.{ -2, 0, 0, -2 },
        &.{ -2, -2 },
        comparison.spectral_value_known_spectrum,
        &multi_scalar_assignments[4],
    ),
    multiScalarCase(
        "near_degeneracy",
        &.{ 1 + near_offset, near_offset, near_offset, 1 + near_offset },
        &.{ 1, 1 + near_separation },
        comparison.spectral_value_near_degenerate,
        &multi_scalar_assignments[5],
    ),
};

/// `scalar.three_scalar` reference points, in the order the fixture records
/// its six cubic couplings.
fn threeScalarAssignments(entries: [6]Scalar) [6]Assignment {
    const names = [_][]const u8{ "c111", "c112", "c113", "c122", "c123", "c133" };
    var assignments: [6]Assignment = undefined;
    for (&assignments, names, entries) |*slot, name, entry| {
        slot.* = .{ .name = name, .value = entry };
    }
    return assignments;
}

const three_scalar_assignments = [_][6]Assignment{
    threeScalarAssignments(.{ 53, 26, -4, 44, -22, 29 }),
    threeScalarAssignments(.{ 30, 12, -6, 30, -6, 21 }),
    threeScalarAssignments(.{ 2, 20, -10, 2, -10, -13 }),
    threeScalarAssignments(.{ 1, 1, 0, 1, 0, 4 }),
    threeScalarAssignments(.{ 0, 2, 0, 0, 0, 3 }),
    threeScalarAssignments(.{
        1 + near_offset,
        near_offset,
        0,
        1 + near_offset,
        0,
        4,
    }),
};

fn threeScalarCase(
    id: []const u8,
    assignments: *const [6]Assignment,
    scale: Scalar,
    matrix: []const Scalar,
    eigenvalues: []const Scalar,
    policy: comparison.Policy,
) Case {
    return .{
        .id = id,
        .assignments = assignments,
        // The slice coordinate is one, so the mass matrix is the coupling
        // matrix itself.
        .backgrounds = &.{1},
        .scale = scale,
        .matrix = matrix,
        .eigenvalues = eigenvalues,
        .policy = policy,
    };
}

const three_scalar_cases = [_]Case{
    threeScalarCase(
        "positive_dense",
        &three_scalar_assignments[0],
        3,
        &.{ 53, 26, -4, 26, 44, -22, -4, -22, 29 },
        &.{ 9, 36, 81 },
        comparison.spectral_value_known_spectrum,
    ),
    threeScalarCase(
        "positive_degeneracy_dense",
        &three_scalar_assignments[1],
        3,
        &.{ 30, 12, -6, 12, 30, -6, -6, -6, 21 },
        &.{ 18, 18, 45 },
        comparison.spectral_value_known_spectrum,
    ),
    threeScalarCase(
        "negative_degeneracy_dense",
        &three_scalar_assignments[2],
        3,
        &.{ 2, 20, -10, 20, 2, -10, -10, -10, -13 },
        &.{ -18, -18, 27 },
        comparison.spectral_value_known_spectrum,
    ),
    threeScalarCase(
        "exact_zero_mode",
        &three_scalar_assignments[3],
        1,
        &.{ 1, 1, 0, 1, 1, 0, 0, 0, 4 },
        &.{ 0, 2, 4 },
        comparison.spectral_value_zero_mode,
    ),
    threeScalarCase(
        "indefinite",
        &three_scalar_assignments[4],
        1,
        &.{ 0, 2, 0, 2, 0, 0, 0, 0, 3 },
        &.{ -2, 2, 3 },
        comparison.spectral_value_known_spectrum,
    ),
    threeScalarCase(
        "near_degeneracy",
        &three_scalar_assignments[5],
        1,
        &.{
            1 + near_offset, near_offset,     0,
            near_offset,     1 + near_offset, 0,
            0,               0,               4,
        },
        &.{ 1, 1 + near_separation, 4 },
        comparison.spectral_value_near_degenerate,
    ),
};

// -- exact-spectrum catalog through the production path --------------------

test "every phi4 reference point agrees with its known spectrum" {
    var subject = try Subject.init(
        example_data.phi4_model,
        full_space_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();
    for (phi4_cases) |case| try expectCaseValue(&subject, case);
}

test "every two-scalar reference point agrees with its known spectrum" {
    var subject = try Subject.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();
    for (multi_scalar_cases) |case| try expectCaseValue(&subject, case);
}

test "every three-scalar reference point agrees with its known spectrum" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();
    for (three_scalar_cases) |case| try expectCaseValue(&subject, case);
}

// -- fixture mass-matrix entries -------------------------------------------

/// The one spectral-value node reachable from `root`.
fn findSpectralValue(
    graph: *const value.Graph,
    root: value.ValueId,
) ?value.ValueId {
    const item = graph.value(root);
    if (item.node == .scalar_one_loop_spectral_value) return root;
    var index: usize = 0;
    while (value.childAt(item.node, index)) |child| : (index += 1) {
        if (findSpectralValue(graph, child)) |found| return found;
    }
    return null;
}

/// Evaluates the mass matrix the derivation built, densely and row-major.
///
/// This is the boundary decision 0007 asks the fixture's transcribed
/// `mass_matrix` to establish: the entries come from the model, its parameters,
/// and its background, and they are compared against a formula transcribed by
/// hand from the fixture rather than produced by the derivation.
fn massMatrixOf(
    subject: *const Subject,
    assignments: []const Assignment,
    backgrounds: []const Scalar,
    out: []Scalar,
) !u32 {
    const graph = &subject.artifact.graph;
    const contribution = subject.artifact.contribution(.scalar_one_loop) orelse
        return error.MissingContribution;
    const spectral = findSpectralValue(graph, contribution.value) orelse
        return error.MissingSpectralValue;
    const matrix = switch (graph.value(spectral).node) {
        .scalar_one_loop_spectral_value => |node| node.matrix,
        else => return error.MissingSpectralValue,
    };
    const entries = switch (graph.value(matrix).node) {
        .real_symmetric_matrix => |node| node,
        else => return error.MissingMassMatrix,
    };

    const packed_values = try subject.pack(assignments);
    defer test_allocator.allocator.free(packed_values);

    const dimension = entries.dimension;
    if (out.len != dimension * dimension) return error.ShapeMismatch;
    for (0..dimension) |row| {
        for (0..dimension) |column| {
            const stored = entries.entries[
                value.upperTriangleIndex(
                    dimension,
                    @intCast(@min(row, column)),
                    @intCast(@max(row, column)),
                )
            ];
            out[row * dimension + column] = try directReal(graph, stored, .{
                .parameters = packed_values,
                .backgrounds = backgrounds,
                .scale = 1,
                .eigenvalues = &.{},
            });
        }
    }
    return dimension;
}

fn expectFixtureMatrix(subject: *Subject, case: Case) !void {
    errdefer std.debug.print("fixture case: {s}\n", .{case.id});
    var storage: [9]Scalar = undefined;
    const dimension = try massMatrixOf(
        subject,
        case.assignments,
        case.backgrounds,
        storage[0..case.matrix.len],
    );
    try std.testing.expectEqual(
        case.matrix.len,
        @as(usize, dimension) * @as(usize, dimension),
    );
    // Exact equality: every fixture entry is a sum of products of exactly
    // representable parameters, so a rounded agreement would be evidence of a
    // different formula rather than of arithmetic.
    try std.testing.expectEqualSlices(
        Scalar,
        case.matrix,
        storage[0..case.matrix.len],
    );
}

test "each fixture mass matrix equals the matrix the derivation built" {
    var phi4 = try Subject.init(
        example_data.phi4_model,
        full_space_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer phi4.deinit();
    for (phi4_cases) |case| try expectFixtureMatrix(&phi4, case);

    var two = try Subject.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer two.deinit();
    for (multi_scalar_cases) |case| try expectFixtureMatrix(&two, case);

    var three = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer three.deinit();
    for (three_scalar_cases) |case| try expectFixtureMatrix(&three, case);
}

// -- characteristic polynomials --------------------------------------------

/// Coefficients of `det(lambda I - M)` for a dense symmetric matrix, computed
/// from its entries.
const Invariants = struct { trace: f64, minors: f64, determinant: f64 };

fn invariantsOf(matrix: []const Scalar, dimension: usize) Invariants {
    var result = Invariants{ .trace = 0, .minors = 0, .determinant = 0 };
    for (0..dimension) |index| result.trace += matrix[index * dimension + index];
    for (0..dimension) |row| {
        for (row + 1..dimension) |column| {
            result.minors += matrix[row * dimension + row] *
                matrix[column * dimension + column] -
                matrix[row * dimension + column] * matrix[column * dimension + row];
        }
    }
    result.determinant = switch (dimension) {
        1 => matrix[0],
        2 => matrix[0] * matrix[3] - matrix[1] * matrix[2],
        3 => matrix[0] * (matrix[4] * matrix[8] - matrix[5] * matrix[7]) -
            matrix[1] * (matrix[3] * matrix[8] - matrix[5] * matrix[6]) +
            matrix[2] * (matrix[3] * matrix[7] - matrix[4] * matrix[6]),
        else => unreachable,
    };
    return result;
}

fn invariantsOfSpectrum(eigenvalues: []const Scalar) Invariants {
    var result = Invariants{ .trace = 0, .minors = 0, .determinant = 1 };
    for (eigenvalues) |eigenvalue| {
        result.trace += eigenvalue;
        result.determinant *= eigenvalue;
    }
    for (eigenvalues, 0..) |first, index| {
        for (eigenvalues[index + 1 ..]) |second| result.minors += first * second;
    }
    return result;
}

fn expectCharacteristicPolynomial(case: Case) !void {
    errdefer std.debug.print("fixture case: {s}\n", .{case.id});
    const dimension = case.eigenvalues.len;
    const from_matrix = invariantsOf(case.matrix, dimension);
    const from_spectrum = invariantsOfSpectrum(case.eigenvalues);

    // Every catalog entry but the near-degenerate pair has an exactly
    // representable spectrum, so its symmetric functions agree exactly.
    const policy = comparison.reordered_value_well_conditioned;
    try policy.expectCloseAt(from_matrix.trace, from_spectrum.trace, .{
        .magnitude = @abs(from_matrix.trace),
    });
    try policy.expectCloseAt(from_matrix.minors, from_spectrum.minors, .{
        .magnitude = @abs(from_matrix.minors),
    });
    try policy.expectCloseAt(
        from_matrix.determinant,
        from_spectrum.determinant,
        .{ .magnitude = @abs(from_matrix.determinant) },
    );
}

test "each fixture spectrum satisfies its recorded characteristic polynomial" {
    // The recorded eigenvalue multiset is an input to the known-spectrum
    // evaluator, so it needs its own evidence. These symmetric functions are
    // exactly the coefficients of the fixture's factored polynomial, computed
    // from the matrix entries on one side and from the multiset on the other,
    // with no numerical eigensolver on either.
    for (phi4_cases) |case| try expectCharacteristicPolynomial(case);
    for (multi_scalar_cases) |case| try expectCharacteristicPolynomial(case);
    for (three_scalar_cases) |case| try expectCharacteristicPolynomial(case);
}

test "the reported spectrum reproduces the matrix power sums" {
    // `Tr M^2` is the second power sum, and it is the coefficient of the
    // fixed-parameter scale relation below. Checking it here separates a wrong
    // spectrum from a wrong scale response there.
    for (three_scalar_cases) |case| {
        errdefer std.debug.print("fixture case: {s}\n", .{case.id});
        var from_matrix: f64 = 0;
        for (case.matrix) |entry| from_matrix += entry * entry;
        var from_spectrum: f64 = 0;
        for (case.eigenvalues) |eigenvalue| from_spectrum += eigenvalue * eigenvalue;
        try comparison.reordered_value_well_conditioned.expectCloseAt(
            from_matrix,
            from_spectrum,
            .{ .magnitude = from_matrix },
        );
    }
}

// -- direct Typed Value IR evaluation --------------------------------------

const DirectInputs = struct {
    parameters: []const Scalar,
    backgrounds: []const Scalar,
    scale: Scalar,
    /// Supplied by the fixture. This evaluator never diagonalizes anything.
    eigenvalues: []const Scalar,
};

const DirectError = error{UnsupportedNode};

/// Direct evaluation of the real subset of the Typed Value IR.
///
/// Deliberately naive and recursive: it shares no code with lowering or the
/// interpreter and re-evaluates shared subexpressions rather than reusing them.
fn directReal(
    graph: *const value.Graph,
    id: value.ValueId,
    inputs: DirectInputs,
) DirectError!Scalar {
    const item = graph.value(id);
    return switch (item.node) {
        .rational => |rational| kernel_module.rationalToScalar(rational) catch
            std.math.nan(Scalar),
        .pi => std.math.pi,
        .sqrt_rational => |rational| @sqrt(
            kernel_module.rationalToScalar(rational) catch std.math.nan(Scalar),
        ),
        .parameter => |input| inputs.parameters[input.id],
        .background => |input| inputs.backgrounds[input.index],
        .renormalization_scale => inputs.scale,
        .add => |children| blk: {
            var total = try directReal(graph, children[0], inputs);
            for (children[1..]) |child| {
                total += try directReal(graph, child, inputs);
            }
            break :blk total;
        },
        .multiply => |children| blk: {
            var total = try directReal(graph, children[0], inputs);
            for (children[1..]) |child| {
                total *= try directReal(graph, child, inputs);
            }
            break :blk total;
        },
        .divide => |binary| try directReal(graph, binary.numerator, inputs) /
            try directReal(graph, binary.denominator, inputs),
        .power => |node| kernel_module.integerPower(
            try directReal(graph, node.base, inputs),
            node.exponent,
        ),
        else => error.UnsupportedNode,
    };
}

/// Direct evaluation of the complex subset, including the spectral value.
///
/// The spectral node is evaluated from the fixture's eigenvalue multiset by the
/// independent evaluator above, so this path shares no eigensolver, rotation,
/// or convergence behaviour with the kernel it is compared against.
fn directComplex(
    graph: *const value.Graph,
    id: value.ValueId,
    inputs: DirectInputs,
) DirectError!Complex64 {
    const item = graph.value(id);
    return switch (item.node) {
        .promote_real_to_complex => |operand| .{
            .re = try directReal(graph, operand, inputs),
            .im = 0,
        },
        .scalar_one_loop_spectral_value => |node| blk: {
            const scale = try directReal(graph, node.scale, inputs);
            break :blk spectralSumAt(inputs.eigenvalues, scale).value;
        },
        .add => |children| blk: {
            var total = try directComplex(graph, children[0], inputs);
            for (children[1..]) |child| {
                total = total.add(try directComplex(graph, child, inputs));
            }
            break :blk total;
        },
        else => error.UnsupportedNode,
    };
}

fn expectDirectAgreement(subject: *Subject, case: Case, root: value.ValueId) !void {
    errdefer std.debug.print("fixture case: {s}\n", .{case.id});

    const packed_values = try subject.pack(case.assignments);
    defer test_allocator.allocator.free(packed_values);
    const expected = try directComplex(&subject.artifact.graph, root, .{
        .parameters = packed_values,
        .backgrounds = case.backgrounds,
        .scale = case.scale,
        .eigenvalues = case.eigenvalues,
    });

    const outcome = try subject.evaluateValue(
        case.assignments,
        case.scale,
        case.backgrounds,
    );
    try std.testing.expectEqual(Status.ok, outcome.status);
    try case.policy.expectCloseAt(expected.re, outcome.value.re, .{
        .magnitude = @abs(expected.re),
    });
    try case.policy.expectCloseAt(expected.im, outcome.value.im, .{
        .magnitude = @abs(expected.im),
    });
}

test "direct Typed Value IR evaluation agrees with kernel evaluation" {
    // The complete requested truncation, so the comparison covers the promoted
    // tree part and the complex addition as well as the spectral node.
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .total,
        1,
    );
    defer subject.deinit();
    try std.testing.expectEqual(
        kernel_module.ResultType.complex64,
        subject.kernel.resultType(),
    );
    for (three_scalar_cases) |case| {
        try expectDirectAgreement(&subject, case, subject.artifact.total);
    }
}

test "direct evaluation covers the one-by-one and two-by-two fixtures too" {
    var phi4 = try Subject.init(
        example_data.phi4_model,
        full_space_request,
        .value,
        .total,
        1,
    );
    defer phi4.deinit();
    for (phi4_cases) |case| {
        try expectDirectAgreement(&phi4, case, phi4.artifact.total);
    }

    var two = try Subject.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
        .total,
        1,
    );
    defer two.deinit();
    for (multi_scalar_cases) |case| {
        try expectDirectAgreement(&two, case, two.artifact.total);
    }
}

// -- derivatives and statuses ----------------------------------------------

test "the phi4 zero-mode gradient is a finite published limit" {
    var subject = try Subject.init(
        example_data.phi4_model,
        full_space_request,
        .value_gradient,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    // The fixture's `zero_mass_squared_gradient` point: `m2 = -1`, `lambda = 2`
    // at `phi = 1` makes the mass-squared exactly zero.
    var values: [1]kernel_module.Complex64 = undefined;
    var gradients: [1]kernel_module.Complex64 = undefined;
    var statuses: [1]Status = undefined;
    try subject.evaluateInto(&.{
        .{ .name = "m2", .value = -1 },
        .{ .name = "lambda", .value = 2 },
    }, 1, &.{1}, .{
        .values = &values,
        .gradients = &gradients,
        .statuses = &statuses,
    });

    try std.testing.expectEqual(Status.ok, statuses[0]);
    // The analytic limit is taken before a logarithm is formed, so the point is
    // published rather than reported non-finite.
    try comparison.spectral_gradient_zero_mode.expectCloseAt(
        0,
        gradients[0].re,
        .{ .magnitude = 0 },
    );
    try comparison.spectral_gradient_zero_mode.expectCloseAt(
        0,
        gradients[0].im,
        .{ .magnitude = 0 },
    );
}

test "the phi4 zero-mode Hessian is singular and publishes nothing" {
    var subject = try Subject.init(
        example_data.phi4_model,
        full_space_request,
        .value_gradient_hessian,
        .{ .role = .scalar_one_loop },
        2,
    );
    defer subject.deinit();

    const sentinel = kernel_module.Complex64{ .re = -1234, .im = -4321 };
    var values = [_]kernel_module.Complex64{sentinel} ** 2;
    var gradients = [_]kernel_module.Complex64{sentinel} ** 2;
    var hessians = [_]kernel_module.Complex64{sentinel} ** 2;
    var statuses: [2]Status = undefined;

    // The zero mode sits at `phi = 1`; `phi = 2` is an ordinary point beside it.
    try subject.evaluateInto(&.{
        .{ .name = "m2", .value = -1 },
        .{ .name = "lambda", .value = 2 },
    }, 1, &.{ 1, 2 }, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });

    // The zero-zero coefficient of the second-derivative formula diverges and
    // the projected first-derivative block is not exactly zero, so the point is
    // `singular_derivative` rather than a large finite number.
    try std.testing.expectEqual(Status.singular_derivative, statuses[0]);
    try std.testing.expectEqual(sentinel, values[0]);
    try std.testing.expectEqual(sentinel, gradients[0]);
    try std.testing.expectEqual(sentinel, hessians[0]);

    // Publication is point-atomic, so the ordinary neighbour is unaffected.
    try std.testing.expectEqual(Status.ok, statuses[1]);
    try std.testing.expect(hessians[1].re != sentinel.re);
    const expected = try oneLoopSecondSpectralDerivative(3, 1);
    // `x = m2 + lambda phi^2 / 2 = 3` at `phi = 2`, with `dx/dphi = 2 phi = 4`
    // and `d2x/dphi2 = 2`.
    const first = oneLoopFirstSpectralDerivative(3, 1);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        expected.re * 16.0 + first.re * 2.0,
        hessians[1].re,
        .{ .magnitude = @abs(expected.re * 16.0) + @abs(first.re * 2.0) },
    );
}

test "a failing point reports its own failure, not its neighbour's leftovers" {
    // Regression, found by the `one_loop_pipeline` fuzz target. An operation
    // that fails publishes no result: the eigensolver leaves its eigenvalues
    // unwritten rather than emitting an unconverged spectrum. Execution
    // therefore has to stop at the first failure, because the instructions
    // after it would otherwise read whatever the frame held -- in a batch, the
    // previous point's spectrum.
    //
    // The slice model makes that visible because its mass matrix is `b` times a
    // fixed coupling matrix: the matrix goes non-finite with the background
    // while its background derivative stays exactly the finite coupling matrix.
    // The first point below sits at `b = 0`, where the whole spectrum is zero
    // and the projected first-derivative block is not, so it is
    // `singular_derivative` and publishes the spectrum `{0, 0, 0}`. The second
    // has a non-finite matrix, so its eigensolve fails; reading those leftover
    // zeros would report the first point's failure for the second point,
    // collapsing two statuses the specification keeps distinct.
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value_gradient_hessian,
        .{ .role = .scalar_one_loop },
        2,
    );
    defer subject.deinit();

    const assignments = three_scalar_assignments[0];
    var values: [2]kernel_module.Complex64 = undefined;
    var gradients: [2]kernel_module.Complex64 = undefined;
    var hessians: [2]kernel_module.Complex64 = undefined;
    var statuses: [2]Status = undefined;
    try subject.evaluateInto(&assignments, 1, &.{ 0, std.math.inf(Scalar) }, .{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    });

    try std.testing.expectEqual(Status.singular_derivative, statuses[0]);
    try std.testing.expectEqual(Status.non_finite, statuses[1]);

    // The same point alone reports the same status, so a batch retains
    // independent status per point.
    var alone: [1]kernel_module.Complex64 = undefined;
    var alone_gradient: [1]kernel_module.Complex64 = undefined;
    var alone_hessian: [1]kernel_module.Complex64 = undefined;
    var alone_status: [1]Status = undefined;
    try subject.evaluateInto(&assignments, 1, &.{std.math.inf(Scalar)}, .{
        .values = &alone,
        .gradients = &alone_gradient,
        .hessians = &alone_hessian,
        .statuses = &alone_status,
    });
    try std.testing.expectEqual(Status.non_finite, alone_status[0]);
}

// -- fixed-parameter scale variation ---------------------------------------

test "fixed-parameter scale variation follows the exact trace relation" {
    // The fixture's diagnostic operation: parameters and background are held
    // fixed while only the positive scale changes. The difference is then
    // `-Tr[(M^2)^2] log(mu2/mu1) / (32 pi^2)`, computed here from the fixture's
    // transcribed matrix entries rather than from anything the kernel reports.
    var phi4 = try Subject.init(
        example_data.phi4_model,
        full_space_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer phi4.deinit();

    const case = phi4_cases[0];
    const at_mu1 = try phi4.evaluateValue(case.assignments, 1, case.backgrounds);
    const at_mu2 = try phi4.evaluateValue(case.assignments, 2, case.backgrounds);
    try std.testing.expectEqual(Status.ok, at_mu1.status);
    try std.testing.expectEqual(Status.ok, at_mu2.status);

    try expectScaleRelation(case, at_mu1.value, at_mu2.value, 1, 2);
    // A positive spectrum contributes no imaginary part at either scale.
    try std.testing.expectEqual(@as(Scalar, 0), at_mu1.value.im);
    try std.testing.expectEqual(@as(Scalar, 0), at_mu2.value.im);

    var three = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer three.deinit();
    for (three_scalar_cases) |dense| {
        const first = try three.evaluateValue(dense.assignments, 2, dense.backgrounds);
        const second = try three.evaluateValue(dense.assignments, 5, dense.backgrounds);
        try std.testing.expectEqual(Status.ok, first.status);
        try std.testing.expectEqual(Status.ok, second.status);
        try expectScaleRelation(dense, first.value, second.value, 2, 5);
        // Only the scale moved, so the imaginary component is unchanged.
        try std.testing.expectEqual(first.value.im, second.value.im);
    }
}

fn expectScaleRelation(
    case: Case,
    at_first: Complex64,
    at_second: Complex64,
    first_scale: Scalar,
    second_scale: Scalar,
) !void {
    errdefer std.debug.print("fixture case: {s}\n", .{case.id});
    var trace_square: f64 = 0;
    for (case.matrix) |entry| trace_square += entry * entry;
    const expected = -trace_square * @log(second_scale / first_scale) /
        (32.0 * std.math.pi * std.math.pi);
    const actual = at_second.re - at_first.re;
    try comparison.reordered_value_well_conditioned.expectCloseAt(
        expected,
        actual,
        .{
            .magnitude = @abs(at_first.re) + @abs(at_second.re) + @abs(expected),
        },
    );
}

// -- metamorphic transformations -------------------------------------------

fn multiply3(left: [9]Scalar, right: [9]Scalar) [9]Scalar {
    var product: [9]Scalar = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            var total: Scalar = 0;
            for (0..3) |inner| {
                total += left[row * 3 + inner] * right[inner * 3 + column];
            }
            product[row * 3 + column] = total;
        }
    }
    return product;
}

fn transpose3(matrix: [9]Scalar) [9]Scalar {
    var result: [9]Scalar = undefined;
    for (0..3) |row| {
        for (0..3) |column| result[row * 3 + column] = matrix[column * 3 + row];
    }
    return result;
}

/// The six upper-triangle couplings of a dense symmetric three-by-three matrix,
/// in the fixture's recorded order.
fn couplingsOf(matrix: [9]Scalar) [6]Scalar {
    return .{ matrix[0], matrix[1], matrix[2], matrix[4], matrix[5], matrix[8] };
}

test "a field permutation preserves the three-scalar spectral value" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    // The fixture's `positive_dense_permutation` transformation: the reversal
    // permutation, applied to rows and columns alike.
    const original = [9]Scalar{ 53, 26, -4, 26, 44, -22, -4, -22, 29 };
    const permutation = [9]Scalar{ 0, 0, 1, 0, 1, 0, 1, 0, 0 };
    const permuted = multiply3(multiply3(permutation, original), transpose3(permutation));

    const before = threeScalarAssignments(couplingsOf(original));
    const after = threeScalarAssignments(couplingsOf(permuted));
    const first = try subject.evaluateValue(&before, 3, &.{1});
    const second = try subject.evaluateValue(&after, 3, &.{1});
    try std.testing.expectEqual(Status.ok, first.status);
    try std.testing.expectEqual(Status.ok, second.status);

    // A permutation of the scalar basis leaves the eigenvalue multiset alone,
    // and the sum is over that multiset, so the two values are the same number.
    try std.testing.expectEqual(first.value.re, second.value.re);
    try std.testing.expectEqual(first.value.im, second.value.im);
}

test "an orthogonal basis change preserves the three-scalar spectral value" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    // The fixture's `positive_dense_orthogonal` transformation. Its entries are
    // thirds, so the transformed matrix is not exactly the fixture's integer
    // one; the comparison is therefore the declared known-spectrum policy
    // rather than bitwise equality.
    const original = [9]Scalar{ 53, 26, -4, 26, 44, -22, -4, -22, 29 };
    const third = 1.0 / 3.0;
    const rotation = [9]Scalar{
        third,        -2.0 * third, -2.0 * third,
        -2.0 * third, third,        -2.0 * third,
        -2.0 * third, -2.0 * third, third,
    };
    const rotated = multiply3(multiply3(rotation, original), transpose3(rotation));

    const before = threeScalarAssignments(couplingsOf(original));
    const after = threeScalarAssignments(couplingsOf(rotated));
    const first = try subject.evaluateValue(&before, 3, &.{1});
    const second = try subject.evaluateValue(&after, 3, &.{1});
    try std.testing.expectEqual(Status.ok, first.status);
    try std.testing.expectEqual(Status.ok, second.status);

    const expected = spectralSumAt(&.{ 9, 36, 81 }, 3);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        first.value.re,
        second.value.re,
        .{ .magnitude = expected.unsigned_scale.re },
    );
    try std.testing.expectEqual(@as(Scalar, 0), second.value.im);
}

test "the two-scalar basis relations preserve the complex spectral value" {
    var subject = try Subject.init(
        example_data.multi_scalar_model,
        full_space_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    // The fixture's `field_permutation` and `orthogonal_basis_change` cases,
    // both starting from diag(4, -1): an indefinite spectrum, so the imaginary
    // component has to survive the transformation as well.
    const original = multiScalarAssignments(.{ 4, 0, -1 });
    const permuted = multiScalarAssignments(.{ -1, 0, 4 });
    const rotated = multiScalarAssignments(.{ 1.5, 2.5, 1.5 });

    const first = try subject.evaluateValue(&original, 1, &.{ 0, 0 });
    const second = try subject.evaluateValue(&permuted, 1, &.{ 0, 0 });
    const third = try subject.evaluateValue(&rotated, 1, &.{ 0, 0 });
    try std.testing.expectEqual(Status.ok, first.status);
    try std.testing.expectEqual(Status.ok, second.status);
    try std.testing.expectEqual(Status.ok, third.status);

    // The permutation is exact, so the two values agree bitwise.
    try std.testing.expectEqual(first.value.re, second.value.re);
    try std.testing.expectEqual(first.value.im, second.value.im);

    const expected = spectralSumAt(&.{ 4, -1 }, 1);
    try expectComplexApprox(expected.value, third.value, expected.unsigned_scale);
    try std.testing.expect(third.value.im > 0);
}

// -- zero-coupling reduction -----------------------------------------------

test "binding a coupling to zero agrees with a structurally absent tensor" {
    // Numerical specialization and structural reduction are different
    // derivation paths. The reduced model declares no quartic at all, so its
    // mass matrix is a different expression that happens to take the same
    // value once the quartic coupling is bound to exact zero.
    const reduced_model =
        \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
        \\"conventions":{"metric":"mostly_plus",
        \\"scalar_representation":"real_components","fermions":"two_component_weyl"},
        \\"parameters":{"m2":{"domain":"real","mass_dimension":2}},
        \\"fields":{"real_scalars":[{"id":"phi"}],"weyl_fermions":[],
        \\"gauge_vectors":[]},
        \\"tensors":{"scalar_mass_squared":{"components":[
        \\{"indices":["phi","phi"],"value":"m2"}]}}}
    ;

    var full = try Subject.init(
        example_data.phi4_model,
        full_space_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer full.deinit();
    var reduced = try Subject.init(
        reduced_model,
        full_space_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer reduced.deinit();

    // The reduced model records the quartic as structurally absent rather than
    // deriving a zero contribution.
    try std.testing.expect(reduced.artifact.absence(.scalar_quartic) != null);
    try std.testing.expect(full.artifact.absence(.scalar_quartic) == null);

    for ([_]Scalar{ 0, 1, -2.5, 7 }) |background| {
        const specialized = try full.evaluateValue(&.{
            .{ .name = "m2", .value = 3 },
            .{ .name = "lambda", .value = 0 },
        }, 1, &.{background});
        const structural = try reduced.evaluateValue(&.{
            .{ .name = "m2", .value = 3 },
        }, 1, &.{background});
        try std.testing.expectEqual(Status.ok, specialized.status);
        try std.testing.expectEqual(Status.ok, structural.status);
        try std.testing.expectEqual(specialized.value.re, structural.value.re);
        try std.testing.expectEqual(specialized.value.im, structural.value.im);
    }
}

// -- seeded-defect acceptance ----------------------------------------------

/// The value a deliberately defective implementation would report.
///
/// Each variant is one row of decision 0007's seeded-defect table. The tests
/// below check that the case the decision assigns to a row really does separate
/// the defective value from the production one under the named policy: an
/// oracle that could not tell them apart would accept a wrong implementation.
const Defect = enum {
    /// Replace the `3/2` subtraction by another constant.
    shifted_constant,
    /// Use `1/(32 pi^2)` instead of `1/(64 pi^2)`.
    wrong_normalization,
    /// Report `log|x|` as a real result, discarding the branch.
    real_logarithm,
    /// Divide by `muR` instead of `muR^2`.
    linear_scale,
};

fn defectiveEigenvalue(
    defect: Defect,
    mass_squared: f64,
    renormalization_scale: f64,
) Complex64 {
    if (mass_squared == 0) return .{ .re = 0, .im = 0 };
    const square = mass_squared * mass_squared;
    const magnitude = @abs(mass_squared);
    const pi_squared = std.math.pi * std.math.pi;
    return switch (defect) {
        .shifted_constant => .{
            .re = square * (@log(magnitude /
                (renormalization_scale * renormalization_scale)) - 1.0) /
                (64.0 * pi_squared),
            .im = if (mass_squared < 0) square / (64.0 * std.math.pi) else 0,
        },
        .wrong_normalization => .{
            .re = square * (@log(magnitude /
                (renormalization_scale * renormalization_scale)) - 1.5) /
                (32.0 * pi_squared),
            .im = if (mass_squared < 0) square / (32.0 * std.math.pi) else 0,
        },
        .real_logarithm => .{
            .re = square * (@log(magnitude /
                (renormalization_scale * renormalization_scale)) - 1.5) /
                (64.0 * pi_squared),
            .im = 0,
        },
        .linear_scale => .{
            .re = square * (@log(magnitude / renormalization_scale) - 1.5) /
                (64.0 * pi_squared),
            .im = if (mass_squared < 0) square / (64.0 * std.math.pi) else 0,
        },
    };
}

fn defectiveSum(
    defect: Defect,
    eigenvalues: []const f64,
    renormalization_scale: f64,
) Complex64 {
    var total = Complex64{ .re = 0, .im = 0 };
    for (eigenvalues) |eigenvalue| {
        total = total.add(defectiveEigenvalue(
            defect,
            eigenvalue,
            renormalization_scale,
        ));
    }
    return total;
}

/// Fails when `defective` is close enough to `actual` that the case could not
/// reject an implementation carrying the seeded defect.
fn expectDistinguishable(
    label: []const u8,
    policy: comparison.Policy,
    actual: Complex64,
    defective: Complex64,
    scale: Complex64,
) !void {
    errdefer std.debug.print("seeded defect not separated: {s}\n", .{label});
    const real_agrees = policy.agreeAt(
        defective.re,
        actual.re,
        .{ .magnitude = scale.re },
    );
    const imaginary_agrees = policy.agreeAt(
        defective.im,
        actual.im,
        .{ .magnitude = scale.im },
    );
    try std.testing.expect(!real_agrees or !imaginary_agrees);
}

test "the positive known spectrum separates the constant and normalization defects" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    const case = three_scalar_cases[0];
    const outcome = try subject.evaluateValue(case.assignments, case.scale, case.backgrounds);
    try expectCaseValue(&subject, case);

    const reference = spectralSumAt(case.eigenvalues, case.scale);
    for ([_]Defect{ .shifted_constant, .wrong_normalization }) |defect| {
        try expectDistinguishable(
            @tagName(defect),
            case.policy,
            outcome.value,
            defectiveSum(defect, case.eigenvalues, case.scale),
            reference.unsigned_scale,
        );
    }
}

test "a non-unit scale separates the linear-scale defect twice over" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    // `positive_dense` is recorded at scale three, where dividing by `muR`
    // instead of `muR^2` changes every logarithm.
    const case = three_scalar_cases[0];
    const reference = spectralSumAt(case.eigenvalues, case.scale);
    const outcome = try subject.evaluateValue(case.assignments, case.scale, case.backgrounds);
    try expectDistinguishable(
        "linear_scale value",
        case.policy,
        outcome.value,
        defectiveSum(.linear_scale, case.eigenvalues, case.scale),
        reference.unsigned_scale,
    );

    // The fixed-parameter scale relation catches it a second time, through a
    // different quantity: the defect halves the coefficient of the logarithm.
    const at_first = try subject.evaluateValue(case.assignments, 2, case.backgrounds);
    const at_second = try subject.evaluateValue(case.assignments, 5, case.backgrounds);
    var trace_square: f64 = 0;
    for (case.matrix) |entry| trace_square += entry * entry;
    const defective_difference = defectiveSum(.linear_scale, case.eigenvalues, 5).re -
        defectiveSum(.linear_scale, case.eigenvalues, 2).re;
    const expected = -trace_square * @log(5.0 / 2.0) /
        (32.0 * std.math.pi * std.math.pi);
    const actual = at_second.value.re - at_first.value.re;
    try comparison.reordered_value_well_conditioned.expectCloseAt(
        expected,
        actual,
        .{ .magnitude = @abs(at_first.value.re) + @abs(at_second.value.re) },
    );
    try std.testing.expect(!comparison.reordered_value_well_conditioned.agreeAt(
        defective_difference,
        actual,
        .{ .magnitude = @abs(at_first.value.re) + @abs(at_second.value.re) },
    ));
}

test "negative and indefinite spectra separate the real-logarithm defect" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    for ([_]Case{ three_scalar_cases[2], three_scalar_cases[4] }) |case| {
        const outcome = try subject.evaluateValue(
            case.assignments,
            case.scale,
            case.backgrounds,
        );
        try std.testing.expectEqual(Status.ok, outcome.status);
        // The production value carries a strictly positive imaginary part; a
        // real projection reports exactly zero there.
        try std.testing.expect(outcome.value.im > 0);
        const reference = spectralSumAt(case.eigenvalues, case.scale);
        try expectDistinguishable(
            "real_logarithm",
            case.policy,
            outcome.value,
            defectiveSum(.real_logarithm, case.eigenvalues, case.scale),
            reference.unsigned_scale,
        );
    }
}

test "exact degeneracies separate a dropped repeated eigenvalue" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    // `positive_degeneracy_dense` has spectrum {18, 18, 45} and
    // `negative_degeneracy_dense` has {-18, -18, 27}: dropping the repeat is a
    // distinct value in both, and in the negative case it also halves the
    // imaginary component.
    for ([_]Case{ three_scalar_cases[1], three_scalar_cases[2] }) |case| {
        const outcome = try subject.evaluateValue(
            case.assignments,
            case.scale,
            case.backgrounds,
        );
        try expectCaseValue(&subject, case);
        const reference = spectralSumAt(case.eigenvalues, case.scale);
        const deduplicated = spectralSumAt(case.eigenvalues[1..], case.scale);
        try expectDistinguishable(
            "dropped multiplicity",
            case.policy,
            outcome.value,
            deduplicated.value,
            reference.unsigned_scale,
        );
        // The multiplicity is not merely present, it is exactly two: the
        // repeated contribution is twice the single one.
        const single = oneLoopEigenvalue(case.eigenvalues[0], case.scale);
        const repeated = Complex64{
            .re = outcome.value.re - deduplicated.value.re,
            .im = outcome.value.im - deduplicated.value.im,
        };
        try case.policy.expectCloseAt(single.re, repeated.re, .{
            .magnitude = @abs(single.re),
        });
        try case.policy.expectCloseAt(single.im, repeated.im, .{
            .magnitude = @abs(single.im),
        });
    }
}

test "negative spectra separate a clipped negative eigenvalue" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    for ([_]Case{ three_scalar_cases[2], three_scalar_cases[4] }) |case| {
        const outcome = try subject.evaluateValue(
            case.assignments,
            case.scale,
            case.backgrounds,
        );
        var clipped: [3]Scalar = undefined;
        for (case.eigenvalues, 0..) |eigenvalue, index| {
            clipped[index] = @max(eigenvalue, 0);
        }
        const reference = spectralSumAt(case.eigenvalues, case.scale);
        try expectDistinguishable(
            "clipped negative eigenvalue",
            case.policy,
            outcome.value,
            spectralSumAt(clipped[0..case.eigenvalues.len], case.scale).value,
            reference.unsigned_scale,
        );
    }
}

test "a permuted near-degenerate gradient separates an ordering-dependent derivative" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value_gradient,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    // The near-degenerate coupling matrix and its exact reversal permutation.
    // A derivative that differentiated an eigenvalue label or an eigenvector
    // phase would resolve the close pair differently in the two orderings.
    const original = [9]Scalar{
        1 + near_offset, near_offset,     0,
        near_offset,     1 + near_offset, 0,
        0,               0,               4,
    };
    const permutation = [9]Scalar{ 0, 0, 1, 0, 1, 0, 1, 0, 0 };
    const permuted = multiply3(multiply3(permutation, original), transpose3(permutation));

    const before = threeScalarAssignments(couplingsOf(original));
    const after = threeScalarAssignments(couplingsOf(permuted));

    var gradients: [2]kernel_module.Complex64 = undefined;
    for ([_][6]Assignment{ before, after }, 0..) |assignments, index| {
        var values: [1]kernel_module.Complex64 = undefined;
        var slot: [1]kernel_module.Complex64 = undefined;
        var statuses: [1]Status = undefined;
        try subject.evaluateInto(&assignments, 1, &.{1}, .{
            .values = &values,
            .gradients = &slot,
            .statuses = &statuses,
        });
        try std.testing.expectEqual(Status.ok, statuses[0]);
        gradients[index] = slot[0];
    }

    // `M(b) = b C`, so `dV/db = sum_a c_a Phi'(b c_a)` over the fixture
    // spectrum, which no permutation of the scalar basis can change.
    var expected = Complex64{ .re = 0, .im = 0 };
    for ([_]Scalar{ 1, 1 + near_separation, 4 }) |eigenvalue| {
        const derivative = oneLoopFirstSpectralDerivative(eigenvalue, 1);
        expected = expected.add(.{
            .re = eigenvalue * derivative.re,
            .im = eigenvalue * derivative.im,
        });
    }
    for (gradients) |gradient| {
        try comparison.spectral_gradient_near_degenerate.expectCloseAt(
            expected.re,
            gradient.re,
            .{ .magnitude = @abs(expected.re) },
        );
    }
    try std.testing.expectEqual(gradients[0].re, gradients[1].re);
    try std.testing.expectEqual(gradients[0].im, gradients[1].im);
}

test "an exact zero mode is a published limit rather than zero times infinity" {
    var subject = try Subject.init(
        oracle_fixture.three_scalar_model,
        three_scalar_slice_request,
        .value,
        .{ .role = .scalar_one_loop },
        1,
    );
    defer subject.deinit();

    const case = three_scalar_cases[3];
    const outcome = try subject.evaluateValue(
        case.assignments,
        case.scale,
        case.backgrounds,
    );
    try std.testing.expectEqual(Status.ok, outcome.status);
    // A `0 * log 0` product would be NaN, and a `0 * inf` one would be too.
    // The analytic limit is taken first, so the point is finite and equal to
    // the sum over the nonzero eigenvalues alone.
    try std.testing.expect(std.math.isFinite(outcome.value.re));
    try std.testing.expect(std.math.isFinite(outcome.value.im));
    const nonzero = spectralSumAt(case.eigenvalues[1..], case.scale);
    try case.policy.expectCloseAt(
        nonzero.value.re,
        outcome.value.re,
        .{ .magnitude = nonzero.unsigned_scale.re },
    );
    try std.testing.expectEqual(@as(Scalar, 0), outcome.value.im);
}

// -- exact workspace boundaries --------------------------------------------

test "each fixture dimension is served by exactly its queried workspace" {
    const Bounded = struct {
        model: []const u8,
        request: []const u8,
        assignments: []const Assignment,
        backgrounds: []const Scalar,
    };
    const subjects = [_]Bounded{
        .{
            .model = example_data.phi4_model,
            .request = full_space_request,
            .assignments = phi4_cases[0].assignments,
            .backgrounds = phi4_cases[0].backgrounds,
        },
        .{
            .model = example_data.multi_scalar_model,
            .request = full_space_request,
            .assignments = multi_scalar_cases[0].assignments,
            .backgrounds = multi_scalar_cases[0].backgrounds,
        },
        .{
            .model = oracle_fixture.three_scalar_model,
            .request = three_scalar_slice_request,
            .assignments = three_scalar_cases[0].assignments,
            .backgrounds = three_scalar_cases[0].backgrounds,
        },
    };

    for (subjects) |bounded| {
        var subject = try Subject.init(
            bounded.model,
            bounded.request,
            .value,
            .{ .role = .scalar_one_loop },
            1,
        );
        defer subject.deinit();

        const bound = try subject.bindInputs(bounded.assignments, 1);
        defer bound.deinit();
        var values: [1]kernel_module.Complex64 = undefined;
        var statuses: [1]Status = undefined;
        const inputs = kernel_module.Inputs{
            .parameters = bound.parameters,
            .scales = bound.scales,
            .backgrounds = bounded.backgrounds,
        };
        const buffers = kernel_module.ComplexOutputBuffers{
            .values = &values,
            .statuses = &statuses,
        };

        const layout = subject.kernel.workspaceLayout(1);
        try std.testing.expect(layout.bytes > 0);
        try subject.kernel.evaluateComplex(inputs, 1, subject.workspace, buffers);
        try std.testing.expectEqual(Status.ok, statuses[0]);

        // One byte short is rejected before any slot is written, at every
        // fluctuation dimension the fixtures cover.
        try std.testing.expectError(
            error.WorkspaceTooSmall,
            subject.kernel.evaluateComplex(
                inputs,
                1,
                subject.workspace[0 .. layout.bytes - 1],
                buffers,
            ),
        );
    }
}
