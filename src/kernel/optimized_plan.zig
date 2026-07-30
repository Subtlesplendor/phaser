//! Immutable predecoded execution plan for the optimized interpreter.
//!
//! The authoritative semantics remain in `program.zig` and the safe reference
//! interpreter. This representation replaces slot identifiers and repeated
//! shape arithmetic with checked scalar-frame offsets and prepared numerical
//! operation descriptors.

const std = @import("std");
const builtin = @import("builtin");
const numerics = @import("../numerics/root.zig");
const program_module = @import("program.zig");

const eigensolver = numerics.symmetric_eigensolver;
const spectral = numerics.spectral_derivative;

pub const Scalar = program_module.Scalar;
pub const Complex64 = program_module.Complex64;
pub const Status = program_module.Status;
pub const WorkspaceLayout = program_module.WorkspaceLayout;

/// Four lanes let the portable two-wide vector leaf issue two independent
/// vectors on both baseline x86-64 SSE2 and ARM64 NEON targets.
pub const block_width: usize = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => 4,
    else => 1,
};

pub const vector_width: usize = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => 2,
    else => 1,
};

pub const PlanError = error{
    OutOfMemory,
    SizeOverflow,
};

pub const Unary = struct {
    result: usize,
    operand: usize,
    components: u8,
};

pub const Variadic = struct {
    result: usize,
    operands: []const usize,
    components: u8,
};

pub const Quotient = struct {
    result: usize,
    numerator: usize,
    denominator: usize,
};

pub const IntegerPower = struct {
    result: usize,
    base: usize,
    exponent: u32,
};

pub const Load = struct {
    result: usize,
    source: u32,
};

pub const Assemble = struct {
    result: usize,
    entries: []const usize,
};

pub const Eigensystem = struct {
    result: usize,
    matrix: usize,
    dimension: u32,
    packed_count: usize,
    result_scalars: usize,
    workspace: eigensolver.WorkspaceLayout,
};

pub const SpectralSum = struct {
    result: usize,
    eigensystem: usize,
    dimension: u32,
    scale: usize,
};

pub const SpectralDerivative = struct {
    result: usize,
    eigensystem: usize,
    first: []const usize,
    second: []const usize,
    scale: usize,
    prepared: spectral.Prepared,
};

pub const Extract = struct {
    result: usize,
    source_component: usize,
};

pub const Record = union(program_module.Opcode) {
    load_constant: Load,
    load_parameter: Load,
    load_background: Load,
    load_renormalization_scale: Load,
    negate: Unary,
    add: Variadic,
    multiply: Variadic,
    divide: Quotient,
    power_integer: IntegerPower,
    promote_real_to_complex: Unary,
    assemble_real_symmetric: Assemble,
    symmetric_eigensystem: Eigensystem,
    scalar_one_loop_sum: SpectralSum,
    scalar_one_loop_gradient: SpectralDerivative,
    scalar_one_loop_hessian: SpectralDerivative,
    extract_element: Extract,
};

pub const PrologueEntry = struct {
    frame_offset: usize,
    scalar_count: usize,
    prologue_offset: usize,
};

pub const OutputOffsets = struct {
    value: usize,
    gradient: []const usize,
    hessian: []const usize,
};

pub const ExecutionPlan = struct {
    arena: *std.heap.ArenaAllocator,
    program: program_module.Program,
    records: []const Record,
    slot_offsets: []const usize,
    slot_counts: []const usize,
    outputs: OutputOffsets,
    prologue_entries: []const PrologueEntry,
    prologue_scalars: usize,
    parameter_stage_count: u32,
    frame_scalars: usize,
    block_frame_bytes: usize,
    scalar_frame_offset: usize,
    scratch_offset: usize,
    scratch_bytes: usize,
    lane_status_offset: usize,
    workspace_bytes: usize,

    pub fn deinit(self: *ExecutionPlan) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn workspaceLayout(
        self: *const ExecutionPlan,
        point_count: usize,
    ) WorkspaceLayout {
        _ = point_count;
        return .{
            .bytes = self.workspace_bytes,
            .alignment = @max(@alignOf(Scalar), @alignOf(@Vector(2, Scalar))),
        };
    }

    pub fn prologueBytes(self: *const ExecutionPlan) usize {
        return self.prologue_scalars * @sizeOf(Scalar);
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    program: *const program_module.Program,
) PlanError!ExecutionPlan {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();

    const slot_offsets = try owned.alloc(usize, program.temporaries.len);
    const slot_counts = try owned.alloc(usize, program.temporaries.len);
    var frame_scalars: usize = 0;
    for (program.temporaries, slot_offsets, slot_counts) |temporary, *offset, *count| {
        const scalar_count = temporary.kind.scalarCount() catch
            return error.SizeOverflow;
        offset.* = frame_scalars;
        count.* = scalar_count;
        frame_scalars = std.math.add(usize, frame_scalars, scalar_count) catch
            return error.SizeOverflow;
    }

    const records = try owned.alloc(Record, program.instructions.len);
    for (program.instructions, records) |instruction, *record| {
        record.* = try predecode(owned, program, slot_offsets, instruction);
    }

    const gradient = try predecodeSlots(owned, slot_offsets, program.outputs.gradient);
    const hessian = try predecodeSlots(owned, slot_offsets, program.outputs.hessian);
    const prologue_entries = try buildPrologue(
        owned,
        program,
        slot_offsets,
        slot_counts,
    );
    var prologue_scalars: usize = 0;
    for (prologue_entries) |entry| {
        prologue_scalars = std.math.add(
            usize,
            prologue_scalars,
            entry.scalar_count,
        ) catch return error.SizeOverflow;
    }

    const block_scalars = std.math.mul(
        usize,
        frame_scalars,
        block_width,
    ) catch return error.SizeOverflow;
    const block_frame_bytes = std.math.mul(
        usize,
        block_scalars,
        @sizeOf(Scalar),
    ) catch return error.SizeOverflow;
    const scalar_frame_bytes = std.math.mul(
        usize,
        frame_scalars,
        @sizeOf(Scalar),
    ) catch return error.SizeOverflow;
    const scalar_frame_offset = try alignForward(
        block_frame_bytes,
        @alignOf(Scalar),
    );
    const after_scalar = std.math.add(
        usize,
        scalar_frame_offset,
        scalar_frame_bytes,
    ) catch return error.SizeOverflow;
    const scratch_offset = try alignForward(after_scalar, @alignOf(Scalar));
    const after_scratch = std.math.add(
        usize,
        scratch_offset,
        program.scratch_bytes,
    ) catch return error.SizeOverflow;
    const lane_status_offset = try alignForward(
        after_scratch,
        @alignOf(Status),
    );
    const lane_status_bytes = std.math.mul(
        usize,
        block_width,
        @sizeOf(Status),
    ) catch return error.SizeOverflow;
    const workspace_bytes = std.math.add(
        usize,
        lane_status_offset,
        lane_status_bytes,
    ) catch return error.SizeOverflow;

    return .{
        .arena = arena,
        .program = program.*,
        .records = records,
        .slot_offsets = slot_offsets,
        .slot_counts = slot_counts,
        .outputs = .{
            .value = slot_offsets[program.outputs.value],
            .gradient = gradient,
            .hessian = hessian,
        },
        .prologue_entries = prologue_entries,
        .prologue_scalars = prologue_scalars,
        .parameter_stage_count = program.parameter_stage_count,
        .frame_scalars = frame_scalars,
        .block_frame_bytes = block_frame_bytes,
        .scalar_frame_offset = scalar_frame_offset,
        .scratch_offset = scratch_offset,
        .scratch_bytes = program.scratch_bytes,
        .lane_status_offset = lane_status_offset,
        .workspace_bytes = workspace_bytes,
    };
}

fn predecode(
    allocator: std.mem.Allocator,
    program: *const program_module.Program,
    offsets: []const usize,
    instruction: program_module.Instruction,
) PlanError!Record {
    return switch (instruction) {
        .load_constant => |payload| .{ .load_constant = .{
            .result = offsets[payload.result],
            .source = payload.source,
        } },
        .load_parameter => |payload| .{ .load_parameter = .{
            .result = offsets[payload.result],
            .source = payload.source,
        } },
        .load_background => |payload| .{ .load_background = .{
            .result = offsets[payload.result],
            .source = payload.source,
        } },
        .load_renormalization_scale => |payload| .{
            .load_renormalization_scale = .{
                .result = offsets[payload.result],
                .source = payload.source,
            },
        },
        .negate => |payload| .{ .negate = .{
            .result = offsets[payload.result],
            .operand = offsets[payload.operand],
            .components = componentCount(program.temporaries[payload.result].kind),
        } },
        .add => |payload| .{ .add = .{
            .result = offsets[payload.result],
            .operands = try predecodeSlots(allocator, offsets, payload.operands),
            .components = componentCount(program.temporaries[payload.result].kind),
        } },
        .multiply => |payload| .{ .multiply = .{
            .result = offsets[payload.result],
            .operands = try predecodeSlots(allocator, offsets, payload.operands),
            .components = 1,
        } },
        .divide => |payload| .{ .divide = .{
            .result = offsets[payload.result],
            .numerator = offsets[payload.numerator],
            .denominator = offsets[payload.denominator],
        } },
        .power_integer => |payload| .{ .power_integer = .{
            .result = offsets[payload.result],
            .base = offsets[payload.base],
            .exponent = payload.exponent,
        } },
        .promote_real_to_complex => |payload| .{ .promote_real_to_complex = .{
            .result = offsets[payload.result],
            .operand = offsets[payload.operand],
            .components = 2,
        } },
        .assemble_real_symmetric => |payload| .{ .assemble_real_symmetric = .{
            .result = offsets[payload.result],
            .entries = try predecodeSlots(allocator, offsets, payload.entries),
        } },
        .symmetric_eigensystem => |payload| blk: {
            const dimension = program.temporaries[payload.result].kind.real_eigensystem;
            const packed_count = eigensolver.packedEntryCount(dimension) catch
                return error.SizeOverflow;
            const result_scalars = program.temporaries[payload.result]
                .kind.scalarCount() catch return error.SizeOverflow;
            const workspace = eigensolver.workspaceLayout(dimension) catch
                return error.SizeOverflow;
            break :blk .{ .symmetric_eigensystem = .{
                .result = offsets[payload.result],
                .matrix = offsets[payload.matrix],
                .dimension = dimension,
                .packed_count = packed_count,
                .result_scalars = result_scalars,
                .workspace = workspace,
            } };
        },
        .scalar_one_loop_sum => |payload| .{ .scalar_one_loop_sum = .{
            .result = offsets[payload.result],
            .eigensystem = offsets[payload.eigensystem],
            .dimension = program.temporaries[payload.eigensystem].kind.real_eigensystem,
            .scale = offsets[payload.scale],
        } },
        .scalar_one_loop_gradient => |payload| .{
            .scalar_one_loop_gradient = try predecodeSpectral(
                allocator,
                program,
                offsets,
                payload.result,
                payload.eigensystem,
                payload.first,
                &.{},
                payload.scale,
                .gradient,
            ),
        },
        .scalar_one_loop_hessian => |payload| .{
            .scalar_one_loop_hessian = try predecodeSpectral(
                allocator,
                program,
                offsets,
                payload.result,
                payload.eigensystem,
                payload.first,
                payload.second,
                payload.scale,
                .hessian,
            ),
        },
        .extract_element => |payload| blk: {
            const stride: usize = switch (program.temporaries[payload.source].kind) {
                .complex_matrix => |dimension| dimension,
                else => 1,
            };
            const component = @as(usize, payload.row) * stride + payload.column;
            const scalar_component = std.math.mul(usize, component, 2) catch
                return error.SizeOverflow;
            break :blk .{ .extract_element = .{
                .result = offsets[payload.result],
                .source_component = std.math.add(
                    usize,
                    offsets[payload.source],
                    scalar_component,
                ) catch return error.SizeOverflow,
            } };
        },
    };
}

fn predecodeSpectral(
    allocator: std.mem.Allocator,
    program: *const program_module.Program,
    offsets: []const usize,
    result: u32,
    eigensystem: u32,
    first: []const u32,
    second: []const u32,
    scale: u32,
    order: spectral.Order,
) PlanError!SpectralDerivative {
    const dimension = program.temporaries[eigensystem].kind.real_eigensystem;
    const coordinate_count: u32 = switch (program.temporaries[result].kind) {
        .complex_vector => |value| value,
        .complex_matrix => |value| value,
        else => unreachable,
    };
    return .{
        .result = offsets[result],
        .eigensystem = offsets[eigensystem],
        .first = try predecodeSlots(allocator, offsets, first),
        .second = try predecodeSlots(allocator, offsets, second),
        .scale = offsets[scale],
        .prepared = spectral.prepare(
            dimension,
            coordinate_count,
            order,
        ) catch return error.SizeOverflow,
    };
}

fn predecodeSlots(
    allocator: std.mem.Allocator,
    offsets: []const usize,
    slots: []const u32,
) error{OutOfMemory}![]const usize {
    const decoded = try allocator.alloc(usize, slots.len);
    for (slots, decoded) |slot, *offset| offset.* = offsets[slot];
    return decoded;
}

fn buildPrologue(
    allocator: std.mem.Allocator,
    program: *const program_module.Program,
    offsets: []const usize,
    counts: []const usize,
) error{OutOfMemory}![]const PrologueEntry {
    const storage = try allocator.alloc(PrologueEntry, program.temporaries.len);
    var used: usize = 0;
    var compact_offset: usize = 0;
    for (program.temporaries, 0..) |temporary, slot| {
        if (temporary.live.first_write >= program.parameter_stage_count) continue;
        if (temporary.live.last_use < program.parameter_stage_count and
            !isOutput(program, @intCast(slot)))
        {
            continue;
        }
        storage[used] = .{
            .frame_offset = offsets[slot],
            .scalar_count = counts[slot],
            .prologue_offset = compact_offset,
        };
        compact_offset += counts[slot];
        used += 1;
    }
    return storage[0..used];
}

fn isOutput(program: *const program_module.Program, slot: u32) bool {
    if (program.outputs.value == slot) return true;
    for (program.outputs.gradient) |candidate| {
        if (candidate == slot) return true;
    }
    for (program.outputs.hessian) |candidate| {
        if (candidate == slot) return true;
    }
    return false;
}

fn componentCount(kind: program_module.SlotType) u8 {
    return switch (kind) {
        .complex => 2,
        else => 1,
    };
}

fn alignForward(offset: usize, alignment: usize) error{SizeOverflow}!usize {
    const mask = alignment - 1;
    const with_mask = std.math.add(usize, offset, mask) catch
        return error.SizeOverflow;
    return with_mask & ~mask;
}

test "predecoded plan records offsets and only live prologue regions" {
    const instructions = [_]program_module.Instruction{
        .{ .load_parameter = .{ .result = 0, .source = 0 } },
        .{ .load_constant = .{ .result = 1, .source = 0 } },
        .{ .multiply = .{ .result = 2, .operands = &.{ 0, 1 } } },
        .{ .load_background = .{ .result = 1, .source = 0 } },
        .{ .multiply = .{ .result = 2, .operands = &.{ 0, 1 } } },
    };
    const temporaries = [_]program_module.Temporary{
        .{
            .kind = .real,
            .alignment = @alignOf(Scalar),
            .offset = 0,
            .bytes = @sizeOf(Scalar),
            .live = .{ .first_write = 0, .last_use = 4 },
        },
        .{
            .kind = .real,
            .alignment = @alignOf(Scalar),
            .offset = @sizeOf(Scalar),
            .bytes = @sizeOf(Scalar),
            .live = .{ .first_write = 1, .last_use = 4 },
        },
        .{
            .kind = .real,
            .alignment = @alignOf(Scalar),
            .offset = 2 * @sizeOf(Scalar),
            .bytes = @sizeOf(Scalar),
            .live = .{ .first_write = 2, .last_use = 4 },
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program = program_module.Program{
        .arena = &arena,
        .instructions = &instructions,
        .constants = &.{2},
        .temporaries = &temporaries,
        .outputs = .{ .value = 2, .gradient = &.{}, .hessian = &.{} },
        .capability = .value,
        .result_type = .real64,
        .frame_bytes = 3 * @sizeOf(Scalar),
        .scratch_offset = 3 * @sizeOf(Scalar),
        .scratch_bytes = 0,
        .parameter_stage_count = 3,
        .parameter_count = 1,
        .scale_count = 0,
        .background_count = 1,
        .coordinate_count = 1,
    };
    try program.validate(std.testing.allocator, 64);

    var plan = try compile(std.testing.allocator, &program);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), plan.frame_scalars);
    try std.testing.expectEqual(@as(usize, 3), plan.prologue_entries.len);
    try std.testing.expectEqual(@as(usize, 3), plan.prologue_scalars);
    try std.testing.expectEqual(@as(usize, 0), plan.slot_offsets[0]);
    try std.testing.expectEqual(@as(usize, 2), plan.outputs.value);
}
