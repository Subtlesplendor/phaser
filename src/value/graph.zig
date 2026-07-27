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
    /// An operand's scalar domain or shape is not the one the operation
    /// accepts. Real and complex values never mix implicitly.
    TypeMismatch,
    /// A structured operand count disagrees with its declared dimension.
    InvalidMatrixDimension,
    /// A structured element selects a row or column outside its shape.
    InvalidElementIndex,
    /// A spectral operand contains another spectral operation. Milestone 3
    /// derives one loop order, so a mass matrix built from a loop quantity is
    /// outside its supported structure.
    NestedSpectralOperation,
    /// A third or higher background derivative of a spectral value. Milestone 3
    /// implements the first two only.
    UnsupportedDerivativeOrder,
    /// A spectral derivative was combined with a different canonical
    /// background-coordinate order than the one it was built for.
    CoordinateOrderMismatch,
};

/// Scalar domain of a value. `complex` denotes the `Complex64` pair specified
/// by the kernel instruction set; it is not a general complex number type.
pub const Domain = enum { real, complex };

/// Finite shape of a value.
pub const Shape = union(enum) {
    scalar,
    /// Column vector in canonical background-coordinate order.
    vector: u32,
    /// Square matrix.
    matrix: Matrix,

    pub const Matrix = struct {
        dimension: u32,
        /// True only when construction established symmetry. A backend may
        /// rely on it; it is never assumed because a matrix is expected to be
        /// symmetric physically.
        symmetric: bool,
    };

    pub fn eql(self: Shape, other: Shape) bool {
        return switch (self) {
            .scalar => other == .scalar,
            .vector => |dimension| switch (other) {
                .vector => |right| dimension == right,
                else => false,
            },
            .matrix => |matrix| switch (other) {
                .matrix => |right| matrix.dimension == right.dimension and
                    matrix.symmetric == right.symmetric,
                else => false,
            },
        };
    }
};

/// Statically validated type of a value node.
pub const ValueType = struct {
    domain: Domain = .real,
    shape: Shape = .scalar,

    pub const real_scalar = ValueType{};
    pub const complex_scalar = ValueType{ .domain = .complex };

    pub fn eql(self: ValueType, other: ValueType) bool {
        return self.domain == other.domain and self.shape.eql(other.shape);
    }

    pub fn isScalar(self: ValueType) bool {
        return self.shape == .scalar;
    }
};

/// Formula-version contract a spectral node denotes. It participates in node
/// identity, so a future formula revision cannot silently reuse cached
/// structure.
pub const FormulaVersion = enum {
    scalar_vacuum_msbar_1,

    pub fn text(self: FormulaVersion) []const u8 {
        return switch (self) {
            .scalar_vacuum_msbar_1 => "scalar-vacuum-msbar/1",
        };
    }
};

/// Complex branch convention a spectral node denotes.
pub const BranchPolicy = enum {
    /// Principal logarithm with `Arg(z) in (-pi, pi]`.
    principal_arg,

    pub fn text(self: BranchPolicy) []const u8 {
        return switch (self) {
            .principal_arg => "arg(-pi,pi]",
        };
    }
};

pub const Parameter = struct {
    id: u32,
    name: []const u8,
};

pub const Background = struct {
    index: u32,
    name: []const u8,
};

/// A renormalization-scale input channel. It is a distinct input category from
/// a model parameter even though both carry one real value.
pub const Scale = struct {
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

/// A real symmetric matrix given by its authoritative upper triangle in lexical
/// index order. The lower triangle denotes the same operands rather than
/// separately rounded values.
pub const SymmetricMatrix = struct {
    dimension: u32,
    entries: []const ValueId,
};

/// The invariant scalar one-loop spectral value of a mass-squared matrix.
pub const SpectralValue = struct {
    matrix: ValueId,
    scale: ValueId,
    formula: FormulaVersion,
    branch: BranchPolicy,
};

/// An invariant background derivative of a spectral value.
///
/// The derivative matrices are ordinary real-symmetric matrix nodes, so the
/// operation never differentiates an eigenvalue label or an eigenvector phase.
pub const SpectralDerivative = struct {
    value: ValueId,
    /// Canonical background-coordinate order. Part of node identity.
    coordinates: []const u32,
    /// One first-derivative matrix per coordinate, in that order.
    first: []const ValueId,
    /// Upper triangle of second-derivative matrices over coordinate pairs, in
    /// lexical order. Empty for a gradient.
    second: []const ValueId,
};

/// Selection of one entry of a structured value. A vector uses `row` and
/// requires `column` to be zero.
pub const Element = struct {
    source: ValueId,
    row: u32,
    column: u32,
};

/// The node kinds of the derived Typed Value IR.
///
/// A variant's tag participates in the canonical order key, which decides the
/// operand order of commutative nodes and therefore the accumulation order a
/// lowered kernel uses. New variants are appended rather than inserted, so
/// adding a node kind cannot silently reorder the terms of existing values.
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
    renormalization_scale: Scale,
    /// The exact inclusion of a real value into `Complex64`, producing
    /// `(x, 0)`. It is the only conversion between the two domains; there is no
    /// projection back.
    promote_real_to_complex: ValueId,
    real_symmetric_matrix: SymmetricMatrix,
    scalar_one_loop_spectral_value: SpectralValue,
    scalar_one_loop_spectral_gradient: SpectralDerivative,
    scalar_one_loop_spectral_hessian: SpectralDerivative,
    element: Element,
};

pub const Value = struct {
    node: Node,
    value_type: ValueType,
    mass_dimension: i32,
    /// Hash of this node's content and its operands' order keys.
    ///
    /// Derived from structure alone, never from arena position, so the same
    /// value built by different call sequences receives the same key. This is
    /// what makes canonical operand order, and therefore rendered output,
    /// independent of how a graph was constructed.
    order_key: u64,
    /// True when this node or any operand is a spectral operation. Cheap to
    /// maintain incrementally and it keeps the spectral nesting rule a local
    /// construction check rather than a reachability scan.
    spectral: bool,
};

/// A renormalization scale is a mass, so it has mass dimension one.
pub const scale_mass_dimension: i32 = 1;

/// Mass dimension of a field-dependent scalar mass-squared matrix entry. The
/// scalar one-loop formula version is defined over such a matrix, so the node
/// checks it rather than accepting any consistently dimensioned matrix.
pub const mass_squared_dimension: i32 = 2;

/// The spectral value sums `x^2 [Log(x / mu^2) - 3/2]` over a mass-squared
/// spectrum, so it carries twice the matrix's mass dimension.
pub const spectral_value_mass_dimension: i32 = 2 * mass_squared_dimension;

/// Number of stored upper-triangular entries of an `n x n` symmetric matrix.
pub fn upperTriangleCount(dimension: u32) usize {
    const n: usize = dimension;
    return n * (n + 1) / 2;
}

/// Position of `(row, column)` in the lexical upper-triangle order
/// `(0,0), (0,1), ..., (0,n-1), (1,1), ..., (n-1,n-1)`.
pub fn upperTriangleIndex(dimension: u32, row: u32, column: u32) usize {
    const n: usize = dimension;
    const first: usize = @min(row, column);
    const second: usize = @max(row, column);
    std.debug.assert(second < n);
    return first * n - first * (first -| 1) / 2 + (second - first);
}

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

    pub fn valueType(self: *const Graph, id: ValueId) ValueType {
        return self.value(id).value_type;
    }

    /// Every operand refers to a strictly earlier node, so the value array is a
    /// valid topological order and the graph is acyclic by construction.
    pub fn audit(self: *const Graph) bool {
        for (self.values, 0..) |item, index| {
            // Acyclicity, checked once for every node kind rather than
            // separately inside each case below.
            var position: usize = 0;
            while (childAt(item.node, position)) |child| : (position += 1) {
                if (child.toUsize() >= index) return false;
            }

            const ok = switch (item.node) {
                .add, .multiply => |children| blk: {
                    if (children.len < 2) break :blk false;
                    var previous: ?u64 = null;
                    for (children) |child| {
                        const key = self.values[child.toUsize()].order_key;
                        if (previous) |earlier| {
                            if (key < earlier) break :blk false;
                        }
                        previous = key;
                    }
                    break :blk true;
                },
                .power => |power_node| power_node.exponent >= 2,
                .promote_real_to_complex => |operand| item.value_type.domain == .complex and
                    self.values[operand.toUsize()].value_type.eql(.real_scalar) and
                    self.values[operand.toUsize()].mass_dimension == item.mass_dimension,
                .real_symmetric_matrix => |matrix| blk: {
                    if (item.value_type.shape != .matrix) break :blk false;
                    if (item.value_type.shape.matrix.dimension != matrix.dimension) {
                        break :blk false;
                    }
                    if (!item.value_type.shape.matrix.symmetric) break :blk false;
                    break :blk matrix.entries.len == upperTriangleCount(matrix.dimension);
                },
                .scalar_one_loop_spectral_value => |spectral| blk: {
                    const matrix = self.values[spectral.matrix.toUsize()];
                    if (matrix.value_type.shape != .matrix) break :blk false;
                    if (self.values[spectral.scale.toUsize()].node !=
                        .renormalization_scale) break :blk false;
                    break :blk item.value_type.eql(.complex_scalar) and !matrix.spectral;
                },
                .scalar_one_loop_spectral_gradient => |derivative| blk: {
                    if (self.values[derivative.value.toUsize()].node !=
                        .scalar_one_loop_spectral_value) break :blk false;
                    if (derivative.first.len != derivative.coordinates.len) break :blk false;
                    if (derivative.second.len != 0) break :blk false;
                    break :blk item.value_type.eql(.{
                        .domain = .complex,
                        .shape = .{ .vector = @intCast(derivative.coordinates.len) },
                    });
                },
                .scalar_one_loop_spectral_hessian => |derivative| blk: {
                    if (self.values[derivative.value.toUsize()].node !=
                        .scalar_one_loop_spectral_value) break :blk false;
                    if (derivative.first.len != derivative.coordinates.len) break :blk false;
                    const count: u32 = @intCast(derivative.coordinates.len);
                    if (derivative.second.len != upperTriangleCount(count)) break :blk false;
                    break :blk item.value_type.eql(.{
                        .domain = .complex,
                        .shape = .{ .matrix = .{ .dimension = count, .symmetric = true } },
                    });
                },
                .element => |selection| blk: {
                    const source = self.values[selection.source.toUsize()];
                    if (source.mass_dimension != item.mass_dimension) break :blk false;
                    if (source.value_type.domain != item.value_type.domain) break :blk false;
                    if (!item.value_type.isScalar()) break :blk false;
                    break :blk switch (source.value_type.shape) {
                        .scalar => false,
                        .vector => |dimension| selection.column == 0 and
                            selection.row < dimension,
                        .matrix => |matrix| selection.row < matrix.dimension and
                            selection.column < matrix.dimension,
                    };
                },
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
            // Arena position is the name here, which is exactly what makes this
            // encoding a graph-level rather than a value-level identity.
            try writeNode(item, null, writer);
        }
    }

    /// Deterministic encoding of the value reachable from `root`, numbered in
    /// structural traversal order.
    ///
    /// Numbering comes from a post-order walk that follows canonical operand
    /// order, and operand order is itself content-derived, so the bytes depend
    /// only on the value's structure. Two structurally equal values in
    /// different arenas therefore encode identically, which makes cross-arena
    /// structural comparison a byte comparison.
    pub fn writeValueCanonical(
        self: *const Graph,
        root: ValueId,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) (std.Io.Writer.Error || error{OutOfMemory})!void {
        std.debug.assert(root.toUsize() < self.values.len);

        const count = root.toUsize() + 1;
        const numbering = try allocator.alloc(?usize, count);
        defer allocator.free(numbering);
        @memset(numbering, null);
        const queued = try allocator.alloc(bool, count);
        defer allocator.free(queued);
        @memset(queued, false);

        var sequence = std.ArrayList(ValueId).empty;
        defer sequence.deinit(allocator);

        const Frame = struct { id: ValueId, next_child: usize };
        var stack = std.ArrayList(Frame).empty;
        defer stack.deinit(allocator);

        // Bounded explicit worklist rather than recursion. Operands always
        // refer to strictly earlier nodes, so the walk terminates.
        try stack.append(allocator, .{ .id = root, .next_child = 0 });
        queued[root.toUsize()] = true;
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const node = self.values[top.id.toUsize()].node;
            if (childAt(node, top.next_child)) |child| {
                top.next_child += 1;
                if (!queued[child.toUsize()]) {
                    queued[child.toUsize()] = true;
                    try stack.append(allocator, .{ .id = child, .next_child = 0 });
                }
                continue;
            }
            const finished = top.id;
            _ = stack.pop();
            numbering[finished.toUsize()] = sequence.items.len;
            try sequence.append(allocator, finished);
        }

        try writer.writeAll("value-canonical/1\n");
        for (sequence.items, 0..) |id, position| {
            try writer.print("{d} ", .{position});
            try writeNode(self.values[id.toUsize()], numbering, writer);
        }
    }
};

/// Operands of `node` in fixed order, or null past the last one.
///
/// Every traversal uses this so that adding a node kind cannot leave one walk
/// silently skipping its operands.
pub fn childAt(node: Node, index: usize) ?ValueId {
    return switch (node) {
        .add, .multiply => |children| at(children, index),
        .divide => |binary| switch (index) {
            0 => binary.numerator,
            1 => binary.denominator,
            else => null,
        },
        .power => |power_node| if (index == 0) power_node.base else null,
        .promote_real_to_complex => |operand| if (index == 0) operand else null,
        .real_symmetric_matrix => |matrix| at(matrix.entries, index),
        .scalar_one_loop_spectral_value => |spectral| switch (index) {
            0 => spectral.matrix,
            1 => spectral.scale,
            else => null,
        },
        .scalar_one_loop_spectral_gradient, .scalar_one_loop_spectral_hessian => |derivative| blk: {
            if (index == 0) break :blk derivative.value;
            const after_value = index - 1;
            if (after_value < derivative.first.len) {
                break :blk derivative.first[after_value];
            }
            break :blk at(derivative.second, after_value - derivative.first.len);
        },
        .element => |selection| if (index == 0) selection.source else null,
        else => null,
    };
}

fn at(children: []const ValueId, index: usize) ?ValueId {
    return if (index < children.len) children[index] else null;
}

/// Encodes one node's content and operand names.
///
/// `numbering` renames operands for the value-level encoding; when it is null
/// operands are named by arena position.
fn writeNode(
    item: Value,
    numbering: ?[]const ?usize,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const name = struct {
        fn of(table: ?[]const ?usize, id: ValueId) usize {
            if (table) |entries| return entries[id.toUsize()].?;
            return id.toUsize();
        }
    }.of;

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
        .parameter => |input| try writer.print(
            "parameter {d} {s}",
            .{ input.id, input.name },
        ),
        .background => |input| try writer.print(
            "background {d} {s}",
            .{ input.index, input.name },
        ),
        .renormalization_scale => |input| try writer.print(
            "renormalization_scale {d} {s}",
            .{ input.index, input.name },
        ),
        .add, .multiply => |children| {
            try writer.writeAll(if (item.node == .add) "add" else "multiply");
            for (children) |child| try writer.print(" {d}", .{name(numbering, child)});
        },
        .divide => |binary| try writer.print("divide {d} {d}", .{
            name(numbering, binary.numerator),
            name(numbering, binary.denominator),
        }),
        .power => |power_node| try writer.print("power {d} {d}", .{
            name(numbering, power_node.base),
            power_node.exponent,
        }),
        .promote_real_to_complex => |operand| try writer.print(
            "promote_real_to_complex {d}",
            .{name(numbering, operand)},
        ),
        .real_symmetric_matrix => |matrix| {
            try writer.print("real_symmetric_matrix {d}", .{matrix.dimension});
            for (matrix.entries) |entry| {
                try writer.print(" {d}", .{name(numbering, entry)});
            }
        },
        .scalar_one_loop_spectral_value => |spectral| try writer.print(
            "scalar_one_loop_spectral_value {d} {d} {s} {s}",
            .{
                name(numbering, spectral.matrix),
                name(numbering, spectral.scale),
                spectral.formula.text(),
                spectral.branch.text(),
            },
        ),
        .scalar_one_loop_spectral_gradient, .scalar_one_loop_spectral_hessian => |derivative| {
            try writer.writeAll(if (item.node == .scalar_one_loop_spectral_gradient)
                "scalar_one_loop_spectral_gradient"
            else
                "scalar_one_loop_spectral_hessian");
            try writer.print(" {d} coordinates", .{name(numbering, derivative.value)});
            for (derivative.coordinates) |coordinate| {
                try writer.print(" {d}", .{coordinate});
            }
            try writer.writeAll(" first");
            for (derivative.first) |matrix| {
                try writer.print(" {d}", .{name(numbering, matrix)});
            }
            try writer.writeAll(" second");
            for (derivative.second) |matrix| {
                try writer.print(" {d}", .{name(numbering, matrix)});
            }
        },
        .element => |selection| try writer.print("element {d} {d} {d}", .{
            name(numbering, selection.source),
            selection.row,
            selection.column,
        }),
    }
    try writer.print(" type={s}", .{@tagName(item.value_type.domain)});
    switch (item.value_type.shape) {
        .scalar => try writer.writeAll(":scalar"),
        .vector => |dimension| try writer.print(":vector({d})", .{dimension}),
        .matrix => |matrix| try writer.print(
            ":matrix({d},symmetric={})",
            .{ matrix.dimension, matrix.symmetric },
        ),
    }
    try writer.print(" dimension={d}\n", .{item.mass_dimension});
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

    pub fn valueType(self: *const Builder, id: ValueId) ValueType {
        return self.value(id).value_type;
    }

    pub fn isZero(self: *const Builder, id: ValueId) bool {
        return switch (self.value(id).node) {
            .rational => |rational| rational.isZero(),
            else => false,
        };
    }

    /// True for the promotion of an exact real zero, which is the only exact
    /// zero the complex domain has.
    pub fn isComplexZero(self: *const Builder, id: ValueId) bool {
        return switch (self.value(id).node) {
            .promote_real_to_complex => |operand| self.isZero(operand),
            else => false,
        };
    }

    /// True when `root` reaches a background-coordinate input.
    ///
    /// Operands refer to strictly earlier nodes, so one descending sweep over
    /// the reachable set answers this without recursion.
    pub fn dependsOnBackground(self: *Builder, root: ValueId) BuildError!bool {
        var index = root.toUsize() + 1;
        const reachable = self.allocator.alloc(bool, index) catch
            return error.OutOfMemory;
        defer self.allocator.free(reachable);
        @memset(reachable, false);
        reachable[root.toUsize()] = true;

        while (index > 0) {
            index -= 1;
            if (!reachable[index]) continue;
            const node = self.values.items[index].node;
            if (node == .background) return true;
            var operand: usize = 0;
            while (childAt(node, operand)) |child| : (operand += 1) {
                reachable[child.toUsize()] = true;
            }
        }
        return false;
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
        return self.internCurrent(.pi, .{ .mass_dimension = 0 });
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
        try self.appendSignature(.{ .mass_dimension = dimension });
        if (self.intern.get(self.key.items)) |existing| return existing;
        const owned = self.arena.allocator().dupe(u8, name) catch return error.OutOfMemory;
        return self.internPrepared(
            .{ .parameter = .{ .id = id, .name = owned } },
            .{ .mass_dimension = dimension },
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
        try self.appendSignature(.{ .mass_dimension = dimension });
        if (self.intern.get(self.key.items)) |existing| return existing;
        const owned = self.arena.allocator().dupe(u8, name) catch return error.OutOfMemory;
        return self.internPrepared(
            .{ .background = .{ .index = index, .name = owned } },
            .{ .mass_dimension = dimension },
        );
    }

    /// A renormalization-scale input channel of mass dimension one.
    ///
    /// It is a distinct input category from a model parameter: both carry one
    /// real value, but a scale is bound separately and a spectral node accepts
    /// only a scale.
    pub fn renormalizationScale(
        self: *Builder,
        index: u32,
        name: []const u8,
    ) BuildError!ValueId {
        const signature = Signature{ .mass_dimension = scale_mass_dimension };
        try self.beginKey();
        try self.appendKey("renormalization_scale ");
        try self.appendKeyInteger(index);
        try self.appendSignature(signature);
        if (self.intern.get(self.key.items)) |existing| return existing;
        const owned = self.arena.allocator().dupe(u8, name) catch return error.OutOfMemory;
        return self.internPrepared(
            .{ .renormalization_scale = .{ .index = index, .name = owned } },
            signature,
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

    /// Canonical sum over one scalar domain.
    ///
    /// Real and complex addends never mix: a real contribution joins a complex
    /// sum only through an explicit `promoteRealToComplex`.
    pub fn add(self: *Builder, addends: []const ValueId) BuildError!ValueId {
        std.debug.assert(addends.len > 0);
        const expected = self.valueType(addends[0]);
        if (!expected.isScalar()) return error.TypeMismatch;
        for (addends[1..]) |addend| {
            if (!self.valueType(addend).eql(expected)) return error.TypeMismatch;
        }
        return switch (expected.domain) {
            .real => self.addReal(addends),
            .complex => self.addComplex(addends),
        };
    }

    /// Canonical complex sum.
    ///
    /// Nested sums are flattened and exact complex zeros are dropped, but no
    /// rational coefficient is collected: the Milestone 3 kernel catalog has no
    /// complex multiplication, so a complex sum must not produce a product.
    fn addComplex(self: *Builder, addends: []const ValueId) BuildError!ValueId {
        var operands = std.ArrayList(ValueId).empty;
        defer operands.deinit(self.allocator);

        var dimension: ?i32 = null;
        for (addends) |addend| {
            const group: []const ValueId = switch (self.value(addend).node) {
                .add => |children| children,
                else => &.{addend},
            };
            for (group) |operand| {
                if (self.isComplexZero(operand)) continue;
                const operand_dimension = self.massDimension(operand);
                if (dimension) |shared| {
                    if (shared != operand_dimension) return error.DimensionMismatch;
                } else dimension = operand_dimension;
                if (operands.items.len >= self.limits.value_operands) {
                    return error.CapacityExceeded;
                }
                operands.append(self.allocator, operand) catch return error.OutOfMemory;
            }
        }

        const result_dimension = dimension orelse self.massDimension(addends[0]);
        if (operands.items.len == 0) {
            return self.promoteRealToComplex(try self.zero(result_dimension));
        }
        if (operands.items.len == 1) return operands.items[0];

        std.mem.sort(ValueId, operands.items, @as(*const Builder, self), lessThanOrder);
        return self.internSequence(.add, operands.items, .{
            .value_type = .complex_scalar,
            .mass_dimension = result_dimension,
        });
    }

    /// Canonical real sum. Nested sums are flattened, addends are collected into
    /// distinct terms carrying exact rational coefficients so that opposite
    /// terms cancel, and the survivors are ordered by identifier.
    fn addReal(self: *Builder, addends: []const ValueId) BuildError!ValueId {
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
                // errdefer would double free the consumed case, so every
                // failure releases it explicitly instead.
                if (split.term) |term| {
                    if (entries.items.len >= self.limits.value_operands) {
                        split.deinit();
                        return error.CapacityExceeded;
                    }
                    // `accumulate` transfers ownership only on success, so a
                    // failure leaves the coefficient for this caller to free.
                    const consumed = self.accumulate(
                        &entries,
                        term,
                        &split.coefficient,
                    ) catch |err| {
                        split.deinit();
                        return err;
                    };
                    if (consumed) split.deinit();
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

        std.mem.sort(ValueId, operands.items, @as(*const Builder, self), lessThanOrder);
        return self.internSequence(.add, operands.items, .{
            .mass_dimension = result_dimension,
        });
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
    ///
    /// Real scalars only: the Milestone 3 kernel catalog has no complex or
    /// matrix multiplication, so accepting one here would build structure no
    /// backend can lower.
    pub fn multiply(self: *Builder, factors: []const ValueId) BuildError!ValueId {
        std.debug.assert(factors.len > 0);
        for (factors) |factor| try self.requireRealScalar(factor);

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

        std.mem.sort(ValueId, operands.items, @as(*const Builder, self), lessThanOrder);
        return self.internSequence(.multiply, operands.items, .{
            .mass_dimension = dimension,
        });
    }

    fn requireRealScalar(self: *const Builder, id: ValueId) BuildError!void {
        if (!self.valueType(id).eql(.real_scalar)) return error.TypeMismatch;
    }

    /// Division. A nonzero exact rational divisor becomes multiplication by its
    /// reciprocal, so constant denominators join the product coefficient rather
    /// than surviving as a division node.
    pub fn divide(
        self: *Builder,
        numerator: ValueId,
        denominator: ValueId,
    ) BuildError!ValueId {
        try self.requireRealScalar(numerator);
        try self.requireRealScalar(denominator);
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
        try self.appendSignature(.{ .mass_dimension = dimension });
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(
            .{ .divide = .{ .numerator = numerator, .denominator = denominator } },
            .{ .mass_dimension = dimension },
        );
    }

    pub fn power(self: *Builder, base: ValueId, exponent: u32) BuildError!ValueId {
        try self.requireRealScalar(base);
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
        try self.appendSignature(.{ .mass_dimension = dimension });
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(
            .{ .power = .{ .base = base, .exponent = exponent } },
            .{ .mass_dimension = dimension },
        );
    }

    // -- structured and spectral operations --------------------------------

    /// The exact inclusion of a real value into `Complex64`, producing
    /// `(x, 0)`.
    ///
    /// This is the only conversion between the domains. There is no projection
    /// back, so no path can quietly take a real part.
    pub fn promoteRealToComplex(self: *Builder, operand: ValueId) BuildError!ValueId {
        try self.requireRealScalar(operand);
        const signature = Signature{
            .value_type = .complex_scalar,
            .mass_dimension = self.massDimension(operand),
        };
        try self.beginKey();
        try self.appendKey("promote_real_to_complex ");
        try self.appendKeyInteger(operand.toU32());
        try self.appendSignature(signature);
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(.{ .promote_real_to_complex = operand }, signature);
    }

    /// A real symmetric matrix from its authoritative upper triangle in lexical
    /// index order.
    ///
    /// `entry_mass_dimension` is explicit rather than read from the first entry
    /// so that a zero-dimensional matrix still carries a dimension and so that
    /// every entry is checked against a stated expectation.
    pub fn realSymmetricMatrix(
        self: *Builder,
        dimension: u32,
        entries: []const ValueId,
        entry_mass_dimension: i32,
    ) BuildError!ValueId {
        if (entries.len != upperTriangleCount(dimension)) {
            return error.InvalidMatrixDimension;
        }
        if (entries.len > self.limits.value_operands) return error.CapacityExceeded;
        for (entries) |entry| {
            try self.requireRealScalar(entry);
            if (self.massDimension(entry) != entry_mass_dimension) {
                return error.DimensionMismatch;
            }
        }

        const signature = Signature{
            .value_type = .{
                .shape = .{ .matrix = .{ .dimension = dimension, .symmetric = true } },
            },
            .mass_dimension = entry_mass_dimension,
        };
        try self.beginKey();
        try self.appendKey("real_symmetric_matrix ");
        try self.appendKeyInteger(dimension);
        try self.appendOperands(entries);
        try self.appendSignature(signature);
        if (self.intern.get(self.key.items)) |existing| return existing;

        const owned = self.arena.allocator().dupe(ValueId, entries) catch
            return error.OutOfMemory;
        return self.internPrepared(
            .{ .real_symmetric_matrix = .{ .dimension = dimension, .entries = owned } },
            signature,
        );
    }

    /// The invariant scalar one-loop spectral value of a mass-squared matrix.
    ///
    /// Construction does not diagonalize the matrix, sort symbolic eigenvalues,
    /// or identify matrices related by a basis transformation. Basis covariance
    /// is a semantic property tested independently, not an interning rule.
    pub fn scalarOneLoopSpectralValue(
        self: *Builder,
        matrix: ValueId,
        scale: ValueId,
    ) BuildError!ValueId {
        const matrix_value = self.value(matrix);
        if (matrix_value.value_type.shape != .matrix) return error.TypeMismatch;
        if (matrix_value.value_type.domain != .real) return error.TypeMismatch;
        if (!matrix_value.value_type.shape.matrix.symmetric) return error.TypeMismatch;
        if (matrix_value.mass_dimension != mass_squared_dimension) {
            return error.DimensionMismatch;
        }
        // Milestone 3 derives one loop order, so a mass matrix that already
        // contains a loop quantity is outside its supported structure.
        if (matrix_value.spectral) return error.NestedSpectralOperation;
        if (self.value(scale).node != .renormalization_scale) return error.TypeMismatch;

        const formula = FormulaVersion.scalar_vacuum_msbar_1;
        const branch = BranchPolicy.principal_arg;
        const signature = Signature{
            .value_type = .complex_scalar,
            .mass_dimension = spectral_value_mass_dimension,
        };
        try self.beginKey();
        try self.appendKey("scalar_one_loop_spectral_value ");
        try self.appendKey(formula.text());
        try self.appendKey(" ");
        try self.appendKey(branch.text());
        try self.appendOperands(&.{ matrix, scale });
        try self.appendSignature(signature);
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(.{ .scalar_one_loop_spectral_value = .{
            .matrix = matrix,
            .scale = scale,
            .formula = formula,
            .branch = branch,
        } }, signature);
    }

    /// The invariant background gradient of a spectral value.
    pub fn scalarOneLoopSpectralGradient(
        self: *Builder,
        spectral_value: ValueId,
        coordinates: []const u32,
        first: []const ValueId,
    ) BuildError!ValueId {
        const shared = try self.checkDerivativeOperands(spectral_value, coordinates, first);
        const count: u32 = @intCast(coordinates.len);
        const signature = Signature{
            .value_type = .{ .domain = .complex, .shape = .{ .vector = count } },
            .mass_dimension = std.math.sub(
                i32,
                spectral_value_mass_dimension,
                shared.coordinate_dimension,
            ) catch return error.DimensionOverflow,
        };
        return self.internDerivative(
            .scalar_one_loop_spectral_gradient,
            "scalar_one_loop_spectral_gradient",
            .{
                .value = spectral_value,
                .coordinates = coordinates,
                .first = first,
                .second = &.{},
            },
            signature,
        );
    }

    /// The invariant background Hessian of a spectral value.
    ///
    /// `second` holds the upper triangle of second-derivative matrices over
    /// coordinate pairs, in the same lexical order a symmetric matrix uses.
    pub fn scalarOneLoopSpectralHessian(
        self: *Builder,
        spectral_value: ValueId,
        coordinates: []const u32,
        first: []const ValueId,
        second: []const ValueId,
    ) BuildError!ValueId {
        const shared = try self.checkDerivativeOperands(spectral_value, coordinates, first);
        const count: u32 = @intCast(coordinates.len);
        if (second.len != upperTriangleCount(count)) return error.InvalidMatrixDimension;

        const twice = std.math.mul(i32, shared.coordinate_dimension, 2) catch
            return error.DimensionOverflow;
        const second_dimension = std.math.sub(i32, mass_squared_dimension, twice) catch
            return error.DimensionOverflow;
        for (second) |matrix| {
            try self.requireSymmetricMatrix(matrix, shared.matrix_dimension, second_dimension);
        }

        const signature = Signature{
            .value_type = .{
                .domain = .complex,
                .shape = .{ .matrix = .{ .dimension = count, .symmetric = true } },
            },
            .mass_dimension = std.math.sub(i32, spectral_value_mass_dimension, twice) catch
                return error.DimensionOverflow,
        };
        return self.internDerivative(
            .scalar_one_loop_spectral_hessian,
            "scalar_one_loop_spectral_hessian",
            .{
                .value = spectral_value,
                .coordinates = coordinates,
                .first = first,
                .second = second,
            },
            signature,
        );
    }

    const DerivativeOperands = struct {
        matrix_dimension: u32,
        coordinate_dimension: i32,
    };

    /// Validates the operands both spectral derivative orders share and
    /// recovers the background-coordinate mass dimension the matrix
    /// derivatives imply.
    fn checkDerivativeOperands(
        self: *Builder,
        spectral_value: ValueId,
        coordinates: []const u32,
        first: []const ValueId,
    ) BuildError!DerivativeOperands {
        const parent = self.value(spectral_value);
        if (parent.node != .scalar_one_loop_spectral_value) return error.TypeMismatch;
        if (first.len != coordinates.len) return error.InvalidMatrixDimension;
        if (coordinates.len > self.limits.value_operands) return error.CapacityExceeded;

        const matrix_dimension = self.value(parent.node.scalar_one_loop_spectral_value.matrix)
            .value_type.shape.matrix.dimension;
        if (first.len == 0) {
            return .{ .matrix_dimension = matrix_dimension, .coordinate_dimension = 0 };
        }

        const first_dimension = self.massDimension(first[0]);
        const coordinate_dimension = std.math.sub(
            i32,
            mass_squared_dimension,
            first_dimension,
        ) catch return error.DimensionOverflow;
        for (first) |matrix| {
            try self.requireSymmetricMatrix(matrix, matrix_dimension, first_dimension);
        }
        return .{
            .matrix_dimension = matrix_dimension,
            .coordinate_dimension = coordinate_dimension,
        };
    }

    fn requireSymmetricMatrix(
        self: *const Builder,
        id: ValueId,
        dimension: u32,
        mass_dimension: i32,
    ) BuildError!void {
        const item = self.value(id);
        if (!item.value_type.eql(.{
            .shape = .{ .matrix = .{ .dimension = dimension, .symmetric = true } },
        })) return error.TypeMismatch;
        if (item.mass_dimension != mass_dimension) return error.DimensionMismatch;
    }

    fn internDerivative(
        self: *Builder,
        comptime tag: std.meta.Tag(Node),
        comptime label: []const u8,
        derivative: SpectralDerivative,
        signature: Signature,
    ) BuildError!ValueId {
        try self.beginKey();
        try self.appendKey(label);
        try self.appendKey(" coordinates");
        for (derivative.coordinates) |coordinate| {
            try self.appendKey(" ");
            try self.appendKeyInteger(coordinate);
        }
        try self.appendKey(" value");
        try self.appendOperands(&.{derivative.value});
        try self.appendKey(" first");
        try self.appendOperands(derivative.first);
        try self.appendKey(" second");
        try self.appendOperands(derivative.second);
        try self.appendSignature(signature);
        if (self.intern.get(self.key.items)) |existing| return existing;

        const arena_allocator = self.arena.allocator();
        const owned = SpectralDerivative{
            .value = derivative.value,
            .coordinates = arena_allocator.dupe(u32, derivative.coordinates) catch
                return error.OutOfMemory,
            .first = arena_allocator.dupe(ValueId, derivative.first) catch
                return error.OutOfMemory,
            .second = arena_allocator.dupe(ValueId, derivative.second) catch
                return error.OutOfMemory,
        };
        return self.internPrepared(switch (tag) {
            .scalar_one_loop_spectral_gradient => .{ .scalar_one_loop_spectral_gradient = owned },
            .scalar_one_loop_spectral_hessian => .{ .scalar_one_loop_spectral_hessian = owned },
            else => @compileError("unsupported spectral derivative node"),
        }, signature);
    }

    /// Selects one entry of a structured value.
    ///
    /// A vector uses `row` and requires `column` to be zero.
    pub fn element(
        self: *Builder,
        source: ValueId,
        row: u32,
        column: u32,
    ) BuildError!ValueId {
        const item = self.value(source);
        // A symmetric matrix denotes one value at both mirrored positions, so
        // the selection is normalized to the upper triangle. That makes the
        // symmetry of a derived Hessian an identifier equality rather than a
        // numerical coincidence.
        var selected_row = row;
        var selected_column = column;
        switch (item.value_type.shape) {
            .scalar => return error.TypeMismatch,
            .vector => |dimension| {
                if (row >= dimension or column != 0) return error.InvalidElementIndex;
            },
            .matrix => |matrix| {
                if (row >= matrix.dimension or column >= matrix.dimension) {
                    return error.InvalidElementIndex;
                }
                if (matrix.symmetric) {
                    selected_row = @min(row, column);
                    selected_column = @max(row, column);
                }
            },
        }

        // A stored triangle entry is the element itself, so selecting from a
        // materialized symmetric matrix never introduces an indirection node.
        switch (item.node) {
            .real_symmetric_matrix => |matrix| return matrix.entries[
                upperTriangleIndex(matrix.dimension, selected_row, selected_column)
            ],
            else => {},
        }

        const signature = Signature{
            .value_type = .{ .domain = item.value_type.domain },
            .mass_dimension = item.mass_dimension,
        };
        try self.beginKey();
        try self.appendKey("element ");
        try self.appendKeyInteger(source.toU32());
        try self.appendKey(" ");
        try self.appendKeyInteger(selected_row);
        try self.appendKey(" ");
        try self.appendKeyInteger(selected_column);
        try self.appendSignature(signature);
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(.{ .element = .{
            .source = source,
            .row = selected_row,
            .column = selected_column,
        } }, signature);
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

    /// Type, shape, and mass dimension participate in identity.
    ///
    /// The mass dimension lets an exact zero carry the dimension of the term it
    /// replaces; the type and shape keep two structurally identical operand
    /// lists in different domains distinct.
    fn appendSignature(self: *Builder, signature: Signature) BuildError!void {
        try self.appendKey(" :");
        try self.appendKey(@tagName(signature.value_type.domain));
        switch (signature.value_type.shape) {
            .scalar => try self.appendKey(":scalar"),
            .vector => |dimension| {
                try self.appendKey(":vector:");
                try self.appendKeyInteger(dimension);
            },
            .matrix => |matrix| {
                try self.appendKey(if (matrix.symmetric) ":sym:" else ":matrix:");
                try self.appendKeyInteger(matrix.dimension);
            },
        }
        try self.appendKey(" @");
        try self.appendKeyInteger(@bitCast(signature.mass_dimension));
    }

    fn appendOperands(self: *Builder, operands: []const ValueId) BuildError!void {
        for (operands) |operand| {
            try self.appendKey(" ");
            try self.appendKeyInteger(operand.toU32());
        }
    }

    fn internSequence(
        self: *Builder,
        comptime tag: std.meta.Tag(Node),
        operands: []const ValueId,
        signature: Signature,
    ) BuildError!ValueId {
        try self.beginKey();
        try self.appendKey(switch (tag) {
            .add => "add",
            .multiply => "multiply",
            else => @compileError("unsupported sequence node"),
        });
        try self.appendOperands(operands);
        try self.appendSignature(signature);
        if (self.intern.get(self.key.items)) |existing| return existing;

        const owned = self.arena.allocator().dupe(ValueId, operands) catch
            return error.OutOfMemory;
        return self.internPrepared(switch (tag) {
            .add => .{ .add = owned },
            .multiply => .{ .multiply = owned },
            else => unreachable,
        }, signature);
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
        try self.appendSignature(.{ .mass_dimension = dimension });
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
        }, .{ .mass_dimension = dimension });
    }

    /// Completes interning for the node whose complete key is already in
    /// `self.key` and which is known to be absent.
    fn internPrepared(
        self: *Builder,
        node: Node,
        signature: Signature,
    ) BuildError!ValueId {
        if (self.values.items.len >= self.limits.value_nodes) return error.CapacityExceeded;

        const id = ValueId.fromUsize(self.values.items.len) catch
            return error.CapacityExceeded;
        self.values.append(self.allocator, .{
            .node = node,
            .value_type = signature.value_type,
            .mass_dimension = signature.mass_dimension,
            .order_key = self.orderKey(node, signature),
            .spectral = self.spectralOf(node),
        }) catch return error.OutOfMemory;

        const owned_key = self.arena.allocator().dupe(u8, self.key.items) catch
            return error.OutOfMemory;
        self.intern.put(self.allocator, owned_key, id) catch return error.OutOfMemory;
        return id;
    }

    /// True when the node is a spectral operation or reaches one. Operands are
    /// already interned, so this is one pass over the immediate children.
    fn spectralOf(self: *const Builder, node: Node) bool {
        switch (node) {
            .scalar_one_loop_spectral_value,
            .scalar_one_loop_spectral_gradient,
            .scalar_one_loop_spectral_hessian,
            => return true,
            else => {},
        }
        var position: usize = 0;
        while (childAt(node, position)) |child| : (position += 1) {
            if (self.value(child).spectral) return true;
        }
        return false;
    }

    /// Content hash used to order commutative operands.
    ///
    /// Operands contribute their own order keys rather than their identifiers,
    /// so the result depends on structure alone. Children are already interned
    /// when this runs, so their keys are available.
    ///
    /// Type and shape are deliberately absent. They belong to node identity,
    /// which is the intern key, but two nodes of one kind with the same
    /// operands and mass dimension cannot differ in type, so adding them here
    /// would only perturb the canonical operand order of existing values.
    fn orderKey(self: *const Builder, node: Node, signature: Signature) u64 {
        var hasher = OrderHasher{};
        hasher.update(&.{@intFromEnum(std.meta.activeTag(node))});
        hasher.update(std.mem.asBytes(&signature.mass_dimension));
        switch (node) {
            .rational, .sqrt_rational => |rational| {
                hasher.update(rational.numerator);
                hasher.update("/");
                hasher.update(rational.denominator);
            },
            .pi => {},
            .parameter => |input| {
                hasher.update(std.mem.asBytes(&input.id));
                hasher.update(input.name);
            },
            .background => |input| {
                hasher.update(std.mem.asBytes(&input.index));
                hasher.update(input.name);
            },
            .renormalization_scale => |input| {
                hasher.update(std.mem.asBytes(&input.index));
                hasher.update(input.name);
            },
            .power => |power_node| {
                hasher.update(std.mem.asBytes(&self.value(power_node.base).order_key));
                hasher.update(std.mem.asBytes(&power_node.exponent));
            },
            .real_symmetric_matrix => |matrix| {
                hasher.update(std.mem.asBytes(&matrix.dimension));
                self.hashChildren(&hasher, matrix.entries);
            },
            .scalar_one_loop_spectral_value => |spectral| {
                hasher.update(spectral.formula.text());
                hasher.update(spectral.branch.text());
                self.hashChildren(&hasher, &.{ spectral.matrix, spectral.scale });
            },
            .scalar_one_loop_spectral_gradient, .scalar_one_loop_spectral_hessian => |derivative| {
                for (derivative.coordinates) |coordinate| {
                    hasher.update(std.mem.asBytes(&coordinate));
                }
                self.hashChildren(&hasher, &.{derivative.value});
                self.hashChildren(&hasher, derivative.first);
                self.hashChildren(&hasher, derivative.second);
            },
            .element => |selection| {
                hasher.update(std.mem.asBytes(&self.value(selection.source).order_key));
                hasher.update(std.mem.asBytes(&selection.row));
                hasher.update(std.mem.asBytes(&selection.column));
            },
            .add, .multiply => |children| self.hashChildren(&hasher, children),
            .divide => |binary| self.hashChildren(
                &hasher,
                &.{ binary.numerator, binary.denominator },
            ),
            .promote_real_to_complex => |operand| self.hashChildren(&hasher, &.{operand}),
        }
        return hasher.final();
    }

    fn hashChildren(
        self: *const Builder,
        hasher: *OrderHasher,
        children: []const ValueId,
    ) void {
        for (children) |child| {
            hasher.update(std.mem.asBytes(&self.value(child).order_key));
        }
    }

    fn internCurrent(
        self: *Builder,
        node: Node,
        signature: Signature,
    ) BuildError!ValueId {
        try self.appendSignature(signature);
        if (self.intern.get(self.key.items)) |existing| return existing;
        return self.internPrepared(node, signature);
    }
};

/// The identity a node carries beyond its operands.
const Signature = struct {
    value_type: ValueType = .real_scalar,
    mass_dimension: i32,
};

/// FNV-1a over 64 bits.
///
/// Owned rather than taken from the standard library because canonical operand
/// order feeds rendered output and committed golden files. A standard-library
/// hash could in principle change between toolchain versions and silently
/// reorder every exported equation; this cannot.
const OrderHasher = struct {
    state: u64 = 0xcbf29ce484222325,

    fn update(self: *OrderHasher, bytes: []const u8) void {
        for (bytes) |byte| {
            self.state ^= byte;
            self.state = self.state *% 0x100000001b3;
        }
    }

    fn final(self: *const OrderHasher) u64 {
        return self.state;
    }
};

/// Orders operands by content. The identifier tiebreak keeps the order total
/// and deterministic within one arena if two keys ever collide.
fn lessThanOrder(builder: *const Builder, left: ValueId, right: ValueId) bool {
    const left_key = builder.value(left).order_key;
    const right_key = builder.value(right).order_key;
    if (left_key != right_key) return left_key < right_key;
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

test "structurally equal values encode identically across arenas" {
    // Build the same sum in two builders whose creation orders differ, so the
    // arena positions of every node differ between them. Operand order is
    // content-derived, and the value encoding is numbered by structural
    // traversal, so the bytes must still agree.
    var first = try testBuilder();
    const first_phi = try first.background(0, "phi", 1);
    const first_mass = try first.parameter(1, "m2", 2);
    const first_lambda = try first.parameter(0, "lambda", 0);
    const first_root = try first.add(&.{
        try first.multiply(&.{ first_mass, try first.power(first_phi, 2) }),
        try first.multiply(&.{ first_lambda, try first.power(first_phi, 4) }),
    });
    var first_graph = try first.finish();
    defer first_graph.deinit();

    var second = try testBuilder();
    // Unrelated nodes first, so every shared node lands at a different arena
    // position than it did in the first builder.
    _ = try second.parameter(7, "decoy", 0);
    _ = try second.integer(99, 0);
    _ = try second.background(5, "unused", 1);
    const second_lambda = try second.parameter(0, "lambda", 0);
    const second_quartic = try second.multiply(&.{
        second_lambda,
        try second.power(try second.background(0, "phi", 1), 4),
    });
    const second_mass = try second.parameter(1, "m2", 2);
    const second_root = try second.add(&.{
        second_quartic,
        try second.multiply(&.{
            second_mass,
            try second.power(try second.background(0, "phi", 1), 2),
        }),
    });
    var second_graph = try second.finish();
    defer second_graph.deinit();

    // The arenas genuinely differ in layout, so agreement below is evidence
    // about structure rather than a coincidence of identical construction.
    try std.testing.expect(first_root.toU32() != second_root.toU32());
    try std.testing.expect(first_graph.values.len != second_graph.values.len);

    var first_text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first_text.deinit();
    var second_text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second_text.deinit();
    try first_graph.writeValueCanonical(
        first_root,
        std.testing.allocator,
        &first_text.writer,
    );
    try second_graph.writeValueCanonical(
        second_root,
        std.testing.allocator,
        &second_text.writer,
    );
    try std.testing.expectEqualStrings(first_text.written(), second_text.written());
}

test "the order key depends on content rather than arena position" {
    var builder = try testBuilder();
    defer builder.deinit();

    const late = try builder.parameter(9, "z", 0);
    const early = try builder.parameter(0, "a", 0);

    // Creation order is late-then-early; canonical operand order is decided by
    // the content keys, not by which was built first.
    const sum = try builder.add(&.{ late, early });
    const children = builder.value(sum).node.add;
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expect(
        builder.value(children[0]).order_key <= builder.value(children[1]).order_key,
    );
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

// -- Milestone 3 typed and structured nodes ---------------------------------

fn testMatrix(builder: *Builder, dimension: u32) !ValueId {
    var entries: [6]ValueId = undefined;
    const count = upperTriangleCount(dimension);
    for (entries[0..count], 0..) |*slot, index| {
        var name: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&name, "e{d}", .{index}) catch unreachable;
        slot.* = try builder.parameter(
            @intCast(index),
            text,
            mass_squared_dimension,
        );
    }
    return builder.realSymmetricMatrix(
        dimension,
        entries[0..count],
        mass_squared_dimension,
    );
}

test "the upper triangle is indexed in lexical order" {
    // (0,0) (0,1) (0,2) (1,1) (1,2) (2,2)
    try std.testing.expectEqual(@as(usize, 6), upperTriangleCount(3));
    try std.testing.expectEqual(@as(usize, 0), upperTriangleIndex(3, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), upperTriangleIndex(3, 0, 1));
    try std.testing.expectEqual(@as(usize, 2), upperTriangleIndex(3, 0, 2));
    try std.testing.expectEqual(@as(usize, 3), upperTriangleIndex(3, 1, 1));
    try std.testing.expectEqual(@as(usize, 4), upperTriangleIndex(3, 1, 2));
    try std.testing.expectEqual(@as(usize, 5), upperTriangleIndex(3, 2, 2));

    // The lower triangle names the same stored entry.
    try std.testing.expectEqual(upperTriangleIndex(3, 1, 0), upperTriangleIndex(3, 0, 1));
    try std.testing.expectEqual(upperTriangleIndex(3, 2, 1), upperTriangleIndex(3, 1, 2));
}

test "real and complex values never mix implicitly" {
    var builder = try testBuilder();
    defer builder.deinit();

    const real = try builder.parameter(0, "a", 4);
    const complex = try builder.promoteRealToComplex(real);
    try std.testing.expectEqual(Domain.complex, builder.valueType(complex).domain);
    try std.testing.expectEqual(@as(i32, 4), builder.massDimension(complex));

    // Only an explicit promotion crosses the boundary.
    try std.testing.expectError(error.TypeMismatch, builder.add(&.{ real, complex }));
    try std.testing.expectError(
        error.TypeMismatch,
        builder.multiply(&.{ complex, complex }),
    );
    try std.testing.expectError(error.TypeMismatch, builder.power(complex, 2));
    try std.testing.expectError(error.TypeMismatch, builder.divide(complex, real));
    // There is no projection back: promoting a complex value is not a thing.
    try std.testing.expectError(error.TypeMismatch, builder.promoteRealToComplex(complex));
}

test "a complex sum drops exact zeros without forming a product" {
    var builder = try testBuilder();
    defer builder.deinit();

    const term = try builder.promoteRealToComplex(try builder.parameter(0, "a", 4));
    const complex_zero = try builder.promoteRealToComplex(try builder.zero(4));
    try std.testing.expect(builder.isComplexZero(complex_zero));
    try std.testing.expectEqual(term, try builder.add(&.{ term, complex_zero }));

    // A repeated complex term stays a sum. The Milestone 3 kernel catalog has
    // no complex multiplication, so collecting a coefficient would build
    // structure no backend can lower.
    const doubled = try builder.add(&.{ term, term });
    try std.testing.expectEqual(
        std.meta.Tag(Node).add,
        std.meta.activeTag(builder.value(doubled).node),
    );
    try std.testing.expectEqual(@as(usize, 2), builder.value(doubled).node.add.len);
}

test "matrix construction checks its dimension and entry dimensions" {
    var builder = try testBuilder();
    defer builder.deinit();

    const entry = try builder.parameter(0, "m2", mass_squared_dimension);
    const wrong = try builder.parameter(1, "m", 1);

    try std.testing.expectError(error.InvalidMatrixDimension, builder.realSymmetricMatrix(
        2,
        &.{entry},
        mass_squared_dimension,
    ));
    try std.testing.expectError(error.DimensionMismatch, builder.realSymmetricMatrix(
        1,
        &.{wrong},
        mass_squared_dimension,
    ));

    const matrix = try builder.realSymmetricMatrix(
        1,
        &.{entry},
        mass_squared_dimension,
    );
    try std.testing.expect(builder.valueType(matrix).shape.matrix.symmetric);
    try std.testing.expectEqual(@as(u32, 1), builder.valueType(matrix).shape.matrix.dimension);
}

test "a symmetric matrix element selects the one stored entry" {
    var builder = try testBuilder();
    defer builder.deinit();

    const matrix = try testMatrix(&builder, 2);
    // Both mirrored positions denote the same operand, not two separately
    // rounded values.
    try std.testing.expectEqual(
        try builder.element(matrix, 0, 1),
        try builder.element(matrix, 1, 0),
    );
    try std.testing.expectError(
        error.InvalidElementIndex,
        builder.element(matrix, 0, 2),
    );
    try std.testing.expectError(
        error.TypeMismatch,
        builder.element(try builder.one(), 0, 0),
    );
}

test "the spectral value checks its operands and carries its contract" {
    var builder = try testBuilder();
    defer builder.deinit();

    const matrix = try testMatrix(&builder, 2);
    const scale = try builder.renormalizationScale(0, "muR");
    const spectral = try builder.scalarOneLoopSpectralValue(matrix, scale);

    try std.testing.expect(builder.valueType(spectral).eql(.complex_scalar));
    try std.testing.expectEqual(
        spectral_value_mass_dimension,
        builder.massDimension(spectral),
    );
    const node = builder.value(spectral).node.scalar_one_loop_spectral_value;
    try std.testing.expectEqualStrings(
        "scalar-vacuum-msbar/1",
        node.formula.text(),
    );
    try std.testing.expectEqualStrings("arg(-pi,pi]", node.branch.text());

    // A model parameter is not a scale channel, even though both are one real
    // value.
    const parameter_scale = try builder.parameter(9, "muR", scale_mass_dimension);
    try std.testing.expectError(
        error.TypeMismatch,
        builder.scalarOneLoopSpectralValue(matrix, parameter_scale),
    );

    // The formula version is defined over a mass-squared matrix.
    const wrong_dimension = try builder.realSymmetricMatrix(
        1,
        &.{try builder.parameter(8, "m4", 4)},
        4,
    );
    try std.testing.expectError(
        error.DimensionMismatch,
        builder.scalarOneLoopSpectralValue(wrong_dimension, scale),
    );
}

test "a nested spectral operand is rejected, and is currently unreachable" {
    var builder = try testBuilder();
    defer builder.deinit();

    const scale = try builder.renormalizationScale(0, "muR");
    const spectral = try builder.scalarOneLoopSpectralValue(try testMatrix(&builder, 1), scale);
    try std.testing.expect(builder.value(spectral).spectral);

    // Every spectral result is complex, and every operation that produces a
    // real scalar accepts only real operands. No real matrix entry can
    // therefore reach a spectral node today, which makes
    // `NestedSpectralOperation` unreachable. The rule is implemented anyway so
    // that a future real-valued spectral projection meets it rather than
    // silently deriving two-loop structure; this test asserts the condition
    // that keeps it unreachable, so removing that condition fails here.
    try std.testing.expectEqual(Domain.complex, builder.valueType(spectral).domain);
    const gradient_node = try builder.scalarOneLoopSpectralGradient(
        spectral,
        &.{0},
        &.{try builder.realSymmetricMatrix(
            1,
            &.{try builder.parameter(5, "d", 1)},
            1,
        )},
    );
    for ([_]ValueId{ spectral, gradient_node, try builder.element(gradient_node, 0, 0) }) |id| {
        try std.testing.expect(builder.value(id).spectral);
        try std.testing.expectEqual(Domain.complex, builder.valueType(id).domain);
    }
    try std.testing.expectError(
        error.TypeMismatch,
        builder.realSymmetricMatrix(
            1,
            &.{try builder.element(gradient_node, 0, 0)},
            3,
        ),
    );
}

test "interning separates type, shape, and spectral contract" {
    var builder = try testBuilder();
    defer builder.deinit();

    const entry = try builder.parameter(0, "m2", mass_squared_dimension);
    const one_by_one = try builder.realSymmetricMatrix(
        1,
        &.{entry},
        mass_squared_dimension,
    );
    // Same single operand, different declared dimension is impossible for a
    // symmetric matrix, so shape separation is observed through the element and
    // the value type instead.
    try std.testing.expectEqual(entry, try builder.element(one_by_one, 0, 0));
    try std.testing.expect(!builder.valueType(one_by_one).eql(builder.valueType(entry)));

    // Two promotions of different real values stay distinct, and one promotion
    // is shared.
    const promoted = try builder.promoteRealToComplex(entry);
    try std.testing.expectEqual(promoted, try builder.promoteRealToComplex(entry));
    try std.testing.expect(promoted != try builder.promoteRealToComplex(
        try builder.parameter(1, "m2b", mass_squared_dimension),
    ));
}

test "a spectral gradient records its canonical coordinate order" {
    var builder = try testBuilder();
    defer builder.deinit();

    const scale = try builder.renormalizationScale(0, "muR");
    const spectral = try builder.scalarOneLoopSpectralValue(try testMatrix(&builder, 1), scale);
    const first = try builder.realSymmetricMatrix(
        1,
        &.{try builder.parameter(5, "d0", 1)},
        1,
    );
    const second = try builder.realSymmetricMatrix(
        1,
        &.{try builder.parameter(6, "d1", 1)},
        1,
    );

    const forward = try builder.scalarOneLoopSpectralGradient(
        spectral,
        &.{ 0, 1 },
        &.{ first, second },
    );
    const reversed = try builder.scalarOneLoopSpectralGradient(
        spectral,
        &.{ 1, 0 },
        &.{ first, second },
    );
    try std.testing.expect(forward != reversed);
    try std.testing.expectEqual(
        @as(u32, 2),
        builder.valueType(forward).shape.vector,
    );
    // Mass dimensions follow from the matrix derivative: a first derivative of
    // a mass-squared matrix with respect to a dimension-one coordinate has
    // dimension one, so the gradient has dimension three.
    try std.testing.expectEqual(@as(i32, 3), builder.massDimension(forward));

    try std.testing.expectError(
        error.InvalidMatrixDimension,
        builder.scalarOneLoopSpectralGradient(spectral, &.{ 0, 1 }, &.{first}),
    );
    try std.testing.expectError(
        error.TypeMismatch,
        builder.scalarOneLoopSpectralGradient(first, &.{0}, &.{first}),
    );
}

test "structured nodes audit and encode deterministically" {
    var builder = try testBuilder();
    const matrix = try testMatrix(&builder, 2);
    const scale = try builder.renormalizationScale(0, "muR");
    const spectral = try builder.scalarOneLoopSpectralValue(matrix, scale);
    const total = try builder.add(&.{
        spectral,
        try builder.promoteRealToComplex(try builder.parameter(7, "omega", 4)),
    });

    var graph = try builder.finish();
    defer graph.deinit();
    try std.testing.expect(graph.audit());

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try graph.writeValueCanonical(total, std.testing.allocator, &first.writer);
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try graph.writeValueCanonical(total, std.testing.allocator, &second.writer);
    try std.testing.expectEqualStrings(first.written(), second.written());

    // The encoding names the contract, the shape, and the scale channel.
    try std.testing.expect(
        std.mem.indexOf(u8, first.written(), "scalar-vacuum-msbar/1") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, first.written(), "arg(-pi,pi]") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, first.written(), "renormalization_scale") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, first.written(), "type=complex:scalar") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, first.written(), "matrix(2,symmetric=true)") != null,
    );
}

test "matrix operand counts respect the value-operand limit" {
    var builder = try Builder.init(std.testing.allocator, .{ .value_operands = 2 });
    defer builder.deinit();

    const entry = try builder.parameter(0, "m2", mass_squared_dimension);
    // A 2x2 matrix stores three entries, one over the configured ceiling.
    try std.testing.expectError(error.CapacityExceeded, builder.realSymmetricMatrix(
        2,
        &.{ entry, entry, entry },
        mass_squared_dimension,
    ));
    _ = try builder.realSymmetricMatrix(1, &.{entry}, mass_squared_dimension);
}
