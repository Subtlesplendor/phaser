//! Domain-independent numerical algorithms.
//!
//! This subsystem is internal. Public scientific APIs consume its algorithms
//! through validated kernel operations rather than exposing numerical
//! implementation details as scientific identities.

pub const complex = @import("complex.zig");
pub const symmetric_eigensolver = @import("symmetric_eigensolver.zig");
pub const spectral_derivative = @import("spectral_derivative.zig");

test {
    _ = complex;
    _ = symmetric_eigensolver;
    _ = spectral_derivative;
}
