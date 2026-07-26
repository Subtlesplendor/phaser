//! Executable mirror of Phaser's numerical-comparison policies.
//!
//! `docs/architecture/NUMERICAL_COMPARISON.md` is the normative catalog. This
//! module carries the numerical fields of each policy so that a test names the
//! policy it appeals to instead of holding its own separately editable literal.
//! The remaining fields the verification specification requires — reference
//! precision, expected conditioning, treatment of special values, permitted
//! point statuses, and branch policy — are prose. They live in that document and
//! are summarized in each constant's doc comment here.
//!
//! One deliberate omission remains. No cataloged policy declares a ULP bound,
//! so `Policy` has no ULP field; it gains one with the first policy that needs
//! one rather than carrying a field with no agreed meaning.
//!
//! Comparisons are on `f64`, which is the kernel's version 0.1 scalar type.

const std = @import("std");

/// What a comparison knows about its own conditioning.
///
/// The magnitude a relative tolerance applies to is a property of the compared
/// quantity, not of the two numbers being compared. For a sum that cancels, the
/// rounding a reordering can introduce is bounded by the sum of the terms'
/// magnitudes, which may be many orders of magnitude above the total. For a
/// finite-difference oracle, the reference carries its own roundoff error from
/// the function values it cancelled. A comparison that knows either quantity
/// supplies it here; one that does not falls back to the compared magnitudes.
pub const Scale = struct {
    /// Magnitude the relative tolerance applies to.
    magnitude: f64 = 0,
    /// Absolute error carried by the reference side of the comparison.
    ///
    /// Zero when neither side is an approximate reference, which is the case
    /// whenever both sides are Phaser evaluations of the same exact quantity.
    reference_error: f64 = 0,
};

/// An approximate comparison policy.
///
/// The rule is
///
///     |expected - actual| <= absolute
///                          + relative * scale.magnitude
///                          + reference_error_multiple * scale.reference_error
///
/// with two exceptions. Numbers that are equal compare equal, which covers
/// identical infinities and the two signed zeros. A non-finite value otherwise
/// never satisfies an approximate policy: a point that produces one fails its
/// status check first, and `non_finite` is a point-level outcome rather than a
/// number to compare.
pub const Policy = struct {
    /// Name this policy carries in `NUMERICAL_COMPARISON.md`.
    name: []const u8,
    absolute: f64 = 0,
    relative: f64 = 0,
    /// Multiple of the reference's own error bar this policy permits.
    reference_error_multiple: f64 = 0,

    /// Largest difference this policy permits at `scale`.
    pub fn permitted(self: Policy, scale: Scale) f64 {
        return self.absolute +
            self.relative * scale.magnitude +
            self.reference_error_multiple * scale.reference_error;
    }

    pub fn agreeAt(self: Policy, expected: f64, actual: f64, scale: Scale) bool {
        if (expected == actual) return true;
        if (!std.math.isFinite(expected) or !std.math.isFinite(actual)) return false;
        return @abs(expected - actual) <= self.permitted(scale);
    }

    /// Compares at the magnitude of the two values themselves.
    ///
    /// Correct only where that magnitude is representative of the terms that
    /// produced it. A caller comparing a quantity formed by cancellation, or
    /// against an approximate reference, uses `agreeAt` with the conditioning
    /// its policy entry declares.
    pub fn agree(self: Policy, expected: f64, actual: f64) bool {
        return self.agreeAt(expected, actual, .{
            .magnitude = @max(@abs(expected), @abs(actual)),
        });
    }

    pub fn expectCloseAt(
        self: Policy,
        expected: f64,
        actual: f64,
        scale: Scale,
    ) !void {
        if (self.agreeAt(expected, actual, scale)) return;
        std.debug.print(
            \\
            \\numerical comparison policy rejected a pair
            \\  policy          {s}
            \\  expected        {e}
            \\  actual          {e}
            \\  difference      {e}
            \\  permitted       {e}
            \\  magnitude       {e}
            \\  reference_error {e}
            \\
        , .{
            self.name,
            expected,
            actual,
            @abs(expected - actual),
            self.permitted(scale),
            scale.magnitude,
            scale.reference_error,
        });
        return error.NumericalPolicyViolated;
    }

    pub fn expectClose(self: Policy, expected: f64, actual: f64) !void {
        return self.expectCloseAt(expected, actual, .{
            .magnitude = @max(@abs(expected), @abs(actual)),
        });
    }
};

/// An exact comparison policy.
///
/// Bitwise rather than arithmetic equality, so that the two signed zeros are
/// distinguished and two identical NaN payloads agree. Where a reproducibility
/// contract promises identical results, that is the promise being tested.
pub const Exact = struct {
    /// Name this policy carries in `NUMERICAL_COMPARISON.md`.
    name: []const u8,

    pub fn agree(_: Exact, expected: f64, actual: f64) bool {
        return @as(u64, @bitCast(expected)) == @as(u64, @bitCast(actual));
    }

    pub fn expectEqual(self: Exact, expected: f64, actual: f64) !void {
        if (self.agree(expected, actual)) return;
        std.debug.print(
            \\
            \\exact comparison policy rejected a pair
            \\  policy   {s}
            \\  expected {e} (0x{X:0>16})
            \\  actual   {e} (0x{X:0>16})
            \\
        , .{
            self.name,
            expected,
            @as(u64, @bitCast(expected)),
            actual,
            @as(u64, @bitCast(actual)),
        });
        return error.NotBitwiseIdentical;
    }

    pub fn expectEqualSlices(
        self: Exact,
        expected: []const f64,
        actual: []const f64,
    ) !void {
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |left, right| {
            try self.expectEqual(left, right);
        }
    }
};

/// Repeated execution of one kernel object, and the operations the kernel
/// contract promises are indistinguishable from it.
///
/// Covers scalar against batch, any batch partition or permutation, staged
/// against unstaged binding, an object that has been moved, and a fresh binding
/// of the same kernel to the same parameter point. Statuses are compared exactly
/// alongside the values.
///
/// Not an approximate policy. It is cataloged so that a test naming it says
/// which contract it is testing rather than reading as an unexplained strict
/// comparison.
pub const same_kernel_bitwise = Exact{ .name = "same_kernel_bitwise" };

/// Two evaluations of one mathematical quantity whose canonical accumulation
/// order differs.
///
/// Field relabelling, coordinate permutation, a supported basis transformation,
/// and dropping a term bound to exactly zero all leave the exact result
/// unchanged while changing the order in which the kernel sums it. Floating-point
/// addition is not associative, so the two agree to rounding of the sum.
///
/// The relative tolerance applies to the sum of the terms' magnitudes, which is
/// what bounds that rounding, and the caller supplies it. Applying it to the
/// magnitude of the result instead would assert a bound the arithmetic does not
/// obey wherever the sum cancels.
///
/// Conditioning: any point. Statuses must be equal and `ok`. Reference
/// precision: none; both sides are `f64` Phaser evaluations and the comparison
/// is symmetric. Branch policy: not applicable while results are real.
pub const reordered_value_well_conditioned = Policy{
    .name = "reordered_value_well_conditioned",
    .relative = 1e-14,
};

/// An exact gradient component against a central first difference of the same
/// kernel's values.
///
/// The reference is the inexact side. Its error is a truncation term that grows
/// as the square of the step and a roundoff term that grows as its inverse,
/// which is why the step is the cube root of the machine epsilon. The relative
/// tolerance covers truncation; the reference-error term covers the roundoff
/// the difference quotient inherits from cancelling two nearby values.
///
/// Conditioning: points where the derivative is not small compared with the
/// magnitudes differenced to produce it. A stationary point is outside this
/// policy, as is a degenerate one. Reference precision: `f64` central
/// difference, reporting its own roundoff floor. Statuses must be `ok`.
pub const finite_difference_gradient_well_conditioned = Policy{
    .name = "finite_difference_gradient_well_conditioned",
    .relative = 1e-8,
    .reference_error_multiple = 10,
};

/// An exact Hessian entry against a central second difference of the same
/// kernel's values.
///
/// As for the gradient, with the fourth root of the machine epsilon as the step:
/// a second difference divides by the square of the step, so its roundoff grows
/// as the inverse square and the balance moves. That leaves the reference four
/// orders of magnitude less accurate than the first-difference one, which is why
/// this policy is separate rather than shared.
///
/// Conditioning, reference precision, and statuses as for the gradient policy.
pub const finite_difference_hessian_well_conditioned = Policy{
    .name = "finite_difference_hessian_well_conditioned",
    .relative = 1e-7,
    .reference_error_multiple = 10,
};

/// A complex scalar one-loop value against the direct evaluator over an
/// analytically known eigenvalue multiset.
///
/// Real and imaginary components are compared separately. The caller supplies
/// the component's unsigned contribution sum as its magnitude, so cancellation
/// between spectral terms does not make the comparison artificially strict.
/// Reference precision: Zig `f64` and `@log`. Statuses must be `ok`; the
/// principal branch is required.
pub const spectral_value_known_spectrum = Policy{
    .name = "spectral_value_known_spectrum",
    .relative = 5e-15,
};

/// A one-loop value at the measured near-degenerate spectrum.
///
/// The unsigned contribution sum is the comparison magnitude. Reference
/// precision, statuses, complex treatment, and branch are as for
/// `spectral_value_known_spectrum`.
pub const spectral_value_near_degenerate = Policy{
    .name = "spectral_value_near_degenerate",
    .relative = 1e-14,
};

/// A one-loop gradient at the measured near-degenerate spectrum.
///
/// The reference is an `f64` central difference and reports its inherited
/// roundoff. Both the analytic and sampled points must have `ok` status.
pub const spectral_gradient_near_degenerate = Policy{
    .name = "spectral_gradient_near_degenerate",
    .relative = 2e-8,
    .reference_error_multiple = 10,
};

/// A one-loop Hessian at the measured near-degenerate spectrum.
///
/// As for the gradient, using a central second difference and its separately
/// reported roundoff. The looser relative bound reflects the second
/// difference's greater cancellation.
pub const spectral_hessian_near_degenerate = Policy{
    .name = "spectral_hessian_near_degenerate",
    .relative = 2e-6,
    .reference_error_multiple = 10,
};

/// A one-loop value with an exact zero eigenvalue.
///
/// The zero contribution is established analytically before evaluating a
/// logarithm. Other contributions use their unsigned sum as the magnitude.
/// Status must be `ok`.
pub const spectral_value_zero_mode = Policy{
    .name = "spectral_value_zero_mode",
    .relative = 5e-15,
};

/// A one-loop gradient with an exact zero eigenvalue.
///
/// The finite first-derivative limit is zero. Finite-difference references use
/// coarse-to-fine variation plus inherited roundoff as their error estimate;
/// status must be `ok`.
pub const spectral_gradient_zero_mode = Policy{
    .name = "spectral_gradient_zero_mode",
    .relative = 2e-8,
    .reference_error_multiple = 10,
};

/// A one-loop Hessian whose spectrum contains an exact zero.
///
/// Status is compared first and may be `ok` only for an analytically
/// established finite cancellation, or `singular_derivative` when a required
/// term diverges. A finite-difference reference uses coarse-to-fine variation
/// plus inherited roundoff as its error estimate. Numbers are compared only for
/// the `ok` case.
pub const spectral_hessian_zero_mode = Policy{
    .name = "spectral_hessian_zero_mode",
    .relative = 2e-6,
    .reference_error_multiple = 10,
};

test "the catalog carries the bounds recorded in the specification" {
    try std.testing.expectEqual(
        @as(f64, 1e-14),
        reordered_value_well_conditioned.relative,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        reordered_value_well_conditioned.reference_error_multiple,
    );
    try std.testing.expectEqual(
        @as(f64, 1e-8),
        finite_difference_gradient_well_conditioned.relative,
    );
    try std.testing.expectEqual(
        @as(f64, 1e-7),
        finite_difference_hessian_well_conditioned.relative,
    );
    try std.testing.expectEqual(
        @as(f64, 5e-15),
        spectral_value_known_spectrum.relative,
    );
    try std.testing.expectEqual(
        @as(f64, 1e-14),
        spectral_value_near_degenerate.relative,
    );
    try std.testing.expectEqual(
        @as(f64, 2e-8),
        spectral_gradient_near_degenerate.relative,
    );
    try std.testing.expectEqual(
        @as(f64, 2e-6),
        spectral_hessian_near_degenerate.relative,
    );
    try std.testing.expectEqual(
        @as(f64, 5e-15),
        spectral_value_zero_mode.relative,
    );
    for ([_]Policy{
        reordered_value_well_conditioned,
        finite_difference_gradient_well_conditioned,
        finite_difference_hessian_well_conditioned,
        spectral_value_known_spectrum,
        spectral_value_near_degenerate,
        spectral_gradient_near_degenerate,
        spectral_hessian_near_degenerate,
        spectral_value_zero_mode,
        spectral_gradient_zero_mode,
        spectral_hessian_zero_mode,
    }) |policy| {
        // Every policy is keyed by a name that appears in the catalog, and none
        // declares an absolute tolerance: each is scale-aware instead.
        try std.testing.expect(policy.name.len > 0);
        try std.testing.expectEqual(@as(f64, 0), policy.absolute);
    }
}

test "a policy applies its relative tolerance to the supplied magnitude" {
    const policy = Policy{ .name = "test", .relative = 1e-12 };

    // A cancelled result: the difference is far outside a relative bound on the
    // result and well inside one on the terms that produced it.
    try std.testing.expect(!policy.agree(1.0, 1.0 + 1e-6));
    try std.testing.expect(policy.agreeAt(1.0, 1.0 + 1e-6, .{ .magnitude = 1e9 }));
}

test "a policy permits a stated multiple of the reference's own error" {
    const policy = Policy{
        .name = "test",
        .relative = 1e-12,
        .reference_error_multiple = 10,
    };
    const scale = Scale{ .magnitude = 1.0, .reference_error = 1e-6 };

    try std.testing.expectEqual(@as(f64, 1e-12 + 1e-5), policy.permitted(scale));
    try std.testing.expect(policy.agreeAt(1.0, 1.0 + 9e-6, scale));
    try std.testing.expect(!policy.agreeAt(1.0, 1.0 + 2e-5, scale));

    // Without the reference term the same pair is rejected, so the term is
    // doing the work rather than being absorbed by the relative tolerance.
    const strict = Policy{ .name = "test", .relative = 1e-12 };
    try std.testing.expect(!strict.agreeAt(1.0, 1.0 + 9e-6, scale));
}

test "identical values agree and other non-finite values never do" {
    const policy = Policy{ .name = "test", .relative = 1e-12 };
    const infinity = std.math.inf(f64);
    const nan = std.math.nan(f64);

    try std.testing.expect(policy.agree(infinity, infinity));
    try std.testing.expect(!policy.agree(infinity, -infinity));
    try std.testing.expect(!policy.agree(infinity, 1.0));
    try std.testing.expect(!policy.agree(nan, nan));
    try std.testing.expect(!policy.agree(nan, 0.0));

    // A zero result is compared exactly unless a policy declares an absolute
    // tolerance, and the signed zeros are equal under an approximate policy.
    try std.testing.expect(policy.agree(0.0, -0.0));
    try std.testing.expect(!policy.agree(0.0, 1e-300));
}

test "the exact policy separates the signed zeros and joins identical NaNs" {
    const nan = std.math.nan(f64);

    try std.testing.expect(same_kernel_bitwise.agree(1.5, 1.5));
    try std.testing.expect(!same_kernel_bitwise.agree(0.0, -0.0));
    try std.testing.expect(same_kernel_bitwise.agree(nan, nan));
    try same_kernel_bitwise.expectEqualSlices(&.{ 1.0, -0.0 }, &.{ 1.0, -0.0 });
}

// The rejecting branch of each `expect` wrapper is deliberately not exercised
// here. It writes its report to the streams the Zig build and test runners use
// for coordination, which `ENGINEERING_STYLE.md` reserves for them, and a
// passing test that writes there makes the run itself fail. The decision the
// wrappers delegate to is covered above; what remains untested is that an
// agreeing pair returns without an error, which is asserted here.
test "an agreeing pair passes the expectation wrappers" {
    const policy = Policy{ .name = "test", .relative = 1e-12 };
    try policy.expectClose(1.0, 1.0 + 1e-15);
    try policy.expectCloseAt(1.0, 1.0 + 1e-6, .{ .magnitude = 1e9 });
    try same_kernel_bitwise.expectEqual(1.5, 1.5);
}
