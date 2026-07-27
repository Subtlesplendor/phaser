//! The differential tier's leak check, in its own file so that it runs last.
//! See `test/conformance/leak_check.zig`.

const test_allocator = @import("test_allocator");

const tier = [_][]const u8{"finite_differences.test."};

test "no differential test leaked memory" {
    try test_allocator.expectChecksWholeTier(
        ".test.no differential test leaked memory",
        &tier,
    );
    try test_allocator.expectNoLeaks();
}
