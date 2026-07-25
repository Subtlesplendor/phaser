const std = @import("std");
const foundation = @import("../foundation/root.zig");
const model_limits = @import("../model/limits.zig");

pub const exact = @import("exact.zig");
pub const Rational = exact.Rational;
const MutableRational = exact.MutableRational;

pub const ValueId = foundation.TypedId("value");

pub const Parameter = struct {
    name: []const u8,
    id: u32,
    mass_dimension: i16,
};

pub const Node = union(enum) {
    rational: Rational,
    parameter: struct {
        id: u32,
        name: []const u8,
    },
    pi,
    sqrt_rational: Rational,
    negate: ValueId,
    add: []const ValueId,
    multiply: []const ValueId,
    divide: struct {
        numerator: ValueId,
        denominator: ValueId,
    },
    power: struct {
        base: ValueId,
        exponent: u32,
    },
};

pub const Value = struct {
    node: Node,
    mass_dimension: i32,
};

pub const FailureKind = enum {
    invalid_token,
    unexpected_token,
    missing_operand,
    missing_operator,
    unmatched_parenthesis,
    unknown_parameter,
    integer_too_large,
    exponent_too_large,
    expression_too_large,
    too_many_tokens,
    too_many_nodes,
    nesting_too_deep,
    dimension_mismatch,
    dimension_overflow,
    division_by_zero,
    invalid_square_root,
    exact_value_too_large,
};

pub const Failure = struct {
    kind: FailureKind,
    span: foundation.SourceSpan,
    expected_dimension: ?i32 = null,
    actual_dimension: ?i32 = null,
};

pub const ParseResult = union(enum) {
    expression: Expression,
    failure: Failure,
};

pub const ParseOptions = struct {
    limits: model_limits.ModelLimits = .{},
    required_dimension: ?i32 = null,
};

pub const Expression = struct {
    arena: *std.heap.ArenaAllocator,
    values: []const Value,
    root: ValueId,

    pub fn deinit(self: *Expression) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn value(self: *const Expression, id: ValueId) Value {
        std.debug.assert(id.toUsize() < self.values.len);
        return self.values[id.toUsize()];
    }

    pub fn rootDimension(self: *const Expression) i32 {
        return self.value(self.root).mass_dimension;
    }

    pub fn isZero(self: *const Expression) bool {
        return switch (self.value(self.root).node) {
            .rational => |rational| rational.isZero(),
            else => false,
        };
    }

    pub fn audit(self: *const Expression) bool {
        for (self.values, 0..) |item_value, index| {
            switch (item_value.node) {
                .negate => |child| if (child.toUsize() >= index) return false,
                .add, .multiply => |children| for (children) |child| {
                    if (child.toUsize() >= index) return false;
                },
                .divide => |binary| {
                    if (binary.numerator.toUsize() >= index) return false;
                    if (binary.denominator.toUsize() >= index) return false;
                },
                .power => |power| if (power.base.toUsize() >= index) return false,
                else => {},
            }
        }
        return self.root.toUsize() < self.values.len;
    }

    pub fn write(self: *const Expression, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.writeValue(self.root, writer, 0);
    }

    fn writeValue(
        self: *const Expression,
        id: ValueId,
        writer: *std.Io.Writer,
        depth: usize,
    ) std.Io.Writer.Error!void {
        std.debug.assert(depth <= self.values.len);
        switch (self.value(id).node) {
            .rational => |rational| try writeRational(rational, writer),
            .parameter => |parameter| try writer.writeAll(parameter.name),
            .pi => try writer.writeAll("pi"),
            .sqrt_rational => |rational| {
                try writer.writeAll("sqrt(");
                try writeRational(rational, writer);
                try writer.writeByte(')');
            },
            .negate => |child| {
                try writer.writeAll("(- ");
                try self.writeValue(child, writer, depth + 1);
                try writer.writeByte(')');
            },
            .add => |children| try self.writeList("+", children, writer, depth),
            .multiply => |children| try self.writeList("*", children, writer, depth),
            .divide => |binary| {
                try writer.writeAll("(/ ");
                try self.writeValue(binary.numerator, writer, depth + 1);
                try writer.writeByte(' ');
                try self.writeValue(binary.denominator, writer, depth + 1);
                try writer.writeByte(')');
            },
            .power => |power| {
                try writer.writeAll("(^ ");
                try self.writeValue(power.base, writer, depth + 1);
                try writer.print(" {d})", .{power.exponent});
            },
        }
    }

    fn writeList(
        self: *const Expression,
        operator: []const u8,
        children: []const ValueId,
        writer: *std.Io.Writer,
        depth: usize,
    ) std.Io.Writer.Error!void {
        try writer.writeByte('(');
        try writer.writeAll(operator);
        for (children) |child| {
            try writer.writeByte(' ');
            try self.writeValue(child, writer, depth + 1);
        }
        try writer.writeByte(')');
    }
};

const Rpn = union(enum) {
    integer: []const u8,
    identifier: []const u8,
    pi,
    negate,
    add,
    subtract,
    multiply,
    divide,
    sqrt,
    power: u32,
};

const Operator = enum {
    left_parenthesis,
    sqrt,
    negate,
    add,
    subtract,
    multiply,
    divide,
};

const StackValue = struct {
    id: ValueId,
    dimension: i32,
    constant: ?*MutableRational,
};

pub fn parse(
    allocator: std.mem.Allocator,
    source_id: foundation.SourceId,
    source: []const u8,
    parameters: []const Parameter,
    options: ParseOptions,
) anyerror!ParseResult {
    if (source.len > options.limits.expression_bytes) {
        return .{ .failure = failureAt(
            .expression_too_large,
            source_id,
            source.len,
            0,
            source.len,
        ) };
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const local = arena.allocator();

    const rpn_result = try toRpn(local, source_id, source, options.limits);
    const rpn = switch (rpn_result) {
        .items => |items| items,
        .failure => |failure| {
            arena.deinit();
            allocator.destroy(arena);
            return .{ .failure = failure };
        },
    };

    const evaluated = try evaluate(
        local,
        source_id,
        source,
        rpn,
        parameters,
        options,
    );
    switch (evaluated) {
        .failure => |failure| {
            arena.deinit();
            allocator.destroy(arena);
            return .{ .failure = failure };
        },
        .complete => |complete| {
            const values = try local.dupe(Value, complete.values);
            const expression = Expression{
                .arena = arena,
                .values = values,
                .root = complete.root,
            };
            std.debug.assert(expression.audit());
            return .{ .expression = expression };
        },
    }
}

const RpnResult = union(enum) {
    items: []const Rpn,
    failure: Failure,
};

fn toRpn(
    allocator: std.mem.Allocator,
    source_id: foundation.SourceId,
    source: []const u8,
    limits: model_limits.ModelLimits,
) !RpnResult {
    var output: std.ArrayList(Rpn) = .empty;
    var operators: std.ArrayList(Operator) = .empty;
    var positions: std.ArrayList(usize) = .empty;
    var cursor: usize = 0;
    var token_count: usize = 0;
    var depth: usize = 0;
    var expect_operand = true;
    var last_was_power = false;

    while (true) {
        while (cursor < source.len and isWhitespace(source[cursor])) cursor += 1;
        if (cursor == source.len) break;
        const start = cursor;
        token_count += 1;
        if (token_count > limits.expression_tokens) {
            return .{ .failure = failureAt(
                .too_many_tokens,
                source_id,
                source.len,
                start,
                start + 1,
            ) };
        }

        const byte = source[cursor];
        if (std.ascii.isDigit(byte)) {
            if (!expect_operand) {
                return .{ .failure = failureAt(
                    .missing_operator,
                    source_id,
                    source.len,
                    start,
                    start + 1,
                ) };
            }
            cursor += 1;
            while (cursor < source.len and std.ascii.isDigit(source[cursor])) cursor += 1;
            const digits = source[start..cursor];
            if (digits.len > 1 and digits[0] == '0') {
                return .{ .failure = failureAt(
                    .invalid_token,
                    source_id,
                    source.len,
                    start,
                    cursor,
                ) };
            }
            if (digits.len > limits.integer_digits) {
                return .{ .failure = failureAt(
                    .integer_too_large,
                    source_id,
                    source.len,
                    start,
                    cursor,
                ) };
            }
            try output.append(allocator, .{ .integer = digits });
            expect_operand = false;
            last_was_power = false;
            continue;
        }

        if (std.ascii.isAlphabetic(byte) or byte == '_') {
            if (!expect_operand) {
                return .{ .failure = failureAt(
                    .missing_operator,
                    source_id,
                    source.len,
                    start,
                    start + 1,
                ) };
            }
            cursor += 1;
            while (cursor < source.len and
                (std.ascii.isAlphanumeric(source[cursor]) or source[cursor] == '_'))
            {
                cursor += 1;
            }
            const identifier = source[start..cursor];
            if (std.mem.eql(u8, identifier, "sqrt")) {
                while (cursor < source.len and isWhitespace(source[cursor])) cursor += 1;
                if (cursor >= source.len or source[cursor] != '(') {
                    return .{ .failure = failureAt(
                        .unexpected_token,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                try operators.append(allocator, .sqrt);
                try positions.append(allocator, start);
                try operators.append(allocator, .left_parenthesis);
                try positions.append(allocator, cursor);
                cursor += 1;
                depth += 1;
                if (depth > limits.expression_depth) {
                    return .{ .failure = failureAt(
                        .nesting_too_deep,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                expect_operand = true;
            } else {
                try output.append(
                    allocator,
                    if (std.mem.eql(u8, identifier, "pi"))
                        .pi
                    else
                        .{ .identifier = identifier },
                );
                expect_operand = false;
            }
            last_was_power = false;
            continue;
        }

        cursor += 1;
        switch (byte) {
            '(' => {
                if (!expect_operand) {
                    return .{ .failure = failureAt(
                        .missing_operator,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                try operators.append(allocator, .left_parenthesis);
                try positions.append(allocator, start);
                depth += 1;
                if (depth > limits.expression_depth) {
                    return .{ .failure = failureAt(
                        .nesting_too_deep,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                expect_operand = true;
                last_was_power = false;
            },
            ')' => {
                if (expect_operand) {
                    return .{ .failure = failureAt(
                        .missing_operand,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                var found = false;
                while (operators.items.len != 0) {
                    const op = operators.pop().?;
                    _ = positions.pop();
                    if (op == .left_parenthesis) {
                        found = true;
                        break;
                    }
                    try appendOperator(allocator, &output, op);
                }
                if (!found) {
                    return .{ .failure = failureAt(
                        .unmatched_parenthesis,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                depth -= 1;
                if (operators.items.len != 0 and operators.items[operators.items.len - 1] == .sqrt) {
                    _ = operators.pop();
                    _ = positions.pop();
                    try output.append(allocator, .sqrt);
                }
                expect_operand = false;
                last_was_power = false;
            },
            '+', '-' => {
                if (expect_operand) {
                    if (byte == '-') {
                        try pushOperator(
                            allocator,
                            &output,
                            &operators,
                            &positions,
                            .negate,
                            start,
                        );
                    }
                } else {
                    try pushOperator(
                        allocator,
                        &output,
                        &operators,
                        &positions,
                        if (byte == '+') .add else .subtract,
                        start,
                    );
                    expect_operand = true;
                }
                last_was_power = false;
            },
            '*', '/' => {
                if (expect_operand) {
                    return .{ .failure = failureAt(
                        .missing_operand,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                try pushOperator(
                    allocator,
                    &output,
                    &operators,
                    &positions,
                    if (byte == '*') .multiply else .divide,
                    start,
                );
                expect_operand = true;
                last_was_power = false;
            },
            '^' => {
                if (expect_operand or last_was_power) {
                    return .{ .failure = failureAt(
                        .unexpected_token,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                while (cursor < source.len and isWhitespace(source[cursor])) cursor += 1;
                const exponent_start = cursor;
                while (cursor < source.len and std.ascii.isDigit(source[cursor])) cursor += 1;
                if (cursor == exponent_start) {
                    return .{ .failure = failureAt(
                        .unexpected_token,
                        source_id,
                        source.len,
                        start,
                        cursor,
                    ) };
                }
                const exponent = std.fmt.parseInt(
                    u32,
                    source[exponent_start..cursor],
                    10,
                ) catch {
                    return .{ .failure = failureAt(
                        .exponent_too_large,
                        source_id,
                        source.len,
                        exponent_start,
                        cursor,
                    ) };
                };
                if (exponent > limits.exponent_magnitude) {
                    return .{ .failure = failureAt(
                        .exponent_too_large,
                        source_id,
                        source.len,
                        exponent_start,
                        cursor,
                    ) };
                }
                try output.append(allocator, .{ .power = exponent });
                expect_operand = false;
                last_was_power = true;
            },
            else => return .{ .failure = failureAt(
                .invalid_token,
                source_id,
                source.len,
                start,
                cursor,
            ) },
        }
    }

    if (expect_operand) {
        return .{ .failure = failureAt(
            .missing_operand,
            source_id,
            source.len,
            source.len,
            source.len,
        ) };
    }
    while (operators.items.len != 0) {
        const op = operators.pop().?;
        const position = positions.pop().?;
        if (op == .left_parenthesis or op == .sqrt) {
            return .{ .failure = failureAt(
                .unmatched_parenthesis,
                source_id,
                source.len,
                position,
                position + 1,
            ) };
        }
        try appendOperator(allocator, &output, op);
    }
    return .{ .items = output.items };
}

fn pushOperator(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(Rpn),
    operators: *std.ArrayList(Operator),
    positions: *std.ArrayList(usize),
    incoming: Operator,
    position: usize,
) !void {
    while (operators.items.len != 0) {
        const top = operators.items[operators.items.len - 1];
        if (top == .left_parenthesis or top == .sqrt) break;
        if (precedence(top) < precedence(incoming)) break;
        _ = operators.pop();
        _ = positions.pop();
        try appendOperator(allocator, output, top);
    }
    try operators.append(allocator, incoming);
    try positions.append(allocator, position);
}

fn appendOperator(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(Rpn),
    operator: Operator,
) !void {
    try output.append(allocator, switch (operator) {
        .negate => .negate,
        .add => .add,
        .subtract => .subtract,
        .multiply => .multiply,
        .divide => .divide,
        .sqrt => .sqrt,
        .left_parenthesis => unreachable,
    });
}

fn precedence(operator: Operator) u8 {
    return switch (operator) {
        .add, .subtract => 1,
        .multiply, .divide => 2,
        .negate => 3,
        .sqrt => 4,
        .left_parenthesis => 0,
    };
}

const Evaluated = union(enum) {
    complete: struct {
        values: []const Value,
        root: ValueId,
    },
    failure: Failure,
};

fn evaluate(
    allocator: std.mem.Allocator,
    source_id: foundation.SourceId,
    source: []const u8,
    rpn: []const Rpn,
    parameters: []const Parameter,
    options: ParseOptions,
) !Evaluated {
    var values: std.ArrayList(Value) = .empty;
    var stack: std.ArrayList(StackValue) = .empty;

    for (rpn) |item| {
        if (values.items.len >= options.limits.expression_nodes) {
            return .{ .failure = failureAt(
                .too_many_nodes,
                source_id,
                source.len,
                0,
                source.len,
            ) };
        }
        switch (item) {
            .integer => |digits| {
                const rational = try allocator.create(MutableRational);
                rational.* = try MutableRational.initInteger(allocator, digits);
                if (rational.bitCount() > options.limits.exact_integer_bits) {
                    return .{ .failure = failureAt(
                        .exact_value_too_large,
                        source_id,
                        source.len,
                        0,
                        source.len,
                    ) };
                }
                const id = try appendRational(allocator, &values, rational);
                try stack.append(allocator, .{
                    .id = id,
                    .dimension = 0,
                    .constant = rational,
                });
            },
            .identifier => |identifier| {
                const parameter = findParameter(parameters, identifier) orelse {
                    return .{ .failure = failureAt(
                        .unknown_parameter,
                        source_id,
                        source.len,
                        0,
                        source.len,
                    ) };
                };
                const id = try appendValue(allocator, &values, .{
                    .node = .{ .parameter = .{
                        .id = parameter.id,
                        .name = try allocator.dupe(u8, parameter.name),
                    } },
                    .mass_dimension = parameter.mass_dimension,
                });
                try stack.append(allocator, .{
                    .id = id,
                    .dimension = parameter.mass_dimension,
                    .constant = null,
                });
            },
            .pi => {
                const id = try appendValue(allocator, &values, .{
                    .node = .pi,
                    .mass_dimension = 0,
                });
                try stack.append(allocator, .{
                    .id = id,
                    .dimension = 0,
                    .constant = null,
                });
            },
            .negate => {
                var operand = stack.pop() orelse return .{ .failure = failureAt(
                    .missing_operand,
                    source_id,
                    source.len,
                    0,
                    source.len,
                ) };
                if (operand.constant) |constant| {
                    constant.negate();
                    operand.id = try appendRational(allocator, &values, constant);
                } else {
                    operand.id = switch (values.items[operand.id.toUsize()].node) {
                        .negate => |child| child,
                        else => try appendValue(allocator, &values, .{
                            .node = .{ .negate = operand.id },
                            .mass_dimension = operand.dimension,
                        }),
                    };
                }
                try stack.append(allocator, operand);
            },
            .sqrt => {
                const operand = stack.pop() orelse return .{ .failure = failureAt(
                    .missing_operand,
                    source_id,
                    source.len,
                    0,
                    source.len,
                ) };
                const constant = operand.constant orelse return .{ .failure = failureAt(
                    .invalid_square_root,
                    source_id,
                    source.len,
                    0,
                    source.len,
                ) };
                if (operand.dimension != 0 or !constant.isPositive()) {
                    return .{ .failure = failureAt(
                        .invalid_square_root,
                        source_id,
                        source.len,
                        0,
                        source.len,
                    ) };
                }
                if (try constant.perfectSquareRoot(allocator)) |root| {
                    const stored = try allocator.create(MutableRational);
                    stored.* = root;
                    const id = try appendRational(allocator, &values, stored);
                    try stack.append(allocator, .{
                        .id = id,
                        .dimension = 0,
                        .constant = stored,
                    });
                } else {
                    const id = try appendValue(allocator, &values, .{
                        .node = .{ .sqrt_rational = try constant.publish(allocator) },
                        .mass_dimension = 0,
                    });
                    try stack.append(allocator, .{
                        .id = id,
                        .dimension = 0,
                        .constant = null,
                    });
                }
            },
            .power => |exponent| {
                const operand = stack.pop() orelse return .{ .failure = failureAt(
                    .missing_operand,
                    source_id,
                    source.len,
                    0,
                    source.len,
                ) };
                const dimension = std.math.mul(
                    i32,
                    operand.dimension,
                    @as(i32, @intCast(exponent)),
                ) catch return .{ .failure = failureAt(
                    .dimension_overflow,
                    source_id,
                    source.len,
                    0,
                    source.len,
                ) };
                if (operand.constant) |constant| {
                    const powered = try allocator.create(MutableRational);
                    powered.* = try MutableRational.power(allocator, constant, exponent);
                    if (powered.bitCount() > options.limits.exact_integer_bits) {
                        return .{ .failure = failureAt(
                            .exact_value_too_large,
                            source_id,
                            source.len,
                            0,
                            source.len,
                        ) };
                    }
                    const id = try appendRational(allocator, &values, powered);
                    try stack.append(allocator, .{
                        .id = id,
                        .dimension = dimension,
                        .constant = powered,
                    });
                } else {
                    const id = if (exponent == 1)
                        operand.id
                    else
                        try appendValue(allocator, &values, .{
                            .node = .{ .power = .{
                                .base = operand.id,
                                .exponent = exponent,
                            } },
                            .mass_dimension = dimension,
                        });
                    try stack.append(allocator, .{
                        .id = id,
                        .dimension = dimension,
                        .constant = null,
                    });
                }
            },
            .add, .subtract, .multiply, .divide => {
                const rhs = stack.pop() orelse return .{ .failure = failureAt(
                    .missing_operand,
                    source_id,
                    source.len,
                    0,
                    source.len,
                ) };
                const lhs = stack.pop() orelse return .{ .failure = failureAt(
                    .missing_operand,
                    source_id,
                    source.len,
                    0,
                    source.len,
                ) };
                if ((item == .add or item == .subtract) and lhs.dimension != rhs.dimension) {
                    return .{ .failure = failureAt(
                        .dimension_mismatch,
                        source_id,
                        source.len,
                        0,
                        source.len,
                    ) };
                }
                if (item == .divide and rhs.constant != null and rhs.constant.?.isZero()) {
                    return .{ .failure = failureAt(
                        .division_by_zero,
                        source_id,
                        source.len,
                        0,
                        source.len,
                    ) };
                }
                const combined = try combine(
                    allocator,
                    &values,
                    lhs,
                    rhs,
                    item,
                    options.limits,
                ) orelse return .{ .failure = failureAt(
                    .exact_value_too_large,
                    source_id,
                    source.len,
                    0,
                    source.len,
                ) };
                try stack.append(allocator, combined);
            },
        }
    }

    if (stack.items.len != 1) {
        return .{ .failure = failureAt(
            .missing_operator,
            source_id,
            source.len,
            0,
            source.len,
        ) };
    }
    const root = stack.items[0];
    if (options.required_dimension) |required| {
        if (root.dimension != required) {
            var failure = failureAt(
                .dimension_mismatch,
                source_id,
                source.len,
                0,
                source.len,
            );
            failure.expected_dimension = required;
            failure.actual_dimension = root.dimension;
            return .{ .failure = failure };
        }
    }
    return .{ .complete = .{ .values = values.items, .root = root.id } };
}

fn combine(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(Value),
    lhs: StackValue,
    rhs: StackValue,
    operation: Rpn,
    limits: model_limits.ModelLimits,
) !?StackValue {
    if ((operation == .add or operation == .subtract) and lhs.dimension != rhs.dimension) {
        return null;
    }
    if (operation == .divide and rhs.constant != null and rhs.constant.?.isZero()) {
        return null;
    }

    const dimension = switch (operation) {
        .add, .subtract => lhs.dimension,
        .multiply => std.math.add(i32, lhs.dimension, rhs.dimension) catch return null,
        .divide => std.math.sub(i32, lhs.dimension, rhs.dimension) catch return null,
        else => unreachable,
    };

    if (lhs.constant != null and rhs.constant != null) {
        const result = try allocator.create(MutableRational);
        result.* = switch (operation) {
            .add => try MutableRational.add(allocator, lhs.constant.?, rhs.constant.?),
            .subtract => try MutableRational.subtract(allocator, lhs.constant.?, rhs.constant.?),
            .multiply => try MutableRational.multiply(allocator, lhs.constant.?, rhs.constant.?),
            .divide => try MutableRational.divide(allocator, lhs.constant.?, rhs.constant.?),
            else => unreachable,
        };
        if (result.bitCount() > limits.exact_integer_bits) return null;
        return .{
            .id = try appendRational(allocator, values, result),
            .dimension = dimension,
            .constant = result,
        };
    }

    const id = switch (operation) {
        .add => try appendAssociative(allocator, values, .add, lhs.id, rhs.id, dimension),
        .subtract => blk: {
            const negated = try appendValue(allocator, values, .{
                .node = .{ .negate = rhs.id },
                .mass_dimension = rhs.dimension,
            });
            break :blk try appendAssociative(
                allocator,
                values,
                .add,
                lhs.id,
                negated,
                dimension,
            );
        },
        .multiply => try appendAssociative(
            allocator,
            values,
            .multiply,
            lhs.id,
            rhs.id,
            dimension,
        ),
        .divide => try appendValue(allocator, values, .{
            .node = .{ .divide = .{
                .numerator = lhs.id,
                .denominator = rhs.id,
            } },
            .mass_dimension = dimension,
        }),
        else => unreachable,
    };
    return .{ .id = id, .dimension = dimension, .constant = null };
}

fn appendAssociative(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(Value),
    comptime tag: std.meta.Tag(Node),
    lhs: ValueId,
    rhs: ValueId,
    dimension: i32,
) !ValueId {
    const lhs_children: []const ValueId = switch (values.items[lhs.toUsize()].node) {
        tag => |children| children,
        else => &.{lhs},
    };
    const rhs_children: []const ValueId = switch (values.items[rhs.toUsize()].node) {
        tag => |children| children,
        else => &.{rhs},
    };
    const children = try allocator.alloc(ValueId, lhs_children.len + rhs_children.len);
    @memcpy(children[0..lhs_children.len], lhs_children);
    @memcpy(children[lhs_children.len..], rhs_children);
    return appendValue(allocator, values, .{
        .node = @unionInit(Node, @tagName(tag), children),
        .mass_dimension = dimension,
    });
}

fn appendRational(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(Value),
    rational: *const MutableRational,
) !ValueId {
    return appendValue(allocator, values, .{
        .node = .{ .rational = try rational.publish(allocator) },
        .mass_dimension = 0,
    });
}

fn appendValue(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(Value),
    value: Value,
) !ValueId {
    for (values.items, 0..) |existing, index| {
        if (existing.mass_dimension == value.mass_dimension and
            nodeEqual(existing.node, value.node))
        {
            return ValueId.fromUsize(index);
        }
    }
    const id = try ValueId.fromUsize(values.items.len);
    try values.append(allocator, value);
    return id;
}

fn nodeEqual(lhs: Node, rhs: Node) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .rational => |left| switch (rhs) {
            .rational => |right| rationalEqual(left, right),
            else => unreachable,
        },
        .parameter => |left| switch (rhs) {
            .parameter => |right| left.id == right.id and
                std.mem.eql(u8, left.name, right.name),
            else => unreachable,
        },
        .pi => true,
        .sqrt_rational => |left| switch (rhs) {
            .sqrt_rational => |right| rationalEqual(left, right),
            else => unreachable,
        },
        .negate => |left| switch (rhs) {
            .negate => |right| left == right,
            else => unreachable,
        },
        .add => |left| switch (rhs) {
            .add => |right| std.mem.eql(ValueId, left, right),
            else => unreachable,
        },
        .multiply => |left| switch (rhs) {
            .multiply => |right| std.mem.eql(ValueId, left, right),
            else => unreachable,
        },
        .divide => |left| switch (rhs) {
            .divide => |right| left.numerator == right.numerator and
                left.denominator == right.denominator,
            else => unreachable,
        },
        .power => |left| switch (rhs) {
            .power => |right| left.base == right.base and
                left.exponent == right.exponent,
            else => unreachable,
        },
    };
}

fn rationalEqual(lhs: Rational, rhs: Rational) bool {
    return std.mem.eql(u8, lhs.numerator, rhs.numerator) and
        std.mem.eql(u8, lhs.denominator, rhs.denominator);
}

fn findParameter(parameters: []const Parameter, name: []const u8) ?Parameter {
    for (parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, name)) return parameter;
    }
    return null;
}

fn failureAt(
    kind: FailureKind,
    source_id: foundation.SourceId,
    source_length: usize,
    start: usize,
    end: usize,
) Failure {
    return .{
        .kind = kind,
        .span = foundation.SourceSpan.init(
            source_id,
            source_length,
            start,
            end,
        ) catch unreachable,
    };
}

fn writeRational(rational: Rational, writer: *std.Io.Writer) !void {
    try writer.writeAll(rational.numerator);
    if (!std.mem.eql(u8, rational.denominator, "1")) {
        try writer.writeByte('/');
        try writer.writeAll(rational.denominator);
    }
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

test "expression parsing preserves exact values and precedence" {
    const source_id = try foundation.SourceId.fromUsize(0);
    const result = try parse(
        std.testing.allocator,
        source_id,
        "-2^2 + 1 / 2",
        &.{},
        .{},
    );
    var expression = switch (result) {
        .expression => |expression| expression,
        .failure => return error.TestUnexpectedResult,
    };
    defer expression.deinit();
    const root = expression.value(expression.root);
    const rational = root.node.rational;
    try std.testing.expectEqualStrings("-7", rational.numerator);
    try std.testing.expectEqualStrings("2", rational.denominator);
}

test "expression normalization resolves dimensions and radicals" {
    const source_id = try foundation.SourceId.fromUsize(1);
    const result = try parse(
        std.testing.allocator,
        source_id,
        "sqrt(4 / 9) * m2",
        &.{.{ .name = "m2", .id = 0, .mass_dimension = 2 }},
        .{ .required_dimension = 2 },
    );
    var expression = switch (result) {
        .expression => |expression| expression,
        .failure => return error.TestUnexpectedResult,
    };
    defer expression.deinit();
    try std.testing.expect(expression.audit());
    try std.testing.expectEqual(@as(i32, 2), expression.rootDimension());
}

test "expression parser rejects unknown parameters and bad dimensions" {
    const source_id = try foundation.SourceId.fromUsize(2);
    const unknown = try parse(
        std.testing.allocator,
        source_id,
        "missing",
        &.{},
        .{},
    );
    try std.testing.expectEqual(
        FailureKind.unknown_parameter,
        unknown.failure.kind,
    );

    const dimension = try parse(
        std.testing.allocator,
        source_id,
        "m2 + lambda",
        &.{
            .{ .name = "m2", .id = 0, .mass_dimension = 2 },
            .{ .name = "lambda", .id = 1, .mass_dimension = 0 },
        },
        .{},
    );
    try std.testing.expectEqual(
        FailureKind.dimension_mismatch,
        dimension.failure.kind,
    );
}

test {
    _ = exact;
}
