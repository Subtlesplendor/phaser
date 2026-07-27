//! Target rendering for Typed Value IR.
//!
//! Implements the human-readable Phaser notation and the delimiter-free
//! MathJax-compatible LaTeX fragment specified in
//! `docs/architecture/SYMBOLIC_EXPORT.md`.
//!
//! Rendering never changes scientific content. Exact rationals stay exact, no
//! algebraic simplification, cancellation, factorization, or numerical
//! evaluation occurs, and no contribution is removed. The only rewrites applied
//! are the presentation-only ones section 6 permits: conventional unary minus,
//! omission of multiplication signs, redundant-parenthesis removal, fraction
//! layout, and canonical spacing.
//!
//! Output is a function of the value's structure alone. Operand order is
//! content-derived, so the bytes do not depend on arena position, allocation
//! address, hash iteration, or how the graph happened to be built.

const std = @import("std");
const value = @import("../value/root.zig");

const ValueId = value.ValueId;
const Graph = value.Graph;
const Node = value.Node;

pub const Target = enum {
    /// Compact plain text for terminals, logs, and `repr`.
    phaser,
    /// Delimiter-free mathematical fragment for the MathJax subset Jupyter
    /// uses. No `$`, no `\(`, no preamble, no package-dependent macros.
    latex,
};

pub const Options = struct {
    target: Target,
    /// Byte ceiling for a complete export. Exceeding it is an ordinary
    /// failure, never a silent truncation.
    max_bytes: usize = 256 * 1024,
    /// Node ceiling above which a preview reports the size instead of
    /// rendering.
    max_preview_nodes: usize = 192,
    /// Display names for background coordinates, in canonical order.
    ///
    /// A spectral derivative node stores coordinate indices rather than names,
    /// because names are presentation metadata and must not enter content
    /// identity. An index outside this table falls back to `b<index>`.
    coordinate_names: []const []const u8 = &.{},
};

pub const RenderError = error{
    OutOfMemory,
    /// The complete rendering did not fit the declared byte budget. Nothing is
    /// published.
    OutputCapacityExceeded,
    WriteFailed,
};

/// Operator binding strength. A child is parenthesized when its own strength is
/// below what its position requires.
const Precedence = enum(u8) {
    sum = 0,
    product = 1,
    power = 2,
    atom = 3,
};

/// One pending rendering action.
///
/// The traversal is an explicit stack rather than recursion, so a deep value
/// cannot exhaust the machine stack. Steps are pushed in reverse so that
/// popping yields left-to-right output.
const Step = union(enum) {
    node: struct {
        id: ValueId,
        precedence: Precedence,
        /// Render the node's rational coefficient with its sign removed. Set
        /// when a preceding `-` has already been emitted for it.
        negate_coefficient: bool = false,
    },
    text: []const u8,
};

/// Renders `root` completely, or fails without writing anything.
///
/// The rendering is built in a bounded intermediate first, so a capacity
/// failure cannot publish a partial export. Callers that want streaming
/// behavior should use a different entry point; this one is atomic.
pub fn writeValue(
    graph: *const Graph,
    root: ValueId,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderInto(graph, root, allocator, options, &rendered.writer);
    writer.writeAll(rendered.written()) catch return error.WriteFailed;
}

/// Renders `root` into a caller-owned slice. The caller frees it.
pub fn renderAlloc(
    graph: *const Graph,
    root: ValueId,
    allocator: std.mem.Allocator,
    options: Options,
) RenderError![]u8 {
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    errdefer rendered.deinit();
    try renderInto(graph, root, allocator, options, &rendered.writer);
    return rendered.toOwnedSlice() catch error.OutOfMemory;
}

/// Bounded preview. When the value exceeds the preview budget the output
/// states that it is incomplete and reports the complete size, rather than
/// truncating behind an unmarked ellipsis.
pub fn writeValuePreview(
    graph: *const Graph,
    root: ValueId,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    const nodes = countNodes(graph, root, allocator) catch return error.OutOfMemory;
    if (nodes > options.max_preview_nodes) {
        writer.print(
            "[expression omitted from preview: {d} nodes]",
            .{nodes},
        ) catch return error.WriteFailed;
        return;
    }
    writeValue(graph, root, allocator, options, writer) catch |err| switch (err) {
        error.OutputCapacityExceeded => {
            writer.print(
                "[expression omitted from preview: {d} nodes]",
                .{nodes},
            ) catch return error.WriteFailed;
        },
        else => return err,
    };
}

/// Number of distinct nodes reachable from `root`, which is the size a preview
/// reports. Shared subexpressions count once.
pub fn countNodes(
    graph: *const Graph,
    root: ValueId,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!usize {
    const count = root.toUsize() + 1;
    const reachable = try allocator.alloc(bool, count);
    defer allocator.free(reachable);
    @memset(reachable, false);
    reachable[root.toUsize()] = true;

    // Operands always refer to strictly earlier nodes, so one descending sweep
    // marks the whole reachable set.
    var total: usize = 0;
    var index = count;
    while (index > 0) {
        index -= 1;
        if (!reachable[index]) continue;
        total += 1;
        const node = graph.values[index].node;
        var operand: usize = 0;
        while (value.childAt(node, operand)) |child| : (operand += 1) {
            reachable[child.toUsize()] = true;
        }
    }
    return total;
}

fn renderInto(
    graph: *const Graph,
    root: ValueId,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    std.debug.assert(root.toUsize() < graph.values.len);

    // Dynamic fragments live until their step is popped. An arena never moves
    // an existing allocation, so slices pushed onto the stack stay valid.
    var pool = std.heap.ArenaAllocator.init(allocator);
    defer pool.deinit();

    var stack = std.ArrayList(Step).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .node = .{ .id = root, .precedence = .sum } });

    var written: usize = 0;
    while (stack.pop()) |step| {
        switch (step) {
            .text => |text| {
                written = std.math.add(usize, written, text.len) catch
                    return error.OutputCapacityExceeded;
                if (written > options.max_bytes) return error.OutputCapacityExceeded;
                writer.writeAll(text) catch return error.WriteFailed;
            },
            .node => |request| try expand(
                graph,
                request,
                allocator,
                pool.allocator(),
                options,
                &stack,
                writer,
                &written,
            ),
        }
    }
}

fn emit(
    text: []const u8,
    options: Options,
    writer: *std.Io.Writer,
    written: *usize,
) RenderError!void {
    written.* = std.math.add(usize, written.*, text.len) catch
        return error.OutputCapacityExceeded;
    if (written.* > options.max_bytes) return error.OutputCapacityExceeded;
    writer.writeAll(text) catch return error.WriteFailed;
}

fn expand(
    graph: *const Graph,
    request: @FieldType(Step, "node"),
    allocator: std.mem.Allocator,
    pool: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
    writer: *std.Io.Writer,
    written: *usize,
) RenderError!void {
    const item = graph.value(request.id);
    const own = precedenceOf(graph, options.target, item.node);
    const parenthesize = @intFromEnum(own) < @intFromEnum(request.precedence);

    if (parenthesize) try emit("(", options, writer, written);
    // Pushed first so it pops last, after the whole subexpression.
    if (parenthesize) try stack.append(allocator, .{ .text = ")" });

    switch (item.node) {
        .rational => |rational| try emitRational(
            rational,
            request.negate_coefficient,
            options,
            pool,
            writer,
            written,
        ),
        .pi => try emit(
            switch (options.target) {
                .phaser => "pi",
                .latex => "\\pi",
            },
            options,
            writer,
            written,
        ),
        .sqrt_rational => |rational| {
            switch (options.target) {
                .phaser => {
                    try emit("sqrt(", options, writer, written);
                    try emitRational(rational, false, options, pool, writer, written);
                    try emit(")", options, writer, written);
                },
                .latex => {
                    try emit("\\sqrt{", options, writer, written);
                    try emitRational(rational, false, options, pool, writer, written);
                    try emit("}", options, writer, written);
                },
            }
        },
        .parameter => |input| try emitIdentifier(
            input.name,
            options,
            pool,
            writer,
            written,
        ),
        .background => |input| try emitIdentifier(
            input.name,
            options,
            pool,
            writer,
            written,
        ),
        .add => |children| try expandSum(
            graph,
            children,
            allocator,
            options,
            stack,
            writer,
            written,
        ),
        .multiply => |children| try expandProduct(
            graph,
            children,
            request.negate_coefficient,
            allocator,
            options,
            stack,
            writer,
            written,
        ),
        .divide => |binary| try expandQuotient(
            binary,
            allocator,
            options,
            stack,
            writer,
            written,
        ),
        .power => |power_node| try expandPower(
            power_node,
            allocator,
            pool,
            options,
            stack,
            writer,
            written,
        ),
        .renormalization_scale => |input| try emitIdentifier(
            input.name,
            options,
            pool,
            writer,
            written,
        ),
        // The promotion into `Complex64` is the exact inclusion of the reals,
        // so the rendered mathematics is the operand itself. Nothing is
        // dropped: the export's result-type metadata records that the
        // containing quantity is complex.
        .promote_real_to_complex => |operand| try stack.append(allocator, .{ .node = .{
            .id = operand,
            .precedence = request.precedence,
            .negate_coefficient = request.negate_coefficient,
        } }),
        .real_symmetric_matrix => |matrix| try expandMatrix(
            matrix,
            allocator,
            pool,
            options,
            stack,
        ),
        .scalar_one_loop_spectral_value => |spectral| try expandSpectralValue(
            spectral,
            allocator,
            options,
            stack,
        ),
        .scalar_one_loop_spectral_gradient, .scalar_one_loop_spectral_hessian => |derivative| {
            try expandSpectralDerivative(
                item.node == .scalar_one_loop_spectral_hessian,
                derivative,
                allocator,
                options,
                stack,
            );
        },
        .element => |selection| try expandElement(
            graph,
            selection,
            allocator,
            pool,
            options,
            stack,
        ),
    }
}

/// Pushes a prepared step sequence so that popping yields it in order.
fn pushSequence(
    stack: *std.ArrayList(Step),
    allocator: std.mem.Allocator,
    sequence: []const Step,
) RenderError!void {
    var index = sequence.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, sequence[index]);
    }
}

/// Compact matrix notation.
///
/// Both mirrored positions of the authoritative upper triangle are written, so
/// the reader sees the symmetric matrix the node denotes. No diagonalization,
/// expansion, or numerical evaluation happens here.
fn expandMatrix(
    matrix: value.SymmetricMatrix,
    allocator: std.mem.Allocator,
    pool: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
) RenderError!void {
    var sequence = std.ArrayList(Step).empty;
    defer sequence.deinit(allocator);

    const dimension = matrix.dimension;
    const latex = options.target == .latex;
    if (dimension == 0) {
        try stack.append(allocator, .{
            .text = if (latex) "\\left(\\ \\right)" else "[]",
        });
        return;
    }

    if (latex) {
        const columns = pool.alloc(u8, dimension) catch return error.OutOfMemory;
        @memset(columns, 'c');
        const opening = std.fmt.allocPrint(
            pool,
            "\\left(\\begin{{array}}{{{s}}}",
            .{columns},
        ) catch return error.OutOfMemory;
        try sequence.append(allocator, .{ .text = opening });
    } else {
        try sequence.append(allocator, .{ .text = "[" });
    }

    for (0..dimension) |row| {
        if (row != 0) {
            try sequence.append(allocator, .{ .text = if (latex) " \\\\ " else ", " });
        }
        if (!latex) try sequence.append(allocator, .{ .text = "[" });
        for (0..dimension) |column| {
            if (column != 0) {
                try sequence.append(allocator, .{ .text = if (latex) " & " else ", " });
            }
            const entry = matrix.entries[
                value.upperTriangleIndex(
                    dimension,
                    @intCast(row),
                    @intCast(column),
                )
            ];
            try sequence.append(allocator, .{ .node = .{
                .id = entry,
                .precedence = .sum,
            } });
        }
        if (!latex) try sequence.append(allocator, .{ .text = "]" });
    }

    try sequence.append(allocator, .{
        .text = if (latex) "\\end{array}\\right)" else "]",
    });
    try pushSequence(stack, allocator, sequence.items);
}

/// The named spectral operation.
///
/// Symbolic export preserves the operation and its operands rather than
/// diagonalizing the matrix or expanding a component sum, as section 7 of the
/// export specification requires.
fn expandSpectralValue(
    spectral: value.SpectralValue,
    allocator: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
) RenderError!void {
    const opening: []const u8 = switch (options.target) {
        .phaser => "scalar_one_loop(",
        .latex => "\\mathrm{Tr}\\,\\Phi^{(1)}_{\\mathrm{scalar}}\\!\\left(",
    };
    try pushSequence(stack, allocator, &.{
        .{ .text = opening },
        .{ .node = .{ .id = spectral.matrix, .precedence = .sum } },
        .{ .text = "; " },
        .{ .node = .{ .id = spectral.scale, .precedence = .sum } },
        .{ .text = switch (options.target) {
            .phaser => ")",
            .latex => "\\right)",
        } },
    });
}

/// A whole spectral gradient or Hessian, as the derivative operator applied to
/// its parent value. Individual components render through `expandElement`.
fn expandSpectralDerivative(
    second_order: bool,
    derivative: value.SpectralDerivative,
    allocator: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
) RenderError!void {
    const opening: []const u8 = switch (options.target) {
        .phaser => if (second_order) "hess_b[" else "grad_b[",
        .latex => if (second_order)
            "\\nabla_{b}^{2}\\!\\left("
        else
            "\\nabla_{b}\\!\\left(",
    };
    try pushSequence(stack, allocator, &.{
        .{ .text = opening },
        .{ .node = .{ .id = derivative.value, .precedence = .sum } },
        .{ .text = switch (options.target) {
            .phaser => "]",
            .latex => "\\right)",
        } },
    });
}

/// One component of a structured value.
///
/// A spectral derivative component renders as the corresponding background
/// partial derivative of the parent value, which is what it denotes.
fn expandElement(
    graph: *const Graph,
    selection: value.Element,
    allocator: std.mem.Allocator,
    pool: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
) RenderError!void {
    const source = graph.value(selection.source).node;
    const parent: ?ValueId = switch (source) {
        .scalar_one_loop_spectral_gradient, .scalar_one_loop_spectral_hessian => |derivative| derivative.value,
        else => null,
    };
    if (parent == null) {
        const suffix = switch (options.target) {
            .phaser => std.fmt.allocPrint(
                pool,
                "[{d},{d}]",
                .{ selection.row, selection.column },
            ),
            .latex => std.fmt.allocPrint(
                pool,
                "_{{{d},{d}}}",
                .{ selection.row, selection.column },
            ),
        } catch return error.OutOfMemory;
        try pushSequence(stack, allocator, &.{
            .{ .text = "(" },
            .{ .node = .{ .id = selection.source, .precedence = .sum } },
            .{ .text = ")" },
            .{ .text = suffix },
        });
        return;
    }

    const second_order = source == .scalar_one_loop_spectral_hessian;
    const row = try coordinateName(options, pool, selection.row);
    const column = try coordinateName(options, pool, selection.column);
    const opening: []const u8 = switch (options.target) {
        .phaser => if (second_order) "d2[" else "d[",
        .latex => if (second_order)
            std.fmt.allocPrint(
                pool,
                "\\frac{{\\partial^{{2}}}}{{\\partial {s} \\partial {s}}}\\!\\left(",
                .{
                    try escapeIdentifier(row, options, pool),
                    try escapeIdentifier(column, options, pool),
                },
            ) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(
                pool,
                "\\frac{{\\partial}}{{\\partial {s}}}\\!\\left(",
                .{try escapeIdentifier(row, options, pool)},
            ) catch return error.OutOfMemory,
    };
    const closing: []const u8 = switch (options.target) {
        .phaser => if (second_order)
            std.fmt.allocPrint(pool, "]/d{s} d{s}", .{ row, column }) catch
                return error.OutOfMemory
        else
            std.fmt.allocPrint(pool, "]/d{s}", .{row}) catch return error.OutOfMemory,
        .latex => "\\right)",
    };

    try pushSequence(stack, allocator, &.{
        .{ .text = opening },
        .{ .node = .{ .id = parent.?, .precedence = .sum } },
        .{ .text = closing },
    });
}

/// Display name of a background coordinate.
///
/// Falls back to the canonical position when the caller supplied no table, so
/// a component is never rendered ambiguously.
fn coordinateName(
    options: Options,
    pool: std.mem.Allocator,
    index: u32,
) RenderError![]const u8 {
    if (index < options.coordinate_names.len) return options.coordinate_names[index];
    return std.fmt.allocPrint(pool, "b{d}", .{index}) catch error.OutOfMemory;
}

fn expandSum(
    graph: *const Graph,
    children: []const ValueId,
    allocator: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
    writer: *std.Io.Writer,
    written: *usize,
) RenderError!void {
    _ = writer;
    _ = written;
    _ = options;

    // Presentation-only ordering. The stored operand order is content-derived
    // and canonical but carries no reading convention, so terms are displayed
    // by ascending total background degree, then by descending degree in each
    // coordinate in turn. That reproduces how the same polynomial is written by
    // hand. It changes no scientific content and stays deterministic, because
    // the key is derived from structure and falls back to the canonical order
    // key.
    const ordered = try allocator.dupe(ValueId, children);
    defer allocator.free(ordered);
    std.mem.sort(ValueId, ordered, graph, lessThanForDisplay);

    // Build the step sequence, then push it reversed so it pops in order.
    var sequence = std.ArrayList(Step).empty;
    defer sequence.deinit(allocator);

    for (ordered, 0..) |child, index| {
        const negative = hasNegativeCoefficient(graph, child);
        if (index != 0) {
            try sequence.append(allocator, .{ .text = if (negative) " - " else " + " });
        } else if (negative) {
            // A leading negative term keeps its conventional unary minus.
            try sequence.append(allocator, .{ .text = "-" });
        }
        try sequence.append(allocator, .{ .node = .{
            .id = child,
            .precedence = .sum,
            .negate_coefficient = negative,
        } });
    }

    var index = sequence.items.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, sequence.items[index]);
    }
}

/// Total degree in background coordinates, plus a packed per-coordinate degree
/// profile used to order terms of equal total degree.
const Degree = struct {
    total: u32 = 0,
    /// Degrees of the first eight coordinates, most significant byte first, so
    /// that a descending sort favours the earlier coordinate.
    profile: u64 = 0,

    fn addCoordinate(self: *Degree, index: u32, amount: u32) void {
        self.total +|= amount;
        if (index >= 8) return;
        const shift: std.math.Log2Int(u64) = @intCast((7 - index) * 8);
        const current: u64 = (self.profile >> shift) & 0xff;
        const raised: u64 = @min(current + amount, 0xff);
        self.profile &= ~(@as(u64, 0xff) << shift);
        self.profile |= raised << shift;
    }
};

/// Looks through an exact promotion into `Complex64`.
///
/// A promoted term is displayed as its operand, so every presentation rule that
/// inspects term shape has to see the same thing the reader does.
fn underlying(graph: *const Graph, id: ValueId) ValueId {
    return switch (graph.value(id).node) {
        .promote_real_to_complex => |operand| operand,
        else => id,
    };
}

/// Background degree of one displayed term.
///
/// Only the shapes a canonical term actually takes are inspected: a coordinate,
/// an integer power of one, or a product of such factors. Anything else
/// contributes zero and is separated by the canonical order key instead.
fn termDegree(graph: *const Graph, promoted: ValueId) Degree {
    const id = underlying(graph, promoted);
    var degree = Degree{};
    switch (graph.value(id).node) {
        .background => |input| degree.addCoordinate(input.index, 1),
        .power => |power_node| switch (graph.value(power_node.base).node) {
            .background => |input| degree.addCoordinate(input.index, power_node.exponent),
            else => {},
        },
        .multiply => |children| {
            for (children) |child| {
                switch (graph.value(child).node) {
                    .background => |input| degree.addCoordinate(input.index, 1),
                    .power => |power_node| switch (graph.value(power_node.base).node) {
                        .background => |input| degree.addCoordinate(
                            input.index,
                            power_node.exponent,
                        ),
                        else => {},
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
    return degree;
}

/// Reading order for the factors of one term: coefficient, then symbolic
/// constants, then parameters, then background coordinates.
const FactorRank = enum(u8) {
    coefficient = 0,
    constant = 1,
    parameter = 2,
    coordinate = 3,
    other = 4,
};

const FactorKey = struct {
    rank: FactorRank,
    /// Coordinate index for a background factor; unused otherwise.
    coordinate: u32 = 0,
    /// Parameter name for a parameter factor; empty otherwise.
    name: []const u8 = "",
};

fn factorKey(graph: *const Graph, promoted: ValueId) FactorKey {
    const id = underlying(graph, promoted);
    return switch (graph.value(id).node) {
        .rational => .{ .rank = .coefficient },
        .pi, .sqrt_rational => .{ .rank = .constant },
        .parameter => |input| .{ .rank = .parameter, .name = input.name },
        .background => |input| .{ .rank = .coordinate, .coordinate = input.index },
        .power => |power_node| switch (graph.value(power_node.base).node) {
            .parameter => |input| .{ .rank = .parameter, .name = input.name },
            .background => |input| .{
                .rank = .coordinate,
                .coordinate = input.index,
            },
            else => .{ .rank = .other },
        },
        else => .{ .rank = .other },
    };
}

/// Presentation-only factor ordering. Scientific content is unchanged; this
/// only decides the sequence in which a product's factors are written.
fn lessThanFactorForDisplay(graph: *const Graph, left: ValueId, right: ValueId) bool {
    const left_key = factorKey(graph, left);
    const right_key = factorKey(graph, right);
    if (left_key.rank != right_key.rank) {
        return @intFromEnum(left_key.rank) < @intFromEnum(right_key.rank);
    }
    switch (left_key.rank) {
        .parameter => {
            const order = std.mem.order(u8, left_key.name, right_key.name);
            if (order != .eq) return order == .lt;
        },
        .coordinate => {
            if (left_key.coordinate != right_key.coordinate) {
                return left_key.coordinate < right_key.coordinate;
            }
        },
        else => {},
    }
    return graph.value(left).order_key < graph.value(right).order_key;
}

fn lessThanForDisplay(graph: *const Graph, left: ValueId, right: ValueId) bool {
    // Loop terms come after the polynomial ones, which is how a perturbative
    // sum is written. A spectral term has no visible background degree, so
    // without this it would sort among the constants.
    const left_spectral = graph.value(left).spectral;
    const right_spectral = graph.value(right).spectral;
    if (left_spectral != right_spectral) return right_spectral;

    const left_degree = termDegree(graph, left);
    const right_degree = termDegree(graph, right);
    if (left_degree.total != right_degree.total) {
        return left_degree.total < right_degree.total;
    }
    if (left_degree.profile != right_degree.profile) {
        return left_degree.profile > right_degree.profile;
    }
    return graph.value(left).order_key < graph.value(right).order_key;
}

fn expandProduct(
    graph: *const Graph,
    children: []const ValueId,
    negate_coefficient: bool,
    allocator: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
    writer: *std.Io.Writer,
    written: *usize,
) RenderError!void {
    _ = writer;
    _ = written;

    const separator: []const u8 = switch (options.target) {
        .phaser => " * ",
        // A thin space keeps juxtaposed factors legible without a package.
        .latex => "\\,",
    };

    // Presentation-only factor ordering, matching how a term is written by
    // hand: coefficient, constants, parameters, then background coordinates.
    const ordered = try allocator.dupe(ValueId, children);
    defer allocator.free(ordered);
    std.mem.sort(ValueId, ordered, graph, lessThanFactorForDisplay);

    var sequence = std.ArrayList(Step).empty;
    defer sequence.deinit(allocator);

    var emitted: usize = 0;
    for (ordered) |child| {
        // Only the rational factor carries the sign the sum already emitted.
        const carries_sign = negate_coefficient and
            graph.value(child).node == .rational;
        // Once its sign is stripped, a unit coefficient is not written: the
        // conventional rendering of a negated term is `-x`, not `-1 * x`.
        if (carries_sign and isUnitMagnitude(graph.value(child).node.rational)) {
            continue;
        }
        if (emitted != 0) try sequence.append(allocator, .{ .text = separator });
        try sequence.append(allocator, .{ .node = .{
            .id = child,
            .precedence = .product,
            .negate_coefficient = carries_sign,
        } });
        emitted += 1;
    }

    var index = sequence.items.len;
    while (index > 0) {
        index -= 1;
        try stack.append(allocator, sequence.items[index]);
    }
}

fn expandQuotient(
    binary: value.graph.Divide,
    allocator: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
    writer: *std.Io.Writer,
    written: *usize,
) RenderError!void {
    switch (options.target) {
        .phaser => {
            try stack.append(allocator, .{ .node = .{
                .id = binary.denominator,
                .precedence = .power,
            } });
            try stack.append(allocator, .{ .text = " / " });
            try stack.append(allocator, .{ .node = .{
                .id = binary.numerator,
                .precedence = .product,
            } });
        },
        .latex => {
            // A fraction is self-delimiting, so its parts need no parentheses.
            try emit("\\frac{", options, writer, written);
            try stack.append(allocator, .{ .text = "}" });
            try stack.append(allocator, .{ .node = .{
                .id = binary.denominator,
                .precedence = .sum,
            } });
            try stack.append(allocator, .{ .text = "}{" });
            try stack.append(allocator, .{ .node = .{
                .id = binary.numerator,
                .precedence = .sum,
            } });
        },
    }
}

fn expandPower(
    power_node: value.graph.Power,
    allocator: std.mem.Allocator,
    pool: std.mem.Allocator,
    options: Options,
    stack: *std.ArrayList(Step),
    writer: *std.Io.Writer,
    written: *usize,
) RenderError!void {
    _ = writer;
    _ = written;

    const exponent = std.fmt.allocPrint(pool, "{d}", .{power_node.exponent}) catch
        return error.OutOfMemory;
    switch (options.target) {
        .phaser => {
            try stack.append(allocator, .{ .text = exponent });
            try stack.append(allocator, .{ .text = "^" });
        },
        .latex => {
            try stack.append(allocator, .{ .text = "}" });
            try stack.append(allocator, .{ .text = exponent });
            try stack.append(allocator, .{ .text = "^{" });
        },
    }
    // The base binds tighter than the power operator.
    try stack.append(allocator, .{ .node = .{
        .id = power_node.base,
        .precedence = .atom,
    } });
}

fn emitRational(
    rational: value.Rational,
    negate: bool,
    options: Options,
    pool: std.mem.Allocator,
    writer: *std.Io.Writer,
    written: *usize,
) RenderError!void {
    // The sign is dropped only when the caller already emitted a minus.
    const numerator = if (negate and rational.numerator.len != 0 and
        rational.numerator[0] == '-')
        rational.numerator[1..]
    else
        rational.numerator;
    const integral = std.mem.eql(u8, rational.denominator, "1");

    switch (options.target) {
        .phaser => {
            try emit(numerator, options, writer, written);
            if (!integral) {
                try emit("/", options, writer, written);
                try emit(rational.denominator, options, writer, written);
            }
        },
        .latex => {
            if (integral) {
                try emit(numerator, options, writer, written);
                return;
            }
            const text = std.fmt.allocPrint(
                pool,
                "\\frac{{{s}}}{{{s}}}",
                .{ numerator, rational.denominator },
            ) catch return error.OutOfMemory;
            try emit(text, options, writer, written);
        },
    }
}

/// Emits a semantic identifier safely.
///
/// Identifier text is never interpreted as target source. For LaTeX the name is
/// wrapped in `\mathrm` and every character with target meaning is escaped, so
/// an arbitrary identifier cannot inject markup.
fn emitIdentifier(
    name: []const u8,
    options: Options,
    pool: std.mem.Allocator,
    writer: *std.Io.Writer,
    written: *usize,
) RenderError!void {
    try emit(try escapeIdentifier(name, options, pool), options, writer, written);
}

/// Renders a semantic identifier as target-safe text.
///
/// Identifier text is never interpreted as target source. For LaTeX the name is
/// wrapped in `\mathrm` and every character with target meaning is escaped, so
/// an arbitrary identifier cannot inject markup.
fn escapeIdentifier(
    name: []const u8,
    options: Options,
    pool: std.mem.Allocator,
) RenderError![]const u8 {
    if (options.target == .phaser) return name;

    var escaped = std.ArrayList(u8).empty;
    escaped.appendSlice(pool, "\\mathrm{") catch return error.OutOfMemory;
    for (name) |byte| {
        switch (byte) {
            '#', '$', '%', '&', '_', '{', '}' => {
                escaped.append(pool, '\\') catch return error.OutOfMemory;
                escaped.append(pool, byte) catch return error.OutOfMemory;
            },
            '~' => escaped.appendSlice(pool, "\\textasciitilde{}") catch
                return error.OutOfMemory,
            '^' => escaped.appendSlice(pool, "\\textasciicircum{}") catch
                return error.OutOfMemory,
            '\\' => escaped.appendSlice(pool, "\\textbackslash{}") catch
                return error.OutOfMemory,
            else => escaped.append(pool, byte) catch return error.OutOfMemory,
        }
    }
    escaped.append(pool, '}') catch return error.OutOfMemory;
    return escaped.items;
}

fn precedenceOf(graph: *const Graph, target: Target, node: Node) Precedence {
    return switch (node) {
        .add => .sum,
        .multiply => .product,
        .divide => switch (target) {
            .phaser => .product,
            // `\frac` is self-delimiting.
            .latex => .atom,
        },
        .power => .power,
        .rational => |rational| switch (target) {
            .phaser => if (std.mem.eql(u8, rational.denominator, "1"))
                Precedence.atom
            else
                // `p/q` binds like a quotient in plain text.
                Precedence.product,
            .latex => .atom,
        },
        .pi, .sqrt_rational, .parameter, .background, .renormalization_scale => .atom,
        // Promotion renders as its operand, so it binds exactly as tightly.
        .promote_real_to_complex => |operand| precedenceOf(graph, target, graph.value(operand).node),
        // Every structured and spectral form the renderer emits is
        // self-delimiting except the plain-text derivative suffix, which binds
        // like a quotient.
        .real_symmetric_matrix,
        .scalar_one_loop_spectral_value,
        .scalar_one_loop_spectral_gradient,
        .scalar_one_loop_spectral_hessian,
        => .atom,
        .element => switch (target) {
            .phaser => .product,
            .latex => .atom,
        },
    };
}

/// True when the value carries a negative exact rational coefficient, which the
/// sum renderer turns into a conventional minus sign.
fn hasNegativeCoefficient(graph: *const Graph, promoted: ValueId) bool {
    return switch (graph.value(underlying(graph, promoted)).node) {
        .rational => |rational| isNegative(rational),
        .multiply => |children| blk: {
            for (children) |child| {
                switch (graph.value(child).node) {
                    .rational => |rational| break :blk isNegative(rational),
                    else => {},
                }
            }
            break :blk false;
        },
        else => false,
    };
}

/// True for exactly 1 or -1, whose magnitude is never written as a factor.
fn isUnitMagnitude(rational: value.Rational) bool {
    if (!std.mem.eql(u8, rational.denominator, "1")) return false;
    const digits = if (rational.numerator.len != 0 and rational.numerator[0] == '-')
        rational.numerator[1..]
    else
        rational.numerator;
    return std.mem.eql(u8, digits, "1");
}

fn isNegative(rational: value.Rational) bool {
    return rational.numerator.len != 0 and rational.numerator[0] == '-';
}

// -- tests -----------------------------------------------------------------

fn renderForTest(
    graph: *const Graph,
    root: ValueId,
    target: Target,
) ![]u8 {
    return renderAlloc(graph, root, std.testing.allocator, .{ .target = target });
}

fn expectRender(
    graph: *const Graph,
    root: ValueId,
    target: Target,
    expected: []const u8,
) !void {
    const text = try renderForTest(graph, root, target);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "exact rationals never become decimals" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const three_quarters = try builder.divide(
        try builder.integer(3, 0),
        try builder.integer(4, 0),
    );
    var graph = try builder.finish();
    defer graph.deinit();

    try expectRender(&graph, three_quarters, .phaser, "3/4");
    try expectRender(&graph, three_quarters, .latex, "\\frac{3}{4}");
}

test "symbolic constants and exact radicals are preserved" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const pi_node = try builder.pi();
    var half = try value.graph.exact.MutableRational.initInteger(
        std.testing.allocator,
        "2",
    );
    defer half.deinit();
    const radical = try builder.sqrtRational(&half, 0);
    const product = try builder.multiply(&.{ pi_node, radical });
    var graph = try builder.finish();
    defer graph.deinit();

    // Operand order is content-derived rather than creation-ordered, so the
    // assertion is on the rendered pieces rather than on their arrangement.
    const plain = try renderForTest(&graph, product, .phaser);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "sqrt(2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, " * ") != null);

    const latex = try renderForTest(&graph, product, .latex);
    defer std.testing.allocator.free(latex);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\sqrt{2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\,") != null);
}

test "precedence adds only the parentheses it needs" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const a = try builder.parameter(0, "a", 0);
    const b = try builder.parameter(1, "b", 0);
    const c = try builder.parameter(2, "c", 0);

    // (a + b) * c requires parentheses; a * b + c does not.
    const grouped = try builder.multiply(&.{ try builder.add(&.{ a, b }), c });
    const flat = try builder.add(&.{ try builder.multiply(&.{ a, b }), c });
    var graph = try builder.finish();
    defer graph.deinit();

    const grouped_text = try renderForTest(&graph, grouped, .phaser);
    defer std.testing.allocator.free(grouped_text);
    try std.testing.expect(std.mem.indexOf(u8, grouped_text, "(") != null);

    const flat_text = try renderForTest(&graph, flat, .phaser);
    defer std.testing.allocator.free(flat_text);
    try std.testing.expect(std.mem.indexOf(u8, flat_text, "(") == null);
}

test "a power parenthesizes a compound base" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const a = try builder.parameter(0, "a", 0);
    const b = try builder.parameter(1, "b", 0);
    const squared = try builder.power(try builder.add(&.{ a, b }), 2);
    var graph = try builder.finish();
    defer graph.deinit();

    try expectRender(&graph, squared, .phaser, "(a + b)^2");
    try expectRender(&graph, squared, .latex, "(\\mathrm{a} + \\mathrm{b})^{2}");
}

test "negative coefficients render as conventional subtraction" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const a = try builder.parameter(0, "a", 0);
    const b = try builder.parameter(1, "b", 0);
    const difference = try builder.subtract(a, b);
    var graph = try builder.finish();
    defer graph.deinit();

    const text = try renderForTest(&graph, difference, .phaser);
    defer std.testing.allocator.free(text);
    // Operand order is content-derived, so accept either arrangement; what
    // matters is that a minus appears and no literal -1 factor survives.
    try std.testing.expect(std.mem.indexOf(u8, text, " - ") != null or
        std.mem.startsWith(u8, text, "-"));
    try std.testing.expect(std.mem.indexOf(u8, text, "-1") == null);
}

test "identifiers are escaped rather than interpreted as markup" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const awkward = try builder.parameter(0, "m_h2", 0);
    const hostile = try builder.parameter(1, "a$b", 0);
    const product = try builder.multiply(&.{ awkward, hostile });
    var graph = try builder.finish();
    defer graph.deinit();

    const text = try renderForTest(&graph, product, .latex);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "m\\_h2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "a\\$b") != null);
    // The raw characters never reach the output unescaped.
    try std.testing.expect(std.mem.indexOf(u8, text, "m_h2") == null);
}

test "the LaTeX fragment carries no delimiters or preamble" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const phi = try builder.background(0, "phi", 1);
    const mass = try builder.parameter(0, "m2", 2);
    const term = try builder.divide(
        try builder.multiply(&.{ mass, try builder.power(phi, 2) }),
        try builder.integer(2, 0),
    );
    var graph = try builder.finish();
    defer graph.deinit();

    const text = try renderForTest(&graph, term, .latex);
    defer std.testing.allocator.free(text);
    for ([_][]const u8{ "$", "\\(", "\\[", "\\begin{document}", "\\usepackage" }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, text, forbidden) == null);
    }
}

test "rendering is deterministic" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const phi = try builder.background(0, "phi", 1);
    const lambda = try builder.parameter(0, "lambda", 0);
    const quartic = try builder.divide(
        try builder.multiply(&.{ lambda, try builder.power(phi, 4) }),
        try builder.integer(24, 0),
    );
    var graph = try builder.finish();
    defer graph.deinit();

    const first = try renderForTest(&graph, quartic, .latex);
    defer std.testing.allocator.free(first);
    const second = try renderForTest(&graph, quartic, .latex);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "a complete export fails rather than truncating" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const a = try builder.parameter(0, "parameter_with_a_long_name", 0);
    const b = try builder.parameter(1, "another_long_parameter_name", 0);
    const sum = try builder.add(&.{ a, b });
    var graph = try builder.finish();
    defer graph.deinit();

    const complete = try renderForTest(&graph, sum, .phaser);
    defer std.testing.allocator.free(complete);

    // Exactly the required budget succeeds.
    const exact = try renderAlloc(&graph, sum, std.testing.allocator, .{
        .target = .phaser,
        .max_bytes = complete.len,
    });
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings(complete, exact);

    // One byte less fails, and publishes nothing.
    try std.testing.expectError(error.OutputCapacityExceeded, renderAlloc(
        &graph,
        sum,
        std.testing.allocator,
        .{ .target = .phaser, .max_bytes = complete.len - 1 },
    ));
}

test "a preview states that it is incomplete and reports the size" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    errdefer builder.deinit();

    // A wide dimensionless sum, so every addend agrees dimensionally.
    var addends: [24]ValueId = undefined;
    for (&addends, 0..) |*slot, index| {
        var name: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&name, "p{d}", .{index}) catch unreachable;
        slot.* = try builder.parameter(@intCast(index), text, 0);
    }
    const root = try builder.add(&addends);
    var graph = try builder.finish();
    defer graph.deinit();

    const total = try countNodes(&graph, root, std.testing.allocator);
    try std.testing.expect(total > 4);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeValuePreview(&graph, root, std.testing.allocator, .{
        .target = .latex,
        .max_preview_nodes = 4,
    }, &output.writer);

    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "omitted from preview") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "nodes") != null);
}

test "a preview renders completely when it fits" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const a = try builder.parameter(0, "a", 0);
    const b = try builder.parameter(1, "b", 0);
    const sum = try builder.add(&.{ a, b });
    var graph = try builder.finish();
    defer graph.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeValuePreview(&graph, sum, std.testing.allocator, .{
        .target = .phaser,
    }, &output.writer);
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "omitted") == null,
    );
}

test "shared subexpressions are counted once" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const phi = try builder.background(0, "phi", 1);
    const squared = try builder.power(phi, 2);
    const doubled = try builder.add(&.{ squared, squared });
    var graph = try builder.finish();
    defer graph.deinit();

    // add(2, phi^2) reaches four distinct nodes: the sum, the coefficient, the
    // power, and the coordinate.
    const total = try countNodes(&graph, doubled, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), total);
}

// -- Milestone 3 structured and spectral notation ---------------------------

/// A 2x2 mass matrix and its spectral value, built directly so that the
/// rendering tests do not depend on the derivation path.
fn buildSpectralFixture(builder: *value.Builder) !struct {
    matrix: ValueId,
    spectral: ValueId,
} {
    const phi = try builder.background(0, "phi", 1);
    const m2 = try builder.parameter(0, "m2", 2);
    const g = try builder.parameter(1, "g", 2);
    const matrix = try builder.realSymmetricMatrix(
        2,
        &.{ m2, g, try builder.multiply(&.{ m2, try builder.power(phi, 0) }) },
        2,
    );
    return .{
        .matrix = matrix,
        .spectral = try builder.scalarOneLoopSpectralValue(
            matrix,
            try builder.renormalizationScale(0, "muR"),
        ),
    };
}

test "a matrix renders compactly with both mirrored positions" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const fixture = try buildSpectralFixture(&builder);
    var graph = try builder.finish();
    defer graph.deinit();

    // The stored upper triangle is authoritative; the lower triangle shows the
    // same operands rather than separately rounded values.
    try expectRender(&graph, fixture.matrix, .phaser, "[[m2, g], [g, m2]]");
    const latex = try renderForTest(&graph, fixture.matrix, .latex);
    defer std.testing.allocator.free(latex);
    try std.testing.expect(
        std.mem.indexOf(u8, latex, "\\left(\\begin{array}{cc}") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, latex, " & ") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, " \\\\ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, latex, "\\end{array}\\right)") != null);
}

test "the spectral operation is preserved rather than expanded" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const fixture = try buildSpectralFixture(&builder);
    var graph = try builder.finish();
    defer graph.deinit();

    try expectRender(
        &graph,
        fixture.spectral,
        .phaser,
        "scalar_one_loop([[m2, g], [g, m2]]; muR)",
    );

    const latex = try renderForTest(&graph, fixture.spectral, .latex);
    defer std.testing.allocator.free(latex);
    // A named spectral head with a trace, not a diagonalization or a component
    // sum over eigenvalues.
    try std.testing.expect(
        std.mem.indexOf(u8, latex, "\\mathrm{Tr}\\,\\Phi^{(1)}_{\\mathrm{scalar}}") != null,
    );
    for ([_][]const u8{ "\\log", "\\lambda_", "$", "\\begin{document}" }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, latex, forbidden) == null);
    }
}

test "a spectral derivative component renders as a background partial" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const fixture = try buildSpectralFixture(&builder);
    var first: [1]ValueId = undefined;
    const background = value.Background{ .order = &.{0}, .mass_dimension = 1 };
    try value.gradient(&builder, fixture.spectral, background, &first);
    var second: [1]ValueId = undefined;
    try value.hessian(&builder, fixture.spectral, background, &second);
    var graph = try builder.finish();
    defer graph.deinit();

    const options = Options{ .target = .phaser, .coordinate_names = &.{"phi"} };
    const gradient_text = try renderAlloc(
        &graph,
        first[0],
        std.testing.allocator,
        options,
    );
    defer std.testing.allocator.free(gradient_text);
    try std.testing.expect(std.mem.startsWith(u8, gradient_text, "d[scalar_one_loop("));
    try std.testing.expect(std.mem.endsWith(u8, gradient_text, "]/dphi"));

    const hessian_text = try renderAlloc(
        &graph,
        second[0],
        std.testing.allocator,
        options,
    );
    defer std.testing.allocator.free(hessian_text);
    try std.testing.expect(std.mem.startsWith(u8, hessian_text, "d2[scalar_one_loop("));
    try std.testing.expect(std.mem.endsWith(u8, hessian_text, "]/dphi dphi"));

    // Without a supplied name table the component still identifies its
    // coordinate, by canonical position.
    const unnamed = try renderAlloc(&graph, first[0], std.testing.allocator, .{
        .target = .phaser,
    });
    defer std.testing.allocator.free(unnamed);
    try std.testing.expect(std.mem.endsWith(u8, unnamed, "]/db0"));
}

test "a promoted real term renders as the real mathematics it denotes" {
    var builder = try value.Builder.init(std.testing.allocator, .{});
    const phi = try builder.background(0, "phi", 1);
    const tree = try builder.multiply(&.{
        try builder.parameter(0, "m2", 2),
        try builder.power(phi, 2),
    });
    const fixture = try buildSpectralFixture(&builder);
    const total = try builder.add(&.{
        try builder.promoteRealToComplex(tree),
        fixture.spectral,
    });
    var graph = try builder.finish();
    defer graph.deinit();

    const text = try renderForTest(&graph, total, .phaser);
    defer std.testing.allocator.free(text);
    // The inclusion into Complex64 adds no mathematics, and the loop term is
    // written after the polynomial one, as a perturbative sum is written.
    try std.testing.expect(std.mem.startsWith(u8, text, "m2 * phi^2 + scalar_one_loop("));
}
