//! Numerical Kernel IR: the immutable instruction program the safe reference
//! backend executes.
//!
//! The opcode catalog, slot model, ordering rules, workspace query, and status
//! semantics are specified in `docs/architecture/KERNEL_INSTRUCTION_SET.md`.
//! Nothing here evaluates exact arithmetic; every constant was converted to
//! `f64` during lowering.

const std = @import("std");

/// Milestone 2 kernels are real. Every slot holds one `f64`.
pub const Scalar = f64;

pub const Opcode = enum(u8) {
    load_constant,
    load_parameter,
    load_background,
    negate,
    add,
    multiply,
    divide,
    power_integer,
};

/// Payload of an instruction that copies from an indexed slot space.
pub const Load = struct { result: u32, source: u32 };

/// Payload of a variadic arithmetic instruction. `add` and `multiply` share
/// one type so that a switch may capture them together.
pub const Variadic = struct { result: u32, operands: []const u32 };

pub const Unary = struct { result: u32, operand: u32 };
pub const Quotient = struct { result: u32, numerator: u32, denominator: u32 };
pub const IntegerPower = struct { result: u32, base: u32, exponent: u32 };

pub const Instruction = union(Opcode) {
    load_constant: Load,
    load_parameter: Load,
    load_background: Load,
    negate: Unary,
    add: Variadic,
    multiply: Variadic,
    divide: Quotient,
    power_integer: IntegerPower,

    pub fn result(self: Instruction) u32 {
        return switch (self) {
            inline else => |payload| payload.result,
        };
    }
};

/// Outputs a kernel can produce. A fused capability evaluates all of its
/// outputs at one point under one status policy.
pub const Capability = enum {
    value,
    value_gradient,
    value_gradient_hessian,

    pub fn includesGradient(self: Capability) bool {
        return self != .value;
    }

    pub fn includesHessian(self: Capability) bool {
        return self == .value_gradient_hessian;
    }
};

/// Per-point numerical status. A failed point never corrupts another point.
pub const Status = enum {
    ok,
    non_finite,
    division_by_zero,
};

pub const ValidationError = error{
    OperandOutOfRange,
    OperandNotWritten,
    ResultOutOfRange,
    SourceOutOfRange,
    TooFewOperands,
    ExponentTooLarge,
    OutputNotWritten,
    OutputOutOfRange,
    DuplicateResultSlotInUse,
};

pub const Outputs = struct {
    /// Temporary slot holding the potential value.
    value: u32,
    /// One slot per background coordinate.
    gradient: []const u32,
    /// Row-major, `coordinate_count * coordinate_count` slots.
    hessian: []const u32,
};

/// Exact workspace requirement for one operation.
pub const WorkspaceLayout = struct {
    bytes: usize,
    alignment: usize,
};

pub const Program = struct {
    arena: *std.heap.ArenaAllocator,
    instructions: []const Instruction,
    constants: []const Scalar,
    outputs: Outputs,
    capability: Capability,
    /// Number of leading instructions that depend only on constants and bound
    /// parameters. The interpreter executes them once per binding rather than
    /// once per point.
    parameter_stage_count: u32,
    temporary_count: u32,
    parameter_count: u32,
    background_count: u32,
    coordinate_count: u32,

    pub fn deinit(self: *Program) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    /// Exact workspace requirement.
    ///
    /// The reference backend evaluates points one at a time and reuses its
    /// temporaries, so the requirement does not depend on `point_count`.
    /// Callers must not rely on that: the query exists so a later backend can
    /// return a point-count-dependent layout without an API change.
    pub fn workspaceLayout(
        self: *const Program,
        point_count: usize,
    ) WorkspaceLayout {
        _ = point_count;
        return .{
            .bytes = @as(usize, self.temporary_count) * @sizeOf(Scalar),
            .alignment = @alignOf(Scalar),
        };
    }

    /// Number of scalars a batch of `point_count` points writes per output
    /// category.
    pub fn valueCount(self: *const Program, point_count: usize) usize {
        _ = self;
        return point_count;
    }

    pub fn gradientCount(
        self: *const Program,
        point_count: usize,
    ) error{SizeOverflow}!usize {
        return std.math.mul(usize, point_count, self.coordinate_count) catch
            error.SizeOverflow;
    }

    pub fn hessianCount(
        self: *const Program,
        point_count: usize,
    ) error{SizeOverflow}!usize {
        const rows = try self.gradientCount(point_count);
        return std.math.mul(usize, rows, self.coordinate_count) catch
            error.SizeOverflow;
    }

    /// Establishes every invariant the interpreter then relies on. A program
    /// that fails validation never becomes a kernel.
    pub fn validate(
        self: *const Program,
        allocator: std.mem.Allocator,
        exponent_limit: u32,
    ) (ValidationError || error{OutOfMemory})!void {
        const written = try allocator.alloc(bool, self.temporary_count);
        defer allocator.free(written);
        @memset(written, false);

        for (self.instructions) |instruction| {
            // Operands must already hold a defined value at this point in
            // program order, which also proves the program is acyclic.
            switch (instruction) {
                .load_constant => |payload| {
                    if (payload.source >= self.constants.len) {
                        return error.SourceOutOfRange;
                    }
                },
                .load_parameter => |payload| {
                    if (payload.source >= self.parameter_count) {
                        return error.SourceOutOfRange;
                    }
                },
                .load_background => |payload| {
                    if (payload.source >= self.background_count) {
                        return error.SourceOutOfRange;
                    }
                },
                .negate => |payload| try requireWritten(written, payload.operand),
                .add, .multiply => |payload| {
                    if (payload.operands.len < 2) return error.TooFewOperands;
                    for (payload.operands) |operand| {
                        try requireWritten(written, operand);
                    }
                },
                .divide => |payload| {
                    try requireWritten(written, payload.numerator);
                    try requireWritten(written, payload.denominator);
                },
                .power_integer => |payload| {
                    try requireWritten(written, payload.base);
                    if (payload.exponent > exponent_limit) return error.ExponentTooLarge;
                },
            }

            const slot = instruction.result();
            if (slot >= self.temporary_count) return error.ResultOutOfRange;
            written[slot] = true;
        }

        try requireOutput(written, self.outputs.value, self.temporary_count);
        for (self.outputs.gradient) |slot| {
            try requireOutput(written, slot, self.temporary_count);
        }
        for (self.outputs.hessian) |slot| {
            try requireOutput(written, slot, self.temporary_count);
        }
    }
};

fn requireWritten(written: []const bool, slot: u32) ValidationError!void {
    if (slot >= written.len) return error.OperandOutOfRange;
    if (!written[slot]) return error.OperandNotWritten;
}

fn requireOutput(written: []const bool, slot: u32, count: u32) ValidationError!void {
    if (slot >= count) return error.OutputOutOfRange;
    if (!written[slot]) return error.OutputNotWritten;
}

// -- tests -----------------------------------------------------------------

fn programForTest(
    allocator: std.mem.Allocator,
    instructions: []const Instruction,
    outputs: Outputs,
    temporary_count: u32,
) !Program {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const owned = try arena.allocator().dupe(Instruction, instructions);
    const constants = try arena.allocator().dupe(Scalar, &.{ 1.0, 2.0 });
    return .{
        .arena = arena,
        .instructions = owned,
        .constants = constants,
        .outputs = outputs,
        .capability = .value,
        .parameter_stage_count = 0,
        .temporary_count = temporary_count,
        .parameter_count = 2,
        .background_count = 1,
        .coordinate_count = 1,
    };
}

test "a well formed program validates" {
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .load_parameter = .{ .result = 1, .source = 0 } },
            .{ .multiply = .{ .result = 2, .operands = &.{ 0, 1 } } },
        },
        .{ .value = 2, .gradient = &.{}, .hessian = &.{} },
        3,
    );
    defer program.deinit();
    try program.validate(std.testing.allocator, 64);
}

test "reading an unwritten slot is rejected" {
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            // Slot 1 was never written.
            .{ .multiply = .{ .result = 2, .operands = &.{ 0, 1 } } },
        },
        .{ .value = 2, .gradient = &.{}, .hessian = &.{} },
        3,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.OperandNotWritten,
        program.validate(std.testing.allocator, 64),
    );
}

test "an out of range operand is rejected" {
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .negate = .{ .result = 1, .operand = 9 } },
        },
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.OperandOutOfRange,
        program.validate(std.testing.allocator, 64),
    );
}

test "an out of range constant or input source is rejected" {
    var program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_constant = .{ .result = 0, .source = 7 } }},
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.SourceOutOfRange,
        program.validate(std.testing.allocator, 64),
    );

    var parameter_program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_parameter = .{ .result = 0, .source = 5 } }},
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer parameter_program.deinit();
    try std.testing.expectError(
        error.SourceOutOfRange,
        parameter_program.validate(std.testing.allocator, 64),
    );
}

test "a variadic instruction needs at least two operands" {
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .add = .{ .result = 1, .operands = &.{0} } },
        },
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.TooFewOperands,
        program.validate(std.testing.allocator, 64),
    );
}

test "an oversized exponent is rejected" {
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_parameter = .{ .result = 0, .source = 0 } },
            .{ .power_integer = .{ .result = 1, .base = 0, .exponent = 999 } },
        },
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.ExponentTooLarge,
        program.validate(std.testing.allocator, 64),
    );
}

test "an undeclared output slot is rejected" {
    var program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_constant = .{ .result = 0, .source = 0 } }},
        // Slot 1 is never written.
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.OutputNotWritten,
        program.validate(std.testing.allocator, 64),
    );
}

test "workspace is exactly the temporary storage the program uses" {
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .load_parameter = .{ .result = 1, .source = 0 } },
            .{ .add = .{ .result = 2, .operands = &.{ 0, 1 } } },
        },
        .{ .value = 2, .gradient = &.{}, .hessian = &.{} },
        3,
    );
    defer program.deinit();

    const layout = program.workspaceLayout(1);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(f64)), layout.bytes);
    try std.testing.expectEqual(@as(usize, @alignOf(f64)), layout.alignment);

    // Independent of point count for this backend, though callers may not
    // assume so.
    try std.testing.expectEqual(layout.bytes, program.workspaceLayout(97).bytes);
}
