//! Benchmark-only module root for internal numerical leaves.
//!
//! Production does not import or re-export this namespace. Its location gives
//! the benchmark module the same `src/` module path as Phaser, so the numerical
//! implementation can keep its existing private imports without widening the
//! supported Zig API.

const numerics = @import("numerics/root.zig");

pub const complex = numerics.complex;
pub const symmetric_eigensolver = numerics.symmetric_eigensolver;
pub const spectral_derivative = numerics.spectral_derivative;
