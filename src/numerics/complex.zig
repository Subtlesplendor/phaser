//! The complex scalar shared by the numerical kernel and the numerical
//! algorithms it executes.
//!
//! It lives here rather than in the kernel because the invariant spectral
//! derivative operation produces complex results and must not depend on the
//! instruction program that calls it.

const std = @import("std");

pub const Scalar = f64;

/// A pair of IEEE binary64 components. This is a semantic type, not a stable C
/// layout.
///
/// The arithmetic is deliberately incomplete. Milestone 3 forms complex
/// quantities only as scalar one-loop coefficients, and every factor
/// multiplying such a coefficient is real, so there is no complex product,
/// quotient, or power here to fix an evaluation order for.
pub const Complex64 = struct {
    re: Scalar,
    im: Scalar,

    pub const zero = Complex64{ .re = 0, .im = 0 };

    pub fn add(self: Complex64, other: Complex64) Complex64 {
        return .{ .re = self.re + other.re, .im = self.im + other.im };
    }

    pub fn subtract(self: Complex64, other: Complex64) Complex64 {
        return .{ .re = self.re - other.re, .im = self.im - other.im };
    }

    pub fn negate(self: Complex64) Complex64 {
        return .{ .re = -self.re, .im = -self.im };
    }

    /// Component-wise product by a real factor.
    pub fn scale(self: Complex64, factor: Scalar) Complex64 {
        return .{ .re = self.re * factor, .im = self.im * factor };
    }

    /// Component-wise quotient by a real divisor.
    pub fn divide(self: Complex64, divisor: Scalar) Complex64 {
        return .{ .re = self.re / divisor, .im = self.im / divisor };
    }

    pub fn isFinite(self: Complex64) bool {
        return std.math.isFinite(self.re) and std.math.isFinite(self.im);
    }
};

// -- tests -----------------------------------------------------------------

test "real scaling and division are component-wise" {
    const z = Complex64{ .re = 3, .im = -4 };
    try std.testing.expectEqual(Complex64{ .re = 6, .im = -8 }, z.scale(2));
    try std.testing.expectEqual(Complex64{ .re = 1.5, .im = -2 }, z.divide(2));
}

// Negating both operands of a quotient leaves it bitwise unchanged, which is
// what makes a divided difference symmetric in its two endpoints without
// anyone copying one orientation onto the other.
test "a quotient is invariant under negating numerator and denominator" {
    const numerator = Complex64{ .re = 0x1.23456789abcdep-3, .im = -0x1.fedcba9876543p-7 };
    const denominator: Scalar = 0x1.5555555555555p-11;
    try std.testing.expectEqual(
        numerator.divide(denominator),
        numerator.negate().divide(-denominator),
    );
}

test "finiteness covers both components" {
    try std.testing.expect((Complex64{ .re = 1, .im = 2 }).isFinite());
    try std.testing.expect(!(Complex64{ .re = 1, .im = std.math.inf(Scalar) }).isFinite());
    try std.testing.expect(!(Complex64{ .re = std.math.nan(Scalar), .im = 0 }).isFinite());
}
