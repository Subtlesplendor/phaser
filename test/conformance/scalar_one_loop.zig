const std = @import("std");
const comparison = @import("numerical_comparison");

// Numerical transcription smoke tests for the exact language-neutral fixtures.
// Milestone 0 intentionally has no fixture or model parser.
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

fn spectralSum(eigenvalues: []const f64) SpectralSum {
    var sum = SpectralSum{
        .value = .{ .re = 0, .im = 0 },
        .unsigned_scale = .{ .re = 0, .im = 0 },
    };
    for (eigenvalues) |eigenvalue| {
        const contribution = oneLoopEigenvalue(eigenvalue, 1);
        sum.value = sum.value.add(contribution);
        sum.unsigned_scale.re += @abs(contribution.re);
        sum.unsigned_scale.im += @abs(contribution.im);
    }
    return sum;
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
