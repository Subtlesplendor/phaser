//! The conformance tier's leak check, in its own file so that it runs last.
//!
//! See `expectChecksWholeTier` for why this cannot live at the bottom of
//! `root.zig`, and `test/support/allocator.zig` for what it checks and when.

const test_allocator = @import("test_allocator");

const tier = [_][]const u8{
    "scalar_one_loop.test.",
    "classical_scalar.test.",
    "one_loop_artifact.test.",
    "one_loop_kernel.test.",
    "potential_kernel.test.",
    "parameter_binding.test.",
};

test "no conformance test leaked memory" {
    try test_allocator.expectChecksWholeTier(
        ".test.no conformance test leaked memory",
        &tier,
    );
    try test_allocator.expectNoLeaks();
}
