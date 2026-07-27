test {
    _ = @import("scalar_one_loop.zig");
    _ = @import("classical_scalar.zig");
    _ = @import("one_loop_artifact.zig");
    _ = @import("one_loop_kernel.zig");
    _ = @import("potential_kernel.zig");
    _ = @import("parameter_binding.zig");
    // Last, so its check runs after every test above. `leak_check.zig` asserts
    // that placement, so an import added below it fails rather than quietly
    // moving the check earlier.
    _ = @import("leak_check.zig");
}
