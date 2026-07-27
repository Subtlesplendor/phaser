//! Domain-independent numerical algorithms.
//!
//! This subsystem is internal. Public scientific APIs consume its algorithms
//! through validated kernel operations rather than exposing numerical
//! implementation details as scientific identities.

pub const symmetric_eigensolver = @import("symmetric_eigensolver.zig");

test {
    _ = symmetric_eigensolver;
}
