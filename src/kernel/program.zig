//! Numerical Kernel IR: the immutable instruction program the safe reference
//! backend executes.
//!
//! The opcode catalog, slot model, ordering rules, workspace query, and status
//! semantics are specified in `docs/architecture/KERNEL_INSTRUCTION_SET.md`.
//! Nothing here evaluates exact arithmetic; every constant was converted to
//! `f64` during lowering.

const std = @import("std");
const numerics = @import("../numerics/root.zig");

const eigensolver = numerics.symmetric_eigensolver;
const spectral = numerics.spectral_derivative;

/// The real scalar type of every input channel, matrix entry, eigenvalue, and
/// eigensolver temporary.
pub const Scalar = f64;

/// A pair of IEEE binary64 components. This is a semantic type, not a stable C
/// layout.
///
/// It is defined alongside the numerical algorithms because the invariant
/// spectral derivative operation produces complex results and must not depend
/// on the instruction program that calls it.
pub const Complex64 = numerics.complex.Complex64;

/// Numerical type of a kernel's outputs.
///
/// It is kernel metadata fixed by the selected contributions, not a per-point
/// property: a loop-containing output stays `complex64` at a point whose
/// imaginary component happens to be zero.
pub const ResultType = enum {
    real64,
    complex64,

    pub fn Element(comptime self: ResultType) type {
        return switch (self) {
            .real64 => Scalar,
            .complex64 => Complex64,
        };
    }
};

/// Type and shape of one temporary slot.
///
/// Constant, parameter, scale, and background slots are always `Real64`, so
/// only temporaries carry a type.
pub const SlotType = union(enum) {
    real,
    complex,
    /// Authoritative packed upper triangle of an `n x n` real symmetric matrix.
    real_symmetric_matrix: u32,
    /// `n` real eigenvalues followed by the `n x n` real eigenvector matrix.
    real_eigensystem: u32,
    /// `n` `Complex64` components of an invariant spectral gradient, in
    /// canonical background-coordinate order.
    complex_vector: u32,
    /// Dense row-major `n x n` `Complex64` invariant spectral Hessian. It is
    /// dense rather than triangular because every entry is evaluated from the
    /// formula; symmetry is a property to be checked, not a storage saving.
    complex_matrix: u32,

    pub fn eql(self: SlotType, other: SlotType) bool {
        return switch (self) {
            .real => other == .real,
            .complex => other == .complex,
            inline .real_symmetric_matrix,
            .real_eigensystem,
            .complex_vector,
            .complex_matrix,
            => |dimension, tag| switch (other) {
                tag => |right| dimension == right,
                else => false,
            },
        };
    }

    /// Number of `Scalar` values the slot occupies.
    pub fn scalarCount(self: SlotType) error{SizeOverflow}!usize {
        return switch (self) {
            .real => 1,
            // A `Complex64` is two binary64 components in the frame.
            .complex => 2,
            .real_symmetric_matrix => |dimension| eigensolver.packedEntryCount(dimension),
            .real_eigensystem => |dimension| blk: {
                const n: usize = dimension;
                const vectors = std.math.mul(usize, n, n) catch
                    return error.SizeOverflow;
                break :blk std.math.add(usize, n, vectors) catch error.SizeOverflow;
            },
            .complex_vector => |dimension| std.math.mul(usize, dimension, 2) catch
                error.SizeOverflow,
            .complex_matrix => |dimension| blk: {
                const n: usize = dimension;
                const entries = std.math.mul(usize, n, n) catch
                    return error.SizeOverflow;
                break :blk std.math.mul(usize, entries, 2) catch error.SizeOverflow;
            },
        };
    }

    pub fn byteSize(self: SlotType) error{SizeOverflow}!usize {
        const count = try self.scalarCount();
        return std.math.mul(usize, count, @sizeOf(Scalar)) catch error.SizeOverflow;
    }

    /// Every slot type is built from `Scalar` components, so one alignment
    /// serves all of them today. The descriptor still records it, because a
    /// future scalar type or vector layout would not share it.
    pub fn alignment(self: SlotType) usize {
        _ = self;
        return @alignOf(Scalar);
    }

    pub fn resultType(self: SlotType) ?ResultType {
        return switch (self) {
            .real => .real64,
            .complex => .complex64,
            else => null,
        };
    }
};

/// The instruction positions over which a temporary holds a live value.
///
/// Recorded so that an audit can verify slot reuse independently of the
/// allocator that chose it, as the potential-kernel specification asks.
pub const LiveRange = struct {
    /// Position of the instruction that first writes the slot.
    first_write: u32,
    /// Position of the last instruction that reads it, or of the write itself
    /// when the slot is a declared output that the caller reads.
    last_use: u32,

    pub fn overlaps(self: LiveRange, other: LiveRange) bool {
        return self.first_write <= other.last_use and other.first_write <= self.last_use;
    }
};

/// A validated typed temporary.
pub const Temporary = struct {
    kind: SlotType,
    alignment: usize,
    /// Byte offset into the temporary frame.
    offset: usize,
    bytes: usize,
    live: LiveRange,
};

pub const Opcode = enum(u8) {
    load_constant,
    load_parameter,
    load_background,
    load_renormalization_scale,
    negate,
    add,
    multiply,
    divide,
    power_integer,
    promote_real_to_complex,
    assemble_real_symmetric,
    symmetric_eigensystem,
    scalar_one_loop_sum,
    scalar_one_loop_gradient,
    scalar_one_loop_hessian,
    extract_element,
};

/// Payload of an instruction that copies from an indexed slot space.
pub const Load = struct { result: u32, source: u32 };

/// Payload of a variadic arithmetic instruction. `add` and `multiply` share
/// one type so that a switch may capture them together.
pub const Variadic = struct { result: u32, operands: []const u32 };

pub const Unary = struct { result: u32, operand: u32 };
pub const Quotient = struct { result: u32, numerator: u32, denominator: u32 };
pub const IntegerPower = struct { result: u32, base: u32, exponent: u32 };

/// Copies the canonical upper triangle into a matrix temporary.
pub const Assemble = struct {
    result: u32,
    /// The `n(n+1)/2` entries in lexical index order.
    entries: []const u32,
};

/// Diagonalizes a real-symmetric matrix temporary.
pub const Eigensystem = struct { result: u32, matrix: u32 };

/// The restricted scalar one-loop spectral sum over a computed eigensystem.
pub const SpectralSum = struct {
    result: u32,
    eigensystem: u32,
    scale: u32,
};

/// The invariant scalar one-loop spectral gradient.
///
/// It reuses the eigensystem the value operation already computed, so the two
/// share one diagonalization and cannot disagree about the spectrum.
pub const SpectralGradient = struct {
    result: u32,
    eigensystem: u32,
    /// One real-symmetric first-derivative matrix per background coordinate,
    /// in canonical coordinate order.
    first: []const u32,
    scale: u32,
};

/// The invariant scalar one-loop spectral Hessian.
pub const SpectralHessian = struct {
    result: u32,
    eigensystem: u32,
    first: []const u32,
    /// Real-symmetric second-derivative matrices over the upper triangle of
    /// coordinate pairs, in lexical order.
    second: []const u32,
    scale: u32,
};

/// Selects one `Complex64` component of a structured spectral result.
pub const Extract = struct {
    result: u32,
    source: u32,
    row: u32,
    /// Zero for a vector source.
    column: u32,
};

pub const Instruction = union(Opcode) {
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
    scalar_one_loop_gradient: SpectralGradient,
    scalar_one_loop_hessian: SpectralHessian,
    extract_element: Extract,

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
///
/// These outcomes are distinct and are never collapsed into one another. A
/// negative eigenvalue and a finite nonzero imaginary component are successful
/// results, not failures.
pub const Status = enum {
    ok,
    non_finite,
    division_by_zero,
    /// A bounded numerical operation exhausted its convergence or
    /// postcondition contract.
    nonconvergent,
    /// A requested derivative is mathematically singular, including an
    /// uncancelled zero-mode scalar Hessian term.
    singular_derivative,
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
    /// An operand or result does not have the type the opcode requires.
    SlotTypeMismatch,
    /// A structured result's dimension disagrees with its operand count.
    ShapeMismatch,
    /// A temporary's recorded byte range escapes the frame, or two
    /// simultaneously live temporaries share storage.
    InvalidSlotLayout,
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
    /// Validated typed temporaries, indexed by slot number.
    temporaries: []const Temporary,
    outputs: Outputs,
    capability: Capability,
    result_type: ResultType,
    /// Bytes of the typed temporary frame.
    frame_bytes: usize,
    /// Byte offset at which the shared numerical scratch region begins.
    scratch_offset: usize,
    /// Bytes of the largest scratch requirement of any single operation. One
    /// region is shared, because no two operations are in flight at once.
    scratch_bytes: usize,
    /// Number of leading instructions that depend only on constants, bound
    /// parameters, and the bound renormalization scale. The interpreter
    /// executes them once per binding rather than once per point.
    parameter_stage_count: u32,
    parameter_count: u32,
    scale_count: u32,
    background_count: u32,
    coordinate_count: u32,

    pub fn deinit(self: *Program) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn temporaryCount(self: *const Program) u32 {
        return @intCast(self.temporaries.len);
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
            .bytes = self.scratch_offset + self.scratch_bytes,
            .alignment = @alignOf(Scalar),
        };
    }

    /// Number of elements a batch of `point_count` points writes per output
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

    fn slotType(self: *const Program, slot: u32) ValidationError!SlotType {
        if (slot >= self.temporaries.len) return error.OperandOutOfRange;
        return self.temporaries[slot].kind;
    }

    /// Establishes every invariant the interpreter then relies on. A program
    /// that fails validation never becomes a kernel.
    pub fn validate(
        self: *const Program,
        allocator: std.mem.Allocator,
        exponent_limit: u32,
    ) (ValidationError || error{OutOfMemory})!void {
        try self.validateSlotLayout();

        const written = try allocator.alloc(bool, self.temporaries.len);
        defer allocator.free(written);
        @memset(written, false);

        for (self.instructions) |instruction| {
            try self.validateInstruction(instruction, written, exponent_limit);
            const slot = instruction.result();
            // Defense in depth rather than a reachable branch: every current
            // instruction kind already validates its own result slot inside
            // `validateInstruction`, either through `requireResultType` or a
            // direct `slotType` lookup, so this never actually fires against
            // today's instruction catalog. It stays because that is a property
            // of the catalog, not a guarantee `Instruction.result()` or this
            // loop makes on its own -- an instruction kind added later without
            // its own check would rely on exactly this.
            if (slot >= self.temporaries.len) return error.ResultOutOfRange;
            written[slot] = true;
        }

        try requireOutput(written, self.outputs.value, self.temporaryCount());
        // The declared value slot carries the kernel's declared result type, so
        // a caller's buffer element type is decided by validated structure.
        const value_type = self.temporaries[self.outputs.value].kind.resultType() orelse
            return error.SlotTypeMismatch;
        if (value_type != self.result_type) return error.SlotTypeMismatch;

        for (self.outputs.gradient) |slot| {
            try requireOutput(written, slot, self.temporaryCount());
            if (self.temporaries[slot].kind.resultType() != self.result_type) {
                return error.SlotTypeMismatch;
            }
        }
        for (self.outputs.hessian) |slot| {
            try requireOutput(written, slot, self.temporaryCount());
            if (self.temporaries[slot].kind.resultType() != self.result_type) {
                return error.SlotTypeMismatch;
            }
        }
    }

    /// Checks that every temporary lies inside the frame and that no two
    /// simultaneously live temporaries share storage.
    ///
    /// This verifies the schedule independently of the allocator that produced
    /// it: reuse is only sound when the live ranges of two slots sharing bytes
    /// are disjoint.
    fn validateSlotLayout(self: *const Program) ValidationError!void {
        for (self.temporaries) |temporary| {
            const expected = temporary.kind.byteSize() catch
                return error.InvalidSlotLayout;
            if (temporary.bytes != expected) return error.InvalidSlotLayout;
            if (temporary.alignment != temporary.kind.alignment()) {
                return error.InvalidSlotLayout;
            }
            // The `alignment == 0` disjunct guards the modulo just after it
            // from dividing by zero, but every `SlotType.alignment()` today
            // returns a fixed nonzero `@alignOf(Scalar)`, and the check just
            // above already rejects any temporary whose declared alignment
            // does not match it -- so this can never observe a zero here
            // either. Kept for the same reason as the result-slot check in
            // `validate`: a future slot kind with its own alignment could
            // make it reachable, and the modulo below is only safe because of
            // it.
            if (temporary.alignment == 0 or
                temporary.offset % temporary.alignment != 0)
            {
                return error.InvalidSlotLayout;
            }
            const end = std.math.add(usize, temporary.offset, temporary.bytes) catch
                return error.InvalidSlotLayout;
            if (end > self.frame_bytes) return error.InvalidSlotLayout;
            if (temporary.live.first_write > temporary.live.last_use) {
                return error.InvalidSlotLayout;
            }
        }

        for (self.temporaries, 0..) |left, index| {
            for (self.temporaries[index + 1 ..]) |right| {
                const disjoint = left.offset + left.bytes <= right.offset or
                    right.offset + right.bytes <= left.offset;
                if (disjoint) continue;
                if (left.live.overlaps(right.live)) return error.InvalidSlotLayout;
            }
        }

        if (self.scratch_offset < self.frame_bytes) return error.InvalidSlotLayout;
        if (self.scratch_offset % @alignOf(Scalar) != 0) return error.InvalidSlotLayout;
    }

    fn validateInstruction(
        self: *const Program,
        instruction: Instruction,
        written: []const bool,
        exponent_limit: u32,
    ) ValidationError!void {
        switch (instruction) {
            .load_constant => |payload| {
                if (payload.source >= self.constants.len) return error.SourceOutOfRange;
                try self.requireResultType(payload.result, .real);
            },
            .load_parameter => |payload| {
                if (payload.source >= self.parameter_count) return error.SourceOutOfRange;
                try self.requireResultType(payload.result, .real);
            },
            .load_background => |payload| {
                if (payload.source >= self.background_count) return error.SourceOutOfRange;
                try self.requireResultType(payload.result, .real);
            },
            .load_renormalization_scale => |payload| {
                if (payload.source >= self.scale_count) return error.SourceOutOfRange;
                try self.requireResultType(payload.result, .real);
            },
            // Negation is component-wise and keeps its operand's scalar type.
            .negate => |payload| {
                try requireWritten(written, payload.operand);
                const operand = try self.slotType(payload.operand);
                if (operand.resultType() == null) return error.SlotTypeMismatch;
                try self.requireResultType(payload.result, operand);
            },
            .add => |payload| {
                if (payload.operands.len < 2) return error.TooFewOperands;
                const shared = try self.slotType(payload.operands[0]);
                if (shared.resultType() == null) return error.SlotTypeMismatch;
                for (payload.operands) |operand| {
                    try requireWritten(written, operand);
                    if (!(try self.slotType(operand)).eql(shared)) {
                        return error.SlotTypeMismatch;
                    }
                }
                try self.requireResultType(payload.result, shared);
            },
            // There is no complex multiply, divide, or power in this catalog.
            .multiply => |payload| {
                if (payload.operands.len < 2) return error.TooFewOperands;
                for (payload.operands) |operand| {
                    try requireWritten(written, operand);
                    try self.requireSlotType(operand, .real);
                }
                try self.requireResultType(payload.result, .real);
            },
            .divide => |payload| {
                try requireWritten(written, payload.numerator);
                try requireWritten(written, payload.denominator);
                try self.requireSlotType(payload.numerator, .real);
                try self.requireSlotType(payload.denominator, .real);
                try self.requireResultType(payload.result, .real);
            },
            .power_integer => |payload| {
                try requireWritten(written, payload.base);
                try self.requireSlotType(payload.base, .real);
                try self.requireResultType(payload.result, .real);
                if (payload.exponent > exponent_limit) return error.ExponentTooLarge;
            },
            .promote_real_to_complex => |payload| {
                try requireWritten(written, payload.operand);
                try self.requireSlotType(payload.operand, .real);
                try self.requireResultType(payload.result, .complex);
            },
            .assemble_real_symmetric => |payload| {
                const result = try self.slotType(payload.result);
                const dimension = switch (result) {
                    .real_symmetric_matrix => |value| value,
                    else => return error.SlotTypeMismatch,
                };
                const expected = eigensolver.packedEntryCount(dimension) catch
                    return error.ShapeMismatch;
                if (payload.entries.len != expected) return error.ShapeMismatch;
                for (payload.entries) |entry| {
                    try requireWritten(written, entry);
                    try self.requireSlotType(entry, .real);
                }
            },
            .symmetric_eigensystem => |payload| {
                try requireWritten(written, payload.matrix);
                const matrix = try self.slotType(payload.matrix);
                const result = try self.slotType(payload.result);
                const source = switch (matrix) {
                    .real_symmetric_matrix => |value| value,
                    else => return error.SlotTypeMismatch,
                };
                const target = switch (result) {
                    .real_eigensystem => |value| value,
                    else => return error.SlotTypeMismatch,
                };
                if (source != target) return error.ShapeMismatch;
            },
            .scalar_one_loop_sum => |payload| {
                try requireWritten(written, payload.eigensystem);
                try requireWritten(written, payload.scale);
                if ((try self.slotType(payload.eigensystem)) != .real_eigensystem) {
                    return error.SlotTypeMismatch;
                }
                try self.requireSlotType(payload.scale, .real);
                try self.requireResultType(payload.result, .complex);
            },
            .scalar_one_loop_gradient => |payload| {
                const dimension = try self.spectralOperands(
                    written,
                    payload.eigensystem,
                    payload.scale,
                );
                const coordinates = switch (try self.slotType(payload.result)) {
                    .complex_vector => |count| count,
                    else => return error.SlotTypeMismatch,
                };
                if (payload.first.len != coordinates) return error.ShapeMismatch;
                try self.requireMatrices(written, payload.first, dimension);
            },
            .scalar_one_loop_hessian => |payload| {
                const dimension = try self.spectralOperands(
                    written,
                    payload.eigensystem,
                    payload.scale,
                );
                const coordinates = switch (try self.slotType(payload.result)) {
                    .complex_matrix => |count| count,
                    else => return error.SlotTypeMismatch,
                };
                if (payload.first.len != coordinates) return error.ShapeMismatch;
                const pairs = eigensolver.packedEntryCount(coordinates) catch
                    return error.ShapeMismatch;
                if (payload.second.len != pairs) return error.ShapeMismatch;
                try self.requireMatrices(written, payload.first, dimension);
                try self.requireMatrices(written, payload.second, dimension);
            },
            .extract_element => |payload| {
                try requireWritten(written, payload.source);
                const rows = switch (try self.slotType(payload.source)) {
                    .complex_vector => |count| blk: {
                        if (payload.column != 0) return error.ShapeMismatch;
                        break :blk count;
                    },
                    .complex_matrix => |count| blk: {
                        if (payload.column >= count) return error.ShapeMismatch;
                        break :blk count;
                    },
                    else => return error.SlotTypeMismatch,
                };
                if (payload.row >= rows) return error.ShapeMismatch;
                try self.requireResultType(payload.result, .complex);
            },
        }
    }

    /// Checks the eigensystem and scale both spectral derivative orders share
    /// and returns the matrix dimension they fix.
    fn spectralOperands(
        self: *const Program,
        written: []const bool,
        eigensystem: u32,
        scale: u32,
    ) ValidationError!u32 {
        try requireWritten(written, eigensystem);
        try requireWritten(written, scale);
        try self.requireSlotType(scale, .real);
        return switch (try self.slotType(eigensystem)) {
            .real_eigensystem => |dimension| dimension,
            else => error.SlotTypeMismatch,
        };
    }

    fn requireMatrices(
        self: *const Program,
        written: []const bool,
        slots: []const u32,
        dimension: u32,
    ) ValidationError!void {
        for (slots) |slot| {
            try requireWritten(written, slot);
            try self.requireSlotType(slot, .{ .real_symmetric_matrix = dimension });
        }
    }

    fn requireSlotType(
        self: *const Program,
        slot: u32,
        expected: SlotType,
    ) ValidationError!void {
        if (!(try self.slotType(slot)).eql(expected)) return error.SlotTypeMismatch;
    }

    fn requireResultType(
        self: *const Program,
        slot: u32,
        expected: SlotType,
    ) ValidationError!void {
        if (slot >= self.temporaries.len) return error.ResultOutOfRange;
        if (!self.temporaries[slot].kind.eql(expected)) return error.SlotTypeMismatch;
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

/// Builds a frame of real temporaries whose live ranges cover the whole
/// program, which is what a test that is not about reuse wants.
fn realFrame(allocator: std.mem.Allocator, count: u32) ![]Temporary {
    const temporaries = try allocator.alloc(Temporary, count);
    for (temporaries, 0..) |*slot, index| {
        slot.* = .{
            .kind = .real,
            .alignment = @alignOf(Scalar),
            .offset = index * @sizeOf(Scalar),
            .bytes = @sizeOf(Scalar),
            .live = .{ .first_write = 0, .last_use = std.math.maxInt(u32) },
        };
    }
    return temporaries;
}

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
    const temporaries = try realFrame(arena.allocator(), temporary_count);
    const frame_bytes = @as(usize, temporary_count) * @sizeOf(Scalar);
    return .{
        .arena = arena,
        .instructions = owned,
        .constants = constants,
        .temporaries = temporaries,
        .outputs = outputs,
        .capability = .value,
        .result_type = .real64,
        .frame_bytes = frame_bytes,
        .scratch_offset = frame_bytes,
        .scratch_bytes = 0,
        .parameter_stage_count = 0,
        .parameter_count = 2,
        .scale_count = 1,
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
    // Exactly at the boundary (2 temporaries declared, operand names slot 2)
    // rather than far past it, which an off-by-one would reject just as
    // readily.
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .negate = .{ .result = 1, .operand = 2 } },
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

test "a result slot exactly at the temporary count is rejected" {
    // `requireResultType` is what a plain load's result passes through, and
    // its own range check is what this exercises: one temporary declared,
    // result names slot 1.
    var program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_constant = .{ .result = 1, .source = 0 } }},
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.ResultOutOfRange,
        program.validate(std.testing.allocator, 64),
    );
}

test "an assembled matrix's out of range result slot is rejected before its shape" {
    // `assemble_real_symmetric` reads its own result slot's declared type
    // before anything else in the instruction, to learn the dimension its
    // entry count must match -- so an out of range result here is caught by
    // that direct lookup, not by `requireResultType`, and reports
    // `OperandOutOfRange` rather than `ResultOutOfRange`. That distinction is
    // what tells the two code paths apart.
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .assemble_real_symmetric = .{ .result = 1, .entries = &.{0} } },
        },
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.OperandOutOfRange,
        program.validate(std.testing.allocator, 64),
    );
}

test "an out of range constant or input source is rejected" {
    // Exactly at the boundary: `programForTest` fixes two constants, so index
    // 2 is the first invalid one. A far-out-of-range index would pass under an
    // off-by-one as readily as under the correct check, so it cannot tell them
    // apart the way the boundary itself does.
    var program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_constant = .{ .result = 0, .source = 2 } }},
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.SourceOutOfRange,
        program.validate(std.testing.allocator, 64),
    );

    // `programForTest` fixes parameter_count at 2.
    var parameter_program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_parameter = .{ .result = 0, .source = 2 } }},
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer parameter_program.deinit();
    try std.testing.expectError(
        error.SourceOutOfRange,
        parameter_program.validate(std.testing.allocator, 64),
    );

    // `programForTest` fixes background_count at 1.
    var background_program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_background = .{ .result = 0, .source = 1 } }},
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer background_program.deinit();
    try std.testing.expectError(
        error.SourceOutOfRange,
        background_program.validate(std.testing.allocator, 64),
    );

    // The scale channel is its own slot space, so an index valid for parameters
    // is not thereby valid for scales.
    var scale_program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_renormalization_scale = .{ .result = 0, .source = 1 } }},
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer scale_program.deinit();
    try std.testing.expectError(
        error.SourceOutOfRange,
        scale_program.validate(std.testing.allocator, 64),
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

test "an exponent exactly at the limit is accepted and one past it is not" {
    // The far-oversized case above cannot tell a strict limit from an
    // off-by-one one; only the boundary itself can.
    var at_limit = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_parameter = .{ .result = 0, .source = 0 } },
            .{ .power_integer = .{ .result = 1, .base = 0, .exponent = 64 } },
        },
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer at_limit.deinit();
    try at_limit.validate(std.testing.allocator, 64);

    var one_over = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_parameter = .{ .result = 0, .source = 0 } },
            .{ .power_integer = .{ .result = 1, .base = 0, .exponent = 65 } },
        },
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer one_over.deinit();
    try std.testing.expectError(
        error.ExponentTooLarge,
        one_over.validate(std.testing.allocator, 64),
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

test "an output slot exactly at the temporary count is out of range" {
    // Distinct from the case above: slot 2 does not exist at all (one
    // temporary declared), rather than existing but unwritten, which is what
    // separates `OutputOutOfRange` from `OutputNotWritten`.
    var program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_constant = .{ .result = 0, .source = 0 } }},
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.OutputOutOfRange,
        program.validate(std.testing.allocator, 64),
    );
}

test "workspace is exactly the temporary frame plus the shared scratch" {
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

test "slot sizes follow their declared type and shape" {
    try std.testing.expectEqual(@as(usize, 8), try (SlotType{ .real = {} }).byteSize());
    try std.testing.expectEqual(@as(usize, 16), try (SlotType{ .complex = {} }).byteSize());
    // A 3x3 symmetric matrix stores six entries; its eigensystem stores three
    // eigenvalues and a full 3x3 eigenvector matrix.
    try std.testing.expectEqual(
        @as(usize, 6 * 8),
        try (SlotType{ .real_symmetric_matrix = 3 }).byteSize(),
    );
    try std.testing.expectEqual(
        @as(usize, (3 + 9) * 8),
        try (SlotType{ .real_eigensystem = 3 }).byteSize(),
    );
}

test "two temporaries may share bytes only when their live ranges are disjoint" {
    const early = LiveRange{ .first_write = 0, .last_use = 3 };
    const late = LiveRange{ .first_write = 4, .last_use = 9 };
    const straddling = LiveRange{ .first_write = 2, .last_use = 6 };
    // Touching at exactly one instruction position is still overlapping: both
    // ranges are live during that instruction, so a slot shared there is read
    // or written by two temporaries at once.
    const touching = LiveRange{ .first_write = 3, .last_use = 5 };
    try std.testing.expect(!early.overlaps(late));
    try std.testing.expect(early.overlaps(straddling));
    try std.testing.expect(late.overlaps(straddling));
    try std.testing.expect(early.overlaps(touching));
    try std.testing.expect(touching.overlaps(early));

    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .load_constant = .{ .result = 1, .source = 1 } },
            .{ .add = .{ .result = 1, .operands = &.{ 0, 1 } } },
        },
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer program.deinit();

    // Overlapping storage with overlapping live ranges is a layout defect, not
    // a schedule the interpreter is entitled to trust.
    const temporaries = @constCast(program.temporaries);
    temporaries[1].offset = temporaries[0].offset;
    try std.testing.expectError(
        error.InvalidSlotLayout,
        program.validate(std.testing.allocator, 64),
    );

    // The same sharing is sound once the ranges are disjoint.
    temporaries[0].live = .{ .first_write = 0, .last_use = 1 };
    temporaries[1].live = .{ .first_write = 2, .last_use = 2 };
    try program.validate(std.testing.allocator, 64);
}

test "a temporary's declared alignment must match its slot type" {
    var program = try programForTest(
        std.testing.allocator,
        &.{.{ .load_constant = .{ .result = 0, .source = 0 } }},
        .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
        1,
    );
    defer program.deinit();

    // Zero is as good a mismatch as any other for this check, and it is the
    // one value that would panic the modulo two lines below if this check
    // ever let it through instead of catching it here.
    const temporaries = @constCast(program.temporaries);
    temporaries[0].alignment = 0;
    try std.testing.expectError(
        error.InvalidSlotLayout,
        program.validate(std.testing.allocator, 64),
    );
}

test "adjacently packed temporaries in reverse offset order are disjoint at the boundary" {
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .load_constant = .{ .result = 1, .source = 1 } },
            .{ .add = .{ .result = 1, .operands = &.{ 0, 1 } } },
        },
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer program.deinit();

    // Slot 1 (the second temporary in declaration order) is packed *before*
    // slot 0 in the frame, touching it exactly at the boundary: disjoint, not
    // overlapping. This is the ordering the disjointness check's second
    // clause covers, distinct from the touching-in-declaration-order case
    // above; both clauses' boundaries need their own coverage.
    const temporaries = @constCast(program.temporaries);
    temporaries[0].offset = @sizeOf(Scalar);
    temporaries[1].offset = 0;
    try program.validate(std.testing.allocator, 64);
}

/// Builds a frame from declared slot types, packed in slot order, for the
/// structured programs a real-only frame cannot express.
fn typedProgramForTest(
    allocator: std.mem.Allocator,
    instructions: []const Instruction,
    outputs: Outputs,
    kinds: []const SlotType,
    result_type: ResultType,
) !Program {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const temporaries = try arena.allocator().alloc(Temporary, kinds.len);
    var offset: usize = 0;
    for (kinds, temporaries) |kind, *slot| {
        const bytes = try kind.byteSize();
        offset = std.mem.alignForward(usize, offset, kind.alignment());
        slot.* = .{
            .kind = kind,
            .alignment = kind.alignment(),
            .offset = offset,
            .bytes = bytes,
            .live = .{ .first_write = 0, .last_use = std.math.maxInt(u32) },
        };
        offset += bytes;
    }
    const frame_bytes = std.mem.alignForward(usize, offset, @alignOf(Scalar));
    return .{
        .arena = arena,
        .instructions = try arena.allocator().dupe(Instruction, instructions),
        .constants = try arena.allocator().dupe(Scalar, &.{4.0}),
        .temporaries = temporaries,
        .outputs = outputs,
        .capability = .value,
        .result_type = result_type,
        .frame_bytes = frame_bytes,
        .scratch_offset = frame_bytes,
        .scratch_bytes = 0,
        .parameter_stage_count = 0,
        .parameter_count = 0,
        .scale_count = 1,
        .background_count = 0,
        .coordinate_count = 1,
    };
}

/// The slot plan of a one-by-one spectral gradient, shared by the cases below.
const spectral_gradient_slots = [_]SlotType{
    .real,
    .{ .real_symmetric_matrix = 1 },
    .{ .real_eigensystem = 1 },
    .real,
    .{ .complex_vector = 1 },
    .complex,
};

fn spectralGradientProgram(
    allocator: std.mem.Allocator,
    gradient: SpectralGradient,
    extract: Extract,
) !Program {
    return typedProgramForTest(
        allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .assemble_real_symmetric = .{ .result = 1, .entries = &.{0} } },
            .{ .symmetric_eigensystem = .{ .result = 2, .matrix = 1 } },
            .{ .load_renormalization_scale = .{ .result = 3, .source = 0 } },
            .{ .scalar_one_loop_gradient = gradient },
            .{ .extract_element = extract },
        },
        .{ .value = 5, .gradient = &.{}, .hessian = &.{} },
        &spectral_gradient_slots,
        .complex64,
    );
}

test "a spectral gradient and its extraction validate as structured results" {
    var program = try spectralGradientProgram(
        std.testing.allocator,
        .{ .result = 4, .eigensystem = 2, .first = &.{1}, .scale = 3 },
        .{ .result = 5, .source = 4, .row = 0, .column = 0 },
    );
    defer program.deinit();
    try program.validate(std.testing.allocator, 64);
}

test "a derivative operand count that disagrees with its result shape is rejected" {
    // The result declares one background coordinate, so one first-derivative
    // matrix is required and two are not.
    var program = try spectralGradientProgram(
        std.testing.allocator,
        .{ .result = 4, .eigensystem = 2, .first = &.{ 1, 1 }, .scale = 3 },
        .{ .result = 5, .source = 4, .row = 0, .column = 0 },
    );
    defer program.deinit();
    try std.testing.expectError(
        error.ShapeMismatch,
        program.validate(std.testing.allocator, 64),
    );
}

test "an extraction outside its source shape is rejected" {
    var out_of_range = try spectralGradientProgram(
        std.testing.allocator,
        .{ .result = 4, .eigensystem = 2, .first = &.{1}, .scale = 3 },
        .{ .result = 5, .source = 4, .row = 1, .column = 0 },
    );
    defer out_of_range.deinit();
    try std.testing.expectError(
        error.ShapeMismatch,
        out_of_range.validate(std.testing.allocator, 64),
    );

    // A vector has one column, so naming another is a shape error rather than
    // an index that silently wraps into the next component.
    var wrong_column = try spectralGradientProgram(
        std.testing.allocator,
        .{ .result = 4, .eigensystem = 2, .first = &.{1}, .scale = 3 },
        .{ .result = 5, .source = 4, .row = 0, .column = 1 },
    );
    defer wrong_column.deinit();
    try std.testing.expectError(
        error.ShapeMismatch,
        wrong_column.validate(std.testing.allocator, 64),
    );

    // Extraction applies to structured spectral results only.
    var scalar_source = try spectralGradientProgram(
        std.testing.allocator,
        .{ .result = 4, .eigensystem = 2, .first = &.{1}, .scale = 3 },
        .{ .result = 5, .source = 3, .row = 0, .column = 0 },
    );
    defer scalar_source.deinit();
    try std.testing.expectError(
        error.SlotTypeMismatch,
        scalar_source.validate(std.testing.allocator, 64),
    );
}

test "a derivative matrix of the wrong dimension is rejected" {
    var program = try typedProgramForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .assemble_real_symmetric = .{
                .result = 1,
                .entries = &.{ 0, 0, 0 },
            } },
            .{ .symmetric_eigensystem = .{ .result = 2, .matrix = 1 } },
            .{ .load_renormalization_scale = .{ .result = 3, .source = 0 } },
            .{ .assemble_real_symmetric = .{ .result = 4, .entries = &.{0} } },
            // The eigensystem is two by two; this first-derivative matrix is
            // one by one.
            .{ .scalar_one_loop_gradient = .{
                .result = 5,
                .eigensystem = 2,
                .first = &.{4},
                .scale = 3,
            } },
            .{ .extract_element = .{
                .result = 6,
                .source = 5,
                .row = 0,
                .column = 0,
            } },
        },
        .{ .value = 6, .gradient = &.{}, .hessian = &.{} },
        &.{
            .real,
            .{ .real_symmetric_matrix = 2 },
            .{ .real_eigensystem = 2 },
            .real,
            .{ .real_symmetric_matrix = 1 },
            .{ .complex_vector = 1 },
            .complex,
        },
        .complex64,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.SlotTypeMismatch,
        program.validate(std.testing.allocator, 64),
    );
}

test "extracting a matrix column exactly at its dimension is rejected" {
    // A one-by-one Hessian has exactly one column, index 0; index 1 names the
    // column immediately past it. "an extraction outside its source shape is
    // rejected" covers the vector case (`extract_element` on a
    // `.complex_vector` source); this is the matrix case, whose column check
    // is a separate boundary.
    var program = try typedProgramForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .assemble_real_symmetric = .{ .result = 1, .entries = &.{0} } },
            .{ .symmetric_eigensystem = .{ .result = 2, .matrix = 1 } },
            .{ .load_renormalization_scale = .{ .result = 3, .source = 0 } },
            .{ .assemble_real_symmetric = .{ .result = 4, .entries = &.{0} } },
            .{ .scalar_one_loop_hessian = .{
                .result = 5,
                .eigensystem = 2,
                .first = &.{4},
                .second = &.{4},
                .scale = 3,
            } },
            .{ .extract_element = .{ .result = 6, .source = 5, .row = 0, .column = 1 } },
        },
        .{ .value = 6, .gradient = &.{}, .hessian = &.{} },
        &.{
            .real,
            .{ .real_symmetric_matrix = 1 },
            .{ .real_eigensystem = 1 },
            .real,
            .{ .real_symmetric_matrix = 1 },
            .{ .complex_matrix = 1 },
            .complex,
        },
        .complex64,
    );
    defer program.deinit();
    try std.testing.expectError(
        error.ShapeMismatch,
        program.validate(std.testing.allocator, 64),
    );
}

test "structured complex slot sizes follow their declared shape" {
    // A gradient over two coordinates is two complex components; the Hessian
    // over the same coordinates is the full dense four.
    try std.testing.expectEqual(
        @as(usize, 2 * 16),
        try (SlotType{ .complex_vector = 2 }).byteSize(),
    );
    try std.testing.expectEqual(
        @as(usize, 4 * 16),
        try (SlotType{ .complex_matrix = 2 }).byteSize(),
    );

    // Equal dimensions of different structured kinds are still different
    // types, so first-fit slot reuse can never confuse them.
    try std.testing.expect(!(SlotType{ .complex_vector = 2 })
        .eql(.{ .complex_matrix = 2 }));
    try std.testing.expect(!(SlotType{ .real_symmetric_matrix = 2 })
        .eql(.{ .real_eigensystem = 2 }));
    try std.testing.expect((SlotType{ .complex_matrix = 2 })
        .eql(.{ .complex_matrix = 2 }));

    // The two unstructured kinds are likewise never confused with each other.
    try std.testing.expect((SlotType{ .real = {} }).eql(.{ .real = {} }));
    try std.testing.expect(!(SlotType{ .real = {} }).eql(.{ .complex = {} }));
    try std.testing.expect((SlotType{ .complex = {} }).eql(.{ .complex = {} }));
    try std.testing.expect(!(SlotType{ .complex = {} }).eql(.{ .real = {} }));

    // A structured slot is not a publishable result element on its own; only
    // an extracted component is.
    try std.testing.expectEqual(
        @as(?ResultType, null),
        (SlotType{ .complex_vector = 2 }).resultType(),
    );
    try std.testing.expectEqual(
        @as(?ResultType, .complex64),
        (SlotType{ .complex = {} }).resultType(),
    );
}

test "a mistyped operand or result is rejected" {
    var program = try programForTest(
        std.testing.allocator,
        &.{
            .{ .load_constant = .{ .result = 0, .source = 0 } },
            .{ .promote_real_to_complex = .{ .result = 1, .operand = 0 } },
        },
        .{ .value = 1, .gradient = &.{}, .hessian = &.{} },
        2,
    );
    defer program.deinit();

    // Slot 1 is declared real, so it cannot receive a promotion.
    try std.testing.expectError(
        error.SlotTypeMismatch,
        program.validate(std.testing.allocator, 64),
    );
}
