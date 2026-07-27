//! The integration tier's leak check, in its own file so that it runs last.
//! See `test/conformance/leak_check.zig`.

const test_allocator = @import("test_allocator");

const tier = [_][]const u8{
    "model_loading.test.",
    "value_graph.test.",
    "symbolic_export.test.",
    "cli_examples.test.",
};

test "no integration test leaked memory" {
    try test_allocator.expectChecksWholeTier(
        ".test.no integration test leaked memory",
        &tier,
    );
    try test_allocator.expectNoLeaks();
}
