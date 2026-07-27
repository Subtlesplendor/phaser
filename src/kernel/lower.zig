//! Lowering from Typed Value IR to an instruction program.
//!
//! Common subexpressions need no discovery pass: the value graph is interned,
//! so a shared subexpression is one node and therefore one instruction. What
//! lowering adds is instruction selection, exact-to-`f64` conversion, execution
//! order, and temporary-slot assignment with live-range reuse.

const std = @import("std");
const error_injection = @import("../testing/error_injection.zig");
const value = @import("../value/root.zig");
const program_module = @import("program.zig");

const ValueId = value.ValueId;
const Graph = value.Graph;
const Instruction = program_module.Instruction;
const Program = program_module.Program;
const Scalar = program_module.Scalar;
const SlotType = program_module.SlotType;
const Temporary = program_module.Temporary;
const eigensolver = @import("../numerics/root.zig").symmetric_eigensolver;

pub const LowerError = error{
    OutOfMemory,
    /// An exact constant has no faithful `f64` representation under the
    /// conversion policy.
    ConstantNotRepresentable,
    /// The value graph uses a node kind this backend does not implement.
    UnsupportedOperation,
    CapacityExceeded,
    /// A structured shape or workspace requirement is not representable.
    SizeOverflow,
};

pub const LowerOptions = struct {
    /// Highest `power_integer` exponent the program may contain.
    exponent_limit: u32 = 64,
    /// Ceiling on emitted instructions.
    max_instructions: usize = 1024 * 1024,
};

pub const Request = struct {
    graph: *const Graph,
    capability: program_module.Capability,
    /// Root of the potential value.
    value_root: ValueId,
    /// One root per background coordinate; empty when no gradient is lowered.
    gradient_roots: []const ValueId,
    /// Row-major roots; empty when no Hessian is lowered.
    hessian_roots: []const ValueId,
    parameter_count: u32,
    background_count: u32,
    coordinate_count: u32,
};

const lower_tw = error_injection.module(enum {
    collect_roots,
    mark_reachable,
    classify_stages,
    assign_slots,
    emit,
    publish,
}, lower);

/// Lowers `request` into a validated program.
pub fn lower(
    allocator: std.mem.Allocator,
    request: Request,
    options: LowerOptions,
) LowerError!Program {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var builder = Builder{
        .allocator = allocator,
        .arena = arena.allocator(),
        .graph = request.graph,
        .options = options,
    };
    defer builder.deinit();

    try lower_tw.check(.collect_roots);
    try builder.collectRoots(request);
    try lower_tw.check(.mark_reachable);
    try builder.markReachable();
    try lower_tw.check(.classify_stages);
    try builder.classifyStages();
    try lower_tw.check(.assign_slots);
    try builder.assignSlots();
    try lower_tw.check(.emit);
    try builder.emit();

    try lower_tw.check(.publish);
    const outputs = program_module.Outputs{
        .value = builder.slotOf(request.value_root),
        .gradient = try builder.slotsOf(request.gradient_roots),
        .hessian = try builder.slotsOf(request.hessian_roots),
    };
    const frame = try builder.layoutFrame();

    return .{
        .arena = arena,
        .instructions = try builder.arena.dupe(Instruction, builder.instructions.items),
        .constants = try builder.arena.dupe(Scalar, builder.constants.items),
        .temporaries = frame.temporaries,
        .outputs = outputs,
        .capability = request.capability,
        .result_type = builder.resultTypeOf(request.value_root),
        .frame_bytes = frame.bytes,
        .scratch_offset = frame.bytes,
        .scratch_bytes = builder.scratch_bytes,
        .parameter_stage_count = builder.parameter_stage_count,
        .parameter_count = request.parameter_count,
        .scale_count = builder.scale_count,
        .background_count = request.background_count,
        .coordinate_count = request.coordinate_count,
    };
}

const Builder = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    graph: *const Graph,
    options: LowerOptions,

    frontier: usize = 0,
    reachable: []bool = &.{},
    slots: []u32 = &.{},
    last_use: []usize = &.{},
    /// True when a node depends, transitively, on a background coordinate and
    /// must therefore be recomputed for every point.
    background_dependent: []bool = &.{},
    parameter_stage_count: u32 = 0,
    roots: std.ArrayList(ValueId) = .empty,
    instructions: std.ArrayList(Instruction) = .empty,
    constants: std.ArrayList(Scalar) = .empty,
    /// One entry per allocated temporary, in slot order.
    pool: std.ArrayList(Slot) = .empty,
    /// Largest single-operation scratch requirement seen so far. One region is
    /// shared, because no two operations are in flight at once.
    scratch_bytes: usize = 0,
    /// Number of renormalization-scale channels the emitted program reads.
    /// A selection that reads no scale declares no scale channel, so its
    /// callers pass none.
    scale_count: u32 = 0,

    /// A temporary under construction: its type, the instruction that wrote it,
    /// and the position after which its storage may be reused.
    const Slot = struct {
        kind: SlotType,
        first_write: u32,
        last_use: u32,
        /// True while the slot holds a live value. First-fit reuse considers
        /// only released slots of an identical type.
        live: bool,
    };

    fn deinit(self: *Builder) void {
        if (self.reachable.len != 0) self.allocator.free(self.reachable);
        if (self.slots.len != 0) self.allocator.free(self.slots);
        if (self.last_use.len != 0) self.allocator.free(self.last_use);
        if (self.background_dependent.len != 0) {
            self.allocator.free(self.background_dependent);
        }
        self.roots.deinit(self.allocator);
        self.instructions.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.pool.deinit(self.allocator);
    }

    fn collectRoots(self: *Builder, request: Request) LowerError!void {
        try self.roots.append(self.allocator, request.value_root);
        for (request.gradient_roots) |root| {
            try self.roots.append(self.allocator, root);
        }
        for (request.hessian_roots) |root| {
            try self.roots.append(self.allocator, root);
        }
        var highest: usize = 0;
        for (self.roots.items) |root| highest = @max(highest, root.toUsize());
        self.frontier = highest + 1;
    }

    /// Marks every node any output depends on. Operands refer to strictly
    /// earlier nodes, so one descending sweep suffices.
    fn markReachable(self: *Builder) LowerError!void {
        self.reachable = try self.allocator.alloc(bool, self.frontier);
        @memset(self.reachable, false);
        for (self.roots.items) |root| self.reachable[root.toUsize()] = true;

        var index = self.frontier;
        while (index > 0) {
            index -= 1;
            if (!self.reachable[index]) continue;
            const node = self.graph.values[index].node;
            var operand: usize = 0;
            while (value.childAt(node, operand)) |child| : (operand += 1) {
                self.reachable[child.toUsize()] = true;
            }
        }
    }

    /// Classifies every reachable node by binding stage.
    ///
    /// A node is background dependent when it loads a coordinate or has any
    /// background-dependent operand. Everything else depends only on constants
    /// and bound parameters, so it can be computed once per binding instead of
    /// once per point. Operands precede their consumers, so one ascending sweep
    /// resolves the whole set.
    fn classifyStages(self: *Builder) LowerError!void {
        self.background_dependent = try self.allocator.alloc(bool, self.frontier);
        @memset(self.background_dependent, false);

        for (self.reachable, 0..) |included, index| {
            if (!included) continue;
            const node = self.graph.values[index].node;
            self.background_dependent[index] = blk: {
                if (node == .background) break :blk true;
                var operand: usize = 0;
                while (value.childAt(node, operand)) |child| : (operand += 1) {
                    if (self.background_dependent[child.toUsize()]) break :blk true;
                }
                break :blk false;
            };
        }
    }

    /// Emission order: every parameter-stage node, then every
    /// background-dependent node, each in ascending node order.
    ///
    /// This is a valid topological order because a parameter-stage node never
    /// depends on a background-dependent one. Making the split contiguous is
    /// what lets the interpreter execute the first section once per binding.
    fn stageOf(self: *const Builder, index: usize) u1 {
        return if (self.background_dependent[index]) 1 else 0;
    }

    /// Computes the last instruction that reads each node, then assigns
    /// temporary slots with reuse. Output roots never die, so their slots stay
    /// live to the end.
    fn assignSlots(self: *Builder) LowerError!void {
        self.last_use = try self.allocator.alloc(usize, self.frontier);
        @memset(self.last_use, 0);
        self.slots = try self.allocator.alloc(u32, self.frontier);
        @memset(self.slots, 0);

        var position: usize = 0;
        for ([_]u1{ 0, 1 }) |stage| {
            for (self.reachable, 0..) |included, index| {
                if (!included or self.stageOf(index) != stage) continue;
                const node = self.graph.values[index].node;
                var operand: usize = 0;
                while (value.childAt(node, operand)) |child| : (operand += 1) {
                    self.noteUse(child, position, stage);
                }
                position += 1;
            }
            if (stage == 0) self.parameter_stage_count = @intCast(position);
        }

        // An output is read by the caller after the last instruction.
        for (self.roots.items) |root| self.last_use[root.toUsize()] = position;

        // A parameter-stage value consumed by the background section must
        // survive every point, not just its first reader: the background
        // section reruns per point while the parameter section does not.
        for (self.last_use) |*last| {
            if (last.* == std.math.maxInt(usize)) last.* = position;
        }
    }

    fn noteUse(self: *Builder, operand: ValueId, position: usize, stage: u1) void {
        const index = operand.toUsize();
        if (stage == 1 and !self.background_dependent[index]) {
            // The background stage reruns for every point, so a value produced
            // by the parameter stage must remain live through the entire
            // program. Mark this during the ordinary operand traversal rather
            // than rescanning every background node for every producer.
            self.last_use[index] = std.math.maxInt(usize);
        } else {
            self.last_use[index] = position;
        }
    }

    fn emit(self: *Builder) LowerError!void {
        // Node position, which `assignSlots` counted the same way, decides when
        // an operand dies. Instruction position, which one node may advance by
        // more than one, is what the recorded live ranges use.
        var node_position: usize = 0;
        for ([_]u1{ 0, 1 }) |stage| {
            for (self.reachable, 0..) |included, index| {
                if (!included or self.stageOf(index) != stage) continue;
                const id = ValueId.fromUsize(index) catch return error.CapacityExceeded;
                const node = self.graph.values[index].node;

                // Every operand is read here, so its slot stays live at least
                // this long.
                var operand: usize = 0;
                while (value.childAt(node, operand)) |child| : (operand += 1) {
                    self.extendLiveRange(self.slotOf(child), self.instructions.items.len);
                }

                // Operands are read before the result is written, and the
                // interpreter computes into a local before storing, so a result
                // may safely reuse a slot that dies at this instruction.
                try self.releaseExpired(node, node_position);
                self.slots[index] = try self.emitNode(node, id);
                node_position += 1;
            }
            if (stage == 0) self.parameter_stage_count = @intCast(self.instructions.items.len);
        }

        // A slot still holding a live value is read by the caller after the
        // last instruction.
        const end: u32 = @intCast(self.instructions.items.len);
        for (self.pool.items) |*slot| {
            if (slot.live) slot.last_use = end;
        }
    }

    fn append(self: *Builder, instruction: Instruction) LowerError!void {
        if (self.instructions.items.len >= self.options.max_instructions) {
            return error.CapacityExceeded;
        }
        try self.instructions.append(self.allocator, instruction);
    }

    /// Emits the instructions one value node needs and returns the slot holding
    /// its value.
    fn emitNode(self: *Builder, node: value.Node, id: ValueId) LowerError!u32 {
        // The spectral value is the one node that is not a single instruction:
        // its matrix operand is diagonalized into its own temporary, and the
        // restricted one-loop sum then runs over that eigensystem.
        if (node == .scalar_one_loop_spectral_value) {
            const spectral = node.scalar_one_loop_spectral_value;
            const dimension = self.graph.valueType(spectral.matrix).shape.matrix.dimension;

            const eigensystem = try self.acquireSlot(
                .{ .real_eigensystem = dimension },
                self.instructions.items.len,
            );
            try self.append(.{ .symmetric_eigensystem = .{
                .result = eigensystem,
                .matrix = self.slotOf(spectral.matrix),
            } });

            // The solver's own scratch shares one region with every other
            // operation's, because no two are in flight at once.
            const layout = eigensolver.workspaceLayout(dimension) catch
                return error.SizeOverflow;
            self.scratch_bytes = @max(self.scratch_bytes, layout.bytes);

            self.extendLiveRange(eigensystem, self.instructions.items.len);
            self.pool.items[eigensystem].live = false;
            const result = try self.acquireSlot(.complex, self.instructions.items.len);
            try self.append(.{ .scalar_one_loop_sum = .{
                .result = result,
                .eigensystem = eigensystem,
                .scale = self.slotOf(spectral.scale),
            } });
            return result;
        }

        const result = try self.acquireSlot(
            try self.slotTypeOf(id),
            self.instructions.items.len,
        );
        try self.append(try self.select(node, result, id));
        return result;
    }

    fn select(
        self: *Builder,
        node: value.Node,
        result: u32,
        id: ValueId,
    ) LowerError!Instruction {
        _ = id;
        return switch (node) {
            .rational => |rational| .{ .load_constant = .{
                .result = result,
                .source = try self.internConstant(try rationalToScalar(rational)),
            } },
            .pi => .{ .load_constant = .{
                .result = result,
                .source = try self.internConstant(std.math.pi),
            } },
            .sqrt_rational => |rational| .{ .load_constant = .{
                .result = result,
                .source = try self.internConstant(
                    @sqrt(try rationalToScalar(rational)),
                ),
            } },
            .parameter => |input| .{ .load_parameter = .{
                .result = result,
                .source = input.id,
            } },
            .background => |input| .{ .load_background = .{
                .result = result,
                .source = input.index,
            } },
            .add => |children| .{ .add = .{
                .result = result,
                .operands = try self.operandSlots(children),
            } },
            .multiply => |children| blk: {
                // A product by exactly minus one lowers to the negate opcode,
                // which is the same value with one fewer slot and load.
                if (children.len == 2) {
                    for (children, 0..) |child, position| {
                        if (self.isMinusOne(child)) {
                            break :blk Instruction{ .negate = .{
                                .result = result,
                                .operand = self.slotOf(children[1 - position]),
                            } };
                        }
                    }
                }
                break :blk Instruction{ .multiply = .{
                    .result = result,
                    .operands = try self.operandSlots(children),
                } };
            },
            .divide => |binary| .{ .divide = .{
                .result = result,
                .numerator = self.slotOf(binary.numerator),
                .denominator = self.slotOf(binary.denominator),
            } },
            .power => |power_node| blk: {
                if (power_node.exponent > self.options.exponent_limit) {
                    return error.CapacityExceeded;
                }
                break :blk Instruction{ .power_integer = .{
                    .result = result,
                    .base = self.slotOf(power_node.base),
                    .exponent = power_node.exponent,
                } };
            },
            .renormalization_scale => |input| blk: {
                self.scale_count = @max(self.scale_count, input.index + 1);
                break :blk Instruction{ .load_renormalization_scale = .{
                    .result = result,
                    .source = input.index,
                } };
            },
            .promote_real_to_complex => |operand| .{ .promote_real_to_complex = .{
                .result = result,
                .operand = self.slotOf(operand),
            } },
            .real_symmetric_matrix => |matrix| .{ .assemble_real_symmetric = .{
                .result = result,
                .entries = try self.operandSlots(matrix.entries),
            } },
            // Handled by `emitNode`, which needs two instructions for it.
            .scalar_one_loop_spectral_value => unreachable,
            // The invariant spectral derivatives are a separate numerical
            // operation. Failing here keeps the unsupported capability explicit
            // rather than evaluating a potential without its derivatives.
            .scalar_one_loop_spectral_gradient,
            .scalar_one_loop_spectral_hessian,
            .element,
            => error.UnsupportedOperation,
        };
    }

    fn isMinusOne(self: *const Builder, id: ValueId) bool {
        return switch (self.graph.value(id).node) {
            .rational => |rational| std.mem.eql(u8, rational.numerator, "-1") and
                std.mem.eql(u8, rational.denominator, "1"),
            else => false,
        };
    }

    fn operandSlots(self: *Builder, children: []const ValueId) LowerError![]const u32 {
        const slots = try self.arena.alloc(u32, children.len);
        for (children, slots) |child, *slot| slot.* = self.slotOf(child);
        return slots;
    }

    fn slotOf(self: *const Builder, id: ValueId) u32 {
        std.debug.assert(self.reachable[id.toUsize()]);
        return self.slots[id.toUsize()];
    }

    fn slotsOf(self: *Builder, ids: []const ValueId) LowerError![]const u32 {
        const slots = try self.arena.alloc(u32, ids.len);
        for (ids, slots) |id, *slot| slot.* = self.slotOf(id);
        return slots;
    }

    fn releaseExpired(self: *Builder, node: value.Node, position: usize) LowerError!void {
        var operand: usize = 0;
        while (value.childAt(node, operand)) |child| : (operand += 1) {
            self.releaseIfDead(child, position);
        }
    }

    fn releaseIfDead(self: *Builder, id: ValueId, position: usize) void {
        if (self.last_use[id.toUsize()] != position) return;
        // A node consumed twice by one instruction releases once; marking a
        // slot not live twice is harmless but the live range must not shrink.
        self.pool.items[self.slots[id.toUsize()]].live = false;
    }

    /// Deterministic first-fit reuse.
    ///
    /// The scan is in slot order and takes the first released slot whose type
    /// is identical, so the assignment depends only on the instruction sequence
    /// and never on allocation or iteration order. A different type never
    /// shares storage, which keeps the frame's typed view sound without any
    /// runtime type tag.
    fn acquireSlot(self: *Builder, kind: SlotType, position: usize) LowerError!u32 {
        const written: u32 = @intCast(position);
        for (self.pool.items, 0..) |*slot, index| {
            if (slot.live or !slot.kind.eql(kind)) continue;
            slot.live = true;
            slot.last_use = written;
            return @intCast(index);
        }
        const index = self.pool.items.len;
        try self.pool.append(self.allocator, .{
            .kind = kind,
            .first_write = written,
            .last_use = written,
            .live = true,
        });
        return @intCast(index);
    }

    /// Records that `slot` is still readable at `position`.
    fn extendLiveRange(self: *Builder, slot: u32, position: usize) void {
        const entry = &self.pool.items[slot];
        entry.last_use = @max(entry.last_use, @as(u32, @intCast(position)));
    }

    const Frame = struct {
        temporaries: []const Temporary,
        bytes: usize,
    };

    /// Assigns byte offsets to the allocated slots.
    ///
    /// Slots that shared a pool entry share their bytes by construction, and
    /// their live ranges are disjoint because reuse only took a released slot.
    /// Program validation re-establishes both facts independently.
    fn layoutFrame(self: *Builder) LowerError!Frame {
        const temporaries = try self.arena.alloc(Temporary, self.pool.items.len);
        var offset: usize = 0;
        for (self.pool.items, temporaries) |slot, *descriptor| {
            const alignment = slot.kind.alignment();
            offset = std.mem.alignForward(usize, offset, alignment);
            const bytes = slot.kind.byteSize() catch return error.SizeOverflow;
            descriptor.* = .{
                .kind = slot.kind,
                .alignment = alignment,
                .offset = offset,
                .bytes = bytes,
                .live = .{ .first_write = slot.first_write, .last_use = slot.last_use },
            };
            offset = std.math.add(usize, offset, bytes) catch return error.SizeOverflow;
        }
        return .{
            .temporaries = temporaries,
            .bytes = std.mem.alignForward(usize, offset, @alignOf(Scalar)),
        };
    }

    fn resultTypeOf(self: *const Builder, root: ValueId) program_module.ResultType {
        return switch (self.graph.valueType(root).domain) {
            .real => .real64,
            .complex => .complex64,
        };
    }

    /// The temporary type a node's value occupies.
    ///
    /// It follows the node's validated value type rather than its kind, so an
    /// operation that is polymorphic in the scalar domain, such as `add`, lands
    /// in a slot of the domain its operands actually have.
    fn slotTypeOf(self: *const Builder, id: ValueId) LowerError!SlotType {
        const declared = self.graph.valueType(id);
        return switch (declared.shape) {
            .scalar => switch (declared.domain) {
                .real => .real,
                .complex => .complex,
            },
            .matrix => |matrix| if (declared.domain == .real and matrix.symmetric)
                .{ .real_symmetric_matrix = matrix.dimension }
            else
                error.UnsupportedOperation,
            // A complex vector is a spectral gradient, whose numerical
            // operation is not part of this catalog.
            .vector => error.UnsupportedOperation,
        };
    }

    fn internConstant(self: *Builder, scalar: Scalar) LowerError!u32 {
        for (self.constants.items, 0..) |existing, index| {
            if (existing == scalar) return @intCast(index);
        }
        const index = self.constants.items.len;
        try self.constants.append(self.allocator, scalar);
        return @intCast(index);
    }
};

/// Converts an exact rational to `f64` under the Milestone 2 conversion policy.
///
/// The numerator and denominator each convert through the correctly rounded
/// decimal-to-`f64` path, and the quotient is one further rounded division, so
/// the result is within 1.5 units in the last place of the exact value.
///
/// Conversion fails rather than losing the value when either part overflows to
/// infinity, when a nonzero part underflows to zero, or when the quotient does.
/// A rational whose parts are individually out of range but whose quotient is
/// representable is therefore rejected rather than approximated. Exact
/// big-rational conversion is deferred.
pub fn rationalToScalar(rational: value.Rational) LowerError!Scalar {
    const numerator = std.fmt.parseFloat(Scalar, rational.numerator) catch
        return error.ConstantNotRepresentable;
    const denominator = std.fmt.parseFloat(Scalar, rational.denominator) catch
        return error.ConstantNotRepresentable;

    if (!std.math.isFinite(numerator) or !std.math.isFinite(denominator)) {
        return error.ConstantNotRepresentable;
    }
    if (denominator == 0) return error.ConstantNotRepresentable;
    const numerator_is_zero = std.mem.eql(u8, rational.numerator, "0");
    if (numerator == 0 and !numerator_is_zero) return error.ConstantNotRepresentable;

    const quotient = numerator / denominator;
    if (!std.math.isFinite(quotient)) return error.ConstantNotRepresentable;
    if (quotient == 0 and !numerator_is_zero) return error.ConstantNotRepresentable;
    return quotient;
}

// -- tests -----------------------------------------------------------------

test "exact rationals convert under the declared policy" {
    try std.testing.expectEqual(
        @as(Scalar, 0.5),
        try rationalToScalar(.{ .numerator = "1", .denominator = "2" }),
    );
    try std.testing.expectEqual(
        @as(Scalar, -0.25),
        try rationalToScalar(.{ .numerator = "-1", .denominator = "4" }),
    );
    try std.testing.expectEqual(
        @as(Scalar, 0.0),
        try rationalToScalar(.{ .numerator = "0", .denominator = "1" }),
    );
    // 1/24 is the quartic orbit coefficient and must round to the nearest
    // representable value rather than to something coarser.
    try std.testing.expectEqual(
        @as(Scalar, 1.0 / 24.0),
        try rationalToScalar(.{ .numerator = "1", .denominator = "24" }),
    );
}

test "an unrepresentable constant fails rather than losing the value" {
    const huge = "1" ++ ("0" ** 400);
    try std.testing.expectError(
        error.ConstantNotRepresentable,
        rationalToScalar(.{ .numerator = huge, .denominator = "1" }),
    );
    try std.testing.expectError(
        error.ConstantNotRepresentable,
        rationalToScalar(.{ .numerator = "1", .denominator = huge }),
    );
}

test "lowering shares an interned subexpression as one instruction" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const phi = try builder.background(0, "phi", 1);
    const squared = try builder.power(phi, 2);
    // Both terms reference the same interned square.
    const total = try builder.add(&.{
        try builder.multiply(&.{ try builder.parameter(0, "a", 2), squared }),
        try builder.multiply(&.{ try builder.parameter(1, "b", 2), squared }),
    });
    var graph = try builder.finish();
    defer graph.deinit();

    var program = try lower(std.testing.allocator, .{
        .graph = &graph,
        .capability = .value,
        .value_root = total,
        .gradient_roots = &.{},
        .hessian_roots = &.{},
        .parameter_count = 2,
        .background_count = 1,
        .coordinate_count = 1,
    }, .{});
    defer program.deinit();
    try program.validate(std.testing.allocator, 64);

    var powers: usize = 0;
    for (program.instructions) |instruction| {
        if (instruction == .power_integer) powers += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), powers);
}

test "a product by minus one lowers to the negate opcode" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const a = try builder.parameter(0, "a", 0);
    const b = try builder.parameter(1, "b", 0);
    const difference = try builder.subtract(a, b);
    var graph = try builder.finish();
    defer graph.deinit();

    var program = try lower(std.testing.allocator, .{
        .graph = &graph,
        .capability = .value,
        .value_root = difference,
        .gradient_roots = &.{},
        .hessian_roots = &.{},
        .parameter_count = 2,
        .background_count = 0,
        .coordinate_count = 0,
    }, .{});
    defer program.deinit();
    try program.validate(std.testing.allocator, 64);

    var negations: usize = 0;
    for (program.instructions) |instruction| {
        if (instruction == .negate) negations += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), negations);
}

test "temporary slots are reused once their value is dead" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    // A long chain, where each intermediate dies immediately.
    var current = try builder.parameter(0, "a", 0);
    for (1..12) |index| {
        current = try builder.add(&.{
            current,
            try builder.parameter(@intCast(index), "b", 0),
        });
    }
    var graph = try builder.finish();
    defer graph.deinit();

    var program = try lower(std.testing.allocator, .{
        .graph = &graph,
        .capability = .value,
        .value_root = current,
        .gradient_roots = &.{},
        .hessian_roots = &.{},
        .parameter_count = 12,
        .background_count = 0,
        .coordinate_count = 0,
    }, .{});
    defer program.deinit();
    try program.validate(std.testing.allocator, 64);

    // Reuse means fewer slots than instructions.
    try std.testing.expect(program.temporaries.len < program.instructions.len);
}

test "lowering is deterministic" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const phi = try builder.background(0, "phi", 1);
    const lambda = try builder.parameter(0, "lambda", 0);
    const quartic = try builder.divide(
        try builder.multiply(&.{ lambda, try builder.power(phi, 4) }),
        try builder.integer(24, 0),
    );
    var graph = try builder.finish();
    defer graph.deinit();

    const request = Request{
        .graph = &graph,
        .capability = .value,
        .value_root = quartic,
        .gradient_roots = &.{},
        .hessian_roots = &.{},
        .parameter_count = 1,
        .background_count = 1,
        .coordinate_count = 1,
    };
    var first = try lower(std.testing.allocator, request, .{});
    defer first.deinit();
    var second = try lower(std.testing.allocator, request, .{});
    defer second.deinit();

    try std.testing.expectEqual(first.instructions.len, second.instructions.len);
    try std.testing.expectEqual(first.temporaries.len, second.temporaries.len);
    try std.testing.expectEqualSlices(Scalar, first.constants, second.constants);
    for (first.instructions, second.instructions) |left, right| {
        try std.testing.expectEqual(
            @as(program_module.Opcode, left),
            @as(program_module.Opcode, right),
        );
        try std.testing.expectEqual(left.result(), right.result());
    }
}

test "tripwires exercise every lowering rollback boundary" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const phi = try builder.background(0, "phi", 1);
    const lambda = try builder.parameter(0, "lambda", 0);
    const quartic = try builder.multiply(&.{
        lambda,
        try builder.power(phi, 4),
    });
    var graph = try builder.finish();
    defer graph.deinit();

    const request = Request{
        .graph = &graph,
        .capability = .value,
        .value_root = quartic,
        .gradient_roots = &.{},
        .hessian_roots = &.{},
        .parameter_count = 1,
        .background_count = 1,
        .coordinate_count = 1,
    };

    for (std.meta.tags(lower_tw.FailPoint)) |point| {
        lower_tw.errorAlways(point, error.OutOfMemory);
        defer lower_tw.reset();
        try std.testing.expectError(
            error.OutOfMemory,
            lower(std.testing.allocator, request, .{}),
        );
        try lower_tw.end(.reset);
    }
}
