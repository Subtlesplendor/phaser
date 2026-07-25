const std = @import("std");
const SourceSpan = @import("source.zig").SourceSpan;

pub const Code = enum(u32) {
    invalid_source_span = 0x0001_0001,
    capacity_overflow = 0x0002_0001,
    capacity_exceeded = 0x0002_0002,
    invalid_alignment = 0x0002_0003,
    allocation_failed = 0x0002_0004,
    invalid_limit = 0x0002_0005,
};

pub const Category = enum {
    source,
    capacity,
    allocation,
    configuration,
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
};

pub const LimitName = enum {
    total_memory_bytes,
    max_diagnostics,
    max_related_locations,
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
};

pub const Diagnostic = struct {
    code: Code,
    category: Category,
    severity: Severity = .err,
    primary: ?SourceSpan = null,
    detail: Detail = .none,
    related: []const SourceSpan = &.{},
    cause: ?u32 = null,

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
        }

        if (self.primary) |span| {
            try writer.print(
                " source={d} span=[{d},{d})",
                .{ span.source_id.toU32(), span.start, span.end },
            );
        }
        if (self.cause) |cause| try writer.print(" cause={d}", .{cause});
        try writer.print(" related={d}", .{self.related.len});
    }
};

pub const Template = struct {
    code: Code,
    category: Category,
    severity: Severity = .err,
    primary: ?SourceSpan = null,
    detail: Detail = .none,
    related: []const SourceSpan = &.{},
    cause: ?u32 = null,
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
    related_start: u32,
    related_length: u32,
    cause: ?u32,
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
            std.debug.assert(cause < self.pending.items.len);
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
            .related_start = @intCast(related_start),
            .related_length = @intCast(template.related.len),
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
        "error:capacity:capacity_exceeded resource=workspace_bytes limit=32 current=24 requested=9 related=0",
        output.written(),
    );
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
        .cause = 0,
    });

    var diagnostics = try builder.finish();
    defer diagnostics.deinit();

    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqual(Code.invalid_source_span, diagnostics.items[0].code);
    try std.testing.expectEqual(@as(?u32, 0), diagnostics.items[1].cause);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items[1].related.len);
    try std.testing.expectEqual(@as(u32, 7), diagnostics.items[1].related[0].start);
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
        .cause = 0,
    });

    var diagnostics = try builder.finish();
    defer diagnostics.deinit();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
}
