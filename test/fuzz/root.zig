const std = @import("std");
const phaser = @import("phaser");
const foundation = phaser.foundation;

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

test "expression_parser" {
    try std.testing.fuzz({}, fuzzExpression, .{
        .corpus = &.{
            @embedFile("../corpus/expression_parser/empty.txt"),
            @embedFile("../corpus/expression_parser/rational.txt"),
            @embedFile("../corpus/expression_parser/radical.txt"),
            @embedFile("../corpus/expression_parser/invalid.txt"),
        },
    });
}

fn fuzzExpression(_: void, smith: *std.testing.Smith) !void {
    const length = smith.valueRangeLessThan(u16, 0, 1025);
    var bytes: [1024]u8 = undefined;
    for (bytes[0..length]) |*byte| byte.* = smith.value(u8);
    const source_id = try foundation.SourceId.fromUsize(0);
    const parameters = [_]phaser.expression.Parameter{
        .{ .name = "a", .id = 0, .mass_dimension = 0 },
        .{ .name = "m2", .id = 1, .mass_dimension = 2 },
    };
    const options = phaser.expression.ParseOptions{
        .limits = .{
            .expression_bytes = 1024,
            .expression_tokens = 256,
            .expression_nodes = 256,
            .expression_depth = 32,
            .integer_digits = 64,
            .exponent_magnitude = 32,
            .exact_integer_bits = 2048,
        },
    };
    const first = try phaser.expression.parse(
        std.testing.allocator,
        source_id,
        bytes[0..length],
        &parameters,
        options,
    );
    const second = try phaser.expression.parse(
        std.testing.allocator,
        source_id,
        bytes[0..length],
        &parameters,
        options,
    );
    switch (first) {
        .failure => |first_failure| switch (second) {
            .failure => |second_failure| {
                try std.testing.expectEqual(first_failure.kind, second_failure.kind);
                try std.testing.expectEqual(first_failure.span, second_failure.span);
            },
            .expression => |second_expression| {
                var owned = second_expression;
                defer owned.deinit();
                return error.NondeterministicExpressionParse;
            },
        },
        .expression => |first_expression| {
            var first_owned = first_expression;
            defer first_owned.deinit();
            var second_owned = switch (second) {
                .expression => |expression| expression,
                .failure => return error.NondeterministicExpressionParse,
            };
            defer second_owned.deinit();
            var first_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer first_output.deinit();
            var second_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer second_output.deinit();
            try first_owned.write(&first_output.writer);
            try second_owned.write(&second_output.writer);
            try std.testing.expectEqualStrings(
                first_output.written(),
                second_output.written(),
            );
        },
    }
}

test "scalar_model_parser" {
    try std.testing.fuzz({}, fuzzModel, .{
        .corpus = &.{
            @embedFile("../corpus/scalar_model_parser/empty.json"),
            @embedFile("../corpus/scalar_model_parser/minimal.json"),
            @embedFile("../corpus/scalar_model_parser/invalid.json"),
        },
    });
}

fn fuzzModel(_: void, smith: *std.testing.Smith) !void {
    const length = smith.valueRangeLessThan(u16, 0, 2049);
    var bytes: [2048]u8 = undefined;
    for (bytes[0..length]) |*byte| byte.* = smith.value(u8);
    const context = switch (foundation.Context.init(std.testing.allocator, .{
        .max_diagnostics = 8,
        .max_related_locations = 8,
    })) {
        .context => |value| value,
        .failure => unreachable,
    };
    const source = phaser.ModelSource{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = bytes[0..length],
    };
    const options = phaser.ModelLoadOptions{ .limits = .{
        .source_bytes = 2048,
        .json_tokens = 512,
        .parameters = 32,
        .real_scalars = 32,
        .tensor_components = 128,
        .expression_bytes = 256,
        .expression_tokens = 128,
        .expression_nodes = 128,
        .expression_depth = 32,
        .integer_digits = 64,
        .exponent_magnitude = 32,
        .exact_integer_bits = 2048,
        .value_nodes = 1024,
        .scratch_bytes = 1024 * 1024,
        .persistent_bytes = 1024 * 1024,
    } };
    const first = try phaser.loadModel(context, source, options);
    const second = try phaser.loadModel(context, source, options);
    switch (first) {
        .diagnostics => |first_diagnostics| {
            var first_owned = first_diagnostics;
            defer first_owned.deinit();
            var second_owned = switch (second) {
                .diagnostics => |diagnostics| diagnostics,
                .model => |model| {
                    var owned = model;
                    defer owned.deinit();
                    return error.NondeterministicModelParse;
                },
            };
            defer second_owned.deinit();
            try std.testing.expectEqual(
                first_owned.items[0].code,
                second_owned.items[0].code,
            );
            try std.testing.expectEqual(
                first_owned.items[0].category,
                second_owned.items[0].category,
            );
            try std.testing.expectEqual(
                first_owned.items[0].primary,
                second_owned.items[0].primary,
            );
        },
        .model => |first_model| {
            var first_owned = first_model;
            defer first_owned.deinit();
            var second_owned = switch (second) {
                .model => |model| model,
                .diagnostics => |diagnostics| {
                    var owned = diagnostics;
                    defer owned.deinit();
                    return error.NondeterministicModelParse;
                },
            };
            defer second_owned.deinit();
            try std.testing.expectEqual(
                first_owned.fingerprint().bytes,
                second_owned.fingerprint().bytes,
            );
        },
    }
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
