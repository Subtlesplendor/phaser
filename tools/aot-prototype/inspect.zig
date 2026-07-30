//! Stable symbol used only to inspect the prototype's generated machine code.

const generated = @import("generated_aot");

export fn phaser_aot_phi4_batch(
    bound: *const generated.Bound,
    backgrounds: [*]const f64,
    point_count: usize,
    values: [*]f64,
    statuses: [*]generated.Status,
) bool {
    var workspace: [0]u8 = .{};
    generated.evaluateBatch(
        bound,
        backgrounds[0..point_count],
        point_count,
        &workspace,
        values[0..point_count],
        statuses[0..point_count],
    ) catch return false;
    return true;
}
