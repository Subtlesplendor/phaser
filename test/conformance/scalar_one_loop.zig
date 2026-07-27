const std = @import("std");
const comparison = @import("numerical_comparison");
const fixture_data = @import("conformance_fixture_data");

// Numerical transcription smoke tests for the exact language-neutral fixtures.
// The JSON metadata is checked structurally, but expected-value expressions
// remain hand-transcribed: Milestone 3 preparation adds no fixture-expression
// parser.
const Complex64 = struct {
    re: f64,
    im: f64,

    fn add(self: Complex64, other: Complex64) Complex64 {
        return .{ .re = self.re + other.re, .im = self.im + other.im };
    }
};

fn oneLoopEigenvalue(mass_squared: f64, renormalization_scale: f64) Complex64 {
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

fn oneLoopFirstSpectralDerivative(
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

fn oneLoopSecondSpectralDerivative(
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

fn expectComplexApprox(
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

fn symmetricEigenvalues2x2(a: f64, b: f64, d: f64) [2]f64 {
    const center = (a + d) / 2.0;
    const half_difference = (a - d) / 2.0;
    const radius = @sqrt(half_difference * half_difference + b * b);
    return .{ center + radius, center - radius };
}

const SpectralSum = struct {
    value: Complex64,
    unsigned_scale: Complex64,
};

fn spectralSumAt(
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

fn spectralSum(eigenvalues: []const f64) SpectralSum {
    return spectralSumAt(eigenvalues, 1);
}

fn requiredObject(
    object: std.json.ObjectMap,
    key: []const u8,
) !std.json.ObjectMap {
    const value = object.get(key) orelse return error.MissingFixtureField;
    return switch (value) {
        .object => |map| map,
        else => error.InvalidFixtureField,
    };
}

fn requiredArray(
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const std.json.Value {
    const value = object.get(key) orelse return error.MissingFixtureField;
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidFixtureField,
    };
}

fn requiredString(
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const u8 {
    const value = object.get(key) orelse return error.MissingFixtureField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFixtureField,
    };
}

fn requiredNumberString(
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const u8 {
    const value = object.get(key) orelse return error.MissingFixtureField;
    return switch (value) {
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
    const calculation = try requiredObject(object, "calculation");
    try std.testing.expectEqualStrings(
        "effective_potential",
        try requiredString(calculation, "kind"),
    );
    try std.testing.expectEqualStrings(
        "scalar_one_loop",
        try requiredString(calculation, "contribution"),
    );
    try std.testing.expectEqualStrings(
        "1",
        try requiredNumberString(calculation, "loop_order"),
    );
    _ = try requiredString(calculation, "operation");

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
        std.testing.allocator,
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

test "positive and negative scalar masses preserve the principal branch" {
    const expected_real = -3.0 / (128.0 * std.math.pi * std.math.pi);
    try expectComplexApprox(
        .{ .re = expected_real, .im = 0 },
        oneLoopEigenvalue(1, 1),
        .{ .re = @abs(expected_real), .im = 0 },
    );
    try expectComplexApprox(
        .{ .re = expected_real, .im = 1.0 / (64.0 * std.math.pi) },
        oneLoopEigenvalue(-1, 1),
        .{
            .re = @abs(expected_real),
            .im = 1.0 / (64.0 * std.math.pi),
        },
    );
}

test "value and first derivative have zero limits from both sides" {
    try expectComplexApprox(
        .{ .re = 0, .im = 0 },
        oneLoopEigenvalue(0, 1),
        .{ .re = 0, .im = 0 },
    );
    const first_derivative = oneLoopFirstSpectralDerivative(0, 1);
    try comparison.spectral_gradient_zero_mode.expectCloseAt(
        0,
        first_derivative.re,
        .{ .magnitude = 0 },
    );
    try comparison.spectral_gradient_zero_mode.expectCloseAt(
        0,
        first_derivative.im,
        .{ .magnitude = 0 },
    );

    const epsilon = 1e-100;
    const positive = oneLoopFirstSpectralDerivative(epsilon, 1);
    const negative = oneLoopFirstSpectralDerivative(-epsilon, 1);
    try std.testing.expect(@abs(positive.re) < 1e-95);
    try std.testing.expect(@abs(negative.re) < 1e-95);
    try std.testing.expect(@abs(negative.im) < 1e-95);
}

test "a required zero-mode second derivative is singular" {
    try std.testing.expectError(
        error.SingularDerivative,
        oneLoopSecondSpectralDerivative(0, 1),
    );
}

test "negative degeneracy preserves multiplicity" {
    const single = oneLoopEigenvalue(-2, 1);
    const repeated = spectralSum(&.{ -2, -2 });
    try expectComplexApprox(
        .{ .re = 2.0 * single.re, .im = 2.0 * single.im },
        repeated.value,
        repeated.unsigned_scale,
    );
}

test "field permutation and orthogonal basis changes preserve complex spectral sums" {
    const original = symmetricEigenvalues2x2(4, 0, -1);
    const permuted = symmetricEigenvalues2x2(-1, 0, 4);

    // A 45-degree orthogonal rotation of diag(4, -1).
    const rotated = symmetricEigenvalues2x2(1.5, 2.5, 1.5);

    const expected = spectralSum(&original);
    const permuted_sum = spectralSum(&permuted);
    const rotated_sum = spectralSum(&rotated);
    try expectComplexApprox(
        expected.value,
        permuted_sum.value,
        expected.unsigned_scale,
    );
    try expectComplexApprox(
        expected.value,
        rotated_sum.value,
        expected.unsigned_scale,
    );
}

test "the phi4 fixed-parameter scale pair obeys its exact relation" {
    const at_mu1 = spectralSumAt(&.{1}, 1);
    const at_mu2 = spectralSumAt(&.{1}, 2);
    const actual_difference = at_mu2.value.re - at_mu1.value.re;
    const expected_difference =
        -@log(2.0) / (32.0 * std.math.pi * std.math.pi);
    try comparison.reordered_value_well_conditioned.expectCloseAt(
        expected_difference,
        actual_difference,
        .{
            .magnitude = @abs(at_mu1.value.re) +
                @abs(at_mu2.value.re) +
                @abs(expected_difference),
        },
    );
    try std.testing.expectEqual(@as(f64, 0), at_mu1.value.im);
    try std.testing.expectEqual(@as(f64, 0), at_mu2.value.im);
}

fn expectTranscribedSpectrum(
    eigenvalues: []const f64,
    renormalization_scale: f64,
    expected: Complex64,
) !void {
    const actual = spectralSumAt(eigenvalues, renormalization_scale);
    try expectComplexApprox(expected, actual.value, actual.unsigned_scale);
}

test "the two-scalar exact spectra match every fixture transcription" {
    const pi_squared = std.math.pi * std.math.pi;
    try expectTranscribedSpectrum(
        &.{ 1, 4 },
        1,
        .{
            .re = -3.0 / (128.0 * pi_squared) +
                (@log(4.0) - 1.5) / (4.0 * pi_squared),
            .im = 0,
        },
    );
    try expectTranscribedSpectrum(
        &.{ 2, 2 },
        1,
        .{
            .re = (@log(2.0) - 1.5) / (8.0 * pi_squared),
            .im = 0,
        },
    );
    try expectTranscribedSpectrum(
        &.{ 0, 4 },
        1,
        .{
            .re = (@log(4.0) - 1.5) / (4.0 * pi_squared),
            .im = 0,
        },
    );
    try expectTranscribedSpectrum(
        &.{ 4, -1 },
        1,
        .{
            .re = (@log(4.0) - 1.5) / (4.0 * pi_squared) -
                3.0 / (128.0 * pi_squared),
            .im = 1.0 / (64.0 * std.math.pi),
        },
    );
    try expectTranscribedSpectrum(
        &.{ -2, -2 },
        1,
        .{
            .re = (@log(2.0) - 1.5) / (8.0 * pi_squared),
            .im = 1.0 / (8.0 * std.math.pi),
        },
    );

    const near = 1.0 + 0x1p-20;
    const near_actual = spectralSum(&.{ 1, near });
    const near_expected = Complex64{
        .re = (-1.5 +
            near * near * (@log(near) - 1.5)) /
            (64.0 * pi_squared),
        .im = 0,
    };
    try comparison.spectral_value_near_degenerate.expectCloseAt(
        near_expected.re,
        near_actual.value.re,
        .{ .magnitude = near_actual.unsigned_scale.re },
    );
    try comparison.spectral_value_near_degenerate.expectCloseAt(
        near_expected.im,
        near_actual.value.im,
        .{ .magnitude = near_actual.unsigned_scale.im },
    );
}

test "the three-scalar exact spectra match every fixture transcription" {
    const pi_squared = std.math.pi * std.math.pi;
    try expectTranscribedSpectrum(
        &.{ 9, 36, 81 },
        3,
        .{
            .re = (81.0 * -1.5 +
                1296.0 * (@log(4.0) - 1.5) +
                6561.0 * (@log(9.0) - 1.5)) /
                (64.0 * pi_squared),
            .im = 0,
        },
    );
    try expectTranscribedSpectrum(
        &.{ 18, 18, 45 },
        3,
        .{
            .re = (648.0 * (@log(2.0) - 1.5) +
                2025.0 * (@log(5.0) - 1.5)) /
                (64.0 * pi_squared),
            .im = 0,
        },
    );
    try expectTranscribedSpectrum(
        &.{ -18, -18, 27 },
        3,
        .{
            .re = (648.0 * (@log(2.0) - 1.5) +
                729.0 * (@log(3.0) - 1.5)) /
                (64.0 * pi_squared),
            .im = 81.0 / (8.0 * std.math.pi),
        },
    );
    try expectTranscribedSpectrum(
        &.{ 0, 2, 4 },
        1,
        .{
            .re = (4.0 * (@log(2.0) - 1.5) +
                16.0 * (@log(4.0) - 1.5)) /
                (64.0 * pi_squared),
            .im = 0,
        },
    );
    try expectTranscribedSpectrum(
        &.{ -2, 2, 3 },
        1,
        .{
            .re = (8.0 * (@log(2.0) - 1.5) +
                9.0 * (@log(3.0) - 1.5)) /
                (64.0 * pi_squared),
            .im = 1.0 / (16.0 * std.math.pi),
        },
    );

    const near = 1.0 + 0x1p-20;
    const near_actual = spectralSum(&.{ 1, near, 4 });
    const near_expected = (-1.5 +
        near * near * (@log(near) - 1.5) +
        16.0 * (@log(4.0) - 1.5)) /
        (64.0 * pi_squared);
    try comparison.spectral_value_near_degenerate.expectCloseAt(
        near_expected,
        near_actual.value.re,
        .{ .magnitude = near_actual.unsigned_scale.re },
    );

    const permuted = spectralSumAt(&.{ 81, 36, 9 }, 3);
    const original = spectralSumAt(&.{ 9, 36, 81 }, 3);
    try expectComplexApprox(
        original.value,
        permuted.value,
        original.unsigned_scale,
    );
}
