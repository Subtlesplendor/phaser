const std = @import("std");

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

fn expectComplexApprox(expected: Complex64, actual: Complex64, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected.re, actual.re, tolerance);
    try std.testing.expectApproxEqAbs(expected.im, actual.im, tolerance);
}

fn symmetricEigenvalues2x2(a: f64, b: f64, d: f64) [2]f64 {
    const center = (a + d) / 2.0;
    const half_difference = (a - d) / 2.0;
    const radius = @sqrt(half_difference * half_difference + b * b);
    return .{ center + radius, center - radius };
}

fn spectralSum(eigenvalues: []const f64) Complex64 {
    var sum = Complex64{ .re = 0, .im = 0 };
    for (eigenvalues) |eigenvalue| {
        sum = sum.add(oneLoopEigenvalue(eigenvalue, 1));
    }
    return sum;
}

test "positive and negative scalar masses preserve the principal branch" {
    const expected_real = -3.0 / (128.0 * std.math.pi * std.math.pi);
    try expectComplexApprox(
        .{ .re = expected_real, .im = 0 },
        oneLoopEigenvalue(1, 1),
        1e-15,
    );
    try expectComplexApprox(
        .{ .re = expected_real, .im = 1.0 / (64.0 * std.math.pi) },
        oneLoopEigenvalue(-1, 1),
        1e-15,
    );
}

test "value and first derivative have zero limits from both sides" {
    try expectComplexApprox(
        .{ .re = 0, .im = 0 },
        oneLoopEigenvalue(0, 1),
        0,
    );
    try expectComplexApprox(
        .{ .re = 0, .im = 0 },
        oneLoopFirstSpectralDerivative(0, 1),
        0,
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
        repeated,
        1e-15,
    );
}

test "field permutation and orthogonal basis changes preserve complex spectral sums" {
    const original = symmetricEigenvalues2x2(4, 0, -1);
    const permuted = symmetricEigenvalues2x2(-1, 0, 4);

    // A 45-degree orthogonal rotation of diag(4, -1).
    const rotated = symmetricEigenvalues2x2(1.5, 2.5, 1.5);

    const expected = spectralSum(&original);
    try expectComplexApprox(expected, spectralSum(&permuted), 1e-15);
    try expectComplexApprox(expected, spectralSum(&rotated), 1e-15);
}
