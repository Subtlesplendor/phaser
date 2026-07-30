//! Optimized scalar and blocked instruction-major interpreter.
//!
//! Calls cross one complete checked boundary, then execute the immutable
//! predecoded plan. Arithmetic is vectorized only across independent points;
//! each lane retains the program's recorded operation and accumulation order.

const std = @import("std");
const numerics = @import("../numerics/root.zig");
const program_module = @import("program.zig");
const reference = @import("interpret.zig");
const plan_module = @import("optimized_plan.zig");

const eigensolver = numerics.symmetric_eigensolver;
const spectral = numerics.spectral_derivative;
const ExecutionPlan = plan_module.ExecutionPlan;
const Record = plan_module.Record;
const Scalar = program_module.Scalar;
const Complex64 = program_module.Complex64;
const Status = program_module.Status;
const ResultType = program_module.ResultType;
const lane_count = plan_module.block_width;
const vector_lane_count = plan_module.vector_width;

pub const CallError = reference.CallError;
pub const Inputs = reference.Inputs;
pub const OutputBuffers = reference.OutputBuffers;
pub const ComplexOutputBuffers = reference.ComplexOutputBuffers;

const Vector = @Vector(2, Scalar);

const Workspace = struct {
    block_frame: []Scalar,
    scalar_frame: []Scalar,
    scratch: []u8,
    lane_statuses: []Status,
};

pub fn evaluate(
    plan: *const ExecutionPlan,
    inputs: Inputs,
    point_count: usize,
    workspace: []u8,
    outputs: OutputBuffers,
) CallError!void {
    return evaluateTyped(
        .real64,
        plan,
        inputs,
        &.{},
        .ok,
        point_count,
        workspace,
        outputs,
        .direct,
    );
}

pub fn evaluateComplex(
    plan: *const ExecutionPlan,
    inputs: Inputs,
    point_count: usize,
    workspace: []u8,
    outputs: ComplexOutputBuffers,
) CallError!void {
    return evaluateTyped(
        .complex64,
        plan,
        inputs,
        &.{},
        .ok,
        point_count,
        workspace,
        outputs,
        .direct,
    );
}

pub fn evaluateStaged(
    plan: *const ExecutionPlan,
    prologue: []const u8,
    prologue_status: Status,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: OutputBuffers,
) CallError!void {
    return evaluateTyped(
        .real64,
        plan,
        .{ .parameters = &.{}, .backgrounds = backgrounds },
        prologue,
        prologue_status,
        point_count,
        workspace,
        outputs,
        .staged,
    );
}

pub fn evaluateStagedComplex(
    plan: *const ExecutionPlan,
    prologue: []const u8,
    prologue_status: Status,
    backgrounds: []const Scalar,
    point_count: usize,
    workspace: []u8,
    outputs: ComplexOutputBuffers,
) CallError!void {
    return evaluateTyped(
        .complex64,
        plan,
        .{ .parameters = &.{}, .backgrounds = backgrounds },
        prologue,
        prologue_status,
        point_count,
        workspace,
        outputs,
        .staged,
    );
}

/// Executes the predecoded parameter stage once and writes only regions live
/// into the background stage or final publication.
pub fn runParameterStage(
    plan: *const ExecutionPlan,
    inputs: Inputs,
    workspace_bytes: []u8,
    prologue_bytes: []align(@alignOf(Scalar)) u8,
) Status {
    std.debug.assert(prologue_bytes.len == plan.prologueBytes());
    std.debug.assert(workspace_bytes.len >= plan.workspace_bytes);
    const workspace = workspaceOf(plan, workspace_bytes);
    const status = executeScalar(
        plan,
        plan.records[0..plan.parameter_stage_count],
        inputs,
        0,
        workspace,
    );
    if (status != .ok) return status;
    const prologue = std.mem.bytesAsSlice(Scalar, prologue_bytes);
    for (plan.prologue_entries) |entry| {
        for (0..entry.scalar_count) |component| {
            prologue[entry.prologue_offset + component] =
                scalarAt(workspace.block_frame, entry.frame_offset + component, 0).*;
        }
    }
    return status;
}

fn evaluateTyped(
    comptime result_type: ResultType,
    plan: *const ExecutionPlan,
    inputs: Inputs,
    prologue: []const u8,
    prologue_status: Status,
    point_count: usize,
    workspace_bytes: []u8,
    outputs: reference.Buffers(result_type),
    kind: reference.CallKind,
) CallError!void {
    const layout = plan.workspaceLayout(point_count);
    try reference.validateCall(
        result_type,
        &plan.program,
        inputs,
        prologue,
        point_count,
        layout,
        workspace_bytes,
        outputs,
        kind,
    );
    if (kind == .staged and prologue.len != plan.prologueBytes()) {
        return error.ShapeMismatch;
    }

    const workspace = workspaceOf(plan, workspace_bytes);
    const records = switch (kind) {
        .direct => plan.records,
        .staged => plan.records[plan.parameter_stage_count..],
    };

    var point: usize = 0;
    if (lane_count > 1) {
        while (point + lane_count <= point_count) : (point += lane_count) {
            const statuses = workspace.lane_statuses[0..lane_count];
            @memset(statuses, .ok);
            if (kind == .staged) {
                materializePrologue(plan, prologue, workspace.block_frame, lane_count);
                if (prologue_status != .ok) {
                    @memset(statuses, prologue_status);
                } else {
                    executeFullBlock(plan, records, inputs, point, workspace, statuses);
                }
            } else {
                executeFullBlock(plan, records, inputs, point, workspace, statuses);
            }
            publishBlock(
                result_type,
                plan,
                workspace.block_frame,
                outputs,
                point,
                statuses,
            );
        }
    }

    while (point < point_count) : (point += 1) {
        var status = prologue_status;
        if (kind == .staged) {
            materializePrologue(plan, prologue, workspace.block_frame, 1);
        }
        if (status == .ok) {
            status = executeScalar(plan, records, inputs, point, workspace);
        }
        publishLane(
            result_type,
            plan,
            workspace.block_frame,
            outputs,
            point,
            0,
            status,
        );
    }
}

fn workspaceOf(plan: *const ExecutionPlan, bytes: []u8) Workspace {
    const aligned: []align(@alignOf(Scalar)) u8 =
        @alignCast(bytes[0..plan.workspace_bytes]);
    const block = std.mem.bytesAsSlice(
        Scalar,
        aligned[0..plan.block_frame_bytes],
    );
    const scalar_bytes = plan.frame_scalars * @sizeOf(Scalar);
    const scalar_region: []align(@alignOf(Scalar)) u8 = @alignCast(
        aligned[plan.scalar_frame_offset..][0..scalar_bytes],
    );
    const scalar = std.mem.bytesAsSlice(
        Scalar,
        scalar_region,
    );
    return .{
        .block_frame = block,
        .scalar_frame = scalar,
        .scratch = aligned[plan.scratch_offset..][0..plan.scratch_bytes],
        .lane_statuses = std.mem.bytesAsSlice(
            Status,
            aligned[plan.lane_status_offset..][0 .. lane_count * @sizeOf(Status)],
        ),
    };
}

fn materializePrologue(
    plan: *const ExecutionPlan,
    prologue_bytes: []const u8,
    frame: []Scalar,
    active_lanes: usize,
) void {
    const aligned: []align(@alignOf(Scalar)) const u8 =
        @alignCast(prologue_bytes);
    const prologue = std.mem.bytesAsSlice(Scalar, aligned);
    for (plan.prologue_entries) |entry| {
        for (0..entry.scalar_count) |component| {
            const value = prologue[entry.prologue_offset + component];
            for (0..active_lanes) |lane| {
                scalarAt(frame, entry.frame_offset + component, lane).* = value;
            }
        }
    }
}

fn executeScalar(
    plan: *const ExecutionPlan,
    records: []const Record,
    inputs: Inputs,
    point: usize,
    workspace: Workspace,
) Status {
    const frame = workspace.block_frame;
    for (records) |record| {
        switch (record) {
            .load_constant => |payload| {
                scalarAt(frame, payload.result, 0).* =
                    plan.program.constants[payload.source];
            },
            .load_parameter => |payload| {
                scalarAt(frame, payload.result, 0).* = inputs.parameters[payload.source];
            },
            .load_background => |payload| {
                const source = point * plan.program.background_count + payload.source;
                scalarAt(frame, payload.result, 0).* = inputs.backgrounds[source];
            },
            .load_renormalization_scale => |payload| {
                scalarAt(frame, payload.result, 0).* = inputs.scales[payload.source];
            },
            .negate => |payload| trustedNegateScalar(frame, payload),
            .add => |payload| trustedVariadicScalar(frame, payload, .add),
            .multiply => |payload| trustedVariadicScalar(frame, payload, .multiply),
            .divide => |payload| {
                const denominator = scalarAt(frame, payload.denominator, 0).*;
                if (denominator == 0) return .division_by_zero;
                scalarAt(frame, payload.result, 0).* =
                    scalarAt(frame, payload.numerator, 0).* / denominator;
            },
            .power_integer => |payload| {
                scalarAt(frame, payload.result, 0).* = trustedPowerScalar(
                    scalarAt(frame, payload.base, 0).*,
                    payload.exponent,
                );
            },
            .promote_real_to_complex => |payload| {
                scalarAt(frame, payload.result, 0).* =
                    scalarAt(frame, payload.operand, 0).*;
                scalarAt(frame, payload.result + 1, 0).* = 0;
            },
            .assemble_real_symmetric => |payload| {
                for (payload.entries, 0..) |entry, component| {
                    scalarAt(frame, payload.result + component, 0).* =
                        scalarAt(frame, entry, 0).*;
                }
            },
            .symmetric_eigensystem,
            .scalar_one_loop_gradient,
            .scalar_one_loop_hessian,
            => {
                if (executeStructuredLane(record, workspace, 0)) |failure| {
                    return failure;
                }
            },
            .scalar_one_loop_sum => |payload| {
                writeComplexLane(
                    frame,
                    payload.result,
                    0,
                    spectralSumLane(frame, payload, 0),
                );
            },
            .extract_element => |payload| {
                scalarAt(frame, payload.result, 0).* =
                    scalarAt(frame, payload.source_component, 0).*;
                scalarAt(frame, payload.result + 1, 0).* =
                    scalarAt(frame, payload.source_component + 1, 0).*;
            },
        }
    }
    return .ok;
}

fn executeFullBlock(
    plan: *const ExecutionPlan,
    records: []const Record,
    inputs: Inputs,
    first_point: usize,
    workspace: Workspace,
    statuses: []Status,
) void {
    std.debug.assert(lane_count > 1);
    const frame = workspace.block_frame;
    for (records) |record| {
        switch (record) {
            .load_constant => |payload| {
                broadcast(frame, payload.result, plan.program.constants[payload.source]);
            },
            .load_parameter => |payload| {
                broadcast(frame, payload.result, inputs.parameters[payload.source]);
            },
            .load_background => |payload| {
                for (0..lane_count) |lane| {
                    const source = (first_point + lane) *
                        plan.program.background_count + payload.source;
                    scalarAt(frame, payload.result, lane).* = inputs.backgrounds[source];
                }
            },
            .load_renormalization_scale => |payload| {
                broadcast(frame, payload.result, inputs.scales[payload.source]);
            },
            .negate => |payload| trustedNegateBlock(frame, payload, statuses),
            .add => |payload| {
                trustedVariadicBlock(frame, payload, .add, statuses);
            },
            .multiply => |payload| {
                trustedVariadicBlock(frame, payload, .multiply, statuses);
            },
            .divide => |payload| trustedDivideBlock(frame, payload, statuses),
            .power_integer => |payload| trustedPowerBlock(frame, payload, statuses),
            .promote_real_to_complex => |payload| {
                copyActiveComponent(
                    frame,
                    payload.result,
                    payload.operand,
                    statuses,
                );
                zeroComponent(frame, payload.result + 1);
            },
            .assemble_real_symmetric => |payload| {
                for (payload.entries, 0..) |entry, component| {
                    copyActiveComponent(
                        frame,
                        payload.result + component,
                        entry,
                        statuses,
                    );
                }
            },
            .symmetric_eigensystem,
            .scalar_one_loop_gradient,
            .scalar_one_loop_hessian,
            => {
                for (0..lane_count) |lane| {
                    if (statuses[lane] != .ok) continue;
                    if (executeStructuredLane(record, workspace, lane)) |failure| {
                        statuses[lane] = failure;
                        zeroLane(frame, plan.frame_scalars, lane);
                    }
                }
            },
            .scalar_one_loop_sum => |payload| {
                for (0..lane_count) |lane| {
                    if (statuses[lane] == .ok) {
                        writeComplexLane(
                            frame,
                            payload.result,
                            lane,
                            spectralSumLane(frame, payload, lane),
                        );
                    } else {
                        writeComplexLane(frame, payload.result, lane, Complex64.zero);
                    }
                }
            },
            .extract_element => |payload| {
                copyActiveComponent(
                    frame,
                    payload.result,
                    payload.source_component,
                    statuses,
                );
                copyActiveComponent(
                    frame,
                    payload.result + 1,
                    payload.source_component + 1,
                    statuses,
                );
            },
        }
    }
}

fn executeStructuredLane(record: Record, workspace: Workspace, lane: usize) ?Status {
    return switch (record) {
        .symmetric_eigensystem => |payload| blk: {
            gatherRange(
                workspace.block_frame,
                workspace.scalar_frame,
                payload.matrix,
                payload.packed_count,
                lane,
            );
            const result = workspace.scalar_frame[payload.result..][0..payload.result_scalars];
            const n: usize = payload.dimension;
            const solved = eigensolver.solveValidated(.{
                .dimension = n,
                .packed_upper = workspace.scalar_frame[payload.matrix..][0..payload.packed_count],
                .workspace = workspace.scratch[0..payload.workspace.bytes],
                .outputs = .{
                    .eigenvalues = result[0..n],
                    .eigenvectors = result[n..],
                },
            });
            if (eigensystemStatus(solved)) |failure| break :blk failure;
            scatterRange(
                workspace.block_frame,
                workspace.scalar_frame,
                payload.result,
                payload.result_scalars,
                lane,
            );
            break :blk null;
        },
        .scalar_one_loop_gradient,
        .scalar_one_loop_hessian,
        => |payload| blk: {
            const eigensystem_scalars = payload.prepared.dimension +
                payload.prepared.square;
            gatherRange(
                workspace.block_frame,
                workspace.scalar_frame,
                payload.eigensystem,
                eigensystem_scalars,
                lane,
            );
            for (payload.first) |offset| {
                gatherRange(
                    workspace.block_frame,
                    workspace.scalar_frame,
                    offset,
                    payload.prepared.triangle,
                    lane,
                );
            }
            for (payload.second) |offset| {
                gatherRange(
                    workspace.block_frame,
                    workspace.scalar_frame,
                    offset,
                    payload.prepared.triangle,
                    lane,
                );
            }
            const output_scalars = payload.prepared.output_entries * 2;
            const output_parts = workspace.scalar_frame[payload.result..][0..output_scalars];
            const output_complex = std.mem.bytesAsSlice(
                Complex64,
                std.mem.sliceAsBytes(output_parts),
            );
            const matrices = ScalarFrameMatrices{
                .frame = workspace.scalar_frame,
                .first_offsets = payload.first,
                .second_offsets = payload.second,
                .triangle = payload.prepared.triangle,
            };
            const outcome = spectral.evaluateValidated(
                payload.prepared,
                .{
                    .dimension = @intCast(payload.prepared.dimension),
                    .coordinate_count = @intCast(payload.prepared.coordinate_count),
                    .order = payload.prepared.order,
                    .eigenvalues = workspace.scalar_frame[payload.eigensystem..][0..payload.prepared.dimension],
                    .eigenvectors = workspace.scalar_frame[payload.eigensystem + payload.prepared.dimension ..][0..payload.prepared.square],
                    .scale = scalarAt(workspace.block_frame, payload.scale, lane).*,
                },
                matrices,
                workspace.scratch[0..payload.prepared.layout.bytes],
                switch (payload.prepared.order) {
                    .gradient => .{ .gradient = output_complex },
                    .hessian => .{ .hessian = output_complex },
                },
            );
            if (spectralStatus(outcome)) |failure| break :blk failure;
            scatterRange(
                workspace.block_frame,
                workspace.scalar_frame,
                payload.result,
                output_scalars,
                lane,
            );
            break :blk null;
        },
        else => unreachable,
    };
}

const ScalarFrameMatrices = struct {
    frame: []Scalar,
    first_offsets: []const usize,
    second_offsets: []const usize,
    triangle: usize,

    pub fn first(self: ScalarFrameMatrices, index: usize) []const Scalar {
        return self.frame[self.first_offsets[index]..][0..self.triangle];
    }

    pub fn second(self: ScalarFrameMatrices, index: usize) []const Scalar {
        return self.frame[self.second_offsets[index]..][0..self.triangle];
    }
};

fn spectralSumLane(
    frame: []Scalar,
    payload: plan_module.SpectralSum,
    lane: usize,
) Complex64 {
    var total = Complex64.zero;
    for (0..payload.dimension) |index| {
        total = total.add(reference.scalarOneLoopTerm(
            scalarAt(frame, payload.eigensystem + index, lane).*,
            scalarAt(frame, payload.scale, lane).*,
        ));
    }
    return total;
}

const VariadicOperation = enum { add, multiply };

fn trustedNegateScalar(frame: []Scalar, payload: plan_module.Unary) void {
    @setRuntimeSafety(false);
    for (0..payload.components) |component| {
        scalarAt(frame, payload.result + component, 0).* =
            -scalarAt(frame, payload.operand + component, 0).*;
    }
}

fn trustedVariadicScalar(
    frame: []Scalar,
    payload: plan_module.Variadic,
    operation: VariadicOperation,
) void {
    @setRuntimeSafety(false);
    for (0..payload.components) |component| {
        var accumulator = scalarAt(
            frame,
            payload.operands[0] + component,
            0,
        ).*;
        for (payload.operands[1..]) |operand| {
            const value = scalarAt(frame, operand + component, 0).*;
            accumulator = switch (operation) {
                .add => accumulator + value,
                .multiply => accumulator * value,
            };
        }
        scalarAt(frame, payload.result + component, 0).* = accumulator;
    }
}

fn trustedPowerScalar(base: Scalar, exponent: u32) Scalar {
    @setRuntimeSafety(false);
    return reference.integerPower(base, exponent);
}

fn trustedNegateBlock(
    frame: []Scalar,
    payload: plan_module.Unary,
    statuses: []const Status,
) void {
    @setRuntimeSafety(false);
    for (0..payload.components) |component| {
        for (0..vectorGroupCount()) |group| {
            const value = readVector(frame, payload.operand + component, group);
            writeActiveVector(
                frame,
                payload.result + component,
                group,
                -value,
                statuses,
            );
        }
    }
}

fn trustedVariadicBlock(
    frame: []Scalar,
    payload: plan_module.Variadic,
    operation: VariadicOperation,
    statuses: []const Status,
) void {
    @setRuntimeSafety(false);
    for (0..payload.components) |component| {
        for (0..vectorGroupCount()) |group| {
            var accumulator = readVector(
                frame,
                payload.operands[0] + component,
                group,
            );
            for (payload.operands[1..]) |operand| {
                const value = readVector(frame, operand + component, group);
                accumulator = switch (operation) {
                    .add => accumulator + value,
                    .multiply => accumulator * value,
                };
            }
            writeActiveVector(
                frame,
                payload.result + component,
                group,
                accumulator,
                statuses,
            );
        }
    }
}

fn trustedDivideBlock(
    frame: []Scalar,
    payload: plan_module.Quotient,
    statuses: []Status,
) void {
    @setRuntimeSafety(false);
    for (0..lane_count) |lane| {
        if (statuses[lane] == .ok and
            scalarAt(frame, payload.denominator, lane).* == 0)
        {
            statuses[lane] = .division_by_zero;
        }
    }
    for (0..vectorGroupCount()) |group| {
        const quotient = readVector(frame, payload.numerator, group) /
            readVector(frame, payload.denominator, group);
        writeActiveVector(frame, payload.result, group, quotient, statuses);
    }
}

fn trustedPowerBlock(
    frame: []Scalar,
    payload: plan_module.IntegerPower,
    statuses: []const Status,
) void {
    @setRuntimeSafety(false);
    for (0..vectorGroupCount()) |group| {
        var result: Vector = @splat(1);
        var factor = readVector(frame, payload.base, group);
        var remaining = payload.exponent;
        while (remaining != 0) {
            if (remaining & 1 != 0) result *= factor;
            remaining >>= 1;
            if (remaining != 0) factor *= factor;
        }
        writeActiveVector(frame, payload.result, group, result, statuses);
    }
}

fn vectorGroupCount() usize {
    std.debug.assert(vector_lane_count == 2);
    return lane_count / vector_lane_count;
}

fn readVector(frame: []Scalar, offset: usize, group: usize) Vector {
    const first = offset * lane_count + group * vector_lane_count;
    return .{ frame[first], frame[first + 1] };
}

fn writeActiveVector(
    frame: []Scalar,
    offset: usize,
    group: usize,
    value: Vector,
    statuses: []const Status,
) void {
    const first_lane = group * vector_lane_count;
    const values: [vector_lane_count]Scalar = value;
    for (values, 0..) |element, within| {
        const lane = first_lane + within;
        scalarAt(frame, offset, lane).* =
            if (statuses[lane] == .ok) element else 0;
    }
}

fn copyActiveComponent(
    frame: []Scalar,
    result: usize,
    operand: usize,
    statuses: []const Status,
) void {
    for (0..lane_count) |lane| {
        scalarAt(frame, result, lane).* = if (statuses[lane] == .ok)
            scalarAt(frame, operand, lane).*
        else
            0;
    }
}

fn zeroComponent(frame: []Scalar, offset: usize) void {
    @memset(frame[offset * lane_count ..][0..lane_count], 0);
}

fn zeroLane(frame: []Scalar, frame_scalars: usize, lane: usize) void {
    for (0..frame_scalars) |offset| scalarAt(frame, offset, lane).* = 0;
}

fn broadcast(frame: []Scalar, offset: usize, value: Scalar) void {
    @memset(frame[offset * lane_count ..][0..lane_count], value);
}

fn scalarAt(frame: []Scalar, offset: usize, lane: usize) *Scalar {
    return &frame[offset * lane_count + lane];
}

fn writeComplexLane(
    frame: []Scalar,
    offset: usize,
    lane: usize,
    value: Complex64,
) void {
    scalarAt(frame, offset, lane).* = value.re;
    scalarAt(frame, offset + 1, lane).* = value.im;
}

fn readComplexLane(
    frame: []const Scalar,
    offset: usize,
    lane: usize,
) Complex64 {
    return .{
        .re = frame[offset * lane_count + lane],
        .im = frame[(offset + 1) * lane_count + lane],
    };
}

fn gatherRange(
    block_frame: []const Scalar,
    scalar_frame: []Scalar,
    offset: usize,
    count: usize,
    lane: usize,
) void {
    for (0..count) |component| {
        scalar_frame[offset + component] =
            block_frame[(offset + component) * lane_count + lane];
    }
}

fn scatterRange(
    block_frame: []Scalar,
    scalar_frame: []const Scalar,
    offset: usize,
    count: usize,
    lane: usize,
) void {
    for (0..count) |component| {
        scalarAt(block_frame, offset + component, lane).* =
            scalar_frame[offset + component];
    }
}

fn eigensystemStatus(status: eigensolver.Status) ?Status {
    return switch (status) {
        .ok => null,
        .non_finite => .non_finite,
        .nonconvergent => .nonconvergent,
    };
}

fn spectralStatus(status: spectral.Status) ?Status {
    return switch (status) {
        .ok => null,
        .non_finite => .non_finite,
        .singular_derivative => .singular_derivative,
    };
}

fn publishBlock(
    comptime result_type: ResultType,
    plan: *const ExecutionPlan,
    frame: []const Scalar,
    outputs: reference.Buffers(result_type),
    first_point: usize,
    statuses: []Status,
) void {
    for (0..lane_count) |lane| {
        publishLane(
            result_type,
            plan,
            frame,
            outputs,
            first_point + lane,
            lane,
            statuses[lane],
        );
    }
}

fn publishLane(
    comptime result_type: ResultType,
    plan: *const ExecutionPlan,
    frame: []const Scalar,
    outputs: reference.Buffers(result_type),
    point: usize,
    lane: usize,
    computed: Status,
) void {
    var status = computed;
    if (status == .ok) {
        if (!outputFinite(result_type, frame, plan.outputs.value, lane)) {
            status = .non_finite;
        }
        if (status == .ok) {
            for (plan.outputs.gradient) |offset| {
                if (!outputFinite(result_type, frame, offset, lane)) {
                    status = .non_finite;
                    break;
                }
            }
        }
        if (status == .ok) {
            for (plan.outputs.hessian) |offset| {
                if (!outputFinite(result_type, frame, offset, lane)) {
                    status = .non_finite;
                    break;
                }
            }
        }
    }
    outputs.statuses[point] = status;
    if (status != .ok) return;

    outputs.values[point] = readOutput(result_type, frame, plan.outputs.value, lane);
    if (outputs.gradients.len != 0) {
        for (plan.outputs.gradient, 0..) |offset, index| {
            outputs.gradients[point * plan.program.coordinate_count + index] =
                readOutput(result_type, frame, offset, lane);
        }
    }
    if (outputs.hessians.len != 0) {
        const stride = plan.program.coordinate_count * plan.program.coordinate_count;
        for (plan.outputs.hessian, 0..) |offset, index| {
            outputs.hessians[point * stride + index] =
                readOutput(result_type, frame, offset, lane);
        }
    }
}

fn outputFinite(
    comptime result_type: ResultType,
    frame: []const Scalar,
    offset: usize,
    lane: usize,
) bool {
    return switch (result_type) {
        .real64 => std.math.isFinite(frame[offset * lane_count + lane]),
        .complex64 => readComplexLane(frame, offset, lane).isFinite(),
    };
}

fn readOutput(
    comptime result_type: ResultType,
    frame: []const Scalar,
    offset: usize,
    lane: usize,
) result_type.Element() {
    return switch (result_type) {
        .real64 => frame[offset * lane_count + lane],
        .complex64 => readComplexLane(frame, offset, lane),
    };
}

test "lane failures are isolated across a full block and scalar remainder" {
    const instructions = [_]program_module.Instruction{
        .{ .load_constant = .{ .result = 0, .source = 0 } },
        .{ .load_background = .{ .result = 1, .source = 0 } },
        .{ .divide = .{ .result = 2, .numerator = 0, .denominator = 1 } },
    };
    const temporaries = [_]program_module.Temporary{
        .{
            .kind = .real,
            .alignment = @alignOf(Scalar),
            .offset = 0,
            .bytes = @sizeOf(Scalar),
            .live = .{ .first_write = 0, .last_use = 2 },
        },
        .{
            .kind = .real,
            .alignment = @alignOf(Scalar),
            .offset = @sizeOf(Scalar),
            .bytes = @sizeOf(Scalar),
            .live = .{ .first_write = 1, .last_use = 2 },
        },
        .{
            .kind = .real,
            .alignment = @alignOf(Scalar),
            .offset = 2 * @sizeOf(Scalar),
            .bytes = @sizeOf(Scalar),
            .live = .{ .first_write = 2, .last_use = 2 },
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program = program_module.Program{
        .arena = &arena,
        .instructions = &instructions,
        .constants = &.{1},
        .temporaries = &temporaries,
        .outputs = .{ .value = 2, .gradient = &.{}, .hessian = &.{} },
        .capability = .value,
        .result_type = .real64,
        .frame_bytes = 3 * @sizeOf(Scalar),
        .scratch_offset = 3 * @sizeOf(Scalar),
        .scratch_bytes = 0,
        .parameter_stage_count = 1,
        .parameter_count = 0,
        .scale_count = 0,
        .background_count = 1,
        .coordinate_count = 1,
    };
    try program.validate(std.testing.allocator, 64);
    var plan = try plan_module.compile(std.testing.allocator, &program);
    defer plan.deinit();

    const backgrounds = [_]Scalar{ 2, 0, -4, -0.0, 8, 16, -2, 0, 0.25 };
    const sentinel: Scalar = -12345;
    var values = [_]Scalar{sentinel} ** backgrounds.len;
    var statuses: [backgrounds.len]Status = undefined;
    const layout = plan.workspaceLayout(backgrounds.len);
    const workspace = try std.testing.allocator.alignedAlloc(
        u8,
        .of(@Vector(2, Scalar)),
        layout.bytes,
    );
    defer std.testing.allocator.free(workspace);

    try evaluate(
        &plan,
        .{ .parameters = &.{}, .backgrounds = &backgrounds },
        backgrounds.len,
        workspace,
        .{ .values = &values, .statuses = &statuses },
    );
    try std.testing.expectEqualSlices(Status, &.{
        .ok,
        .division_by_zero,
        .ok,
        .division_by_zero,
        .ok,
        .ok,
        .ok,
        .division_by_zero,
        .ok,
    }, &statuses);
    try std.testing.expectEqual(@as(Scalar, 0.5), values[0]);
    try std.testing.expectEqual(sentinel, values[1]);
    try std.testing.expectEqual(@as(Scalar, -0.25), values[2]);
    try std.testing.expectEqual(sentinel, values[3]);
    try std.testing.expectEqual(@as(Scalar, 0.125), values[4]);
    try std.testing.expectEqual(@as(Scalar, 0.0625), values[5]);
    try std.testing.expectEqual(@as(Scalar, -0.5), values[6]);
    try std.testing.expectEqual(sentinel, values[7]);
    try std.testing.expectEqual(@as(Scalar, 4), values[8]);

    var partitioned_values = [_]Scalar{sentinel} ** backgrounds.len;
    var partitioned_statuses: [backgrounds.len]Status = undefined;
    const boundaries = [_]usize{ 0, 2, 5, backgrounds.len };
    for (boundaries[0 .. boundaries.len - 1], boundaries[1..]) |start, end| {
        try evaluate(
            &plan,
            .{ .parameters = &.{}, .backgrounds = backgrounds[start..end] },
            end - start,
            workspace,
            .{
                .values = partitioned_values[start..end],
                .statuses = partitioned_statuses[start..end],
            },
        );
    }
    try std.testing.expectEqualSlices(Scalar, &values, &partitioned_values);
    try std.testing.expectEqualSlices(Status, &statuses, &partitioned_statuses);

    const order = [_]usize{ 8, 3, 6, 1, 5, 0, 7, 2, 4 };
    var permuted_backgrounds: [backgrounds.len]Scalar = undefined;
    for (order, &permuted_backgrounds) |source, *destination| {
        destination.* = backgrounds[source];
    }
    var permuted_values = [_]Scalar{sentinel} ** backgrounds.len;
    var permuted_statuses: [backgrounds.len]Status = undefined;
    try evaluate(
        &plan,
        .{ .parameters = &.{}, .backgrounds = &permuted_backgrounds },
        permuted_backgrounds.len,
        workspace,
        .{
            .values = &permuted_values,
            .statuses = &permuted_statuses,
        },
    );
    for (order, permuted_values, permuted_statuses) |
        source,
        permuted_value,
        permuted_status,
    | {
        try std.testing.expectEqual(statuses[source], permuted_status);
        try std.testing.expectEqual(values[source], permuted_value);
    }

    try std.testing.expectError(
        error.WorkspaceTooSmall,
        evaluate(
            &plan,
            .{ .parameters = &.{}, .backgrounds = &backgrounds },
            backgrounds.len,
            workspace[0 .. layout.bytes - 1],
            .{ .values = &values, .statuses = &statuses },
        ),
    );

    const misaligned_storage = try std.testing.allocator.alignedAlloc(
        u8,
        .of(@Vector(2, Scalar)),
        layout.bytes + 1,
    );
    defer std.testing.allocator.free(misaligned_storage);
    try std.testing.expectError(
        error.WorkspaceMisaligned,
        evaluate(
            &plan,
            .{ .parameters = &.{}, .backgrounds = &backgrounds },
            backgrounds.len,
            misaligned_storage[1..],
            .{ .values = &values, .statuses = &statuses },
        ),
    );
}
