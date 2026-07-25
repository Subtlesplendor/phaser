const std = @import("std");

pub fn TypedId(comptime semantic_name: []const u8) type {
    return enum(u32) {
        _,

        pub const name = semantic_name;

        pub fn fromU64(value: u64) error{Overflow}!@This() {
            const narrowed = std.math.cast(u32, value) orelse return error.Overflow;
            return @enumFromInt(narrowed);
        }

        pub fn fromUsize(value: usize) error{Overflow}!@This() {
            return fromU64(value);
        }

        pub fn toU32(self: @This()) u32 {
            return @intFromEnum(self);
        }

        pub fn toUsize(self: @This()) usize {
            return @intFromEnum(self);
        }
    };
}

pub const SourceId = TypedId("source");

test "typed identifiers are distinct and round trip" {
    const ScalarId = TypedId("scalar");
    const ParameterId = TypedId("parameter");

    try std.testing.expect(ScalarId != ParameterId);

    const scalar = try ScalarId.fromUsize(17);
    try std.testing.expectEqual(@as(u32, 17), scalar.toU32());
    try std.testing.expectEqual(@as(usize, 17), scalar.toUsize());
}

test "typed identifier conversion rejects overflow" {
    const ValueId = TypedId("value");
    try std.testing.expectError(
        error.Overflow,
        ValueId.fromU64(@as(u64, std.math.maxInt(u32)) + 1),
    );
}
