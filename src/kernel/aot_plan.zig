//! Bounded, model-specific input to the experimental AOT source generator.
//!
//! The AOT boundary deliberately consumes an already validated kernel program.
//! It resolves reused temporary slots into immutable instruction-definition
//! identifiers, rejects everything outside the prototype subset, and owns all
//! data needed after the source kernel has been destroyed.

const std = @import("std");
const program_module = @import("program.zig");

pub const format_version = 1;
pub const backend_version = "aot_tree_value/1";

pub const Limits = struct {
    max_instructions: usize = 128,
    max_operands: usize = 256,
    max_name_bytes: usize = 4 * 1024,
    max_source_bytes: usize = 64 * 1024,
};

pub const Identity = struct {
    model_fingerprint: [32]u8,
    request_fingerprint: [32]u8,
    parameter_names: []const []const u8,
    background_names: []const []const u8,
};

pub const PlanError = error{
    OutOfMemory,
    SizeOverflow,
    InstructionLimitExceeded,
    OperandLimitExceeded,
    NameLimitExceeded,
    UnsupportedCapability,
    UnsupportedResultType,
    UnsupportedDerivativeOutput,
    UnsupportedRenormalizationScale,
    UnsupportedInputShape,
    UnsupportedSlotType,
    UnsupportedOpcode,
    InvalidValidatedProgram,
};

pub const DefinitionId = u32;

pub const IntegerPower = struct {
    base: DefinitionId,
    exponent: u32,
};

pub const Node = union(enum) {
    constant: f64,
    parameter: u32,
    background: u32,
    negate: DefinitionId,
    add: []const DefinitionId,
    multiply: []const DefinitionId,
    power_integer: IntegerPower,
};

pub const Plan = struct {
    arena: *std.heap.ArenaAllocator,
    nodes: []const Node,
    parameter_stage_count: u32,
    output: DefinitionId,
    parameter_count: u32,
    background_count: u32,
    model_fingerprint: [32]u8,
    request_fingerprint: [32]u8,
    parameter_names: []const []const u8,
    background_names: []const []const u8,
    max_source_bytes: usize,

    pub fn deinit(self: *Plan) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }
};

/// Compiles the supported subset from a program whose validation has already
/// succeeded. The prototype is intentionally fixed to the existing phi4
/// channel shape; widening it requires a new backend version and evidence.
pub fn compile(
    allocator: std.mem.Allocator,
    program: *const program_module.Program,
    identity: Identity,
    limits: Limits,
) PlanError!Plan {
    if (program.capability != .value) return error.UnsupportedCapability;
    if (program.result_type != .real64) return error.UnsupportedResultType;
    if (program.outputs.gradient.len != 0 or program.outputs.hessian.len != 0) {
        return error.UnsupportedDerivativeOutput;
    }
    if (program.scale_count != 0) return error.UnsupportedRenormalizationScale;
    if (program.parameter_count != 3 or
        program.background_count != 1 or
        program.coordinate_count != 1 or
        identity.parameter_names.len != program.parameter_count or
        identity.background_names.len != program.background_count)
    {
        return error.UnsupportedInputShape;
    }
    if (program.instructions.len > limits.max_instructions) {
        return error.InstructionLimitExceeded;
    }
    if (program.parameter_stage_count > program.instructions.len) {
        return error.InvalidValidatedProgram;
    }

    for (program.temporaries) |temporary| {
        if (temporary.kind != .real) return error.UnsupportedSlotType;
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();

    const nodes = try owned.alloc(Node, program.instructions.len);
    const definitions = try owned.alloc(?DefinitionId, program.temporaries.len);
    @memset(definitions, null);

    var operand_count: usize = 0;
    for (program.instructions, nodes, 0..) |instruction, *node, index| {
        const definition: DefinitionId = @intCast(index);
        node.* = switch (instruction) {
            .load_constant => |payload| blk: {
                const value = program.constants[payload.source];
                break :blk .{ .constant = value };
            },
            .load_parameter => |payload| blk: {
                if (index >= program.parameter_stage_count) {
                    return error.InvalidValidatedProgram;
                }
                break :blk .{ .parameter = payload.source };
            },
            .load_background => |payload| blk: {
                if (index < program.parameter_stage_count) {
                    return error.InvalidValidatedProgram;
                }
                break :blk .{ .background = payload.source };
            },
            .negate => |payload| .{
                .negate = try resolveDefinition(definitions, payload.operand),
            },
            .add => |payload| .{
                .add = try resolveDefinitions(
                    owned,
                    definitions,
                    payload.operands,
                    &operand_count,
                    limits.max_operands,
                ),
            },
            .multiply => |payload| .{
                .multiply = try resolveDefinitions(
                    owned,
                    definitions,
                    payload.operands,
                    &operand_count,
                    limits.max_operands,
                ),
            },
            .power_integer => |payload| .{ .power_integer = .{
                .base = try resolveDefinition(definitions, payload.base),
                .exponent = payload.exponent,
            } },
            else => return error.UnsupportedOpcode,
        };

        const result = instruction.result();
        if (result >= definitions.len) return error.InvalidValidatedProgram;
        definitions[result] = definition;
    }

    const output = try resolveDefinition(definitions, program.outputs.value);
    const parameter_names = try copyNames(
        owned,
        identity.parameter_names,
        limits.max_name_bytes,
    );
    const background_names = try copyNames(
        owned,
        identity.background_names,
        limits.max_name_bytes,
    );
    const parameter_name_bytes = nameBytes(parameter_names) catch
        return error.NameLimitExceeded;
    const background_name_bytes = nameBytes(background_names) catch
        return error.NameLimitExceeded;
    const all_name_bytes = std.math.add(
        usize,
        parameter_name_bytes,
        background_name_bytes,
    ) catch return error.NameLimitExceeded;
    if (all_name_bytes > limits.max_name_bytes) {
        return error.NameLimitExceeded;
    }

    return .{
        .arena = arena,
        .nodes = nodes,
        .parameter_stage_count = program.parameter_stage_count,
        .output = output,
        .parameter_count = program.parameter_count,
        .background_count = program.background_count,
        .model_fingerprint = identity.model_fingerprint,
        .request_fingerprint = identity.request_fingerprint,
        .parameter_names = parameter_names,
        .background_names = background_names,
        .max_source_bytes = limits.max_source_bytes,
    };
}

fn resolveDefinition(
    definitions: []const ?DefinitionId,
    slot: u32,
) PlanError!DefinitionId {
    if (slot >= definitions.len) return error.InvalidValidatedProgram;
    return definitions[slot] orelse error.InvalidValidatedProgram;
}

fn resolveDefinitions(
    allocator: std.mem.Allocator,
    definitions: []const ?DefinitionId,
    slots: []const u32,
    total: *usize,
    maximum: usize,
) PlanError![]const DefinitionId {
    total.* = std.math.add(usize, total.*, slots.len) catch
        return error.OperandLimitExceeded;
    if (total.* > maximum) return error.OperandLimitExceeded;

    const resolved = try allocator.alloc(DefinitionId, slots.len);
    for (slots, resolved) |slot, *definition| {
        definition.* = try resolveDefinition(definitions, slot);
    }
    return resolved;
}

fn copyNames(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    maximum: usize,
) PlanError![]const []const u8 {
    const result = try allocator.alloc([]const u8, names.len);
    var total: usize = 0;
    for (names, result) |name, *copy| {
        total = std.math.add(usize, total, name.len) catch
            return error.NameLimitExceeded;
        if (total > maximum) return error.NameLimitExceeded;
        copy.* = try allocator.dupe(u8, name);
    }
    return result;
}

fn nameBytes(names: []const []const u8) error{SizeOverflow}!usize {
    var total: usize = 0;
    for (names) |name| {
        total = std.math.add(usize, total, name.len) catch
            return error.SizeOverflow;
    }
    return total;
}

const test_parameter_names = [_][]const u8{ "lambda", "m2", "omega" };
const test_background_names = [_][]const u8{"phi"};
const test_multiply_operands = [_]u32{ 0, 3 };
const test_add_operands = [_]u32{ 2, 4 };
const test_instructions = [_]program_module.Instruction{
    .{ .load_parameter = .{ .result = 0, .source = 0 } },
    .{ .load_parameter = .{ .result = 1, .source = 1 } },
    .{ .load_parameter = .{ .result = 2, .source = 2 } },
    .{ .load_background = .{ .result = 3, .source = 0 } },
    .{ .multiply = .{ .result = 4, .operands = &test_multiply_operands } },
    .{ .add = .{ .result = 5, .operands = &test_add_operands } },
};
const test_temporaries = makeTestTemporaries();

fn makeTestTemporaries() [test_instructions.len]program_module.Temporary {
    var result: [test_instructions.len]program_module.Temporary = undefined;
    for (&result, 0..) |*temporary, index| {
        temporary.* = .{
            .kind = .real,
            .alignment = @alignOf(f64),
            .offset = index * @sizeOf(f64),
            .bytes = @sizeOf(f64),
            .live = .{
                .first_write = @intCast(index),
                .last_use = @intCast(test_instructions.len - 1),
            },
        };
    }
    return result;
}

fn programForTest() program_module.Program {
    return .{
        .arena = undefined,
        .instructions = &test_instructions,
        .constants = &.{},
        .temporaries = &test_temporaries,
        .outputs = .{ .value = 5, .gradient = &.{}, .hessian = &.{} },
        .capability = .value,
        .result_type = .real64,
        .frame_bytes = test_temporaries.len * @sizeOf(f64),
        .scratch_offset = test_temporaries.len * @sizeOf(f64),
        .scratch_bytes = 0,
        .parameter_stage_count = 3,
        .parameter_count = 3,
        .scale_count = 0,
        .background_count = 1,
        .coordinate_count = 1,
    };
}

fn identityForTest() Identity {
    return .{
        .model_fingerprint = [_]u8{0x11} ** 32,
        .request_fingerprint = [_]u8{0x22} ** 32,
        .parameter_names = &test_parameter_names,
        .background_names = &test_background_names,
    };
}

test "AOT plan owns predecoded definitions and preserves operand order" {
    const program = programForTest();
    var plan = try compile(
        std.testing.allocator,
        &program,
        identityForTest(),
        .{},
    );
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 6), plan.nodes.len);
    try std.testing.expectEqual(@as(DefinitionId, 5), plan.output);
    try std.testing.expectEqualSlices(
        DefinitionId,
        &.{ 0, 3 },
        plan.nodes[4].multiply,
    );
    try std.testing.expectEqualSlices(
        DefinitionId,
        &.{ 2, 4 },
        plan.nodes[5].add,
    );
    try std.testing.expectEqualStrings("lambda", plan.parameter_names[0]);
}

test "AOT plan rejects every boundary outside the prototype subset" {
    var program = programForTest();
    program.capability = .value_gradient;
    try std.testing.expectError(
        error.UnsupportedCapability,
        compile(std.testing.allocator, &program, identityForTest(), .{}),
    );

    program = programForTest();
    program.result_type = .complex64;
    try std.testing.expectError(
        error.UnsupportedResultType,
        compile(std.testing.allocator, &program, identityForTest(), .{}),
    );

    program = programForTest();
    program.scale_count = 1;
    try std.testing.expectError(
        error.UnsupportedRenormalizationScale,
        compile(std.testing.allocator, &program, identityForTest(), .{}),
    );

    program = programForTest();
    const gradient = [_]u32{5};
    program.outputs.gradient = &gradient;
    try std.testing.expectError(
        error.UnsupportedDerivativeOutput,
        compile(std.testing.allocator, &program, identityForTest(), .{}),
    );

    program = programForTest();
    var non_real_temporaries = test_temporaries;
    non_real_temporaries[0].kind = .complex;
    program.temporaries = &non_real_temporaries;
    try std.testing.expectError(
        error.UnsupportedSlotType,
        compile(std.testing.allocator, &program, identityForTest(), .{}),
    );

    program = programForTest();
    var unsupported_instructions = test_instructions;
    unsupported_instructions[4] = .{ .divide = .{
        .result = 4,
        .numerator = 0,
        .denominator = 3,
    } };
    program.instructions = &unsupported_instructions;
    try std.testing.expectError(
        error.UnsupportedOpcode,
        compile(std.testing.allocator, &program, identityForTest(), .{}),
    );

    program = programForTest();
    program.parameter_count = 2;
    try std.testing.expectError(
        error.UnsupportedInputShape,
        compile(std.testing.allocator, &program, identityForTest(), .{}),
    );

    program = programForTest();
    try std.testing.expectError(
        error.InstructionLimitExceeded,
        compile(
            std.testing.allocator,
            &program,
            identityForTest(),
            .{ .max_instructions = 5 },
        ),
    );
    try std.testing.expectError(
        error.OperandLimitExceeded,
        compile(
            std.testing.allocator,
            &program,
            identityForTest(),
            .{ .max_operands = 3 },
        ),
    );
    try std.testing.expectError(
        error.NameLimitExceeded,
        compile(
            std.testing.allocator,
            &program,
            identityForTest(),
            .{ .max_name_bytes = 3 },
        ),
    );
}

test "AOT planning handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailures,
        .{},
    );
}

fn compileForAllocationFailures(allocator: std.mem.Allocator) !void {
    const program = programForTest();
    var plan = try compile(allocator, &program, identityForTest(), .{});
    defer plan.deinit();
}
