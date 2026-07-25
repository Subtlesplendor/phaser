const std = @import("std");
const foundation = @import("../foundation/root.zig");

pub const HardLimits = struct {
    pub const request_bytes: usize = 1024 * 1024;
    pub const request_json_tokens: usize = 64 * 1024;
    pub const request_json_nesting: usize = 64;
    pub const background_coordinates: usize = 4096;
    pub const contributions: usize = 1024;
};

pub const CalculationLimits = struct {
    request_bytes: usize = 64 * 1024,
    request_json_tokens: usize = 4096,
    request_json_nesting: usize = 16,
    background_coordinates: usize = 512,
    contributions: usize = 64,

    pub fn validate(self: CalculationLimits) ?foundation.Diagnostic {
        inline for (@typeInfo(CalculationLimits).@"struct".fields) |field| {
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

test "standard calculation limits validate" {
    try std.testing.expectEqual(
        @as(?foundation.Diagnostic, null),
        (CalculationLimits{}).validate(),
    );
}

test "every calculation limit checks zero exact and one-over boundaries" {
    inline for (@typeInfo(CalculationLimits).@"struct".fields) |field| {
        var limits = CalculationLimits{};
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
