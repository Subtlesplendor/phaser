const foundation = @import("../foundation/root.zig");

pub const HardLimits = struct {
    pub const source_bytes: usize = 16 * 1024 * 1024;
    pub const json_nesting: usize = 128;
    pub const json_tokens: usize = 1024 * 1024;
    pub const parameters: usize = 4096;
    pub const real_scalars: usize = 4096;
    pub const tensor_components: usize = 1024 * 1024;
    pub const expression_bytes: usize = 64 * 1024;
    pub const expression_tokens: usize = 16 * 1024;
    pub const expression_nodes: usize = 16 * 1024;
    pub const expression_depth: usize = 256;
    pub const integer_digits: usize = 4096;
    pub const exponent_magnitude: usize = 1024;
    pub const exact_integer_bits: usize = 1024 * 1024;
    pub const value_nodes: usize = 1024 * 1024;
    pub const scratch_bytes: usize = 256 * 1024 * 1024;
    pub const persistent_bytes: usize = 512 * 1024 * 1024;
};

pub const ModelLimits = struct {
    source_bytes: usize = 1024 * 1024,
    json_nesting: usize = 64,
    json_tokens: usize = 128 * 1024,
    parameters: usize = 512,
    real_scalars: usize = 512,
    tensor_components: usize = 64 * 1024,
    expression_bytes: usize = 8 * 1024,
    expression_tokens: usize = 2048,
    expression_nodes: usize = 2048,
    expression_depth: usize = 64,
    integer_digits: usize = 256,
    exponent_magnitude: usize = 64,
    exact_integer_bits: usize = 16 * 1024,
    value_nodes: usize = 128 * 1024,
    scratch_bytes: usize = 32 * 1024 * 1024,
    persistent_bytes: usize = 64 * 1024 * 1024,

    pub fn validate(self: ModelLimits) ?foundation.Diagnostic {
        inline for (@typeInfo(ModelLimits).@"struct".fields) |field| {
            const value = @field(self, field.name);
            const hard = @field(HardLimits, field.name);
            if (value == 0 or value > hard) {
                return .{
                    .code = .invalid_limit,
                    .category = .configuration,
                    .detail = .{ .invalid_limit = .{
                        .name = @field(foundation.LimitName, field.name),
                        .value = value,
                    } },
                };
            }
        }
        return null;
    }
};

test "standard model limits validate" {
    try @import("std").testing.expectEqual(
        @as(?foundation.Diagnostic, null),
        (ModelLimits{}).validate(),
    );
}

test "every model limit checks zero exact and one-over boundaries" {
    inline for (@typeInfo(ModelLimits).@"struct".fields) |field| {
        var limits = ModelLimits{};
        @field(limits, field.name) = 0;
        try @import("std").testing.expectEqual(
            foundation.Code.invalid_limit,
            limits.validate().?.code,
        );

        limits = .{};
        @field(limits, field.name) = @field(HardLimits, field.name);
        try @import("std").testing.expectEqual(
            @as(?foundation.Diagnostic, null),
            limits.validate(),
        );

        @field(limits, field.name) = @field(HardLimits, field.name) + 1;
        try @import("std").testing.expectEqual(
            foundation.Code.invalid_limit,
            limits.validate().?.code,
        );
    }
}
