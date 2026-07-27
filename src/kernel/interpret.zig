//! Safe reference backend.
//!
//! Executes a validated instruction program. This is the definition of the
//! expected semantics of every supported instruction; any future optimized
//! backend is differentially tested against it.
//!
//! Execution allocates nothing. Every temporary lives in caller-provided
//! workspace whose exact size comes from `Program.workspaceLayout`.
//!
//! Publication is point-atomic. Instructions accumulate candidate outputs in
//! workspace, and a point's declared buffers are written only after every
//! instruction that point needs has succeeded.

const std = @import("std");
const numerics = @import("../numerics/root.zig");
const program_module = @import("program.zig");

const eigensolver = numerics.symmetric_eigensolver;
const spectral = numerics.spectral_derivative;
const Program = program_module.Program;
const Instruction = program_module.Instruction;
const Scalar = program_module.Scalar;
const Complex64 = program_module.Complex64;
const Status = program_module.Status;
const Temporary = program_module.Temporary;

pub const CallError = error{
    /// Workspace smaller than the queried requirement.
    WorkspaceTooSmall,
    /// Workspace not aligned as the query requires.
    WorkspaceMisaligned,
    /// An input or output buffer has the wrong length for the point count.
    ShapeMismatch,
    /// A point-count-dependent buffer size cannot be represented by `usize`.
    SizeOverflow,
    /// Inputs, outputs, and workspace are pairwise disjoint by contract.
    ForbiddenAliasing,
    /// The requested output is not part of this kernel's capability.
    UnavailableCapability,
    /// The buffer element type is not the kernel's declared result type.
    ResultTypeMismatch,
    /// A bound renormalization scale is not finite and positive.
    InvalidScale,
};

/// Buffers one real evaluation call writes. Only the outputs the capability
/// declares may be present.
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

/// The `Complex64` counterpart. A loop-containing selection uses this even
/// where a point's imaginary component happens to be zero.
pub const ComplexOutputBuffers = struct {
    values: []Complex64,
    gradients: []Complex64 = &.{},
    hessians: []Complex64 = &.{},
    statuses: []Status,
};

pub const Inputs = struct {
    /// One value per declared parameter channel.
    parameters: []const Scalar,
    /// One value per declared scale channel. Validated finite and positive.
    scales: []const Scalar = &.{},
    /// `point_count * background_count`, row-major.
    backgrounds: []const Scalar,
};

/// A typed view over the temporary frame.
///
/// Slot types were validated before the program became a kernel, so each
/// accessor asserts rather than checks: reading a slot at the wrong type would
/// be a programmer error in lowering, not a caller mistake.
const Frame = struct {
    bytes: []align(@alignOf(Scalar)) u8,
    temporaries: []const Temporary,

    fn region(self: Frame, slot: u32) []align(@alignOf(Scalar)) u8 {
        const descriptor = self.temporaries[slot];
        return @alignCast(self.bytes[descriptor.offset..][0..descriptor.bytes]);
    }

    fn scalars(self: Frame, slot: u32) []Scalar {
        return std.mem.bytesAsSlice(Scalar, self.region(slot));
    }

    fn real(self: Frame, slot: u32) *Scalar {
        std.debug.assert(self.temporaries[slot].kind == .real);
        return &self.scalars(slot)[0];
    }

    fn complex(self: Frame, slot: u32) *Complex64 {
        std.debug.assert(self.temporaries[slot].kind == .complex);
        const parts = self.scalars(slot);
        return @ptrCast(parts.ptr);
    }

    /// The authoritative packed upper triangle of a matrix temporary.
    fn matrix(self: Frame, slot: u32) []Scalar {
        std.debug.assert(self.temporaries[slot].kind == .real_symmetric_matrix);
        return self.scalars(slot);
    }

    fn eigenvalues(self: Frame, slot: u32) []Scalar {
        const dimension = self.temporaries[slot].kind.real_eigensystem;
        return self.scalars(slot)[0..dimension];
    }

    fn eigenvectors(self: Frame, slot: u32) []Scalar {
        const dimension = self.temporaries[slot].kind.real_eigensystem;
        return self.scalars(slot)[dimension..];
    }

    /// The components of a structured `Complex64` slot, in the layout its type
    /// declares: canonical coordinate order for a vector, dense row-major for a
    /// matrix.
    fn components(self: Frame, slot: u32) []Complex64 {
        std.debug.assert(switch (self.temporaries[slot].kind) {
            .complex_vector, .complex_matrix => true,
            else => false,
        });
        return std.mem.bytesAsSlice(Complex64, self.region(slot));
    }
};

/// Reads derivative matrices out of their separate temporaries.
///
/// The spectral derivative operation addresses its matrices by index rather
/// than expecting one contiguous buffer, because lowering assigns each of them
/// its own slot.
const FrameMatrices = struct {
    frame: Frame,
    first_slots: []const u32,
    second_slots: []const u32,

    pub fn first(self: FrameMatrices, index: usize) []const Scalar {
        return self.frame.matrix(self.first_slots[index]);
    }

    pub fn second(self: FrameMatrices, index: usize) []const Scalar {
        return self.frame.matrix(self.second_slots[index]);
    }
};

/// Evaluates `point_count` independent points into real buffers.
///
/// Output order equals input point order. A point whose status is not `ok`
/// leaves its output buffers untouched and cannot affect another point.
pub fn evaluate(
    program: *const Program,
    inputs: Inputs,
    point_count: usize,
    workspace: []u8,
    outputs: OutputBuffers,
) CallError!void {
    return evaluateTyped(.real64, program, inputs, point_count, workspace, outputs);
}

/// The `Complex64` counterpart of `evaluate`.
pub fn evaluateComplex(
    program: *const Program,
    inputs: Inputs,
    point_count: usize,
    workspace: []u8,
    outputs: ComplexOutputBuffers,
) CallError!void {
    return evaluateTyped(.complex64, program, inputs, point_count, workspace, outputs);
}

fn Buffers(comptime result_type: program_module.ResultType) type {
    return switch (result_type) {
        .real64 => OutputBuffers,
        .complex64 => ComplexOutputBuffers,
    };
}

fn evaluateTyped(
    comptime result_type: program_module.ResultType,
    program: *const Program,
    inputs: Inputs,
    point_count: usize,
    workspace: []u8,
    outputs: Buffers(result_type),
) CallError!void {
    // Validation runs first, so the alignment cast below is already proven.
    // The workspace is deliberately an unaligned slice rather than an aligned
    // type: alignment is a contract a foreign caller can violate, and the
    // specification requires it to be detected rather than assumed.
    try validateCall(
        result_type,
        program,
        inputs,
        &.{},
        point_count,
        workspace,
        outputs,
        .direct,
    );

    const frame = frameOf(program, workspace);
    for (0..point_count) |point| {
        const backgrounds = inputs.backgrounds[point * program.background_count ..][0..program.background_count];
        const status = run(
            program,
            program.instructions,
            inputs,
            backgrounds,
            frame,
            scratchOf(program, workspace),
        );
        publish(result_type, program, frame, outputs, point, status);
    }
}

/// Executes only the parameter stage, leaving its results in the frame.
///
/// This is the work a binding performs once. It reads no background coordinate,
/// which the instruction partition guarantees structurally rather than by
/// convention.
pub fn runParameterStage(
    program: *const Program,
    inputs: Inputs,
    frame_bytes: []align(@alignOf(Scalar)) u8,
    scratch: []u8,
) Status {
    const frame = Frame{
        .bytes = frame_bytes[0..program.frame_bytes],
        .temporaries = program.temporaries,
    };
    return run(
        program,
        program.instructions[0..program.parameter_stage_count],
        inputs,
        &.{},
        frame,
        scratch,
    );
}

/// Evaluates points from a precomputed parameter-stage snapshot.
///
/// `prologue` is the temporary frame as `runParameterStage` left it. It is
/// copied in once per call and the background section then runs per point, so
/// the parameter-dependent work is not repeated across a batch.
///
/// Results are bitwise identical to `evaluate`, which repeats that work for
/// every point: the instructions, their order, and their inputs are the same.
pub fn evaluateStaged(
    program: *const Program,
    prologue: []const u8,
    prologue_status: Status,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: OutputBuffers,
) CallError!void {
    return evaluateStagedTyped(
        .real64,
        program,
        prologue,
        prologue_status,
        backgrounds,
        point_count,
        workspace,
        outputs,
    );
}

pub fn evaluateStagedComplex(
    program: *const Program,
    prologue: []const u8,
    prologue_status: Status,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: ComplexOutputBuffers,
) CallError!void {
    return evaluateStagedTyped(
        .complex64,
        program,
        prologue,
        prologue_status,
        backgrounds,
        point_count,
        workspace,
        outputs,
    );
}

fn evaluateStagedTyped(
    comptime result_type: program_module.ResultType,
    program: *const Program,
    prologue: []const u8,
    prologue_status: Status,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: Buffers(result_type),
) CallError!void {
    try validateCall(
        result_type,
        program,
        .{ .parameters = &.{}, .backgrounds = backgrounds },
        prologue,
        point_count,
        workspace,
        outputs,
        .staged,
    );
    if (prologue.len != program.frame_bytes) return error.ShapeMismatch;

    const frame = frameOf(program, workspace);
    @memcpy(frame.bytes, prologue);

    const suffix = program.instructions[program.parameter_stage_count..];
    for (0..point_count) |point| {
        const slice = backgrounds[point * program.background_count ..][0..program.background_count];
        const status = run(
            program,
            suffix,
            .{ .parameters = &.{}, .backgrounds = slice },
            slice,
            frame,
            scratchOf(program, workspace),
        );
        publish(
            result_type,
            program,
            frame,
            outputs,
            point,
            if (prologue_status != .ok) prologue_status else status,
        );
    }
}

fn frameOf(program: *const Program, workspace: []u8) Frame {
    const aligned: []align(@alignOf(Scalar)) u8 = @alignCast(workspace[0..program.frame_bytes]);
    return .{ .bytes = aligned, .temporaries = program.temporaries };
}

/// The shared numerical scratch region, which follows the temporary frame.
fn scratchOf(program: *const Program, workspace: []u8) []u8 {
    return workspace[program.scratch_offset..][0..program.scratch_bytes];
}

/// Copies a point's candidate outputs to the caller's buffers.
///
/// A failed point publishes none of its declared outputs, so the caller's
/// buffer keeps whatever it held. That is what makes publication point-atomic:
/// there is no partial write to observe.
fn publish(
    comptime result_type: program_module.ResultType,
    program: *const Program,
    frame: Frame,
    outputs: Buffers(result_type),
    point: usize,
    computed: Status,
) void {
    const status = if (computed != .ok) computed else finiteStatus(result_type, program, frame);
    outputs.statuses[point] = status;
    if (status != .ok) return;

    const read = struct {
        fn of(view: Frame, slot: u32) result_type.Element() {
            return switch (result_type) {
                .real64 => view.real(slot).*,
                .complex64 => view.complex(slot).*,
            };
        }
    }.of;

    outputs.values[point] = read(frame, program.outputs.value);
    const coordinates = program.coordinate_count;
    if (outputs.gradients.len != 0) {
        for (program.outputs.gradient, 0..) |slot, index| {
            outputs.gradients[point * coordinates + index] = read(frame, slot);
        }
    }
    if (outputs.hessians.len != 0) {
        const stride = coordinates * coordinates;
        for (program.outputs.hessian, 0..) |slot, index| {
            outputs.hessians[point * stride + index] = read(frame, slot);
        }
    }
}

fn finiteStatus(
    comptime result_type: program_module.ResultType,
    program: *const Program,
    frame: Frame,
) Status {
    const finite = struct {
        fn of(view: Frame, slot: u32) bool {
            return switch (result_type) {
                .real64 => std.math.isFinite(view.real(slot).*),
                .complex64 => view.complex(slot).isFinite(),
            };
        }
    }.of;

    if (!finite(frame, program.outputs.value)) return .non_finite;
    for (program.outputs.gradient) |slot| {
        if (!finite(frame, slot)) return .non_finite;
    }
    for (program.outputs.hessian) |slot| {
        if (!finite(frame, slot)) return .non_finite;
    }
    return .ok;
}

/// Executes a contiguous range of the instruction stream.
fn run(
    program: *const Program,
    instructions: []const Instruction,
    inputs: Inputs,
    backgrounds: []const Scalar,
    frame: Frame,
    scratch: []u8,
) Status {
    var status: Status = .ok;
    for (instructions) |instruction| {
        switch (instruction) {
            .load_constant => |payload| {
                frame.real(payload.result).* = program.constants[payload.source];
            },
            .load_parameter => |payload| {
                frame.real(payload.result).* = inputs.parameters[payload.source];
            },
            .load_background => |payload| {
                frame.real(payload.result).* = backgrounds[payload.source];
            },
            .load_renormalization_scale => |payload| {
                frame.real(payload.result).* = inputs.scales[payload.source];
            },
            // Component-wise IEEE 754 negation, at either scalar type.
            .negate => |payload| switch (program.temporaries[payload.result].kind) {
                .complex => frame.complex(payload.result).* =
                    frame.complex(payload.operand).negate(),
                else => frame.real(payload.result).* = -frame.real(payload.operand).*,
            },
            // Strictly left to right in recorded operand order. Floating-point
            // addition and multiplication are not associative, so this order is
            // normative rather than incidental. Complex addition applies the
            // same sequence independently to each component.
            .add => |payload| switch (program.temporaries[payload.result].kind) {
                .complex => {
                    var accumulator = frame.complex(payload.operands[0]).*;
                    for (payload.operands[1..]) |operand| {
                        accumulator = accumulator.add(frame.complex(operand).*);
                    }
                    frame.complex(payload.result).* = accumulator;
                },
                else => {
                    var accumulator = frame.real(payload.operands[0]).*;
                    for (payload.operands[1..]) |operand| {
                        accumulator += frame.real(operand).*;
                    }
                    frame.real(payload.result).* = accumulator;
                },
            },
            .multiply => |payload| {
                var accumulator = frame.real(payload.operands[0]).*;
                for (payload.operands[1..]) |operand| {
                    accumulator *= frame.real(operand).*;
                }
                frame.real(payload.result).* = accumulator;
            },
            .divide => |payload| {
                const denominator = frame.real(payload.denominator).*;
                if (denominator == 0) status = .division_by_zero;
                frame.real(payload.result).* = frame.real(payload.numerator).* / denominator;
            },
            .power_integer => |payload| {
                frame.real(payload.result).* = integerPower(
                    frame.real(payload.base).*,
                    payload.exponent,
                );
            },
            // The only conversion between the domains, and it is exact.
            .promote_real_to_complex => |payload| {
                frame.complex(payload.result).* = .{
                    .re = frame.real(payload.operand).*,
                    .im = 0,
                };
            },
            // The upper triangle is authoritative. Nothing averages two
            // independently rounded triangles.
            .assemble_real_symmetric => |payload| {
                const target = frame.matrix(payload.result);
                for (payload.entries, target) |entry, *slot| {
                    slot.* = frame.real(entry).*;
                }
            },
            .symmetric_eigensystem => |payload| {
                const dimension = program.temporaries[payload.result].kind.real_eigensystem;
                const solved = eigensolver.solve(
                    dimension,
                    frame.matrix(payload.matrix),
                    scratch,
                    .{
                        .eigenvalues = frame.eigenvalues(payload.result),
                        .eigenvectors = frame.eigenvectors(payload.result),
                    },
                ) catch {
                    // Shape, workspace, and aliasing were fixed when the program
                    // was validated, so a call-level failure here would be an
                    // internal inconsistency rather than a point outcome.
                    unreachable;
                };
                if (pointStatusOf(solved)) |failure| status = failure;
            },
            .scalar_one_loop_sum => |payload| {
                frame.complex(payload.result).* = scalarOneLoopSum(
                    frame.eigenvalues(payload.eigensystem),
                    frame.real(payload.scale).*,
                );
            },
            // Both derivative orders reuse the eigensystem the value already
            // computed, so a point cannot diagonalize its mass matrix twice and
            // then differentiate a different spectrum than it reported.
            .scalar_one_loop_gradient => |payload| {
                const outcome = spectralDerivative(
                    scratch,
                    .{
                        .dimension = program.temporaries[payload.eigensystem]
                            .kind.real_eigensystem,
                        .coordinate_count = program.temporaries[payload.result]
                            .kind.complex_vector,
                        .order = .gradient,
                        .eigenvalues = frame.eigenvalues(payload.eigensystem),
                        .eigenvectors = frame.eigenvectors(payload.eigensystem),
                        .scale = frame.real(payload.scale).*,
                    },
                    .{
                        .frame = frame,
                        .first_slots = payload.first,
                        .second_slots = &.{},
                    },
                    .{ .gradient = frame.components(payload.result) },
                );
                if (derivativeStatusOf(outcome)) |failure| status = failure;
            },
            .scalar_one_loop_hessian => |payload| {
                const outcome = spectralDerivative(
                    scratch,
                    .{
                        .dimension = program.temporaries[payload.eigensystem]
                            .kind.real_eigensystem,
                        .coordinate_count = program.temporaries[payload.result]
                            .kind.complex_matrix,
                        .order = .hessian,
                        .eigenvalues = frame.eigenvalues(payload.eigensystem),
                        .eigenvectors = frame.eigenvectors(payload.eigensystem),
                        .scale = frame.real(payload.scale).*,
                    },
                    .{
                        .frame = frame,
                        .first_slots = payload.first,
                        .second_slots = payload.second,
                    },
                    .{ .hessian = frame.components(payload.result) },
                );
                if (derivativeStatusOf(outcome)) |failure| status = failure;
            },
            .extract_element => |payload| {
                const source = frame.components(payload.source);
                const stride = switch (program.temporaries[payload.source].kind) {
                    .complex_matrix => |dimension| dimension,
                    else => 1,
                };
                frame.complex(payload.result).* =
                    source[payload.row * stride + payload.column];
            },
        }
    }
    return status;
}

fn spectralDerivative(
    scratch: []u8,
    request: spectral.Request,
    matrices: FrameMatrices,
    outputs: spectral.Outputs,
) spectral.Status {
    return spectral.evaluate(request, matrices, scratch, outputs) catch {
        // Shape, workspace, and slot types were fixed when the program was
        // validated, so a call-level failure here would be an internal
        // inconsistency rather than a point outcome.
        unreachable;
    };
}

/// Maps an invariant derivative outcome onto a point status.
///
/// The outcomes stay distinct: an analytically known singularity is reported as
/// such rather than being turned into a generated infinity and reported as
/// `non_finite`.
fn derivativeStatusOf(outcome: spectral.Status) ?Status {
    return switch (outcome) {
        .ok => null,
        .non_finite => .non_finite,
        .singular_derivative => .singular_derivative,
    };
}

/// Maps an eigensolver outcome onto a point status.
///
/// The outcomes stay distinct: a spectrum that exhausted its convergence or
/// postcondition contract is `nonconvergent`, which is not the same as one
/// that produced a non-finite value, and neither is silently widened into the
/// other.
fn pointStatusOf(solved: eigensolver.Status) ?Status {
    return switch (solved) {
        .ok => null,
        .non_finite => .non_finite,
        .nonconvergent => .nonconvergent,
    };
}

/// The restricted scalar one-loop logarithmic term of one real eigenvalue.
///
/// This is the only logarithm Milestone 3 needs, and it is not a general
/// complex logarithm: it accepts no complex operand and implements only the
/// negative-real-axis branch fixed by formula version
/// `scalar-vacuum-msbar/1`, with `Arg(z)` in `(-pi, pi]`.
///
///     x^2 / (64 pi^2) * [Log(x / mu^2) - 3/2]
///
/// An exact zero returns exact `(0, 0)` from the analytic limit, without
/// forming a logarithm or multiplying zero by infinity.
pub fn scalarOneLoopTerm(eigenvalue: Scalar, scale: Scalar) Complex64 {
    if (eigenvalue == 0) return Complex64.zero;

    const square = eigenvalue * eigenvalue;
    const logarithm = @log(@abs(eigenvalue) / (scale * scale));
    const normalization = 64.0 * std.math.pi * std.math.pi;
    return .{
        .re = square * (logarithm - 1.5) / normalization,
        // A negative eigenvalue contributes the principal branch's imaginary
        // part. It is a successful result, never a clipped or projected one.
        .im = if (eigenvalue < 0) square / (64.0 * std.math.pi) else 0,
    };
}

/// The spectral sum in stored spectrum order.
///
/// Every eigensystem entry is visited, so degenerate eigenvalues keep their
/// multiplicity. Terms are added strictly left to right.
fn scalarOneLoopSum(eigenvalues: []const Scalar, scale: Scalar) Complex64 {
    var total = Complex64.zero;
    for (eigenvalues) |eigenvalue| {
        total = total.add(scalarOneLoopTerm(eigenvalue, scale));
    }
    return total;
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
    comptime result_type: program_module.ResultType,
    program: *const Program,
    inputs: Inputs,
    prologue: []const u8,
    point_count: usize,
    workspace: []const u8,
    outputs: Buffers(result_type),
    kind: CallKind,
) CallError!void {
    // The declared result type decides which method a caller may use, and it is
    // checked before any buffer is read or written.
    if (program.result_type != result_type) return error.ResultTypeMismatch;

    const layout = program.workspaceLayout(point_count);
    if (workspace.len < layout.bytes) return error.WorkspaceTooSmall;
    if (@intFromPtr(workspace.ptr) % layout.alignment != 0) {
        return error.WorkspaceMisaligned;
    }

    // A staged call supplies parameters and the scale through its binding.
    if (kind == .direct) {
        if (inputs.parameters.len != program.parameter_count) {
            return error.ShapeMismatch;
        }
        if (inputs.scales.len != program.scale_count) return error.ShapeMismatch;
        for (inputs.scales) |scale| {
            if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
        }
    }
    const background_values = std.math.mul(
        usize,
        point_count,
        @as(usize, program.background_count),
    ) catch return error.SizeOverflow;
    if (inputs.backgrounds.len != background_values) {
        return error.ShapeMismatch;
    }
    if (outputs.values.len != point_count) return error.ShapeMismatch;
    if (outputs.statuses.len != point_count) return error.ShapeMismatch;

    if (outputs.gradients.len != 0) {
        if (!program.capability.includesGradient()) return error.UnavailableCapability;
        const gradient_values = program.gradientCount(point_count) catch
            return error.SizeOverflow;
        if (outputs.gradients.len != gradient_values) {
            return error.ShapeMismatch;
        }
    }
    if (outputs.hessians.len != 0) {
        if (!program.capability.includesHessian()) return error.UnavailableCapability;
        const hessian_values = program.hessianCount(point_count) catch
            return error.SizeOverflow;
        if (outputs.hessians.len != hessian_values) {
            return error.ShapeMismatch;
        }
    }

    // Inputs, outputs, and workspace are pairwise disjoint. In particular,
    // writing an earlier point must not mutate a later point's input.
    const regions = [_][]const u8{
        std.mem.sliceAsBytes(inputs.parameters),
        std.mem.sliceAsBytes(inputs.scales),
        std.mem.sliceAsBytes(inputs.backgrounds),
        prologue,
        workspace,
        std.mem.sliceAsBytes(outputs.values),
        std.mem.sliceAsBytes(outputs.gradients),
        std.mem.sliceAsBytes(outputs.hessians),
        std.mem.sliceAsBytes(outputs.statuses),
    };
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
    return if (left_start <= right_start)
        right_start - left_start < left.len
    else
        left_start - right_start < right.len;
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

test "the one-loop term implements the principal branch and the zero limit" {
    const pi_squared = std.math.pi * std.math.pi;

    // A positive eigenvalue has an exactly zero imaginary component.
    const positive = scalarOneLoopTerm(1, 1);
    try std.testing.expectEqual(@as(Scalar, -1.5 / (64.0 * pi_squared)), positive.re);
    try std.testing.expectEqual(@as(Scalar, 0), positive.im);

    // A negative eigenvalue takes the principal branch: the real part uses the
    // magnitude and the imaginary part is x^2 / (64 pi).
    const negative = scalarOneLoopTerm(-1, 1);
    try std.testing.expectEqual(positive.re, negative.re);
    try std.testing.expectEqual(@as(Scalar, 1.0 / (64.0 * std.math.pi)), negative.im);

    // An exact zero uses the analytic limit rather than forming a logarithm.
    try std.testing.expectEqual(Complex64.zero, scalarOneLoopTerm(0, 1));
    try std.testing.expectEqual(Complex64.zero, scalarOneLoopTerm(0, 125));
}

test "every eigensolver outcome maps to its own distinct point status" {
    try std.testing.expectEqual(@as(?Status, null), pointStatusOf(.ok));
    try std.testing.expectEqual(@as(?Status, .non_finite), pointStatusOf(.non_finite));
    try std.testing.expectEqual(@as(?Status, .nonconvergent), pointStatusOf(.nonconvergent));

    // Exhaustive over the solver's outcomes, and injective into the kernel's,
    // so a future outcome cannot be quietly folded into an existing status.
    var seen = std.EnumSet(Status).initEmpty();
    for (std.meta.tags(eigensolver.Status)) |solved| {
        if (pointStatusOf(solved)) |mapped| {
            try std.testing.expect(!seen.contains(mapped));
            seen.insert(mapped);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen.count());
}

test "every invariant derivative outcome maps to its own distinct point status" {
    try std.testing.expectEqual(@as(?Status, null), derivativeStatusOf(.ok));
    try std.testing.expectEqual(
        @as(?Status, .non_finite),
        derivativeStatusOf(.non_finite),
    );
    // An analytically known singularity keeps its own status rather than being
    // reported as a generated infinity.
    try std.testing.expectEqual(
        @as(?Status, .singular_derivative),
        derivativeStatusOf(.singular_derivative),
    );

    var seen = std.EnumSet(Status).initEmpty();
    for (std.meta.tags(spectral.Status)) |outcome| {
        if (derivativeStatusOf(outcome)) |mapped| {
            try std.testing.expect(!seen.contains(mapped));
            seen.insert(mapped);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen.count());

    // The eigensolver and the derivative operation share the kernel's status
    // vocabulary without sharing outcomes: only `non_finite` is reachable from
    // both, and neither can produce the other's specific failure.
    try std.testing.expectEqual(
        @as(?Status, .nonconvergent),
        pointStatusOf(.nonconvergent),
    );
    try std.testing.expect(!seen.contains(.nonconvergent));
}

test "the spectral sum preserves multiplicity and adds in stored order" {
    const single = scalarOneLoopTerm(-2, 1);
    const repeated = scalarOneLoopSum(&.{ -2, -2 }, 1);
    try std.testing.expectEqual(single.re + single.re, repeated.re);
    try std.testing.expectEqual(single.im + single.im, repeated.im);

    // An empty spectrum sums to exact complex zero.
    try std.testing.expectEqual(Complex64.zero, scalarOneLoopSum(&.{}, 1));

    // A zero eigenvalue contributes nothing but does not suppress its
    // neighbours.
    const with_zero = scalarOneLoopSum(&.{ 0, 4 }, 1);
    const without = scalarOneLoopSum(&.{4}, 1);
    try std.testing.expectEqual(without.re, with_zero.re);
}
