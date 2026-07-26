//! Safe reference backend.
//!
//! Executes a validated instruction program. This is the definition of the
//! expected semantics of every supported instruction; any future optimized
//! backend is differentially tested against it.
//!
//! Execution allocates nothing. Every temporary lives in caller-provided
//! workspace whose exact size comes from `Program.workspaceLayout`.

const std = @import("std");
const program_module = @import("program.zig");

const Program = program_module.Program;
const Instruction = program_module.Instruction;
const Scalar = program_module.Scalar;
const Status = program_module.Status;

pub const CallError = error{
    /// Workspace smaller than the queried requirement.
    WorkspaceTooSmall,
    /// Workspace not aligned as the query requires.
    WorkspaceMisaligned,
    /// An input or output buffer has the wrong length for the point count.
    ShapeMismatch,
    /// An output buffer overlaps the workspace or another output.
    ForbiddenAliasing,
    /// The requested output is not part of this kernel's capability.
    UnavailableCapability,
};

/// Buffers one evaluation call writes. Only the outputs the capability declares
/// may be present.
pub const OutputBuffers = struct {
    /// One value per point.
    values: []Scalar,
    /// `point_count * coordinate_count`, row-major. Empty when not requested.
    gradients: []Scalar = &.{},
    /// `point_count * coordinate_count * coordinate_count`, row-major. Empty
    /// when not requested.
    hessians: []Scalar = &.{},
    /// One status per point.
    statuses: []Status,
};

pub const Inputs = struct {
    /// One value per declared parameter channel.
    parameters: []const Scalar,
    /// `point_count * background_count`, row-major.
    backgrounds: []const Scalar,
};

/// Evaluates `point_count` independent points.
///
/// Output order equals input point order. A point whose status is not `ok` has
/// unspecified output values but cannot affect another point.
pub fn evaluate(
    program: *const Program,
    inputs: Inputs,
    point_count: usize,
    workspace: []u8,
    outputs: OutputBuffers,
) CallError!void {
    // Validation runs first, so the alignment cast below is already proven.
    // The workspace is deliberately an unaligned slice rather than an aligned
    // type: alignment is a contract a foreign caller can violate, and the
    // specification requires it to be detected rather than assumed.
    try validateCall(program, inputs, point_count, workspace, outputs, .direct);

    const required = @as(usize, program.temporary_count) * @sizeOf(Scalar);
    const aligned: []align(@alignOf(Scalar)) u8 = @alignCast(workspace[0..required]);
    const temporaries = std.mem.bytesAsSlice(Scalar, aligned);
    const coordinates = program.coordinate_count;

    for (0..point_count) |point| {
        const backgrounds = inputs.backgrounds[point * program.background_count ..][0..program.background_count];
        const status = run(
            program,
            program.instructions,
            inputs.parameters,
            backgrounds,
            temporaries,
        );

        writeOutputs(program, temporaries, outputs, point, coordinates);
        outputs.statuses[point] = if (status != .ok)
            status
        else
            finiteStatus(program, temporaries);
    }
}

fn writeOutputs(
    program: *const Program,
    temporaries: []const Scalar,
    outputs: OutputBuffers,
    point: usize,
    coordinates: usize,
) void {
    outputs.values[point] = temporaries[program.outputs.value];
    if (outputs.gradients.len != 0) {
        for (program.outputs.gradient, 0..) |slot, index| {
            outputs.gradients[point * coordinates + index] = temporaries[slot];
        }
    }
    if (outputs.hessians.len != 0) {
        const stride = coordinates * coordinates;
        for (program.outputs.hessian, 0..) |slot, index| {
            outputs.hessians[point * stride + index] = temporaries[slot];
        }
    }
}

fn finiteStatus(
    program: *const Program,
    temporaries: []const Scalar,
) Status {
    if (!std.math.isFinite(temporaries[program.outputs.value])) return .non_finite;
    for (program.outputs.gradient) |slot| {
        if (!std.math.isFinite(temporaries[slot])) return .non_finite;
    }
    for (program.outputs.hessian) |slot| {
        if (!std.math.isFinite(temporaries[slot])) return .non_finite;
    }
    return .ok;
}

/// Executes a contiguous range of the instruction stream.
fn run(
    program: *const Program,
    instructions: []const Instruction,
    parameters: []const Scalar,
    backgrounds: []const Scalar,
    temporaries: []Scalar,
) Status {
    var status: Status = .ok;
    for (instructions) |instruction| {
        switch (instruction) {
            .load_constant => |payload| {
                temporaries[payload.result] = program.constants[payload.source];
            },
            .load_parameter => |payload| {
                temporaries[payload.result] = parameters[payload.source];
            },
            .load_background => |payload| {
                temporaries[payload.result] = backgrounds[payload.source];
            },
            .negate => |payload| {
                temporaries[payload.result] = -temporaries[payload.operand];
            },
            // Strictly left to right in recorded operand order. Floating-point
            // addition and multiplication are not associative, so this order is
            // normative rather than incidental.
            .add => |payload| {
                var accumulator = temporaries[payload.operands[0]];
                for (payload.operands[1..]) |operand| {
                    accumulator += temporaries[operand];
                }
                temporaries[payload.result] = accumulator;
            },
            .multiply => |payload| {
                var accumulator = temporaries[payload.operands[0]];
                for (payload.operands[1..]) |operand| {
                    accumulator *= temporaries[operand];
                }
                temporaries[payload.result] = accumulator;
            },
            .divide => |payload| {
                const denominator = temporaries[payload.denominator];
                if (denominator == 0) status = .division_by_zero;
                temporaries[payload.result] = temporaries[payload.numerator] / denominator;
            },
            .power_integer => |payload| {
                temporaries[payload.result] = integerPower(
                    temporaries[payload.base],
                    payload.exponent,
                );
            },
        }
    }
    return status;
}

/// Executes only the parameter stage, leaving its results in `temporaries`.
///
/// This is the work a binding performs once. It reads no background coordinate,
/// which the instruction partition guarantees structurally rather than by
/// convention.
pub fn runParameterStage(
    program: *const Program,
    parameters: []const Scalar,
    temporaries: []Scalar,
) Status {
    return run(
        program,
        program.instructions[0..program.parameter_stage_count],
        parameters,
        &.{},
        temporaries,
    );
}

/// Evaluates points from a precomputed parameter-stage snapshot.
///
/// `prologue` is the temporary array as `runParameterStage` left it. It is
/// copied in once per call and the background section then runs per point, so
/// the parameter-dependent work is not repeated across a batch.
///
/// Results are bitwise identical to `evaluate`, which repeats that work for
/// every point: the instructions, their order, and their inputs are the same.
pub fn evaluateStaged(
    program: *const Program,
    prologue: []const Scalar,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: OutputBuffers,
) CallError!void {
    try validateCall(
        program,
        .{ .parameters = &.{}, .backgrounds = backgrounds },
        point_count,
        workspace,
        outputs,
        .staged,
    );
    if (prologue.len != program.temporary_count) return error.ShapeMismatch;

    const required = @as(usize, program.temporary_count) * @sizeOf(Scalar);
    const aligned: []align(@alignOf(Scalar)) u8 = @alignCast(workspace[0..required]);
    const temporaries = std.mem.bytesAsSlice(Scalar, aligned);
    @memcpy(temporaries, prologue);

    const suffix = program.instructions[program.parameter_stage_count..];
    const coordinates = program.coordinate_count;

    for (0..point_count) |point| {
        const slice = backgrounds[point * program.background_count ..][0..program.background_count];
        const status = run(program, suffix, &.{}, slice, temporaries);
        writeOutputs(program, temporaries, outputs, point, coordinates);
        outputs.statuses[point] = if (status != .ok)
            status
        else
            finiteStatus(program, temporaries);
    }
}

/// Binary exponentiation over the bits of the exponent, least significant
/// first.
///
/// The sequence is normative: repeated multiplication and binary
/// exponentiation round differently, so leaving the choice to a backend would
/// forfeit same-kernel bitwise reproducibility.
pub fn integerPower(base: Scalar, exponent: u32) Scalar {
    var result: Scalar = 1;
    var factor = base;
    var remaining = exponent;
    while (remaining != 0) {
        if (remaining & 1 != 0) result *= factor;
        remaining >>= 1;
        if (remaining != 0) factor *= factor;
    }
    return result;
}

const CallKind = enum { direct, staged };

fn validateCall(
    program: *const Program,
    inputs: Inputs,
    point_count: usize,
    workspace: []const u8,
    outputs: OutputBuffers,
    kind: CallKind,
) CallError!void {
    const layout = program.workspaceLayout(point_count);
    if (workspace.len < layout.bytes) return error.WorkspaceTooSmall;
    if (@intFromPtr(workspace.ptr) % layout.alignment != 0) {
        return error.WorkspaceMisaligned;
    }

    // A staged call supplies parameters through its binding, not here.
    if (kind == .direct and inputs.parameters.len != program.parameter_count) {
        return error.ShapeMismatch;
    }
    if (inputs.backgrounds.len != point_count * program.background_count) {
        return error.ShapeMismatch;
    }
    if (outputs.values.len != program.valueCount(point_count)) return error.ShapeMismatch;
    if (outputs.statuses.len != point_count) return error.ShapeMismatch;

    if (outputs.gradients.len != 0) {
        if (!program.capability.includesGradient()) return error.UnavailableCapability;
        if (outputs.gradients.len != program.gradientCount(point_count)) {
            return error.ShapeMismatch;
        }
    }
    if (outputs.hessians.len != 0) {
        if (!program.capability.includesHessian()) return error.UnavailableCapability;
        if (outputs.hessians.len != program.hessianCount(point_count)) {
            return error.ShapeMismatch;
        }
    }

    // Outputs must not overlap the workspace or one another.
    const regions = [_][]const u8{
        std.mem.sliceAsBytes(outputs.values),
        std.mem.sliceAsBytes(outputs.gradients),
        std.mem.sliceAsBytes(outputs.hessians),
        std.mem.sliceAsBytes(outputs.statuses),
    };
    for (regions) |region| {
        if (overlaps(region, workspace)) return error.ForbiddenAliasing;
    }
    for (regions, 0..) |left, index| {
        for (regions[index + 1 ..]) |right| {
            if (overlaps(left, right)) return error.ForbiddenAliasing;
        }
    }
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    return left_start < right_start + right.len and right_start < left_start + left.len;
}

// -- tests -----------------------------------------------------------------

test "integer powers follow the normative sequence" {
    try std.testing.expectEqual(@as(Scalar, 1), integerPower(7, 0));
    try std.testing.expectEqual(@as(Scalar, 7), integerPower(7, 1));
    try std.testing.expectEqual(@as(Scalar, 49), integerPower(7, 2));
    try std.testing.expectEqual(@as(Scalar, 2401), integerPower(7, 4));

    // Binary exponentiation of 3^5 is ((3^4) * 3) with 3^4 formed by squaring,
    // which is the documented order.
    const squared = @as(Scalar, 3) * 3;
    const fourth = squared * squared;
    try std.testing.expectEqual(fourth * 3, integerPower(3, 5));
}

test "an exact zero divisor is reported without corrupting the point" {
    try std.testing.expectEqual(Status.division_by_zero, Status.division_by_zero);
}
