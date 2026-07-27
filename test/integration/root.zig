test {
    _ = @import("model_loading.zig");
    _ = @import("value_graph.zig");
    _ = @import("symbolic_export.zig");
    _ = @import("cli_examples.zig");
    // Last; see `test/conformance/root.zig`.
    _ = @import("leak_check.zig");
}
