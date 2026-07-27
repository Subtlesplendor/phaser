const std = @import("std");
const SourceSpan = @import("source.zig").SourceSpan;
const TypedId = @import("typed_id.zig").TypedId;

pub const DiagnosticId = TypedId("diagnostic");

pub const Code = enum(u32) {
    invalid_source_span = 0x0001_0001,
    capacity_overflow = 0x0002_0001,
    capacity_exceeded = 0x0002_0002,
    invalid_alignment = 0x0002_0003,
    allocation_failed = 0x0002_0004,
    invalid_limit = 0x0002_0005,
    invalid_json = 0x0010_0001,
    invalid_model_schema = 0x0010_0002,
    missing_property = 0x0010_0003,
    unknown_property = 0x0010_0004,
    duplicate_property = 0x0010_0005,
    invalid_property_type = 0x0010_0006,
    invalid_identifier = 0x0011_0001,
    reserved_identifier = 0x0011_0002,
    unsupported_sector = 0x0011_0003,
    invalid_convention = 0x0011_0004,
    invalid_expression = 0x0012_0001,
    expression_limit_exceeded = 0x0012_0002,
    unknown_parameter = 0x0012_0003,
    dimension_mismatch = 0x0012_0004,
    static_division_by_zero = 0x0012_0005,
    invalid_square_root = 0x0012_0006,
    exact_value_too_large = 0x0012_0007,
    invalid_tensor_component = 0x0013_0001,
    duplicate_tensor_orbit = 0x0013_0002,
    noncanonical_tensor_indices = 0x0013_0003,
    explicit_zero_component = 0x0013_0004,
    invalid_calculation_schema = 0x0014_0001,
    unsupported_calculation_kind = 0x0014_0002,
    unsupported_environment = 0x0014_0003,
    unsupported_gauge_fixing = 0x0014_0004,
    unsupported_loop_order = 0x0014_0005,
    invalid_background_mode = 0x0014_0006,
    invalid_background_coordinate = 0x0014_0007,
    duplicate_background_coordinate = 0x0014_0008,
    invalid_parameter_point_schema = 0x0015_0001,
    unsupported_mass_unit = 0x0015_0002,
    unsupported_scheme = 0x0015_0003,
    invalid_scale = 0x0015_0004,
    invalid_number = 0x0015_0005,
    number_not_representable = 0x0015_0006,
    missing_parameter_value = 0x0015_0007,
    unknown_parameter_value = 0x0015_0008,
    scheme_mismatch = 0x0015_0009,
};

pub const Category = enum {
    source,
    capacity,
    allocation,
    configuration,
    json,
    expression,
    model,
    calculation,
};

pub const Severity = enum {
    err,
    warning,
    note,
};

pub const Resource = enum {
    source_bytes,
    diagnostic_count,
    related_location_count,
    persistent_bytes,
    scratch_bytes,
    workspace_bytes,
    json_tokens,
    json_nesting,
    parameters,
    real_scalars,
    tensor_components,
    expression_bytes,
    expression_tokens,
    expression_nodes,
    expression_depth,
    integer_digits,
    exponent_magnitude,
    exact_integer_bits,
    value_nodes,
    request_bytes,
    background_coordinates,
    contributions,
    loop_order,
};

pub const LimitName = enum {
    max_diagnostics,
    max_related_locations,
    source_bytes,
    json_nesting,
    json_tokens,
    parameters,
    real_scalars,
    tensor_components,
    expression_bytes,
    expression_tokens,
    expression_nodes,
    expression_depth,
    integer_digits,
    exponent_magnitude,
    exact_integer_bits,
    value_nodes,
    value_operands,
    request_bytes,
    request_json_tokens,
    request_json_nesting,
    background_coordinates,
    contributions,
    significant_digits,
    decimal_exponent,
    scratch_bytes,
    persistent_bytes,
};

pub const Detail = union(enum) {
    none,
    source_span: struct {
        source_length: u64,
        start: u64,
        end: u64,
    },
    capacity: struct {
        resource: Resource,
        limit: usize,
        current: usize,
        requested: usize,
    },
    alignment: struct {
        value: usize,
    },
    allocation: struct {
        resource: Resource,
    },
    invalid_limit: struct {
        name: LimitName,
        value: usize,
    },
    text: struct {
        value: []const u8,
    },
    dimension: struct {
        expected: i32,
        actual: i32,
    },
};

pub const Diagnostic = struct {
    code: Code,
    category: Category,
    severity: Severity = .err,
    primary: ?SourceSpan = null,
    detail: Detail = .none,
    related: []const SourceSpan = &.{},
    cause: ?DiagnosticId = null,

    pub fn render(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "{s}:{s}:{s}",
            .{ severityName(self.severity), @tagName(self.category), @tagName(self.code) },
        );

        switch (self.detail) {
            .none => {},
            .source_span => |detail| try writer.print(
                " source_length={d} start={d} end={d}",
                .{ detail.source_length, detail.start, detail.end },
            ),
            .capacity => |detail| try writer.print(
                " resource={s} limit={d} current={d} requested={d}",
                .{
                    @tagName(detail.resource),
                    detail.limit,
                    detail.current,
                    detail.requested,
                },
            ),
            .alignment => |detail| try writer.print(
                " alignment={d}",
                .{detail.value},
            ),
            .allocation => |detail| try writer.print(
                " resource={s}",
                .{@tagName(detail.resource)},
            ),
            .invalid_limit => |detail| try writer.print(
                " limit={s} value={d}",
                .{ @tagName(detail.name), detail.value },
            ),
            .text => |detail| try writer.print(
                " value={s}",
                .{detail.value},
            ),
            .dimension => |detail| try writer.print(
                " expected={d} actual={d}",
                .{ detail.expected, detail.actual },
            ),
        }

        if (self.primary) |span| {
            try writer.print(
                " source={d} span=[{d},{d})",
                .{ span.source_id.toU32(), span.start, span.end },
            );
        }
        if (self.cause) |cause| {
            try writer.print(" cause={d}", .{cause.toU32()});
        }
        try writer.writeAll(" related=[");
        for (self.related, 0..) |span, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print(
                "source={d} span=[{d},{d})",
                .{ span.source_id.toU32(), span.start, span.end },
            );
        }
        try writer.writeAll("]");
    }
};

pub const Template = struct {
    code: Code,
    category: Category,
    severity: Severity = .err,
    primary: ?SourceSpan = null,
    detail: Detail = .none,
    related: []const SourceSpan = &.{},
    cause: ?DiagnosticId = null,
};

pub fn allocationFailure(resource: Resource) Diagnostic {
    return .{
        .code = .allocation_failed,
        .category = .allocation,
        .detail = .{ .allocation = .{ .resource = resource } },
    };
}

fn severityName(severity: Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
    };
}

const PendingDiagnostic = struct {
    code: Code,
    category: Category,
    severity: Severity,
    primary: ?SourceSpan,
    detail: Detail,
    related_start: usize,
    related_length: usize,
    cause: ?DiagnosticId,
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: []const Diagnostic,
    related_locations: []const SourceSpan,

    pub fn deinit(self: *Diagnostics) void {
        self.allocator.free(self.items);
        self.allocator.free(self.related_locations);
        self.* = undefined;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    max_diagnostics: usize,
    max_related_locations: usize,
    pending: std.ArrayList(PendingDiagnostic) = .empty,
    related: std.ArrayList(SourceSpan) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        max_diagnostics: usize,
        max_related_locations: usize,
    ) Builder {
        return .{
            .allocator = allocator,
            .max_diagnostics = max_diagnostics,
            .max_related_locations = max_related_locations,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.pending.deinit(self.allocator);
        self.related.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Builder, template: Template) error{
        OutOfMemory,
        DiagnosticCapacityExceeded,
        RelatedLocationCapacityExceeded,
        InvalidCause,
    }!void {
        if (self.pending.items.len >= self.max_diagnostics) {
            return error.DiagnosticCapacityExceeded;
        }

        const related_end = std.math.add(
            usize,
            self.related.items.len,
            template.related.len,
        ) catch return error.RelatedLocationCapacityExceeded;
        if (related_end > self.max_related_locations) {
            return error.RelatedLocationCapacityExceeded;
        }
        if (template.cause) |cause| {
            if (cause.toUsize() >= self.pending.items.len) {
                return error.InvalidCause;
            }
        }

        const related_start = self.related.items.len;
        try self.related.appendSlice(self.allocator, template.related);
        errdefer self.related.shrinkRetainingCapacity(related_start);

        try self.pending.append(self.allocator, .{
            .code = template.code,
            .category = template.category,
            .severity = template.severity,
            .primary = template.primary,
            .detail = template.detail,
            .related_start = related_start,
            .related_length = template.related.len,
            .cause = template.cause,
        });
    }

    pub fn finish(self: *Builder) error{OutOfMemory}!Diagnostics {
        const final_items = try self.allocator.alloc(Diagnostic, self.pending.items.len);
        errdefer self.allocator.free(final_items);

        const final_related = try self.allocator.dupe(SourceSpan, self.related.items);
        errdefer self.allocator.free(final_related);

        for (self.pending.items, final_items) |pending, *final| {
            const start: usize = pending.related_start;
            const end = start + pending.related_length;
            final.* = .{
                .code = pending.code,
                .category = pending.category,
                .severity = pending.severity,
                .primary = pending.primary,
                .detail = pending.detail,
                .related = final_related[start..end],
                .cause = pending.cause,
            };
        }

        self.pending.deinit(self.allocator);
        self.related.deinit(self.allocator);
        self.pending = .empty;
        self.related = .empty;

        return .{
            .allocator = self.allocator,
            .items = final_items,
            .related_locations = final_related,
        };
    }
};

test "diagnostic rendering is deterministic and structured" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const diagnostic = Diagnostic{
        .code = .capacity_exceeded,
        .category = .capacity,
        .severity = .err,
        .detail = .{ .capacity = .{
            .resource = .workspace_bytes,
            .limit = 32,
            .current = 24,
            .requested = 9,
        } },
    };
    try diagnostic.render(&output.writer);

    try std.testing.expectEqualStrings(
        "error:capacity:capacity_exceeded resource=workspace_bytes limit=32 current=24 requested=9 related=[]",
        output.written(),
    );
}

test "diagnostic rendering includes primary cause and related locations" {
    const SourceId = @import("typed_id.zig").SourceId;
    const source_id = try SourceId.fromUsize(2);
    const primary = try SourceSpan.init(source_id, 10, 1, 3);
    const first_related = try SourceSpan.init(source_id, 10, 4, 5);
    const second_related = try SourceSpan.init(source_id, 10, 7, 9);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try (Diagnostic{
        .code = .invalid_source_span,
        .category = .source,
        .primary = primary,
        .related = &.{ first_related, second_related },
        .cause = try DiagnosticId.fromUsize(0),
    }).render(&output.writer);

    try std.testing.expectEqualStrings(
        "error:source:invalid_source_span source=2 span=[1,3) cause=0 related=[source=2 span=[4,5),source=2 span=[7,9)]",
        output.written(),
    );

    var different_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer different_output.deinit();
    const different_related = try SourceSpan.init(source_id, 10, 6, 9);
    try (Diagnostic{
        .code = .invalid_source_span,
        .category = .source,
        .primary = primary,
        .related = &.{ first_related, different_related },
        .cause = try DiagnosticId.fromUsize(0),
    }).render(&different_output.writer);
    try std.testing.expect(!std.mem.eql(
        u8,
        output.written(),
        different_output.written(),
    ));
}

test "allocation failure remains available without allocating" {
    const failure = allocationFailure(.persistent_bytes);
    try std.testing.expectEqual(Code.allocation_failed, failure.code);
    try std.testing.expectEqual(
        Resource.persistent_bytes,
        failure.detail.allocation.resource,
    );
}

test "diagnostic builder preserves order causes and related locations" {
    const SourceId = @import("typed_id.zig").SourceId;
    const source_id = try SourceId.fromUsize(0);
    const primary = try SourceSpan.init(source_id, 10, 1, 3);
    const related = try SourceSpan.init(source_id, 10, 7, 8);

    var builder = Builder.init(std.testing.allocator, 4, 4);
    defer builder.deinit();

    try builder.append(.{
        .code = .invalid_source_span,
        .category = .source,
        .primary = primary,
    });
    try builder.append(.{
        .code = .capacity_exceeded,
        .category = .capacity,
        .related = &.{related},
        .cause = try DiagnosticId.fromUsize(0),
    });

    var diagnostics = try builder.finish();
    defer diagnostics.deinit();

    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqual(Code.invalid_source_span, diagnostics.items[0].code);
    try std.testing.expectEqual(
        @as(u32, 0),
        diagnostics.items[1].cause.?.toU32(),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items[1].related.len);
    try std.testing.expectEqual(@as(u32, 7), diagnostics.items[1].related[0].start);
}

test "diagnostic builder rejects invalid causes transactionally" {
    const SourceId = @import("typed_id.zig").SourceId;
    const source_id = try SourceId.fromUsize(0);
    const related = try SourceSpan.init(source_id, 1, 0, 1);

    var builder = Builder.init(std.testing.allocator, 2, 2);
    defer builder.deinit();

    try builder.append(.{
        .code = .invalid_limit,
        .category = .configuration,
    });
    try std.testing.expectError(
        error.InvalidCause,
        builder.append(.{
            .code = .capacity_exceeded,
            .category = .capacity,
            .related = &.{related},
            .cause = try DiagnosticId.fromUsize(1),
        }),
    );
    try std.testing.expectError(
        error.InvalidCause,
        builder.append(.{
            .code = .capacity_exceeded,
            .category = .capacity,
            .related = &.{related},
            .cause = try DiagnosticId.fromU64(std.math.maxInt(u32)),
        }),
    );

    try std.testing.expectEqual(@as(usize, 1), builder.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), builder.related.items.len);

    var diagnostics = try builder.finish();
    defer diagnostics.deinit();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "diagnostic builder capacity failures preserve prior entries" {
    const SourceId = @import("typed_id.zig").SourceId;
    const source_id = try SourceId.fromUsize(0);
    const related = try SourceSpan.init(source_id, 1, 0, 1);

    var builder = Builder.init(std.testing.allocator, 1, 0);
    defer builder.deinit();

    try builder.append(.{
        .code = .invalid_limit,
        .category = .configuration,
    });
    try std.testing.expectError(
        error.DiagnosticCapacityExceeded,
        builder.append(.{
            .code = .capacity_exceeded,
            .category = .capacity,
        }),
    );

    var diagnostics = try builder.finish();
    defer diagnostics.deinit();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);

    var related_builder = Builder.init(std.testing.allocator, 1, 0);
    defer related_builder.deinit();
    try std.testing.expectError(
        error.RelatedLocationCapacityExceeded,
        related_builder.append(.{
            .code = .invalid_source_span,
            .category = .source,
            .related = &.{related},
        }),
    );
    var empty = try related_builder.finish();
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "diagnostic construction handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildDiagnosticSet,
        .{},
    );
}

fn buildDiagnosticSet(allocator: std.mem.Allocator) !void {
    var builder = Builder.init(allocator, 4, 4);
    defer builder.deinit();

    try builder.append(.{
        .code = .allocation_failed,
        .category = .allocation,
        .detail = .{ .allocation = .{ .resource = .persistent_bytes } },
    });
    try builder.append(.{
        .code = .capacity_exceeded,
        .category = .capacity,
        .cause = try DiagnosticId.fromUsize(0),
    });

    var diagnostics = try builder.finish();
    defer diagnostics.deinit();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
}
