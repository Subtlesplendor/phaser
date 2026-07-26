//! Phaser-owned boundary around the vendored Tripwire dependency.
//!
//! Production modules import this file rather than the vendor source directly,
//! so replacing the dependency does not spread a third-party interface through
//! the repository. Declared modules are enabled only in Zig test builds and
//! compile to no-ops in every production build.

const tripwire = @import("vendor/tripwire.zig");

pub const module = tripwire.module;
