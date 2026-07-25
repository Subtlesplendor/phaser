const std = @import("std");
const foundation = @import("phaser").foundation;

test "foundation_capacity" {
    try std.testing.fuzz({}, fuzzCapacity, .{
        .corpus = &.{
            @embedFile("../corpus/foundation_capacity/seed.txt"),
        },
    });
}

fn fuzzCapacity(_: void, smith: *std.testing.Smith) !void {
    const lhs: usize = @truncate(smith.value(u64));
    const rhs: usize = @truncate(smith.value(u64));

    const add_result = foundation.ByteSize.init(lhs).add(
        .init(rhs),
        .workspace_bytes,
    );
    const exact_sum = @as(u128, lhs) + @as(u128, rhs);
    if (exact_sum <= std.math.maxInt(usize)) {
        switch (add_result) {
            .value => |value| try std.testing.expectEqual(
                @as(usize, @intCast(exact_sum)),
                value.value,
            ),
            .failure => return error.TestUnexpectedResult,
        }
    } else {
        switch (add_result) {
            .value => return error.TestUnexpectedResult,
            .failure => |failure| try std.testing.expectEqual(
                foundation.Code.capacity_overflow,
                failure.code,
            ),
        }
    }

    const multiply_result = foundation.ByteSize.init(lhs).multiply(
        rhs,
        .workspace_bytes,
    );
    const exact_product = @as(u128, lhs) * @as(u128, rhs);
    if (exact_product <= std.math.maxInt(usize)) {
        switch (multiply_result) {
            .value => |value| try std.testing.expectEqual(
                @as(usize, @intCast(exact_product)),
                value.value,
            ),
            .failure => return error.TestUnexpectedResult,
        }
    } else {
        switch (multiply_result) {
            .value => return error.TestUnexpectedResult,
            .failure => |failure| try std.testing.expectEqual(
                foundation.Code.capacity_overflow,
                failure.code,
            ),
        }
    }

    const exponent = smith.valueRangeLessThan(
        u7,
        0,
        @bitSizeOf(usize),
    );
    const alignment = @as(usize, 1) << @intCast(exponent);
    const aligned_result = foundation.ByteSize.init(lhs).alignForward(
        alignment,
        .workspace_bytes,
    );
    const exact_aligned = (@as(u128, lhs) + alignment - 1) &
        ~(@as(u128, alignment) - 1);
    if (exact_aligned <= std.math.maxInt(usize)) {
        switch (aligned_result) {
            .value => |value| try std.testing.expectEqual(
                @as(usize, @intCast(exact_aligned)),
                value.value,
            ),
            .failure => return error.TestUnexpectedResult,
        }
    } else {
        switch (aligned_result) {
            .value => return error.TestUnexpectedResult,
            .failure => |failure| try std.testing.expectEqual(
                foundation.Code.capacity_overflow,
                failure.code,
            ),
        }
    }

    const limit: usize = smith.value(u32);
    const initial: usize = if (limit == 0)
        0
    else
        smith.value(u32) % (limit + 1);
    const requested: usize = smith.value(u32);

    var budget = foundation.Budget.init(.scratch_bytes, limit);
    try std.testing.expectEqual(
        foundation.Reservation.committed,
        budget.reserve(initial),
    );
    const old_current = budget.current;
    const old_peak = budget.peak;
    const reservation = budget.reserve(requested);
    const exact_usage = @as(u64, initial) + requested;
    if (exact_usage <= limit) {
        try std.testing.expectEqual(
            foundation.Reservation.committed,
            reservation,
        );
        try std.testing.expectEqual(
            @as(usize, @intCast(exact_usage)),
            budget.current,
        );
    } else {
        switch (reservation) {
            .committed => return error.TestUnexpectedResult,
            .rejected => |failure| try std.testing.expectEqual(
                foundation.Code.capacity_exceeded,
                failure.code,
            ),
        }
        try std.testing.expectEqual(old_current, budget.current);
        try std.testing.expectEqual(old_peak, budget.peak);
    }
}
