//! The fuzz target names, shared by everything that has to agree on them.
//!
//! Three consumers need this list and must not drift apart: `build.zig`
//! declares one filtered run per target, `tools/corpus` locates each target's
//! generated corpus in the build cache, and the targets themselves are declared
//! in `root.zig`. A guard test there fails if a target is added, removed, or
//! renamed without updating this file.

/// One entry per `test "<name>"` in `root.zig`.
pub const names = [_][]const u8{
    "foundation_capacity",
    "expression_parser",
    "scalar_model_parser",
    "value_ir_builder",
    "calculation_request_parser",
    "symbolic_exporter",
    "kernel_lowering",
    "parameter_point_parser",
};

/// The prefix the test binary gives every target.
///
/// The fuzz module's root file is `test/fuzz.zig`, which imports
/// `fuzz/root.zig`, so a target declared as `test "expression_parser"` is named
/// `fuzz.root.test.expression_parser`. The toolchain derives a target's cache
/// directory from that full name, so the corpus tool needs it to find anything;
/// a rename would silently move the directory, which is why the guard test
/// checks this prefix against the names the test runner reports.
pub const test_name_prefix = "fuzz.root.test.";
