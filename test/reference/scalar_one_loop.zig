//! Independent Milestone 3 oracle prototype.
//!
//! This file deliberately imports no Phaser production module. The scalar
//! evaluator accepts an explicit eigenvalue multiset and never constructs a
//! matrix, calls an eigensolver, lowers Typed Value IR, or executes a kernel.
//! Zig's `f64`, `@log`, and `@sqrt` primitives are the intentionally shared
//! numerical boundary recorded by the fixture documentation.

const std = @import("std");
const comparison = @import("numerical_comparison");

const Complex64 = struct {
    re: f64,
    im: f64,

    fn add(self: Complex64, other: Complex64) Complex64 {
        return .{
            .re = self.re + other.re,
            .im = self.im + other.im,
        };
    }
};

const EvaluatedSum = struct {
    value: Complex64,
    /// Component-wise sum of the unsigned individual contributions.
    ///
    /// This, rather than the possibly cancelled result, is the conditioning
    /// scale required by `spectral_value_known_spectrum`.
    unsigned_scale: Complex64,
};

const ReferenceError = error{
    InvalidScale,
    NonFiniteEigenvalue,
};

fn scalarContribution(
    mass_squared: f64,
    renormalization_scale: f64,
) Complex64 {
    if (mass_squared == 0) return .{ .re = 0, .im = 0 };

    const square = mass_squared * mass_squared;
    const logarithm = @log(@abs(mass_squared) /
        (renormalization_scale * renormalization_scale));
    return .{
        .re = square * (logarithm - 1.5) /
            (64.0 * std.math.pi * std.math.pi),
        .im = if (mass_squared < 0)
            square / (64.0 * std.math.pi)
        else
            0,
    };
}

/// Directly evaluates the principal-branch scalar sum over a known spectrum.
fn evaluateKnownSpectrum(
    eigenvalues: []const f64,
    renormalization_scale: f64,
) ReferenceError!EvaluatedSum {
    if (!std.math.isFinite(renormalization_scale) or
        renormalization_scale <= 0)
    {
        return error.InvalidScale;
    }

    var result = EvaluatedSum{
        .value = .{ .re = 0, .im = 0 },
        .unsigned_scale = .{ .re = 0, .im = 0 },
    };
    for (eigenvalues) |eigenvalue| {
        if (!std.math.isFinite(eigenvalue)) {
            return error.NonFiniteEigenvalue;
        }
        const contribution = scalarContribution(
            eigenvalue,
            renormalization_scale,
        );
        result.value = result.value.add(contribution);
        result.unsigned_scale.re += @abs(contribution.re);
        result.unsigned_scale.im += @abs(contribution.im);
    }
    return result;
}

fn firstSpectralDerivative(
    mass_squared: f64,
    renormalization_scale: f64,
) f64 {
    if (mass_squared == 0) return 0;
    return 2.0 * mass_squared *
        (@log(@abs(mass_squared) /
            (renormalization_scale * renormalization_scale)) - 1.0) /
        (64.0 * std.math.pi * std.math.pi);
}

fn secondSpectralDerivative(
    mass_squared: f64,
    renormalization_scale: f64,
) error{SingularDerivative}!f64 {
    if (mass_squared == 0) return error.SingularDerivative;
    return 2.0 *
        @log(@abs(mass_squared) /
            (renormalization_scale * renormalization_scale)) /
        (64.0 * std.math.pi * std.math.pi);
}

const Matrix3 = [3][3]f64;

const MatrixCase = struct {
    name: []const u8,
    matrix: Matrix3,
    eigenvalues: [3]f64,
};

// Q = A / 3 is an exactly recorded orthogonal transformation. For a diagonal
// D, A D A^T has eigenvalues nine times those of D. The resulting integer
// matrices keep their characteristic invariants reviewable by hand while
// exercising every off-diagonal plane of a future 3x3 cyclic Jacobi solver.
const orthogonal_numerator = Matrix3{
    .{ 1, -2, -2 },
    .{ -2, 1, -2 },
    .{ -2, -2, 1 },
};

const exact_spectrum_cases = [_]MatrixCase{
    .{
        .name = "positive_dense",
        .matrix = .{
            .{ 53, 26, -4 },
            .{ 26, 44, -22 },
            .{ -4, -22, 29 },
        },
        .eigenvalues = .{ 9, 36, 81 },
    },
    .{
        .name = "positive_degeneracy_dense",
        .matrix = .{
            .{ 30, 12, -6 },
            .{ 12, 30, -6 },
            .{ -6, -6, 21 },
        },
        .eigenvalues = .{ 18, 18, 45 },
    },
    .{
        .name = "negative_degeneracy_dense",
        .matrix = .{
            .{ 2, 20, -10 },
            .{ 20, 2, -10 },
            .{ -10, -10, -13 },
        },
        .eigenvalues = .{ -18, -18, 27 },
    },
    .{
        .name = "zero_mode",
        .matrix = .{
            .{ 1, 1, 0 },
            .{ 1, 1, 0 },
            .{ 0, 0, 4 },
        },
        .eigenvalues = .{ 0, 2, 4 },
    },
    .{
        .name = "indefinite",
        .matrix = .{
            .{ 0, 2, 0 },
            .{ 2, 0, 0 },
            .{ 0, 0, 3 },
        },
        .eigenvalues = .{ -2, 2, 3 },
    },
    .{
        .name = "near_degenerate",
        .matrix = .{
            .{ 1.0 + 0x1p-21, 0x1p-21, 0 },
            .{ 0x1p-21, 1.0 + 0x1p-21, 0 },
            .{ 0, 0, 4 },
        },
        .eigenvalues = .{ 1, 1.0 + 0x1p-20, 4 },
    },
    .{
        .name = "positive_dense_permuted",
        .matrix = .{
            .{ 29, -22, -4 },
            .{ -22, 44, 26 },
            .{ -4, 26, 53 },
        },
        .eigenvalues = .{ 81, 36, 9 },
    },
};

fn trace(matrix: Matrix3) f64 {
    return matrix[0][0] + matrix[1][1] + matrix[2][2];
}

fn traceSquare(matrix: Matrix3) f64 {
    var result: f64 = 0;
    for (0..3) |row| {
        for (0..3) |column| {
            result += matrix[row][column] * matrix[column][row];
        }
    }
    return result;
}

fn determinant(matrix: Matrix3) f64 {
    return matrix[0][0] *
        (matrix[1][1] * matrix[2][2] -
            matrix[1][2] * matrix[2][1]) -
        matrix[0][1] *
            (matrix[1][0] * matrix[2][2] -
                matrix[1][2] * matrix[2][0]) +
        matrix[0][2] *
            (matrix[1][0] * matrix[2][1] -
                matrix[1][1] * matrix[2][0]);
}

fn expectCharacteristicPolynomial(case: MatrixCase) !void {
    const matrix_trace = trace(case.matrix);
    const matrix_e2 = (matrix_trace * matrix_trace -
        traceSquare(case.matrix)) / 2.0;
    const matrix_determinant = determinant(case.matrix);

    const spectrum_trace =
        case.eigenvalues[0] + case.eigenvalues[1] + case.eigenvalues[2];
    const spectrum_e2 =
        case.eigenvalues[0] * case.eigenvalues[1] +
        case.eigenvalues[0] * case.eigenvalues[2] +
        case.eigenvalues[1] * case.eigenvalues[2];
    const spectrum_determinant =
        case.eigenvalues[0] * case.eigenvalues[1] * case.eigenvalues[2];

    // The three coefficients determine the complete characteristic polynomial
    // of a 3x3 matrix. The scale is the sum of the coefficient's unsigned
    // terms, not the possibly cancelled coefficient.
    try comparison.reordered_value_well_conditioned.expectCloseAt(
        spectrum_trace,
        matrix_trace,
        .{ .magnitude = @abs(spectrum_trace) + @abs(matrix_trace) },
    );
    try comparison.reordered_value_well_conditioned.expectCloseAt(
        spectrum_e2,
        matrix_e2,
        .{
            .magnitude = @abs(matrix_trace * matrix_trace) +
                @abs(traceSquare(case.matrix)) +
                @abs(spectrum_e2),
        },
    );
    try comparison.reordered_value_well_conditioned.expectCloseAt(
        spectrum_determinant,
        matrix_determinant,
        .{
            .magnitude = @abs(spectrum_determinant) +
                @abs(matrix_determinant),
        },
    );
}

fn multiply(left: Matrix3, right: Matrix3) Matrix3 {
    var result: Matrix3 = @splat(@splat(0));
    for (0..3) |row| {
        for (0..3) |column| {
            for (0..3) |inner| {
                result[row][column] += left[row][inner] * right[inner][column];
            }
        }
    }
    return result;
}

fn transpose(matrix: Matrix3) Matrix3 {
    var result: Matrix3 = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            result[row][column] = matrix[column][row];
        }
    }
    return result;
}

fn expectMatrixClose(expected: Matrix3, actual: Matrix3) !void {
    for (0..3) |row| {
        for (0..3) |column| {
            try comparison.reordered_value_well_conditioned.expectCloseAt(
                expected[row][column],
                actual[row][column],
                .{
                    .magnitude = @abs(expected[row][column]) +
                        @abs(actual[row][column]),
                },
            );
        }
    }
}

test "exact-spectrum matrices have the recorded characteristic polynomials" {
    for (exact_spectrum_cases) |case| {
        try expectCharacteristicPolynomial(case);
    }
}

test "the dense positive case is an explicit orthogonal transformation" {
    var orthogonal = orthogonal_numerator;
    for (&orthogonal) |*row| {
        for (row) |*entry| entry.* /= 3.0;
    }
    try expectMatrixClose(
        .{
            .{ 1, 0, 0 },
            .{ 0, 1, 0 },
            .{ 0, 0, 1 },
        },
        multiply(orthogonal, transpose(orthogonal)),
    );

    const diagonal = Matrix3{
        .{ 9, 0, 0 },
        .{ 0, 36, 0 },
        .{ 0, 0, 81 },
    };
    try expectMatrixClose(
        exact_spectrum_cases[0].matrix,
        multiply(multiply(orthogonal, diagonal), transpose(orthogonal)),
    );
}

test "permutation and orthogonal transformation preserve the spectral value" {
    // The final exact-spectrum case is the first case with rows and columns
    // both permuted by (0, 1, 2) -> (2, 1, 0).
    try expectCharacteristicPolynomial(
        exact_spectrum_cases[exact_spectrum_cases.len - 1],
    );

    const original = try evaluateKnownSpectrum(&.{ 9, 36, 81 }, 3);
    const permuted = try evaluateKnownSpectrum(&.{ 81, 9, 36 }, 3);

    try comparison.spectral_value_known_spectrum.expectCloseAt(
        original.value.re,
        permuted.value.re,
        .{ .magnitude = original.unsigned_scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        original.value.im,
        permuted.value.im,
        .{ .magnitude = original.unsigned_scale.im },
    );
}

test "the public three-scalar fixture formula reaches the dense matrix" {
    // For the fixture's cubic potential and background (r, s, t) = (1, 0, 0),
    // M_ij = c_rij * r. This formula is independent of model parsing and of any
    // future production mass-matrix builder.
    const parameters = [_]f64{ 53, 26, -4, 44, -22, 29 };
    const background_r: f64 = 1;
    const mass_matrix = Matrix3{
        .{
            parameters[0] * background_r,
            parameters[1] * background_r,
            parameters[2] * background_r,
        },
        .{
            parameters[1] * background_r,
            parameters[3] * background_r,
            parameters[4] * background_r,
        },
        .{
            parameters[2] * background_r,
            parameters[4] * background_r,
            parameters[5] * background_r,
        },
    };
    try expectMatrixClose(exact_spectrum_cases[0].matrix, mass_matrix);
}

test "the evaluator reproduces the hand-derived phi4 values" {
    const positive = try evaluateKnownSpectrum(&.{1}, 1);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        -3.0 / (128.0 * std.math.pi * std.math.pi),
        positive.value.re,
        .{ .magnitude = positive.unsigned_scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        0,
        positive.value.im,
        .{ .magnitude = positive.unsigned_scale.im },
    );

    const negative = try evaluateKnownSpectrum(&.{-1}, 1);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        -3.0 / (128.0 * std.math.pi * std.math.pi),
        negative.value.re,
        .{ .magnitude = negative.unsigned_scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        1.0 / (64.0 * std.math.pi),
        negative.value.im,
        .{ .magnitude = negative.unsigned_scale.im },
    );

    const zero = try evaluateKnownSpectrum(&.{0}, 1);
    try comparison.spectral_value_zero_mode.expectCloseAt(
        0,
        zero.value.re,
        .{ .magnitude = zero.unsigned_scale.re },
    );
    try comparison.spectral_value_zero_mode.expectCloseAt(
        0,
        zero.value.im,
        .{ .magnitude = zero.unsigned_scale.im },
    );
}

test "the evaluator reproduces the fixed-parameter scale pair" {
    const at_mu1 = try evaluateKnownSpectrum(&.{1}, 1);
    const at_mu2 = try evaluateKnownSpectrum(&.{1}, 2);
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

test "the evaluator reproduces the hand-derived two-scalar values" {
    const positive = try evaluateKnownSpectrum(&.{ 1, 4 }, 1);
    const positive_expected =
        -3.0 / (128.0 * std.math.pi * std.math.pi) +
        (@log(4.0) - 1.5) / (4.0 * std.math.pi * std.math.pi);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        positive_expected,
        positive.value.re,
        .{ .magnitude = positive.unsigned_scale.re },
    );

    const positive_degeneracy =
        try evaluateKnownSpectrum(&.{ 2, 2 }, 1);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        (@log(2.0) - 1.5) /
            (8.0 * std.math.pi * std.math.pi),
        positive_degeneracy.value.re,
        .{ .magnitude = positive_degeneracy.unsigned_scale.re },
    );

    const zero = try evaluateKnownSpectrum(&.{ 0, 4 }, 1);
    try comparison.spectral_value_zero_mode.expectCloseAt(
        (@log(4.0) - 1.5) /
            (4.0 * std.math.pi * std.math.pi),
        zero.value.re,
        .{ .magnitude = zero.unsigned_scale.re },
    );

    const indefinite = try evaluateKnownSpectrum(&.{ 4, -1 }, 1);
    const expected_real =
        (@log(4.0) - 1.5) / (4.0 * std.math.pi * std.math.pi) -
        3.0 / (128.0 * std.math.pi * std.math.pi);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        expected_real,
        indefinite.value.re,
        .{ .magnitude = indefinite.unsigned_scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        1.0 / (64.0 * std.math.pi),
        indefinite.value.im,
        .{ .magnitude = indefinite.unsigned_scale.im },
    );

    const negative_degeneracy = try evaluateKnownSpectrum(&.{ -2, -2 }, 1);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        (@log(2.0) - 1.5) / (8.0 * std.math.pi * std.math.pi),
        negative_degeneracy.value.re,
        .{ .magnitude = negative_degeneracy.unsigned_scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        1.0 / (8.0 * std.math.pi),
        negative_degeneracy.value.im,
        .{ .magnitude = negative_degeneracy.unsigned_scale.im },
    );

    const near = 1.0 + 0x1p-20;
    const near_degeneracy =
        try evaluateKnownSpectrum(&.{ 1, near }, 1);
    const near_expected = (-1.5 +
        near * near * (@log(near) - 1.5)) /
        (64.0 * std.math.pi * std.math.pi);
    try comparison.spectral_value_near_degenerate.expectCloseAt(
        near_expected,
        near_degeneracy.value.re,
        .{ .magnitude = near_degeneracy.unsigned_scale.re },
    );
}

test "the evaluator reproduces every hand-derived three-scalar value" {
    const pi_squared = std.math.pi * std.math.pi;

    const positive = try evaluateKnownSpectrum(&.{ 9, 36, 81 }, 3);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        (81.0 * -1.5 +
            1296.0 * (@log(4.0) - 1.5) +
            6561.0 * (@log(9.0) - 1.5)) /
            (64.0 * pi_squared),
        positive.value.re,
        .{ .magnitude = positive.unsigned_scale.re },
    );

    const positive_degeneracy =
        try evaluateKnownSpectrum(&.{ 18, 18, 45 }, 3);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        (648.0 * (@log(2.0) - 1.5) +
            2025.0 * (@log(5.0) - 1.5)) /
            (64.0 * pi_squared),
        positive_degeneracy.value.re,
        .{ .magnitude = positive_degeneracy.unsigned_scale.re },
    );

    const negative_degeneracy =
        try evaluateKnownSpectrum(&.{ -18, -18, 27 }, 3);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        (648.0 * (@log(2.0) - 1.5) +
            729.0 * (@log(3.0) - 1.5)) /
            (64.0 * pi_squared),
        negative_degeneracy.value.re,
        .{ .magnitude = negative_degeneracy.unsigned_scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        81.0 / (8.0 * std.math.pi),
        negative_degeneracy.value.im,
        .{ .magnitude = negative_degeneracy.unsigned_scale.im },
    );

    const zero = try evaluateKnownSpectrum(&.{ 0, 2, 4 }, 1);
    try comparison.spectral_value_zero_mode.expectCloseAt(
        (4.0 * (@log(2.0) - 1.5) +
            16.0 * (@log(4.0) - 1.5)) /
            (64.0 * pi_squared),
        zero.value.re,
        .{ .magnitude = zero.unsigned_scale.re },
    );

    const indefinite = try evaluateKnownSpectrum(&.{ -2, 2, 3 }, 1);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        (8.0 * (@log(2.0) - 1.5) +
            9.0 * (@log(3.0) - 1.5)) /
            (64.0 * pi_squared),
        indefinite.value.re,
        .{ .magnitude = indefinite.unsigned_scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        1.0 / (16.0 * std.math.pi),
        indefinite.value.im,
        .{ .magnitude = indefinite.unsigned_scale.im },
    );

    const near = 1.0 + near_degenerate_separation;
    const near_degeneracy =
        try evaluateKnownSpectrum(&.{ 1, near, 4 }, 1);
    try comparison.spectral_value_near_degenerate.expectCloseAt(
        (-1.5 +
            near * near * (@log(near) - 1.5) +
            16.0 * (@log(4.0) - 1.5)) /
            (64.0 * pi_squared),
        near_degeneracy.value.re,
        .{ .magnitude = near_degeneracy.unsigned_scale.re },
    );

    const permuted = try evaluateKnownSpectrum(&.{ 81, 36, 9 }, 3);
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        positive.value.re,
        permuted.value.re,
        .{ .magnitude = positive.unsigned_scale.re },
    );
    try comparison.spectral_value_known_spectrum.expectCloseAt(
        positive.value.im,
        permuted.value.im,
        .{ .magnitude = positive.unsigned_scale.im },
    );
}

const near_degenerate_separation = 0x1p-20;

fn nearDegenerateSpectrum(background: f64) [3]f64 {
    return .{
        1.0 + background,
        1.0 + near_degenerate_separation - background,
        4.0 + background / 2.0,
    };
}

fn nearDegenerateValue(background: f64) !f64 {
    const spectrum = nearDegenerateSpectrum(background);
    return (try evaluateKnownSpectrum(&spectrum, 1)).value.re;
}

fn nearDegenerateAnalyticGradient() f64 {
    return firstSpectralDerivative(1, 1) -
        firstSpectralDerivative(1.0 + near_degenerate_separation, 1) +
        firstSpectralDerivative(4, 1) / 2.0;
}

fn nearDegenerateAnalyticHessian() !f64 {
    return try secondSpectralDerivative(1, 1) +
        try secondSpectralDerivative(1.0 + near_degenerate_separation, 1) +
        try secondSpectralDerivative(4, 1) / 4.0;
}

fn firstDifference(step: f64) !struct { value: f64, roundoff: f64 } {
    const positive = try nearDegenerateValue(step);
    const negative = try nearDegenerateValue(-step);
    return .{
        .value = (positive - negative) / (2.0 * step),
        .roundoff = std.math.floatEps(f64) *
            (@abs(positive) + @abs(negative)) / (2.0 * step),
    };
}

fn secondDifference(step: f64) !struct { value: f64, roundoff: f64 } {
    const positive = try nearDegenerateValue(step);
    const center = try nearDegenerateValue(0);
    const negative = try nearDegenerateValue(-step);
    return .{
        .value = (positive - 2.0 * center + negative) / (step * step),
        .roundoff = std.math.floatEps(f64) *
            (@abs(positive) + 2.0 * @abs(center) + @abs(negative)) /
            (step * step),
    };
}

test "near-degenerate value gradient and Hessian meet measured policies" {
    const spectrum = nearDegenerateSpectrum(0);
    const value = try evaluateKnownSpectrum(&spectrum, 1);
    const reversed = try evaluateKnownSpectrum(&.{
        spectrum[2],
        spectrum[1],
        spectrum[0],
    }, 1);
    try comparison.spectral_value_near_degenerate.expectCloseAt(
        value.value.re,
        reversed.value.re,
        .{ .magnitude = value.unsigned_scale.re },
    );

    const gradient_step = std.math.cbrt(std.math.floatEps(f64));
    const gradient_reference = try firstDifference(gradient_step);
    const gradient_expected = nearDegenerateAnalyticGradient();
    try comparison.spectral_gradient_near_degenerate.expectCloseAt(
        gradient_expected,
        gradient_reference.value,
        .{
            .magnitude = @max(
                @abs(gradient_expected),
                @abs(gradient_reference.value),
            ),
            .reference_error = gradient_reference.roundoff,
        },
    );

    const hessian_step = @sqrt(@sqrt(std.math.floatEps(f64)));
    const hessian_reference = try secondDifference(hessian_step);
    const hessian_expected = try nearDegenerateAnalyticHessian();
    try comparison.spectral_hessian_near_degenerate.expectCloseAt(
        hessian_expected,
        hessian_reference.value,
        .{
            .magnitude = @max(
                @abs(hessian_expected),
                @abs(hessian_reference.value),
            ),
            .reference_error = hessian_reference.roundoff,
        },
    );
}

test "zero-mode policies distinguish finite limits from a singular Hessian" {
    const value = try evaluateKnownSpectrum(&.{ 0, 2, 4 }, 1);
    const without_zero = try evaluateKnownSpectrum(&.{ 2, 4 }, 1);
    try comparison.spectral_value_zero_mode.expectCloseAt(
        without_zero.value.re,
        value.value.re,
        .{ .magnitude = value.unsigned_scale.re },
    );
    try comparison.spectral_value_zero_mode.expectCloseAt(
        without_zero.value.im,
        value.value.im,
        .{ .magnitude = value.unsigned_scale.im },
    );
    try comparison.spectral_gradient_zero_mode.expectCloseAt(
        0,
        firstSpectralDerivative(0, 1),
        .{ .magnitude = 0 },
    );
    try std.testing.expectError(
        error.SingularDerivative,
        secondSpectralDerivative(0, 1),
    );

    // If x(t) = t^2, the background Hessian has the analytic zero limit even
    // though f''(x) itself diverges. The oracle establishes the cancellation
    // before any floating-point infinity is formed.
    const cancelled_hessian: f64 = 0;
    try comparison.spectral_hessian_zero_mode.expectCloseAt(
        0,
        cancelled_hessian,
        .{ .magnitude = 0 },
    );
}

fn zeroLinearValue(background: f64) !Complex64 {
    return (try evaluateKnownSpectrum(&.{background}, 1)).value;
}

fn zeroQuadraticValue(background: f64) !f64 {
    return (try evaluateKnownSpectrum(&.{background * background}, 1)).value.re;
}

test "zero-mode gradient and finite Hessian cancellation meet measured policies" {
    const gradient_step = std.math.cbrt(std.math.floatEps(f64));
    const coarse_positive = try zeroLinearValue(gradient_step);
    const coarse_negative = try zeroLinearValue(-gradient_step);
    const coarse_gradient = Complex64{
        .re = (coarse_positive.re - coarse_negative.re) /
            (2.0 * gradient_step),
        .im = (coarse_positive.im - coarse_negative.im) /
            (2.0 * gradient_step),
    };
    const refined_step = gradient_step / 2.0;
    const refined_positive = try zeroLinearValue(refined_step);
    const refined_negative = try zeroLinearValue(-refined_step);
    const refined_gradient = Complex64{
        .re = (refined_positive.re - refined_negative.re) /
            (2.0 * refined_step),
        .im = (refined_positive.im - refined_negative.im) /
            (2.0 * refined_step),
    };
    try comparison.spectral_gradient_zero_mode.expectCloseAt(
        0,
        refined_gradient.re,
        .{
            .magnitude = @abs(refined_gradient.re),
            .reference_error = @abs(refined_gradient.re - coarse_gradient.re) +
                std.math.floatEps(f64) *
                    (@abs(refined_positive.re) + @abs(refined_negative.re)) /
                    (2.0 * refined_step),
        },
    );
    try comparison.spectral_gradient_zero_mode.expectCloseAt(
        0,
        refined_gradient.im,
        .{
            .magnitude = @abs(refined_gradient.im),
            .reference_error = @abs(refined_gradient.im - coarse_gradient.im) +
                std.math.floatEps(f64) *
                    (@abs(refined_positive.im) + @abs(refined_negative.im)) /
                    (2.0 * refined_step),
        },
    );

    const hessian_step = @sqrt(@sqrt(std.math.floatEps(f64)));
    const center = try zeroQuadraticValue(0);
    const coarse_hessian =
        ((try zeroQuadraticValue(hessian_step)) - 2.0 * center +
            (try zeroQuadraticValue(-hessian_step))) /
        (hessian_step * hessian_step);
    const refined_hessian_step = hessian_step / 2.0;
    const refined_hessian_positive =
        try zeroQuadraticValue(refined_hessian_step);
    const refined_hessian_negative =
        try zeroQuadraticValue(-refined_hessian_step);
    const refined_hessian =
        (refined_hessian_positive - 2.0 * center +
            refined_hessian_negative) /
        (refined_hessian_step * refined_hessian_step);
    try comparison.spectral_hessian_zero_mode.expectCloseAt(
        0,
        refined_hessian,
        .{
            .magnitude = @abs(refined_hessian),
            .reference_error = @abs(refined_hessian - coarse_hessian) +
                std.math.floatEps(f64) *
                    (@abs(refined_hessian_positive) + 2.0 * @abs(center) +
                        @abs(refined_hessian_negative)) /
                    (refined_hessian_step * refined_hessian_step),
        },
    );
}

const SeededDefect = enum {
    wrong_constant,
    wrong_normalization,
    real_log_of_absolute_value,
    unsquared_scale,
    dropped_multiplicity,
    clipped_negative,
};

fn evaluateWithSeededDefect(
    defect: SeededDefect,
    eigenvalues: []const f64,
    renormalization_scale: f64,
) Complex64 {
    var result = Complex64{ .re = 0, .im = 0 };
    const count = if (defect == .dropped_multiplicity and eigenvalues.len > 0)
        1
    else
        eigenvalues.len;
    for (eigenvalues[0..count]) |input| {
        const eigenvalue = if (defect == .clipped_negative and input < 0)
            0
        else
            input;
        if (eigenvalue == 0) continue;

        const square = eigenvalue * eigenvalue;
        const scale_denominator = if (defect == .unsquared_scale)
            renormalization_scale
        else
            renormalization_scale * renormalization_scale;
        const constant: f64 = if (defect == .wrong_constant) 1 else 1.5;
        const normalization: f64 = if (defect == .wrong_normalization)
            32.0 * std.math.pi * std.math.pi
        else
            64.0 * std.math.pi * std.math.pi;
        result.re += square *
            (@log(@abs(eigenvalue) / scale_denominator) - constant) /
            normalization;
        if (eigenvalue < 0 and defect != .real_log_of_absolute_value) {
            result.im += square / (64.0 * std.math.pi);
        }
    }
    return result;
}

fn expectSeededValueDefectCaught(
    defect: SeededDefect,
    eigenvalues: []const f64,
    renormalization_scale: f64,
) !void {
    const expected = try evaluateKnownSpectrum(
        eigenvalues,
        renormalization_scale,
    );
    const defective = evaluateWithSeededDefect(
        defect,
        eigenvalues,
        renormalization_scale,
    );
    const real_agrees = comparison.spectral_value_known_spectrum.agreeAt(
        expected.value.re,
        defective.re,
        .{ .magnitude = expected.unsigned_scale.re },
    );
    const imaginary_agrees = comparison.spectral_value_known_spectrum.agreeAt(
        expected.value.im,
        defective.im,
        .{ .magnitude = expected.unsigned_scale.im },
    );
    try std.testing.expect(!real_agrees or !imaginary_agrees);
}

test "the prototype catches every seeded scalar-value defect" {
    try expectSeededValueDefectCaught(.wrong_constant, &.{1}, 1);
    try expectSeededValueDefectCaught(.wrong_normalization, &.{1}, 1);
    try expectSeededValueDefectCaught(.real_log_of_absolute_value, &.{-1}, 1);
    try expectSeededValueDefectCaught(.unsquared_scale, &.{3}, 2);
    try expectSeededValueDefectCaught(.dropped_multiplicity, &.{ 2, 2 }, 1);
    try expectSeededValueDefectCaught(.clipped_negative, &.{ -1, 4 }, 1);
}

fn invariantGradient(
    eigenvalues: []const f64,
    eigenvalue_derivatives: []const f64,
) f64 {
    std.debug.assert(eigenvalues.len == eigenvalue_derivatives.len);
    var result: f64 = 0;
    for (eigenvalues, eigenvalue_derivatives) |eigenvalue, derivative| {
        result += firstSpectralDerivative(eigenvalue, 1) * derivative;
    }
    return result;
}

test "the prototype catches ordering-dependent spectral derivatives" {
    const eigenvalues = [_]f64{ 1, 1 + near_degenerate_separation, 4 };
    const derivatives = [_]f64{ 1, -1, 0.5 };
    const expected = invariantGradient(&eigenvalues, &derivatives);
    const permuted = invariantGradient(
        &.{ 4, 1, 1 + near_degenerate_separation },
        &.{ 0.5, 1, -1 },
    );
    try comparison.spectral_gradient_near_degenerate.expectClose(
        expected,
        permuted,
    );

    // Seeded defect: differentiate only the first item in the eigensolver's
    // arbitrary output order. A phase-dependent eigenvector derivative has the
    // same forbidden symptom: an equivalent ordering or sign choice changes
    // the published derivative.
    const defective =
        firstSpectralDerivative(eigenvalues[0], 1) * derivatives[0];
    try std.testing.expect(
        !comparison.spectral_gradient_near_degenerate.agree(
            expected,
            defective,
        ),
    );
}

test "the prototype catches floating-point zero times infinity" {
    const infinity = std.math.inf(f64);
    const defective = @as(f64, 0) * infinity;
    try std.testing.expect(!std.math.isFinite(defective));
    try std.testing.expect(
        !comparison.spectral_hessian_zero_mode.agreeAt(
            0,
            defective,
            .{ .magnitude = 0 },
        ),
    );
}

test "the evaluator rejects invalid reference inputs explicitly" {
    try std.testing.expectError(
        error.InvalidScale,
        evaluateKnownSpectrum(&.{1}, 0),
    );
    try std.testing.expectError(
        error.InvalidScale,
        evaluateKnownSpectrum(&.{1}, std.math.inf(f64)),
    );
    try std.testing.expectError(
        error.NonFiniteEigenvalue,
        evaluateKnownSpectrum(&.{std.math.nan(f64)}, 1),
    );
}
