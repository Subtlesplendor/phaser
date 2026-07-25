const std = @import("std");
const foundation = @import("../foundation/root.zig");

pub const HardLimits = struct {
    pub const value_nodes: usize = 1024 * 1024;
    pub const value_operands: usize = 64 * 1024;
    pub const exponent_magnitude: usize = 1024;
    pub const exact_integer_bits: usize = 1024 * 1024;
};

pub const ValueLimits = struct {
    value_nodes: usize = 128 * 1024,
    value_operands: usize = 4096,
    exponent_magnitude: usize = 64,
    exact_integer_bits: usize = 16 * 1024,

    pub fn validate(self: ValueLimits) ?foundation.Diagnostic {
        inline for (@typeInfo(ValueLimits).@"struct".fields) |field| {
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

test "standard value limits validate" {
    try std.testing.expectEqual(
        @as(?foundation.Diagnostic, null),
        (ValueLimits{}).validate(),
    );
}

test "every value limit checks zero exact and one-over boundaries" {
    inline for (@typeInfo(ValueLimits).@"struct".fields) |field| {
        var limits = ValueLimits{};
        @field(limits, field.name) = 0;
        try std.testing.expectEqual(
            foundation.Code.invalid_limit,
            limits.validate().?.code,
        );

        limits = .{};
        @field(limits, field.name) = @field(HardLimits, field.name);
        try std.testing.expectEqual(
            @as(?foundation.Diagnostic, null),
            limits.validate(),
        );

        @field(limits, field.name) = @field(HardLimits, field.name) + 1;
        try std.testing.expectEqual(
            foundation.Code.invalid_limit,
            limits.validate().?.code,
        );
    }
}
