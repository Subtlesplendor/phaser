const std = @import("std");
const phaser = @import("phaser");
const foundation = phaser.foundation;

// Every target allocates through this rather than `std.testing.allocator`, and
// the difference is the campaign's iteration budget.
//
// Both are `DebugAllocator`, so the checks a fuzz target wants are identical:
// leak accounting, canaries, double-free and use-after-free detection. What
// `std.testing.allocator` adds is `stack_trace_frames = 10`, a captured
// backtrace on every allocation and free. Unwinding those costs more than the
// exact arithmetic under test: the heaviest target measured 43 seconds for a
// thousand inputs with traces and about one second without, at 1 GiB resident
// against 4 MiB. Capturing them was consuming all but a small fraction of the
// tier's budget. A default-configured `DebugAllocator` in ReleaseSafe captures
// none, and keeps every other check.
//
// The cost is that a leak reports its address and size but not where it was
// allocated, and it is paid only where it is cheap. `DebugAllocator`'s default
// frame count follows the build mode: none in the ReleaseSafe campaign, six in
// Debug. The campaign saves the input that failed, and replaying it the way
// section 7 of DEVELOPMENT_WORKFLOW.md already prescribes -- add it to the
// target's corpus and run `zig build fuzz`, which is Debug -- reports the leak
// with its allocation site. Traces are bought on the one input that failed
// rather than on the hundreds of thousands that did not.
var iteration_gpa: std.heap.DebugAllocator(.{}) = .init;
const iteration_allocator = iteration_gpa.allocator();

/// Give one fuzz input a fresh allocator and fail the campaign if it leaks.
///
/// The test runner does this for `std.testing.allocator` around every input on
/// its own; a private allocator has to say it. Wrapping at the `fuzz` call site
/// keeps it to one visible place per target, so a target either goes through
/// the check or plainly does not.
fn leakChecked(
    comptime target: fn (void, *std.testing.Smith) anyerror!void,
) fn (void, *std.testing.Smith) anyerror!void {
    return struct {
        fn checked(context: void, smith: *std.testing.Smith) anyerror!void {
            iteration_gpa = .init;
            // Runs after the target's own `defer`s, so anything it frees on the
            // way out is already freed and only a real leak is left.
            defer if (iteration_gpa.deinit() == .leak) {
                // The allocator has already named each leaked allocation.
                @panic("fuzz input leaked memory");
            };
            try target(context, smith);
        }
    }.checked;
}

const max_sequence_length = 64;

const Operation = enum(u3) {
    add,
    multiply,
    align_forward,
    reserve,
    release,
};

test "foundation_capacity" {
    try std.testing.fuzz({}, leakChecked(fuzzCapacity), .{
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
    try std.testing.fuzz({}, leakChecked(fuzzExpression), .{
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
        iteration_allocator,
        source_id,
        bytes[0..length],
        &parameters,
        options,
    );
    const second = try phaser.expression.parse(
        iteration_allocator,
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
            var first_output: std.Io.Writer.Allocating = .init(iteration_allocator);
            defer first_output.deinit();
            var second_output: std.Io.Writer.Allocating = .init(iteration_allocator);
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
    try std.testing.fuzz({}, leakChecked(fuzzModel), .{
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
    const context = switch (foundation.Context.init(iteration_allocator, .{
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

test "value_ir_builder" {
    try std.testing.fuzz({}, leakChecked(fuzzValueGraph), .{
        .corpus = &.{
            @embedFile("../corpus/value_ir_builder/leaves.bin"),
            @embedFile("../corpus/value_ir_builder/polynomial.bin"),
            @embedFile("../corpus/value_ir_builder/cancellation.bin"),
        },
    });
}

const max_steps = 48;
const pool_capacity = max_steps + 4;

const Step = struct {
    kind: u8,
    a: u8,
    b: u8,
    c: u8,
};

/// Replays a generated construction script and returns the resulting graph.
///
/// Steps whose operands are dimensionally incompatible, or which exhaust a
/// limit, are skipped: rejecting them is correct behavior, and the property
/// under test is that whatever is accepted is canonical and deterministic.
///
/// The script covers the typed and structured node kinds as well as the real
/// scalar ones, so a generated graph can carry `Complex64` values, symmetric
/// matrices of two dimensions, structured element access, and the scalar
/// spectral value. Most generated combinations are rejected — a matrix needs
/// three entries of mass dimension two in a row — which is why the pool is
/// seeded with operands those constructions can actually use.
fn replay(steps: []const Step, allocator: std.mem.Allocator) !phaser.value.Graph {
    var builder = try phaser.value.Builder.init(allocator, .{
        .value_nodes = 4096,
        .value_operands = 64,
        .exponent_magnitude = 8,
        .exact_integer_bits = 2048,
    });
    errdefer builder.deinit();

    var pool: [pool_capacity]phaser.value.ValueId = undefined;
    var pool_length: usize = 0;

    // Seed the pool so that every script has operands available.
    pool[pool_length] = try builder.background(0, "h", 1);
    pool_length += 1;
    pool[pool_length] = try builder.background(1, "s", 1);
    pool_length += 1;
    pool[pool_length] = try builder.parameter(0, "g", 0);
    pool_length += 1;
    pool[pool_length] = try builder.integer(1, 0);
    pool_length += 1;
    // A mass-squared parameter and the renormalization scale, which are the
    // two operands a spectral value cannot be built without.
    pool[pool_length] = try builder.parameter(1, "m2", 2);
    pool_length += 1;
    const scale = try builder.renormalizationScale(0, "muR");
    pool[pool_length] = scale;
    pool_length += 1;

    for (steps) |step| {
        const first = pool[step.a % pool_length];
        const second = pool[step.b % pool_length];
        const third = pool[step.c % pool_length];

        const produced: ?phaser.value.ValueId = switch (step.kind % 12) {
            0 => builder.add(&.{ first, second }) catch null,
            1 => builder.add(&.{ first, second, third }) catch null,
            2 => builder.multiply(&.{ first, second }) catch null,
            3 => builder.multiply(&.{ first, second, third }) catch null,
            4 => builder.power(first, step.b % 6) catch null,
            5 => builder.divide(first, second) catch null,
            6 => builder.subtract(first, second) catch null,
            7 => builder.promoteRealToComplex(first) catch null,
            8 => builder.realSymmetricMatrix(1, &.{first}, 2) catch null,
            9 => builder.realSymmetricMatrix(
                2,
                &.{ first, second, third },
                2,
            ) catch null,
            10 => builder.scalarOneLoopSpectralValue(first, scale) catch null,
            11 => builder.element(first, step.b % 2, step.c % 2) catch null,
            else => unreachable,
        };
        if (produced) |id| {
            if (pool_length < pool_capacity) {
                pool[pool_length] = id;
                pool_length += 1;
            }
        }
    }
    return builder.finish();
}

fn fuzzValueGraph(_: void, smith: *std.testing.Smith) !void {
    const count = smith.valueRangeLessThan(u16, 0, max_steps + 1);
    var steps: [max_steps]Step = undefined;
    for (steps[0..count]) |*step| {
        step.* = .{
            .kind = smith.value(u8),
            .a = smith.value(u8),
            .b = smith.value(u8),
            .c = smith.value(u8),
        };
    }

    var first = try replay(steps[0..count], iteration_allocator);
    defer first.deinit();
    var second = try replay(steps[0..count], iteration_allocator);
    defer second.deinit();

    // Construction establishes the published invariants.
    try std.testing.expect(first.audit());
    try std.testing.expect(second.audit());

    // Independently built graphs of the same script are byte identical, so
    // construction depends on no allocation address or iteration order.
    var first_output: std.Io.Writer.Allocating = .init(iteration_allocator);
    defer first_output.deinit();
    var second_output: std.Io.Writer.Allocating = .init(iteration_allocator);
    defer second_output.deinit();
    try first.writeCanonical(&first_output.writer);
    try second.writeCanonical(&second_output.writer);
    try std.testing.expectEqualStrings(first_output.written(), second_output.written());

    // Interning: no two published nodes share a canonical encoding.
    try expectDistinctNodes(first);
}

/// Two nodes with the same canonical line would mean interning missed a
/// structurally equal node, which is how the `power` and `divide` lookup
/// omission first showed up.
fn expectDistinctNodes(graph: phaser.value.Graph) !void {
    var seen = std.StringHashMap(void).init(iteration_allocator);
    defer {
        var iterator = seen.keyIterator();
        while (iterator.next()) |key| iteration_allocator.free(key.*);
        seen.deinit();
    }

    var rendered: std.Io.Writer.Allocating = .init(iteration_allocator);
    defer rendered.deinit();
    try graph.writeCanonical(&rendered.writer);

    var lines = std.mem.splitScalar(u8, rendered.written(), '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Drop the leading index, which is the only per-node difference a
        // duplicate would retain.
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const body = line[space + 1 ..];
        const owned = try iteration_allocator.dupe(u8, body);
        errdefer iteration_allocator.free(owned);
        if (seen.contains(owned)) {
            iteration_allocator.free(owned);
            return error.DuplicateInternedNode;
        }
        try seen.put(owned, {});
    }
}

test "calculation_request_parser" {
    try std.testing.fuzz({}, leakChecked(fuzzRequest), .{
        .corpus = &.{
            @embedFile("../corpus/calculation_request_parser/full_space.json"),
            @embedFile("../corpus/calculation_request_parser/component_slice.json"),
            @embedFile("../corpus/calculation_request_parser/invalid.json"),
        },
    });
}

fn fuzzRequest(_: void, smith: *std.testing.Smith) !void {
    const length = smith.valueRangeLessThan(u16, 0, 1025);
    var bytes: [1024]u8 = undefined;
    for (bytes[0..length]) |*byte| byte.* = smith.value(u8);

    const context = switch (foundation.Context.init(iteration_allocator, .{
        .max_diagnostics = 8,
        .max_related_locations = 8,
    })) {
        .context => |value| value,
        .failure => unreachable,
    };
    const source = phaser.RequestSource{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = bytes[0..length],
    };

    const first = try phaser.parseRequest(context, source, .{});
    const second = try phaser.parseRequest(context, source, .{});

    switch (first) {
        .diagnostics => |first_diagnostics| {
            var first_owned = first_diagnostics;
            defer first_owned.deinit();
            var second_owned = switch (second) {
                .diagnostics => |value| value,
                .request => |request| {
                    var owned = request;
                    owned.deinit();
                    return error.NondeterministicRequestParse;
                },
            };
            defer second_owned.deinit();
            try std.testing.expectEqual(
                first_owned.items.len,
                second_owned.items.len,
            );
            for (first_owned.items, second_owned.items) |expected, actual| {
                try std.testing.expectEqual(expected.code, actual.code);
                try std.testing.expectEqual(expected.category, actual.category);
                try std.testing.expectEqual(expected.primary, actual.primary);
            }
        },
        .request => |first_request| {
            var first_owned = first_request;
            defer first_owned.deinit();
            var second_owned = switch (second) {
                .request => |request| request,
                .diagnostics => |diagnostics| {
                    var owned = diagnostics;
                    owned.deinit();
                    return error.NondeterministicRequestParse;
                },
            };
            defer second_owned.deinit();

            // An accepted request normalizes to one identity, and Milestone 2
            // accepts loop order zero only.
            try std.testing.expectEqual(
                phaser.calculation.supported_loop_order,
                first_owned.loop_order,
            );
            const first_fingerprint = try first_owned.fingerprint(iteration_allocator);
            const second_fingerprint = try second_owned.fingerprint(iteration_allocator);
            try std.testing.expectEqualSlices(
                u8,
                &first_fingerprint.bytes,
                &second_fingerprint.bytes,
            );
        },
    }
}

test "symbolic_exporter" {
    try std.testing.fuzz({}, leakChecked(fuzzExporter), .{
        .corpus = &.{
            @embedFile("../corpus/symbolic_exporter/leaves.bin"),
            @embedFile("../corpus/symbolic_exporter/polynomial.bin"),
            @embedFile("../corpus/symbolic_exporter/deep.bin"),
        },
    });
}

/// Renders generated value graphs under generated presentation options.
///
/// The properties are those section 18 requires of every exporter: output is
/// deterministic, a complete export either fits its budget or fails without
/// publishing anything, and a preview that omits content says so.
fn fuzzExporter(_: void, smith: *std.testing.Smith) !void {
    const count = smith.valueRangeLessThan(u16, 0, max_steps + 1);
    var steps: [max_steps]Step = undefined;
    for (steps[0..count]) |*step| {
        step.* = .{
            .kind = smith.value(u8),
            .a = smith.value(u8),
            .b = smith.value(u8),
            .c = smith.value(u8),
        };
    }

    var graph = try replay(steps[0..count], iteration_allocator);
    defer graph.deinit();

    const root = phaser.value.ValueId.fromUsize(graph.values.len - 1) catch return;
    const target: phaser.symbolic.Target = if (smith.value(bool)) .latex else .phaser;
    const options = phaser.symbolic.Options{
        .target = target,
        .max_bytes = smith.valueRangeLessThan(u16, 1, 4096),
        .max_preview_nodes = smith.valueRangeLessThan(u16, 1, 64),
    };

    const first = phaser.symbolic.renderAlloc(
        &graph,
        root,
        iteration_allocator,
        options,
    ) catch |err| switch (err) {
        // A budget below the required size is an ordinary failure that
        // publishes nothing.
        error.OutputCapacityExceeded => return,
        else => return err,
    };
    defer iteration_allocator.free(first);

    // Deterministic for fixed source, target, and options.
    const second = try phaser.symbolic.renderAlloc(
        &graph,
        root,
        iteration_allocator,
        options,
    );
    defer iteration_allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    // A complete export never exceeds the budget it accepted.
    try std.testing.expect(first.len <= options.max_bytes);

    // A LaTeX fragment carries no delimiters or preamble.
    if (target == .latex) {
        try std.testing.expect(std.mem.indexOf(u8, first, "$") == null);
        try std.testing.expect(std.mem.indexOf(u8, first, "\\begin{document}") == null);
    }

    // A preview either renders or visibly states that it omitted content.
    var preview: std.Io.Writer.Allocating = .init(iteration_allocator);
    defer preview.deinit();
    try phaser.symbolic.writeValuePreview(
        &graph,
        root,
        iteration_allocator,
        options,
        &preview.writer,
    );
    const nodes = try phaser.symbolic.countNodes(&graph, root, iteration_allocator);
    if (nodes > options.max_preview_nodes) {
        try std.testing.expect(
            std.mem.indexOf(u8, preview.written(), "omitted from preview") != null,
        );
    }
}

test "kernel_lowering" {
    try std.testing.fuzz({}, leakChecked(fuzzKernel), .{
        .corpus = &.{
            @embedFile("../corpus/kernel_lowering/leaves.bin"),
            @embedFile("../corpus/kernel_lowering/polynomial.bin"),
            @embedFile("../corpus/kernel_lowering/deep.bin"),
            @embedFile("../corpus/kernel_lowering/structured_root.bin"),
        },
    });
}

/// Lowers generated value graphs and compares the reference backend against
/// direct evaluation of the same graph.
///
/// The properties are the ones the potential-kernel contract requires: a
/// published program validates, evaluation stays inside its queried workspace,
/// and scalar and batch evaluation agree.
fn fuzzKernel(_: void, smith: *std.testing.Smith) !void {
    const count = smith.valueRangeLessThan(u16, 0, max_steps + 1);
    var steps: [max_steps]Step = undefined;
    for (steps[0..count]) |*step| {
        step.* = .{
            .kind = smith.value(u8),
            .a = smith.value(u8),
            .b = smith.value(u8),
            .c = smith.value(u8),
        };
    }

    var graph = try replay(steps[0..count], iteration_allocator);
    defer graph.deinit();

    const root = phaser.value.ValueId.fromUsize(graph.values.len - 1) catch return;
    var program = phaser.kernel.lower(iteration_allocator, .{
        .graph = &graph,
        .capability = .value,
        .value_root = root,
        .gradient_roots = &.{},
        .hessian_roots = &.{},
        .parameter_count = 8,
        .background_count = 2,
        .coordinate_count = 2,
    }, .{}) catch |err| switch (err) {
        // A constant outside the conversion policy is an ordinary failure, as
        // is a root whose shape is not a publishable output.
        error.ConstantNotRepresentable,
        error.CapacityExceeded,
        error.UnsupportedOperation,
        error.SizeOverflow,
        => return,
        else => return err,
    };
    defer program.deinit();

    // A published program always satisfies every validation rule.
    try program.validate(iteration_allocator, 64);

    const batch_points = phaser.kernel.optimizedBlockWidth + 1;
    const layout = program.workspaceLayout(batch_points);
    const workspace = try iteration_allocator.alignedAlloc(
        u8,
        .of(phaser.kernel.Scalar),
        layout.bytes,
    );
    defer iteration_allocator.free(workspace);
    var optimized_plan = try phaser.kernel.optimized_plan.compile(
        iteration_allocator,
        &program,
    );
    defer optimized_plan.deinit();
    const optimized_layout = optimized_plan.workspaceLayout(batch_points);
    const optimized_workspace = try iteration_allocator.alignedAlloc(
        u8,
        .of(@Vector(2, phaser.kernel.Scalar)),
        optimized_layout.bytes,
    );
    defer iteration_allocator.free(optimized_workspace);

    var parameters: [8]phaser.kernel.Scalar = undefined;
    for (&parameters, 0..) |*slot, index| {
        slot.* = 0.5 + @as(phaser.kernel.Scalar, @floatFromInt(index)) * 0.25;
    }
    const backgrounds = [_]phaser.kernel.Scalar{
        1.25, -0.75,
        2.5,  0.5,
        -3,   1,
        0,    0,
        4.5,  -2.25,
    };
    // The scale channel exists exactly when the lowered program reads it, and
    // it must be finite and positive.
    var scales: [1]phaser.kernel.Scalar = .{2.5};
    const inputs = phaser.kernel.Inputs{
        .parameters = &parameters,
        .scales = scales[0..program.scale_count],
        .backgrounds = &backgrounds,
    };

    // The result type is a structural property of the program, so the buffers
    // it needs are known before it runs.
    switch (program.result_type) {
        .real64 => try expectKernelAgreement(
            phaser.kernel.Scalar,
            &program,
            inputs,
            backgrounds[0..],
            workspace,
            layout,
            &optimized_plan,
            optimized_workspace,
            optimized_layout,
        ),
        .complex64 => try expectKernelAgreement(
            phaser.kernel.Complex64,
            &program,
            inputs,
            backgrounds[0..],
            workspace,
            layout,
            &optimized_plan,
            optimized_workspace,
            optimized_layout,
        ),
    }
}

/// Batch, scalar, and workspace properties of one lowered program.
fn expectKernelAgreement(
    comptime Element: type,
    program: *const phaser.kernel.Program,
    inputs: phaser.kernel.Inputs,
    backgrounds: []const phaser.kernel.Scalar,
    workspace: []align(@alignOf(phaser.kernel.Scalar)) u8,
    layout: phaser.kernel.WorkspaceLayout,
    optimized_plan: *const phaser.kernel.ExecutionPlan,
    optimized_workspace: []align(@alignOf(@Vector(2, phaser.kernel.Scalar))) u8,
    optimized_layout: phaser.kernel.WorkspaceLayout,
) !void {
    const complex = Element == phaser.kernel.Complex64;
    const sentinel: Element = if (complex) .{ .re = -98765, .im = -56789 } else -98765;
    const batch_points = phaser.kernel.optimizedBlockWidth + 1;

    var values = [_]Element{sentinel} ** batch_points;
    var statuses: [batch_points]phaser.kernel.Status = undefined;
    const run = if (complex)
        phaser.kernel.evaluateComplex(program, inputs, batch_points, workspace, .{
            .values = &values,
            .statuses = &statuses,
        })
    else
        phaser.kernel.evaluate(program, inputs, batch_points, workspace, .{
            .values = &values,
            .statuses = &statuses,
        });
    try run;

    var optimized_values = [_]Element{sentinel} ** batch_points;
    var optimized_statuses: [batch_points]phaser.kernel.Status = undefined;
    const optimized_run = if (complex)
        phaser.kernel.optimized_interpreter.evaluateComplex(
            optimized_plan,
            inputs,
            batch_points,
            optimized_workspace,
            .{ .values = &optimized_values, .statuses = &optimized_statuses },
        )
    else
        phaser.kernel.optimized_interpreter.evaluate(
            optimized_plan,
            inputs,
            batch_points,
            optimized_workspace,
            .{ .values = &optimized_values, .statuses = &optimized_statuses },
        );
    try optimized_run;
    try std.testing.expectEqualSlices(
        phaser.kernel.Status,
        &statuses,
        &optimized_statuses,
    );
    try std.testing.expectEqualSlices(Element, &values, &optimized_values);

    for (0..batch_points) |point| {
        var single = [_]Element{sentinel};
        var single_status: [1]phaser.kernel.Status = undefined;
        const point_inputs = phaser.kernel.Inputs{
            .parameters = inputs.parameters,
            .scales = inputs.scales,
            .backgrounds = backgrounds[point * 2 ..][0..2],
        };
        const alone = if (complex)
            phaser.kernel.evaluateComplex(program, point_inputs, 1, workspace, .{
                .values = &single,
                .statuses = &single_status,
            })
        else
            phaser.kernel.evaluate(program, point_inputs, 1, workspace, .{
                .values = &single,
                .statuses = &single_status,
            });
        try alone;

        // Each point evaluated alone agrees with its place in the batch, and a
        // failed point publishes nothing in either call.
        try std.testing.expectEqual(statuses[point], single_status[0]);
        if (statuses[point] == .ok) {
            try std.testing.expectEqual(values[point], single[0]);
        } else {
            try std.testing.expectEqual(sentinel, values[point]);
            try std.testing.expectEqual(sentinel, single[0]);
        }
    }

    // One byte below the queried size is always rejected.
    if (layout.bytes > 0) {
        const short = workspace[0 .. layout.bytes - 1];
        const rejected = if (complex)
            phaser.kernel.evaluateComplex(program, inputs, batch_points, short, .{
                .values = &values,
                .statuses = &statuses,
            })
        else
            phaser.kernel.evaluate(program, inputs, batch_points, short, .{
                .values = &values,
                .statuses = &statuses,
            });
        try std.testing.expectError(error.WorkspaceTooSmall, rejected);
    }
    if (optimized_layout.bytes > 0) {
        const short = optimized_workspace[0 .. optimized_layout.bytes - 1];
        const rejected = if (complex)
            phaser.kernel.optimized_interpreter.evaluateComplex(
                optimized_plan,
                inputs,
                batch_points,
                short,
                .{ .values = &optimized_values, .statuses = &optimized_statuses },
            )
        else
            phaser.kernel.optimized_interpreter.evaluate(
                optimized_plan,
                inputs,
                batch_points,
                short,
                .{ .values = &optimized_values, .statuses = &optimized_statuses },
            );
        try std.testing.expectError(error.WorkspaceTooSmall, rejected);
    }

    // Calling with the other element type is a call-level error, never a
    // reinterpretation of the caller's buffers.
    if (complex) {
        var real_values: [batch_points]phaser.kernel.Scalar = undefined;
        try std.testing.expectError(
            error.ResultTypeMismatch,
            phaser.kernel.evaluate(program, inputs, batch_points, workspace, .{
                .values = &real_values,
                .statuses = &statuses,
            }),
        );
    } else {
        var complex_values: [batch_points]phaser.kernel.Complex64 = undefined;
        try std.testing.expectError(
            error.ResultTypeMismatch,
            phaser.kernel.evaluateComplex(program, inputs, batch_points, workspace, .{
                .values = &complex_values,
                .statuses = &statuses,
            }),
        );
    }
}

test "one_loop_pipeline" {
    try std.testing.fuzz({}, leakChecked(fuzzOneLoopPipeline), .{
        .corpus = &.{
            @embedFile("../corpus/one_loop_pipeline/positive.bin"),
            @embedFile("../corpus/one_loop_pipeline/indefinite.bin"),
            @embedFile("../corpus/one_loop_pipeline/degenerate.bin"),
            @embedFile("../corpus/one_loop_pipeline/extreme.bin"),
            @embedFile("../corpus/one_loop_pipeline/status_independence.bin"),
        },
    });
}

/// Largest fluctuation dimension the pipeline target builds. Three is the
/// smallest size that reaches the cyclic Jacobi path.
const max_fluctuation_dimension = 3;

/// Drives the whole order-one path: matrix assembly, the symmetric
/// eigensolver, the spectral sum, the invariant derivatives, and complex
/// publication.
///
/// The mass matrix is `b` times a matrix of generated coefficients, so a
/// generated case controls the spectrum directly — degenerate, indefinite,
/// zero, and extreme spectra are all reachable — while the derivative matrices
/// stay exact: `dM/db` is the coefficient matrix and `d2M/db2` is zero.
///
/// The properties are the ones the kernel contract states independently of any
/// particular spectrum: a published program validates, execution stays inside
/// its queried workspace, publication is point-atomic, an `ok` point is finite,
/// the principal branch never produces a negative imaginary part, and scalar
/// and batch evaluation agree bitwise.
fn fuzzOneLoopPipeline(_: void, smith: *std.testing.Smith) !void {
    const dimension = smith.valueRangeLessThan(u32, 1, max_fluctuation_dimension + 1);
    const entry_count = phaser.value.upperTriangleCount(dimension);

    const built = try buildOneLoopGraph(dimension);
    var graph = built.graph;
    defer graph.deinit();
    try std.testing.expect(graph.audit());

    var program = phaser.kernel.lower(iteration_allocator, .{
        .graph = &graph,
        .capability = .value_gradient_hessian,
        .value_root = built.value,
        .gradient_roots = &.{built.gradient},
        .hessian_roots = &.{built.hessian},
        .parameter_count = @intCast(entry_count),
        .background_count = 1,
        .coordinate_count = 1,
    }, .{}) catch |err| switch (err) {
        error.ConstantNotRepresentable, error.CapacityExceeded => return,
        else => return err,
    };
    defer program.deinit();

    try program.validate(iteration_allocator, 64);
    try std.testing.expectEqual(
        phaser.kernel.ResultType.complex64,
        program.result_type,
    );

    var parameters: [6]phaser.kernel.Scalar = undefined;
    for (parameters[0..entry_count]) |*slot| slot.* = generatedScalar(smith);
    const scales = [_]phaser.kernel.Scalar{generatedScalar(smith)};
    const point_count = 3;
    var backgrounds: [point_count]phaser.kernel.Scalar = undefined;
    for (&backgrounds) |*slot| slot.* = generatedScalar(smith);

    const inputs = phaser.kernel.Inputs{
        .parameters = parameters[0..entry_count],
        .scales = &scales,
        .backgrounds = &backgrounds,
    };

    const layout = program.workspaceLayout(point_count);
    const workspace = try iteration_allocator.alignedAlloc(
        u8,
        .of(phaser.kernel.Scalar),
        layout.bytes,
    );
    defer iteration_allocator.free(workspace);

    const sentinel = phaser.kernel.Complex64{ .re = -13579, .im = -24680 };
    var values = [_]phaser.kernel.Complex64{sentinel} ** point_count;
    var gradients = [_]phaser.kernel.Complex64{sentinel} ** point_count;
    var hessians = [_]phaser.kernel.Complex64{sentinel} ** point_count;
    var statuses: [point_count]phaser.kernel.Status = undefined;
    const buffers = phaser.kernel.ComplexOutputBuffers{
        .values = &values,
        .gradients = &gradients,
        .hessians = &hessians,
        .statuses = &statuses,
    };

    phaser.kernel.evaluateComplex(
        &program,
        inputs,
        point_count,
        workspace,
        buffers,
    ) catch |err| switch (err) {
        // A scale that is not finite and positive is rejected for the whole
        // call, before any point runs.
        error.InvalidScale => {
            try std.testing.expect(!(std.math.isFinite(scales[0]) and scales[0] > 0));
            for (values) |published| {
                try std.testing.expectEqual(sentinel, published);
            }
            return;
        },
        else => return err,
    };

    for (statuses, 0..) |status, index| {
        switch (status) {
            .ok => {
                // A published point is finite in every output, and the
                // principal branch of this formula never turns downwards.
                try std.testing.expect(std.math.isFinite(values[index].re));
                try std.testing.expect(std.math.isFinite(values[index].im));
                try std.testing.expect(values[index].im >= 0);
                try std.testing.expect(std.math.isFinite(gradients[index].re));
                try std.testing.expect(std.math.isFinite(hessians[index].re));
            },
            // Publication is point-atomic: a failed point wrote nothing at all.
            .non_finite, .nonconvergent, .singular_derivative => {
                try std.testing.expectEqual(sentinel, values[index]);
                try std.testing.expectEqual(sentinel, gradients[index]);
                try std.testing.expectEqual(sentinel, hessians[index]);
            },
            else => return error.UnexpectedStatus,
        }
    }

    // Each point evaluated alone reproduces its place in the batch bitwise.
    for (0..point_count) |index| {
        var single = [_]phaser.kernel.Complex64{sentinel};
        var single_gradient = [_]phaser.kernel.Complex64{sentinel};
        var single_hessian = [_]phaser.kernel.Complex64{sentinel};
        var single_status: [1]phaser.kernel.Status = undefined;
        try phaser.kernel.evaluateComplex(
            &program,
            .{
                .parameters = inputs.parameters,
                .scales = inputs.scales,
                .backgrounds = backgrounds[index .. index + 1],
            },
            1,
            workspace,
            .{
                .values = &single,
                .gradients = &single_gradient,
                .hessians = &single_hessian,
                .statuses = &single_status,
            },
        );
        try std.testing.expectEqual(statuses[index], single_status[0]);
        try std.testing.expectEqual(values[index], single[0]);
        try std.testing.expectEqual(gradients[index], single_gradient[0]);
        try std.testing.expectEqual(hessians[index], single_hessian[0]);
    }

    // One byte below the queried size is rejected before any slot is written.
    if (layout.bytes > 0) {
        try std.testing.expectError(
            error.WorkspaceTooSmall,
            phaser.kernel.evaluateComplex(
                &program,
                inputs,
                point_count,
                workspace[0 .. layout.bytes - 1],
                buffers,
            ),
        );
    }
}

/// Builds the order-one graph the pipeline target lowers.
///
/// Separate from the target so that ownership transfers exactly once: the
/// builder is released only when construction fails, and the finished graph
/// owns everything afterwards.
const BuiltOneLoop = struct {
    graph: phaser.value.Graph,
    value: phaser.value.ValueId,
    gradient: phaser.value.ValueId,
    hessian: phaser.value.ValueId,
};

fn buildOneLoopGraph(dimension: u32) !BuiltOneLoop {
    const entry_count = phaser.value.upperTriangleCount(dimension);

    var builder = try phaser.value.Builder.init(iteration_allocator, .{
        .value_nodes = 1024,
        .value_operands = 16,
        .exponent_magnitude = 4,
        .exact_integer_bits = 256,
    });
    errdefer builder.deinit();

    const background = try builder.background(0, "b", 1);
    const scale = try builder.renormalizationScale(0, "muR");

    // Every entry has the same structure, so permuting the coefficients is
    // exactly a permutation of the scalar basis.
    var coefficients: [6]phaser.value.ValueId = undefined;
    var entries: [6]phaser.value.ValueId = undefined;
    var zeros: [6]phaser.value.ValueId = undefined;
    for (0..entry_count) |index| {
        var name: [2]u8 = .{ 'p', '0' };
        name[1] = '0' + @as(u8, @intCast(index));
        coefficients[index] = try builder.parameter(@intCast(index), &name, 1);
        entries[index] = try builder.multiply(&.{ coefficients[index], background });
        zeros[index] = try builder.zero(0);
    }

    const matrix = try builder.realSymmetricMatrix(
        dimension,
        entries[0..entry_count],
        2,
    );
    const spectral = try builder.scalarOneLoopSpectralValue(matrix, scale);

    // `dM/db` is the coefficient matrix and `d2M/db2` vanishes identically.
    const first_derivative = try builder.realSymmetricMatrix(
        dimension,
        coefficients[0..entry_count],
        1,
    );
    const second_derivative = try builder.realSymmetricMatrix(
        dimension,
        zeros[0..entry_count],
        0,
    );
    const gradient = try builder.scalarOneLoopSpectralGradient(
        spectral,
        &.{0},
        &.{first_derivative},
    );
    const hessian = try builder.scalarOneLoopSpectralHessian(
        spectral,
        &.{0},
        &.{first_derivative},
        &.{second_derivative},
    );
    const gradient_root = try builder.element(gradient, 0, 0);
    const hessian_root = try builder.element(hessian, 0, 0);

    return .{
        .graph = try builder.finish(),
        .value = spectral,
        .gradient = gradient_root,
        .hessian = hessian_root,
    };
}

/// A generated `f64` biased towards the values that make a spectrum
/// interesting: small integers, exact zero, and the non-finite boundary.
fn generatedScalar(smith: *std.testing.Smith) phaser.kernel.Scalar {
    return switch (smith.valueRangeLessThan(u8, 0, 8)) {
        0 => 0,
        1 => @floatFromInt(@as(i8, @bitCast(smith.value(u8)))),
        2 => @as(phaser.kernel.Scalar, @floatFromInt(
            @as(i8, @bitCast(smith.value(u8))),
        )) / 4,
        3 => std.math.inf(phaser.kernel.Scalar),
        4 => -std.math.inf(phaser.kernel.Scalar),
        5 => std.math.nan(phaser.kernel.Scalar),
        6 => std.math.floatMax(phaser.kernel.Scalar),
        7 => @bitCast(smith.value(u64)),
        else => unreachable,
    };
}

test "parameter_point_parser" {
    try std.testing.fuzz({}, leakChecked(fuzzParameterPoint), .{
        .corpus = &.{
            @embedFile("../corpus/parameter_point_parser/valid.json"),
            @embedFile("../corpus/parameter_point_parser/scientific.json"),
            @embedFile("../corpus/parameter_point_parser/invalid.json"),
        },
    });
}

fn fuzzParameterPoint(_: void, smith: *std.testing.Smith) !void {
    const length = smith.valueRangeLessThan(u16, 0, 1025);
    var bytes: [1024]u8 = undefined;
    for (bytes[0..length]) |*byte| byte.* = smith.value(u8);

    const context = switch (foundation.Context.init(iteration_allocator, .{
        .max_diagnostics = 8,
        .max_related_locations = 8,
    })) {
        .context => |value| value,
        .failure => unreachable,
    };
    const source = phaser.PointSource{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = bytes[0..length],
    };

    const first = try phaser.parseParameterPoint(context, source, .{});
    const second = try phaser.parseParameterPoint(context, source, .{});

    switch (first) {
        .diagnostics => |value| {
            var owned = value;
            defer owned.deinit();
            var other = switch (second) {
                .diagnostics => |inner| inner,
                .point => |point| {
                    var owned_point = point;
                    owned_point.deinit();
                    return error.NondeterministicPointParse;
                },
            };
            defer other.deinit();
            try std.testing.expectEqual(owned.items.len, other.items.len);
            for (owned.items, other.items) |expected, actual| {
                try std.testing.expectEqual(expected.code, actual.code);
            }
        },
        .point => |value| {
            var owned = value;
            defer owned.deinit();
            var other = switch (second) {
                .point => |inner| inner,
                .diagnostics => |diagnostics| {
                    var owned_diagnostics = diagnostics;
                    owned_diagnostics.deinit();
                    return error.NondeterministicPointParse;
                },
            };
            defer other.deinit();

            // Every accepted point is finite, positively scaled, sorted, and
            // free of duplicate names.
            try std.testing.expect(std.math.isFinite(owned.reference_scale));
            try std.testing.expect(owned.reference_scale > 0);
            for (owned.entries) |entry| {
                try std.testing.expect(std.math.isFinite(entry.value));
            }
            if (owned.entries.len > 1) {
                for (
                    owned.entries[1..],
                    owned.entries[0 .. owned.entries.len - 1],
                ) |current, previous| {
                    try std.testing.expect(
                        std.mem.order(u8, previous.name, current.name) == .lt,
                    );
                }
            }
            try std.testing.expectEqual(owned.entries.len, other.entries.len);
        },
    }
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

// Keeps `targets.zig` honest.
//
// `build.zig` runs one filtered test binary per name in that file and
// `tools/corpus` derives each target's cache directory from it, so a target
// declared here but missing there is never fuzzed on its own and its generated
// corpus is invisible to the maintenance tool. Neither failure is loud, so the
// list is checked against the names the test runner actually reports.
test "the shared target list matches the declared fuzz targets" {
    const builtin = @import("builtin");
    const targets = @import("targets.zig");

    const guard = targets.test_name_prefix ++
        "the shared target list matches the declared fuzz targets";

    for (targets.names) |name| {
        const qualified = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{s}",
            .{ targets.test_name_prefix, name },
        );
        defer std.testing.allocator.free(qualified);

        var found = false;
        for (builtin.test_functions) |function| {
            if (std.mem.eql(u8, function.name, qualified)) {
                found = true;
                break;
            }
        }
        // A declared name with no test behind it: the filtered build step runs
        // nothing and the tool reports an empty corpus for a target that has
        // been renamed or removed.
        try std.testing.expect(found);
    }

    for (builtin.test_functions) |function| {
        // `test/fuzz.zig` contributes an unnamed aggregating test that carries
        // no target, and this guard is not a target either.
        if (!std.mem.startsWith(u8, function.name, targets.test_name_prefix)) continue;
        if (std.mem.eql(u8, function.name, guard)) continue;

        const name = function.name[targets.test_name_prefix.len..];
        var declared = false;
        for (targets.names) |candidate| {
            if (std.mem.eql(u8, candidate, name)) {
                declared = true;
                break;
            }
        }
        // A target the runner knows about that `targets.zig` does not: it never
        // gets its own campaign and its corpus is never staged for review.
        try std.testing.expect(declared);
    }
}
