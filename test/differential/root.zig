test {
    _ = @import("finite_differences.zig");
    _ = @import("abi_agreement.zig");
    // Last; see `test/conformance/root.zig`.
    _ = @import("leak_check.zig");
}
