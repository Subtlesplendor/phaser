//! Interned Typed Value IR.
//!
//! One graph holds every value of one calculation artifact in a shared arena.
//! Nodes are interned by structural content and mass dimension, so equal
//! subexpressions share one `ValueId` and structural equality is an identifier
//! comparison.
//!
//! Construction is canonical and deterministic. The exact identities applied
//! are:
//!
//! - commutative operands are flattened and ordered by identifier;
//! - exact rational constants are folded;
//! - a sum is collected into distinct terms with exact rational coefficients,
//!   so opposite terms cancel exactly;
//! - division by a nonzero exact rational becomes multiplication by its
//!   reciprocal; and
//! - the identities involving exact zero and one are applied.
//!
//! These are the stronger canonicalization that a derived IR may apply under
//! internal-representations section 5.5. They are exact structural rules;
//! interning still does not discover general mathematical equivalence, and in
//! particular no common factor is cancelled between a numerator and a
//! non-constant denominator.
//!
//! The boundary between this derived arena and the Milestone 1
//! source-expression representation is recorded in decision 0002.

const std = @import("std");
const foundation = @import("../foundation/root.zig");
const expression = @import("../expression/root.zig");
const limits_module = @import("limits.zig");

pub const exact = expression.exact;
pub const Rational = exact.Rational;
const MutableRational = exact.MutableRational;

pub const ValueId = foundation.TypedId("graph_value");

pub const BuildError = error{
    OutOfMemory,
    CapacityExceeded,
    DimensionMismatch,
    DimensionOverflow,
    DivisionByZero,
    ExponentTooLarge,
};

pub const Parameter = struct {
    id: u32,
    name: []const u8,
};

pub const Background = struct {
    index: u32,
    name: []const u8,
};

pub const Divide = struct {
    numerator: ValueId,
    denominator: ValueId,
};

pub const Power = struct {
    base: ValueId,
    exponent: u32,
};

pub const Node = union(enum) {
    rational: Rational,
    pi,
    sqrt_rational: Rational,
    parameter: Parameter,
    background: Background,
    add: []const ValueId,
    multiply: []const ValueId,
    divide: Divide,
    power: Power,
};

pub const Value = struct {
    node: Node,
    mass_dimension: i32,
};

/// Immutable published graph. Owns its arena and every string and slice its
/// nodes reference.
pub const Graph = struct {
    arena: *std.heap.ArenaAllocator,
    values: []const Value,

    pub fn deinit(self: *Graph) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn value(self: *const Graph, id: ValueId) Value {
        std.debug.assert(id.toUsize() < self.values.len);
        return self.values[id.toUsize()];
    }

    pub fn massDimension(self: *const Graph, id: ValueId) i32 {
        return self.value(id).mass_dimension;
    }

    /// Every operand refers to a strictly earlier node, so the value array is a
    /// valid topological order and the graph is acyclic by construction.
    pub fn audit(self: *const Graph) bool {
        for (self.values, 0..) |item, index| {
            const ok = switch (item.node) {
                .add, .multiply => |children| blk: {
                    if (children.len < 2) break :blk false;
                    var previous: ?ValueId = null;
                    for (children) |child| {
                        if (child.toUsize() >= index) break :blk false;
                        if (previous) |earlier| {
                            if (child.toU32() < earlier.toU32()) break :blk false;
                        }
                        previous = child;
                    }
                    break :blk true;
                },
                .divide => |binary| binary.numerator.toUsize() < index and
                    binary.denominator.toUsize() < index,
                .power => |power_node| power_node.base.toUsize() < index and
                    power_node.exponent >= 2,
                else => true,
            };
            if (!ok) return false;
        }
        return true;
    }

    /// Deterministic linear encoding in dependency order. Children are named by
    /// their position, so the output never expands shared subgraphs and its
    /// length is proportional to the node count.
    pub fn writeCanonical(
        self: *const Graph,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("graph-canonical/1\n");
        for (self.values, 0..) |item, index| {
            try writer.print("{d} ", .{index});
            switch (item.node) {
                .rational => |rational| {
                    try writer.writeAll("rational ");
                    try writeRational(rational, writer);
                },
                .pi => try writer.writeAll("pi"),
                .sqrt_rational => |rational| {
                    try writer.writeAll("sqrt ");
                    try writeRational(rational, writer);
                },
                .parameter => |parameter| try writer.print(
                    "parameter {d} {s}",
                    .{ parameter.id, parameter.name },
                ),
                .background => |background| try writer.print(
                    "background {d} {s}",
                    .{ background.index, background.name },
                ),
                .add => |children| try writeChildren("add", children, writer),
                .multiply => |children| try writeChildren("multiply", children, writer),
                .divide => |binary| try writer.print(
                    "divide {d} {d}",
                    .{ binary.numerator.toUsize(), binary.denominator.toUsize() },
                ),
                .power => |power_node| try writer.print(
                    "power {d} {d}",
                    .{ power_node.base.toUsize(), power_node.exponent },
                ),
            }
            try writer.print(" dimension={d}\n", .{item.mass_dimension});
        }
    }
};

fn writeChildren(
    label: []const u8,
    children: []const ValueId,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.writeAll(label);
    for (children) |child| try writer.print(" {d}", .{child.toUsize()});
}

fn writeRational(rational: Rational, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(rational.numerator);
    if (!std.mem.eql(u8, rational.denominator, "1")) {
        try writer.writeByte('/');
        try writer.writeAll(rational.denominator);
    }
}

/// One addend decomposed into an exact rational coefficient and the term it
/// multiplies. A null term denotes a pure constant.
const Split = struct {
    coefficient: MutableRational,
    term: ?ValueId,

    fn deinit(self: *Split) void {
        self.coefficient.deinit();
        self.* = undefined;
    }
};

/// Mutable construction front end. Not a valid artifact until `finish`.
///
/// `finish` consumes the builder. Calling any method afterwards, including
/// `deinit`, is a programmer error.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    values: std.ArrayList(Value) = .empty,
    intern: std.StringHashMapUnmanaged(ValueId) = .empty,
    key: std.ArrayList(u8) = .empty,
    limits: limits_module.ValueLimits,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: limits_module.ValueLimits,
    ) error{OutOfMemory}!Builder {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        return .{
            .allocator = allocator,
            .arena = arena,
            .limits = limits,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.releaseScratch();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    fn releaseScratch(self: *Builder) void {
        self.values.deinit(self.allocator);
        self.intern.deinit(self.allocator);
        self.key.deinit(self.allocator);
    }

    /// Publishes the immutable graph and consumes the builder.
    pub fn finish(self: *Builder) error{OutOfMemory}!Graph {
        const values = try self.arena.allocator().dupe(Value, self.values.items);
        const arena = self.arena;
        self.releaseScratch();
        self.* = undefined;
        return .{ .arena = arena, .values = values };
    }

    pub fn nodeCount(self: *const Builder) usize {
        return self.values.items.len;
    }

    pub fn value(self: *const Builder, id: ValueId) Value {
        std.debug.assert(id.toUsize() < self.values.items.len);
        return self.values.items[id.toUsize()];
    }

    pub fn massDimension(self: *const Builder, id: ValueId) i32 {
        return self.value(id).mass_dimension;
    }

    pub fn isZero(self: *const Builder, id: ValueId) bool {
        return switch (self.value(id).node) {
            .rational => |rational| rational.isZero(),
            else => false,
        };
    }

    fn isOne(self: *const Builder, id: ValueId) bool {
        return switch (self.value(id).node) {
            .rational => |rational| std.mem.eql(u8, rational.numerator, "1") and
                std.mem.eql(u8, rational.denominator, "1"),
            else => false,
        };
    }

    fn rationalOf(self: *const Builder, id: ValueId) ?Rational {
        return switch (self.value(id).node) {
            .rational => |rational| rational,
            else => null,
        };
    }

    // -- leaves ------------------------------------------------------------

    pub fn integer(self: *Builder, literal: i64, dimension: i32) BuildError!ValueId {
        var buffer: [24]u8 = undefined;
        const digits = std.fmt.bufPrint(&buffer, "{d}", .{literal}) catch unreachable;
        var mutable = MutableRational.initInteger(self.allocator, digits) catch
            return error.OutOfMemory;
        defer mutable.deinit();
        return self.constant(&mutable, dimension);
    }

    pub fn zero(self: *Builder, dimension: i32) BuildError!ValueId {
        return self.integer(0, dimension);
    }

    pub fn one(self: *Builder) BuildError!ValueId {
        return self.integer(1, 0);
    }

    /// Interns a reduced rational. The caller retains ownership of `mutable`.
    pub fn constant(
        self: *Builder,
        mutable: *const MutableRational,
        dimension: i32,
    ) BuildError!ValueId {
        if (mutable.bitCount() > self.limits.exact_integer_bits) {
            return error.CapacityExceeded;
        }
        const published = mutable.publish(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(published.numerator);
        defer self.allocator.free(published.denominator);
        return self.internRational(.rational, published, dimension);
    }

    pub fn pi(self: *Builder) BuildError!ValueId {
        try self.beginKey();
        try self.appendKey("pi");
        return self.internCurrent(.pi, 0);
    }

    pub fn sqrtRational(
        self: *Builder,
        mutable: *const MutableRational,
        dimension: i32,
    ) BuildError!ValueId {
        if (mutable.bitCount() > self.limits.exact_integer_bits) {
            return error.CapacityExceeded;
        }
        const published = mutable.publish(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(published.numerator);
        defer self.allocator.free(published.denominator);
        return self.internRational(.sqrt_rational, published, dimension);
    }

    pub fn parameter(
        self: *Builder,
        id: u32,
        name: []const u8,
        dimension: i32,
    ) BuildError!ValueId {
        try self.beginKey();
        try self.appendKey("parameter ");
        try self.appendKeyInteger(id);
        try self.appendDimension(dimension);
        if (self.intern.get(self.key.items)) |existing| return existing;
        const owned = self.arena.allocator().dupe(u8, name) catch return error.OutOfMemory;
        return self.internPrepared(
            .{ .parameter = .{ .id = id, .name = owned } },
            dimension,
        );
    }

    pub fn background(
        self: *Builder,
        index: u32,
        name: []const u8,
        dimension: i32,
    ) BuildError!ValueId {
        try self.beginKey();
        try self.appendKey("background ");
        try self.appendKeyInteger(index);
        try self.appendDimension(dimension);
        if (self.intern.get(self.key.items)) |existing| return existing;
        const owned = self.arena.allocator().dupe(u8, name) catch return error.OutOfMemory;
        return self.internPrepared(
            .{ .background = .{ .index = index, .name = owned } },
            dimension,
        );
    }

    // -- operations --------------------------------------------------------

    pub fn negate(self: *Builder, operand: ValueId) BuildError!ValueId {
        var minus_one = MutableRational.initInteger(self.allocator, "-1") catch
            return error.OutOfMemory;
        defer minus_one.deinit();
        const factor = try self.constant(&minus_one, 0);
        return self.multiply(&.{ factor, operand });
    }

    pub fn subtract(self: *Builder, left: ValueId, right: ValueId) BuildError!ValueId {
        return self.add(&.{ left, try self.negate(right) });
    }

    /// Canonical sum. Nested sums are flattened, addends are collected into
    /// distinct terms carrying exact rational coefficients so that opposite
    /// terms cancel, and the survivors are ordered by identifier.
    pub fn add(self: *Builder, addends: []const ValueId) BuildError!ValueId {
        std.debug.assert(addends.len > 0);
        const fallback_dimension = self.massDimension(addends[0]);

        var entries = std.ArrayList(Split).empty;
        defer {
            for (entries.items) |*entry| entry.deinit();
            entries.deinit(self.allocator);
        }

        var total = MutableRational.initInteger(self.allocator, "0") catch
            return error.OutOfMemory;
        defer total.deinit();

        var dimension: ?i32 = null;

        for (addends) |addend| {
            // One level of flattening suffices: an operand is already canonical,
            // so its own addends are not themselves sums.
            const group: []const ValueId = switch (self.value(addend).node) {
                .add => |children| children,
                else => &.{addend},
            };
            for (group) |operand| {
                if (self.isZero(operand)) continue;
                const operand_dimension = self.massDimension(operand);
                if (dimension) |expected| {
                    if (expected != operand_dimension) return error.DimensionMismatch;
                } else dimension = operand_dimension;

                var split = try self.splitCoefficient(operand);
                // No errdefer here: `accumulate` either consumes the
                // coefficient into `entries`, which the block-level defer then
                // owns, or leaves it for the explicit release below. An
                // errdefer would double free the consumed case.
                if (split.term) |term| {
                    if (entries.items.len >= self.limits.value_operands) {
                        split.deinit();
                        return error.CapacityExceeded;
                    }
                    if (try self.accumulate(&entries, term, &split.coefficient)) {
                        split.deinit();
                    }
                } else {
                    const combined = MutableRational.add(
                        self.allocator,
                        &total,
                        &split.coefficient,
                    ) catch {
                        split.deinit();
                        return error.OutOfMemory;
                    };
                    total.deinit();
                    total = combined;
                    split.deinit();
                }
            }
        }

        const result_dimension = dimension orelse fallback_dimension;

        var operands = std.ArrayList(ValueId).empty;
        defer operands.deinit(self.allocator);

        for (entries.items) |*entry| {
            if (entry.coefficient.isZero()) continue;
            const term = entry.term.?;
            const rebuilt = if (isMutableOne(&entry.coefficient))
                term
            else
                try self.multiply(&.{
                    try self.constant(&entry.coefficient, 0),
                    term,
                });
            operands.append(self.allocator, rebuilt) catch return error.OutOfMemory;
        }
        if (!total.isZero()) {
            operands.append(
                self.allocator,
                try self.constant(&total, result_dimension),
            ) catch return error.OutOfMemory;
        }

        if (operands.items.len == 0) return self.zero(result_dimension);
        if (operands.items.len == 1) return operands.items[0];

        std.mem.sort(ValueId, operands.items, {}, lessThanId);
        return self.internSequence(.add, operands.items, result_dimension);
    }

    /// Adds `coefficient` into an existing entry for `term`. Returns true when
    /// an entry was found, in which case the caller still owns `coefficient`.
    fn accumulate(
        self: *Builder,
        entries: *std.ArrayList(Split),
        term: ValueId,
        coefficient: *MutableRational,
    ) BuildError!bool {
        for (entries.items) |*entry| {
            if (entry.term.? != term) continue;
            const combined = MutableRational.add(
                self.allocator,
                &entry.coefficient,
                coefficient,
            ) catch return error.OutOfMemory;
            entry.coefficient.deinit();
            entry.coefficient = combined;
            return true;
        }
        entries.append(self.allocator, .{
            .coefficient = coefficient.*,
            .term = term,
        }) catch return error.OutOfMemory;
        return false;
    }

    /// Decomposes one addend into an exact rational coefficient and a term.
    fn splitCoefficient(self: *Builder, operand: ValueId) BuildError!Split {
        switch (self.value(operand).node) {
            .rational => {
                return .{ .coefficient = try self.toMutable(operand), .term = null };
            },
            .multiply => |children| {
                var factor: ?ValueId = null;
                for (children) |child| {
                    if (self.rationalOf(child) != null) {
                        factor = child;
                        break;
                    }
                }
                const rational_factor = factor orelse
                    return .{ .coefficient = try self.oneRational(), .term = operand };

                var remaining = std.ArrayList(ValueId).empty;
                defer remaining.deinit(self.allocator);
                for (children) |child| {
                    if (child == rational_factor) continue;
                    remaining.append(self.allocator, child) catch
                        return error.OutOfMemory;
                }
                var coefficient = try self.toMutable(rational_factor);
                errdefer coefficient.deinit();
                if (remaining.items.len == 0) {
                    return .{ .coefficient = coefficient, .term = null };
                }
                return .{
                    .coefficient = coefficient,
                    .term = try self.multiply(remaining.items),
                };
            },
            else => return .{ .coefficient = try self.oneRational(), .term = operand },
        }
    }

    fn oneRational(self: *Builder) BuildError!MutableRational {
        return MutableRational.initOne(self.allocator) catch error.OutOfMemory;
    }

    /// Canonical product. Nested products are flattened, exact rational factors
    /// are folded into one leading constant, an exact zero collapses the
    /// product, and the survivors are ordered by identifier.
    pub fn multiply(self: *Builder, factors: []const ValueId) BuildError!ValueId {
        std.debug.assert(factors.len > 0);

        var folded = MutableRational.initOne(self.allocator) catch
            return error.OutOfMemory;
        defer folded.deinit();

        var operands = std.ArrayList(ValueId).empty;
        defer operands.deinit(self.allocator);

        var dimension: i32 = 0;
        var saw_exact_zero = false;

        for (factors) |factor| {
            const group: []const ValueId = switch (self.value(factor).node) {
                .multiply => |children| children,
                else => &.{factor},
            };
            for (group) |operand| {
                dimension = std.math.add(
                    i32,
                    dimension,
                    self.massDimension(operand),
                ) catch return error.DimensionOverflow;

                if (self.isZero(operand)) {
                    saw_exact_zero = true;
                    continue;
                }
                if (self.rationalOf(operand) != null) {
                    var mutable = try self.toMutable(operand);
                    defer mutable.deinit();
                    const combined = MutableRational.multiply(
                        self.allocator,
                        &folded,
                        &mutable,
                    ) catch return error.OutOfMemory;
                    folded.deinit();
                    folded = combined;
                    continue;
                }
                if (operands.items.len >= self.limits.value_operands) {
                    return error.CapacityExceeded;
                }
                operands.append(self.allocator, operand) catch return error.OutOfMemory;
            }
        }

        if (saw_exact_zero) return self.zero(dimension);
        if (operands.items.len == 0) return self.constant(&folded, dimension);
        if (!isMutableOne(&folded)) {
            operands.append(
                self.allocator,
                try self.constant(&folded, 0),
            ) catch return error.OutOfMemory;
        }
        if (operands.items.len == 1) return operands.items[0];

        std.mem.sort(ValueId, operands.items, {}, lessThanId);
        return self.internSequence(.multiply, operands.items, dimension);
    }

    /// Division. A nonzero exact rational divisor becomes multiplication by its
    /// reciprocal, so constant denominators join the product coefficient rather
    /// than surviving as a division node.
    pub fn divide(
        self: *Builder,
        numerator: ValueId,
        denominator: ValueId,
    ) BuildError!ValueId {
        if (self.isZero(denominator)) return error.DivisionByZero;
        const dimension = std.math.sub(
            i32,
            self.massDimension(numerator),
            self.massDimension(denominator),
        ) catch return error.DimensionOverflow;

        if (self.rationalOf(denominator) != null) {
            var divisor = try self.toMutable(denominator);
            defer divisor.deinit();
            var unit = try self.oneRational();
            defer unit.deinit();
            var reciprocal = MutableRational.divide(self.allocator, &unit, &divisor) catch
                return error.OutOfMemory;
            defer reciprocal.deinit();
            const negated_dimension = std.math.sub(
                i32,
                0,
                self.massDimension(denominator),
            ) catch return error.DimensionOverflow;
            return self.multiply(&.{
                numerator,
                try self.constant(&reciprocal, negated_dimension),
            });
        }
        if (self.isOne(denominator)) return numerator;

        try self.beginKey();
        try self.appendKey("divide ");
        try self.appendKeyInteger(numerator.toU32());
        try self.appendKey(" ");
        try self.appendKeyInteger(denominator.toU32());
        try self.appendDimension(dimension);
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(
            .{ .divide = .{ .numerator = numerator, .denominator = denominator } },
            dimension,
        );
    }

    pub fn power(self: *Builder, base: ValueId, exponent: u32) BuildError!ValueId {
        if (exponent > self.limits.exponent_magnitude) return error.ExponentTooLarge;
        if (exponent == 0) return self.one();
        if (exponent == 1) return base;

        const dimension = std.math.mul(
            i32,
            self.massDimension(base),
            @as(i32, @intCast(exponent)),
        ) catch return error.DimensionOverflow;

        if (self.rationalOf(base) != null) {
            var mutable = try self.toMutable(base);
            defer mutable.deinit();
            var raised = MutableRational.power(self.allocator, &mutable, exponent) catch
                return error.OutOfMemory;
            defer raised.deinit();
            return self.constant(&raised, dimension);
        }

        try self.beginKey();
        try self.appendKey("power ");
        try self.appendKeyInteger(base.toU32());
        try self.appendKey(" ");
        try self.appendKeyInteger(exponent);
        try self.appendDimension(dimension);
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(
            .{ .power = .{ .base = base, .exponent = exponent } },
            dimension,
        );
    }

    // -- exact arithmetic helpers ------------------------------------------

    fn toMutable(self: *Builder, id: ValueId) BuildError!MutableRational {
        const rational = self.rationalOf(id).?;
        var numerator = try self.bigFromDigits(rational.numerator);
        errdefer numerator.deinit();
        var denominator = try self.bigFromDigits(rational.denominator);
        errdefer denominator.deinit();
        return .{ .numerator = numerator, .denominator = denominator };
    }

    fn bigFromDigits(
        self: *Builder,
        digits: []const u8,
    ) BuildError!std.math.big.int.Managed {
        var magnitude = std.math.big.int.Managed.init(self.allocator) catch
            return error.OutOfMemory;
        errdefer magnitude.deinit();
        magnitude.setString(10, digits) catch return error.OutOfMemory;
        return magnitude;
    }

    // -- interning ---------------------------------------------------------

    fn beginKey(self: *Builder) BuildError!void {
        self.key.clearRetainingCapacity();
    }

    fn appendKey(self: *Builder, text: []const u8) BuildError!void {
        self.key.appendSlice(self.allocator, text) catch return error.OutOfMemory;
    }

    fn appendKeyInteger(self: *Builder, literal: u32) BuildError!void {
        var buffer: [12]u8 = undefined;
        const digits = std.fmt.bufPrint(&buffer, "{d}", .{literal}) catch unreachable;
        try self.appendKey(digits);
    }

    /// Mass dimension participates in identity so that an exact zero can carry
    /// the dimension of the term it replaces.
    fn appendDimension(self: *Builder, dimension: i32) BuildError!void {
        try self.appendKey(" @");
        try self.appendKeyInteger(@bitCast(dimension));
    }

    fn internSequence(
        self: *Builder,
        comptime tag: std.meta.Tag(Node),
        operands: []const ValueId,
        dimension: i32,
    ) BuildError!ValueId {
        try self.beginKey();
        try self.appendKey(switch (tag) {
            .add => "add",
            .multiply => "multiply",
            else => @compileError("unsupported sequence node"),
        });
        for (operands) |operand| {
            try self.appendKey(" ");
            try self.appendKeyInteger(operand.toU32());
        }
        try self.appendDimension(dimension);
        if (self.intern.get(self.key.items)) |existing| return existing;

        const owned = self.arena.allocator().dupe(ValueId, operands) catch
            return error.OutOfMemory;
        return self.internPrepared(switch (tag) {
            .add => .{ .add = owned },
            .multiply => .{ .multiply = owned },
            else => unreachable,
        }, dimension);
    }

    fn internRational(
        self: *Builder,
        comptime tag: std.meta.Tag(Node),
        published: Rational,
        dimension: i32,
    ) BuildError!ValueId {
        try self.beginKey();
        try self.appendKey(switch (tag) {
            .rational => "rational ",
            .sqrt_rational => "sqrt ",
            else => @compileError("unsupported rational node"),
        });
        try self.appendKey(published.numerator);
        try self.appendKey("/");
        try self.appendKey(published.denominator);
        try self.appendDimension(dimension);
        if (self.intern.get(self.key.items)) |existing| return existing;

        const arena_allocator = self.arena.allocator();
        const owned = Rational{
            .numerator = arena_allocator.dupe(u8, published.numerator) catch
                return error.OutOfMemory,
            .denominator = arena_allocator.dupe(u8, published.denominator) catch
                return error.OutOfMemory,
        };
        return self.internPrepared(switch (tag) {
            .rational => .{ .rational = owned },
            .sqrt_rational => .{ .sqrt_rational = owned },
            else => unreachable,
        }, dimension);
    }

    /// Completes interning for the node whose complete key is already in
    /// `self.key` and which is known to be absent.
    fn internPrepared(self: *Builder, node: Node, dimension: i32) BuildError!ValueId {
        if (self.values.items.len >= self.limits.value_nodes) return error.CapacityExceeded;

        const id = ValueId.fromUsize(self.values.items.len) catch
            return error.CapacityExceeded;
        self.values.append(self.allocator, .{
            .node = node,
            .mass_dimension = dimension,
        }) catch return error.OutOfMemory;

        const owned_key = self.arena.allocator().dupe(u8, self.key.items) catch
            return error.OutOfMemory;
        self.intern.put(self.allocator, owned_key, id) catch return error.OutOfMemory;
        return id;
    }

    fn internCurrent(self: *Builder, node: Node, dimension: i32) BuildError!ValueId {
        try self.appendDimension(dimension);
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(node, dimension);
    }
};

fn lessThanId(_: void, left: ValueId, right: ValueId) bool {
    return left.toU32() < right.toU32();
}

fn isMutableOne(mutable: *const MutableRational) bool {
    return mutable.numerator.toConst().orderAgainstScalar(1) == .eq and
        mutable.denominator.toConst().orderAgainstScalar(1) == .eq;
}

/// Copies a validated source expression into the shared arena. Source
/// expressions depend only on parameters, so no background node is produced.
pub fn importExpression(
    builder: *Builder,
    source: *const expression.Expression,
) BuildError!ValueId {
    var mapping = std.ArrayList(ValueId).empty;
    defer mapping.deinit(builder.allocator);
    mapping.ensureTotalCapacity(builder.allocator, source.values.len) catch
        return error.OutOfMemory;

    for (source.values) |item| {
        const mapped: ValueId = switch (item.node) {
            .rational => |rational| blk: {
                var mutable = try mutableFromRational(builder, rational);
                defer mutable.deinit();
                break :blk try builder.constant(&mutable, item.mass_dimension);
            },
            .sqrt_rational => |rational| blk: {
                var mutable = try mutableFromRational(builder, rational);
                defer mutable.deinit();
                break :blk try builder.sqrtRational(&mutable, item.mass_dimension);
            },
            .pi => try builder.pi(),
            .parameter => |parameter| try builder.parameter(
                parameter.id,
                parameter.name,
                item.mass_dimension,
            ),
            .negate => |child| try builder.negate(mapping.items[child.toUsize()]),
            .add, .multiply => |children| blk: {
                var translated = std.ArrayList(ValueId).empty;
                defer translated.deinit(builder.allocator);
                for (children) |child| {
                    translated.append(
                        builder.allocator,
                        mapping.items[child.toUsize()],
                    ) catch return error.OutOfMemory;
                }
                break :blk switch (item.node) {
                    .add => try builder.add(translated.items),
                    else => try builder.multiply(translated.items),
                };
            },
            .divide => |binary| try builder.divide(
                mapping.items[binary.numerator.toUsize()],
                mapping.items[binary.denominator.toUsize()],
            ),
            .power => |power_node| try builder.power(
                mapping.items[power_node.base.toUsize()],
                power_node.exponent,
            ),
        };
        mapping.appendAssumeCapacity(mapped);
    }
    return mapping.items[source.root.toUsize()];
}

fn mutableFromRational(
    builder: *Builder,
    rational: Rational,
) BuildError!MutableRational {
    var numerator = try builder.bigFromDigits(rational.numerator);
    errdefer numerator.deinit();
    var denominator = try builder.bigFromDigits(rational.denominator);
    errdefer denominator.deinit();
    return .{ .numerator = numerator, .denominator = denominator };
}

// -- tests -----------------------------------------------------------------

fn testBuilder() !Builder {
    return Builder.init(std.testing.allocator, .{});
}

test "equal structure interns to one identifier" {
    var builder = try testBuilder();
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const left = try builder.multiply(&.{ phi, phi });
    const right = try builder.multiply(&.{ phi, phi });
    try std.testing.expectEqual(left, right);

    const squared = try builder.power(phi, 2);
    try std.testing.expect(squared != left);
    try std.testing.expectEqual(@as(i32, 2), builder.massDimension(squared));
}

test "commutative operands are ordered so insertion order does not matter" {
    var builder = try testBuilder();
    defer builder.deinit();

    const a = try builder.parameter(0, "a", 2);
    const b = try builder.parameter(1, "b", 2);
    const c = try builder.parameter(2, "c", 2);

    try std.testing.expectEqual(
        try builder.add(&.{ a, b, c }),
        try builder.add(&.{ c, a, b }),
    );
    try std.testing.expectEqual(
        try builder.multiply(&.{ a, b, c }),
        try builder.multiply(&.{ c, b, a }),
    );
}

test "nested commutative nodes flatten" {
    var builder = try testBuilder();
    defer builder.deinit();

    const a = try builder.parameter(0, "a", 0);
    const b = try builder.parameter(1, "b", 0);
    const c = try builder.parameter(2, "c", 0);

    const nested = try builder.add(&.{ try builder.add(&.{ a, b }), c });
    const flat = try builder.add(&.{ a, b, c });
    try std.testing.expectEqual(flat, nested);
    try std.testing.expectEqual(@as(usize, 3), builder.value(flat).node.add.len);
}

test "exact rational constants fold" {
    var builder = try testBuilder();
    defer builder.deinit();

    const half = try builder.divide(try builder.integer(1, 0), try builder.integer(2, 0));
    const third = try builder.divide(try builder.integer(1, 0), try builder.integer(3, 0));
    const sum = try builder.add(&.{ half, third });

    const expected = try builder.divide(
        try builder.integer(5, 0),
        try builder.integer(6, 0),
    );
    try std.testing.expectEqual(expected, sum);
}

test "like terms collect and opposite terms cancel exactly" {
    var builder = try testBuilder();
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);

    // phi + phi == 2 phi
    const doubled = try builder.add(&.{ phi, phi });
    const expected = try builder.multiply(&.{ try builder.integer(2, 0), phi });
    try std.testing.expectEqual(expected, doubled);

    // 3 phi - phi == 2 phi
    const tripled = try builder.multiply(&.{ try builder.integer(3, 0), phi });
    try std.testing.expectEqual(expected, try builder.subtract(tripled, phi));

    // phi - phi == exactly zero
    try std.testing.expect(builder.isZero(try builder.subtract(phi, phi)));
}

test "zero and one identities apply exactly" {
    var builder = try testBuilder();
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const zero_scalar = try builder.zero(1);

    try std.testing.expectEqual(phi, try builder.add(&.{ phi, zero_scalar }));
    try std.testing.expectEqual(phi, try builder.multiply(&.{ phi, try builder.one() }));
    try std.testing.expect(builder.isZero(try builder.multiply(&.{ phi, zero_scalar })));
    try std.testing.expectEqual(phi, try builder.power(phi, 1));
    try std.testing.expectEqual(try builder.one(), try builder.power(phi, 0));
}

test "an exact zero carries the dimension of the term it replaces" {
    var builder = try testBuilder();
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const cancelled = try builder.subtract(phi, phi);
    try std.testing.expect(builder.isZero(cancelled));
    try std.testing.expectEqual(@as(i32, 1), builder.massDimension(cancelled));

    const dimensionless = try builder.zero(0);
    try std.testing.expect(cancelled != dimensionless);
}

test "division by an exact constant becomes a folded coefficient" {
    var builder = try testBuilder();
    defer builder.deinit();

    const lambda = try builder.parameter(0, "lambda", 0);
    const phi = try builder.background(0, "phi", 1);
    const quartic = try builder.divide(
        try builder.multiply(&.{ lambda, try builder.power(phi, 4) }),
        try builder.integer(24, 0),
    );

    try std.testing.expectEqual(
        std.meta.Tag(Node).multiply,
        std.meta.activeTag(builder.value(quartic).node),
    );
    try std.testing.expectEqual(@as(i32, 4), builder.massDimension(quartic));
}

test "a non-constant denominator keeps a division node" {
    var builder = try testBuilder();
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    const mass = try builder.parameter(0, "m", 1);
    const ratio = try builder.divide(phi, mass);

    try std.testing.expectEqual(
        std.meta.Tag(Node).divide,
        std.meta.activeTag(builder.value(ratio).node),
    );
    try std.testing.expectEqual(@as(i32, 0), builder.massDimension(ratio));
}

test "mass dimensions combine and mismatches are rejected" {
    var builder = try testBuilder();
    defer builder.deinit();

    const mass_squared = try builder.parameter(0, "m2", 2);
    const phi = try builder.background(0, "phi", 1);

    const term = try builder.multiply(&.{ mass_squared, try builder.power(phi, 2) });
    try std.testing.expectEqual(@as(i32, 4), builder.massDimension(term));

    try std.testing.expectError(
        error.DimensionMismatch,
        builder.add(&.{ mass_squared, phi }),
    );
}

test "division by an exact zero is rejected" {
    var builder = try testBuilder();
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    try std.testing.expectError(
        error.DivisionByZero,
        builder.divide(phi, try builder.zero(0)),
    );
}

test "capacity limits are enforced at their exact boundary" {
    var builder = try Builder.init(std.testing.allocator, .{ .value_nodes = 3 });
    defer builder.deinit();

    _ = try builder.background(0, "a", 1);
    _ = try builder.background(1, "b", 1);
    _ = try builder.background(2, "c", 1);
    try std.testing.expectEqual(@as(usize, 3), builder.nodeCount());
    try std.testing.expectError(
        error.CapacityExceeded,
        builder.background(3, "d", 1),
    );
}

test "oversized exponents are rejected" {
    var builder = try Builder.init(std.testing.allocator, .{ .exponent_magnitude = 4 });
    defer builder.deinit();

    const phi = try builder.background(0, "phi", 1);
    _ = try builder.power(phi, 4);
    try std.testing.expectError(error.ExponentTooLarge, builder.power(phi, 5));
}

test "published graphs audit and encode deterministically" {
    var builder = try testBuilder();
    const lambda = try builder.parameter(0, "lambda", 0);
    const phi = try builder.background(0, "phi", 1);
    const quartic = try builder.divide(
        try builder.multiply(&.{ lambda, try builder.power(phi, 4) }),
        try builder.integer(24, 0),
    );

    // `finish` consumes the builder; it must not also be deinitialized.
    var graph = try builder.finish();
    defer graph.deinit();

    try std.testing.expect(graph.audit());
    try std.testing.expect(quartic.toUsize() < graph.values.len);
    try std.testing.expectEqual(@as(i32, 4), graph.massDimension(quartic));

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try graph.writeCanonical(&first.writer);
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try graph.writeCanonical(&second.writer);

    try std.testing.expectEqualStrings(first.written(), second.written());
    try std.testing.expect(std.mem.startsWith(u8, first.written(), "graph-canonical/1\n"));
}

test "representative allocation failures never publish a partial graph" {
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var builder = Builder.init(failing.allocator(), .{}) catch continue;
        defer builder.deinit();

        const phi = builder.background(0, "phi", 1) catch continue;
        const lambda = builder.parameter(0, "lambda", 0) catch continue;
        const quartic = builder.multiply(&.{
            lambda,
            builder.power(phi, 4) catch continue,
        }) catch continue;
        try std.testing.expectEqual(@as(i32, 4), builder.massDimension(quartic));
    }
}
