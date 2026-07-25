const std = @import("std");
const foundation = @import("phaser").foundation;

const max_sequence_length = 64;

const Operation = enum(u3) {
    add,
    multiply,
    align_forward,
    reserve,
    release,
};

test "foundation_capacity" {
    try std.testing.fuzz({}, fuzzCapacity, .{
        .corpus = &.{
            @embedFile("../corpus/foundation_capacity/seed.txt"),
            @embedFile("../corpus/foundation_capacity/zero.txt"),
            @embedFile("../corpus/foundation_capacity/exact-limit.txt"),
            @embedFile("../corpus/foundation_capacity/one-over.txt"),
            @embedFile("../corpus/foundation_capacity/overflow.txt"),
            @embedFile("../corpus/foundation_capacity/invalid-alignment.txt"),
            @embedFile("../corpus/foundation_capacity/repeated-rejection.txt"),
        },
    });
}

fn fuzzCapacity(_: void, smith: *std.testing.Smith) !void {
    var arithmetic: usize = @truncate(smith.value(u64));
    const limit: usize = @truncate(smith.value(u64));
    var budget = foundation.Budget.init(.scratch_bytes, limit);
    var oracle_current: u128 = 0;
    var oracle_peak: u128 = 0;

    const operation_count = smith.valueRangeLessThan(
        u8,
        1,
        max_sequence_length + 1,
    );
    for (0..operation_count) |_| {
        const operation: Operation = @enumFromInt(
            smith.valueRangeLessThan(u3, 0, 5),
        );
        switch (operation) {
            .add => try fuzzAdd(smith, &arithmetic),
            .multiply => try fuzzMultiply(smith, &arithmetic),
            .align_forward => try fuzzAlignment(smith, &arithmetic),
            .reserve => try fuzzReservation(
                smith,
                &budget,
                &oracle_current,
                &oracle_peak,
            ),
            .release => fuzzRelease(
                smith,
                &budget,
                &oracle_current,
                oracle_peak,
            ),
        }

        try std.testing.expectEqual(
            @as(usize, @intCast(oracle_current)),
            budget.current,
        );
        try std.testing.expectEqual(
            @as(usize, @intCast(oracle_peak)),
            budget.peak,
        );
    }
}

fn fuzzAdd(smith: *std.testing.Smith, state: *usize) !void {
    const old_state = state.*;
    const remaining = std.math.maxInt(usize) - old_state;
    const rhs = boundaryValue(smith, remaining);
    const result = foundation.ByteSize.init(old_state).add(
        .init(rhs),
        .workspace_bytes,
    );
    const exact = @as(u128, old_state) + rhs;

    if (exact <= std.math.maxInt(usize)) {
        switch (result) {
            .value => |value| state.* = value.value,
            .failure => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, @intCast(exact)), state.*);
    } else {
        const failure = switch (result) {
            .value => return error.TestUnexpectedResult,
            .failure => |failure| failure,
        };
        try std.testing.expectEqual(
            foundation.Code.capacity_overflow,
            failure.code,
        );
        try expectRepeatedArithmeticFailure(
            failure,
            foundation.ByteSize.init(old_state).add(
                .init(rhs),
                .workspace_bytes,
            ),
        );
        try std.testing.expectEqual(old_state, state.*);
    }
}

fn fuzzMultiply(smith: *std.testing.Smith, state: *usize) !void {
    const old_state = state.*;
    const factor = boundaryValue(smith, 1);
    const result = foundation.ByteSize.init(old_state).multiply(
        factor,
        .workspace_bytes,
    );
    const exact = @as(u128, old_state) * factor;

    if (exact <= std.math.maxInt(usize)) {
        switch (result) {
            .value => |value| state.* = value.value,
            .failure => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, @intCast(exact)), state.*);
    } else {
        const failure = switch (result) {
            .value => return error.TestUnexpectedResult,
            .failure => |failure| failure,
        };
        try std.testing.expectEqual(
            foundation.Code.capacity_overflow,
            failure.code,
        );
        try expectRepeatedArithmeticFailure(
            failure,
            foundation.ByteSize.init(old_state).multiply(
                factor,
                .workspace_bytes,
            ),
        );
        try std.testing.expectEqual(old_state, state.*);
    }
}

fn fuzzAlignment(smith: *std.testing.Smith, state: *usize) !void {
    const old_state = state.*;
    const alignment = generatedAlignment(smith);
    const result = foundation.ByteSize.init(old_state).alignForward(
        alignment,
        .workspace_bytes,
    );

    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
        const failure = switch (result) {
            .value => return error.TestUnexpectedResult,
            .failure => |failure| failure,
        };
        try std.testing.expectEqual(
            foundation.Code.invalid_alignment,
            failure.code,
        );
        try expectRepeatedArithmeticFailure(
            failure,
            foundation.ByteSize.init(old_state).alignForward(
                alignment,
                .workspace_bytes,
            ),
        );
        try std.testing.expectEqual(old_state, state.*);
        return;
    }

    const exact = (@as(u128, old_state) + alignment - 1) &
        ~(@as(u128, alignment) - 1);
    if (exact <= std.math.maxInt(usize)) {
        switch (result) {
            .value => |value| state.* = value.value,
            .failure => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, @intCast(exact)), state.*);
    } else {
        const failure = switch (result) {
            .value => return error.TestUnexpectedResult,
            .failure => |failure| failure,
        };
        try std.testing.expectEqual(
            foundation.Code.capacity_overflow,
            failure.code,
        );
        try expectRepeatedArithmeticFailure(
            failure,
            foundation.ByteSize.init(old_state).alignForward(
                alignment,
                .workspace_bytes,
            ),
        );
        try std.testing.expectEqual(old_state, state.*);
    }
}

fn fuzzReservation(
    smith: *std.testing.Smith,
    budget: *foundation.Budget,
    oracle_current: *u128,
    oracle_peak: *u128,
) !void {
    const old_current = budget.current;
    const old_peak = budget.peak;
    const remaining = budget.limit - budget.current;
    const requested = boundaryValue(smith, remaining);
    const exact = oracle_current.* + requested;
    const result = budget.reserve(requested);

    if (exact <= budget.limit and exact <= std.math.maxInt(usize)) {
        try std.testing.expectEqual(foundation.Reservation.committed, result);
        oracle_current.* = exact;
        oracle_peak.* = @max(oracle_peak.*, exact);
    } else {
        const failure = switch (result) {
            .committed => return error.TestUnexpectedResult,
            .rejected => |failure| failure,
        };
        try std.testing.expectEqual(
            if (exact > std.math.maxInt(usize))
                foundation.Code.capacity_overflow
            else
                foundation.Code.capacity_exceeded,
            failure.code,
        );
        const repeated = budget.reserve(requested);
        const repeated_failure = switch (repeated) {
            .committed => return error.TestUnexpectedResult,
            .rejected => |rejected| rejected,
        };
        try expectSameDiagnostic(failure, repeated_failure);
        try std.testing.expectEqual(old_current, budget.current);
        try std.testing.expectEqual(old_peak, budget.peak);
    }
}

fn fuzzRelease(
    smith: *std.testing.Smith,
    budget: *foundation.Budget,
    oracle_current: *u128,
    oracle_peak: u128,
) void {
    const range = oracle_current.* + 1;
    const amount: usize = @intCast(@as(u128, smith.value(u64)) % range);
    budget.release(amount);
    oracle_current.* -= amount;
    std.debug.assert(budget.current == oracle_current.*);
    std.debug.assert(budget.peak == oracle_peak);
}

fn boundaryValue(smith: *std.testing.Smith, exact_boundary: usize) usize {
    return switch (smith.valueRangeLessThan(u3, 0, 5)) {
        0 => 0,
        1 => exact_boundary,
        2 => if (exact_boundary < std.math.maxInt(usize))
            exact_boundary + 1
        else
            std.math.maxInt(usize),
        3 => std.math.maxInt(usize),
        4 => @truncate(smith.value(u64)),
        else => unreachable,
    };
}

fn generatedAlignment(smith: *std.testing.Smith) usize {
    return switch (smith.valueRangeLessThan(u3, 0, 5)) {
        0 => 0,
        1 => 3,
        2 => 1,
        3, 4 => blk: {
            const exponent = smith.valueRangeLessThan(
                u7,
                0,
                @bitSizeOf(usize),
            );
            break :blk @as(usize, 1) << @intCast(exponent);
        },
        else => unreachable,
    };
}

fn expectRepeatedArithmeticFailure(
    first: foundation.Diagnostic,
    repeated: foundation.CapacityResult,
) !void {
    const second = switch (repeated) {
        .value => return error.TestUnexpectedResult,
        .failure => |failure| failure,
    };
    try expectSameDiagnostic(first, second);
}

fn expectSameDiagnostic(
    first: foundation.Diagnostic,
    second: foundation.Diagnostic,
) !void {
    try std.testing.expectEqual(first.code, second.code);
    try std.testing.expectEqual(first.category, second.category);
    try std.testing.expectEqual(first.severity, second.severity);
    try std.testing.expectEqual(first.primary, second.primary);
    try std.testing.expectEqual(first.cause, second.cause);
    try std.testing.expectEqual(first.related.len, second.related.len);

    switch (first.detail) {
        .capacity => |expected| switch (second.detail) {
            .capacity => |actual| try std.testing.expectEqual(expected, actual),
            else => return error.TestUnexpectedResult,
        },
        .alignment => |expected| switch (second.detail) {
            .alignment => |actual| try std.testing.expectEqual(expected, actual),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}
