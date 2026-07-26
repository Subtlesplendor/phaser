//! Lowering from Typed Value IR to an instruction program.
//!
//! Common subexpressions need no discovery pass: the value graph is interned,
//! so a shared subexpression is one node and therefore one instruction. What
//! lowering adds is instruction selection, exact-to-`f64` conversion, execution
//! order, and temporary-slot assignment with live-range reuse.

const std = @import("std");
const value = @import("../value/root.zig");
const program_module = @import("program.zig");

const ValueId = value.ValueId;
const Graph = value.Graph;
const Instruction = program_module.Instruction;
const Program = program_module.Program;
const Scalar = program_module.Scalar;

pub const LowerError = error{
    OutOfMemory,
    /// An exact constant has no faithful `f64` representation under the
    /// conversion policy.
    ConstantNotRepresentable,
    /// The value graph uses a node kind this backend does not implement.
    UnsupportedOperation,
    CapacityExceeded,
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

    try builder.collectRoots(request);
    try builder.markReachable();
    try builder.classifyStages();
    try builder.assignSlots();
    try builder.emit();

    const outputs = program_module.Outputs{
        .value = builder.slotOf(request.value_root),
        .gradient = try builder.slotsOf(request.gradient_roots),
        .hessian = try builder.slotsOf(request.hessian_roots),
    };

    return .{
        .arena = arena,
        .instructions = try builder.arena.dupe(Instruction, builder.instructions.items),
        .constants = try builder.arena.dupe(Scalar, builder.constants.items),
        .outputs = outputs,
        .capability = request.capability,
        .temporary_count = builder.slot_count,
        .parameter_stage_count = builder.parameter_stage_count,
        .parameter_count = request.parameter_count,
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
    free_slots: std.ArrayList(u32) = .empty,
    slot_count: u32 = 0,

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
        self.free_slots.deinit(self.allocator);
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
            switch (self.graph.values[index].node) {
                .add, .multiply => |children| {
                    for (children) |child| self.reachable[child.toUsize()] = true;
                },
                .divide => |binary| {
                    self.reachable[binary.numerator.toUsize()] = true;
                    self.reachable[binary.denominator.toUsize()] = true;
                },
                .power => |power_node| self.reachable[power_node.base.toUsize()] = true,
                else => {},
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
            self.background_dependent[index] = switch (self.graph.values[index].node) {
                .background => true,
                .add, .multiply => |children| blk: {
                    for (children) |child| {
                        if (self.background_dependent[child.toUsize()]) break :blk true;
                    }
                    break :blk false;
                },
                .divide => |binary| self.background_dependent[binary.numerator.toUsize()] or
                    self.background_dependent[binary.denominator.toUsize()],
                .power => |power_node| self.background_dependent[power_node.base.toUsize()],
                else => false,
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
                switch (self.graph.values[index].node) {
                    .add, .multiply => |children| {
                        for (children) |child| self.noteUse(child, position, stage);
                    },
                    .divide => |binary| {
                        self.noteUse(binary.numerator, position, stage);
                        self.noteUse(binary.denominator, position, stage);
                    },
                    .power => |power_node| {
                        self.noteUse(power_node.base, position, stage);
                    },
                    else => {},
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
        var position: usize = 0;
        for ([_]u1{ 0, 1 }) |stage| {
            for (self.reachable, 0..) |included, index| {
                if (!included or self.stageOf(index) != stage) continue;
                if (self.instructions.items.len >= self.options.max_instructions) {
                    return error.CapacityExceeded;
                }
                const id = ValueId.fromUsize(index) catch return error.CapacityExceeded;
                const node = self.graph.values[index].node;

                // Operands are read before the result is written, and the
                // interpreter computes into a local before storing, so a result
                // may safely reuse a slot that dies at this instruction.
                try self.releaseExpired(node, position);
                const result = try self.acquireSlot();
                self.slots[index] = result;

                try self.instructions.append(
                    self.allocator,
                    try self.select(node, result, id),
                );
                position += 1;
            }
        }
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
        switch (node) {
            .add, .multiply => |children| {
                for (children) |child| try self.releaseIfDead(child, position);
            },
            .divide => |binary| {
                try self.releaseIfDead(binary.numerator, position);
                try self.releaseIfDead(binary.denominator, position);
            },
            .power => |power_node| try self.releaseIfDead(power_node.base, position),
            else => {},
        }
    }

    fn releaseIfDead(self: *Builder, id: ValueId, position: usize) LowerError!void {
        if (self.last_use[id.toUsize()] != position) return;
        const slot = self.slots[id.toUsize()];
        // A node consumed twice by one instruction would otherwise be freed
        // twice.
        for (self.free_slots.items) |existing| {
            if (existing == slot) return;
        }
        try self.free_slots.append(self.allocator, slot);
    }

    fn acquireSlot(self: *Builder) LowerError!u32 {
        if (self.free_slots.pop()) |slot| return slot;
        const slot = self.slot_count;
        self.slot_count += 1;
        return slot;
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
    try std.testing.expect(program.temporary_count < program.instructions.len);
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
    try std.testing.expectEqual(first.temporary_count, second.temporary_count);
    try std.testing.expectEqualSlices(Scalar, first.constants, second.constants);
    for (first.instructions, second.instructions) |left, right| {
        try std.testing.expectEqual(
            @as(program_module.Opcode, left),
            @as(program_module.Opcode, right),
        );
        try std.testing.expectEqual(left.result(), right.result());
    }
}
