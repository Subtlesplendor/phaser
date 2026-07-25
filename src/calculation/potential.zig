//! Classical scalar potential derivation.
//!
//! Derives the tree-level effective-potential artifact specified in
//! `docs/calculations/CLASSICAL_SCALAR_POTENTIAL.md` by applying a validated
//! request to a canonical model.

const std = @import("std");
const foundation = @import("../foundation/root.zig");
const model_module = @import("../model/root.zig");
const value = @import("../value/root.zig");
const request_module = @import("request.zig");
const limits_module = @import("limits.zig");

const TensorKind = model_module.TensorKind;

/// Milestone 2 supports four-dimensional models only, which the model loader
/// enforces. A real scalar there has mass dimension (D - 2) / 2 = 1.
pub const scalar_mass_dimension: i32 = 1;

/// The potential density has mass dimension equal to the spacetime dimension.
pub const potential_mass_dimension: i32 = 4;

pub const Role = enum {
    vacuum_energy,
    scalar_tadpole,
    scalar_mass_squared,
    scalar_cubic,
    scalar_quartic,

    fn fromTensor(kind: TensorKind) Role {
        return switch (kind) {
            .vacuum_energy => .vacuum_energy,
            .scalar_tadpole => .scalar_tadpole,
            .scalar_mass_squared => .scalar_mass_squared,
            .scalar_cubic => .scalar_cubic,
            .scalar_quartic => .scalar_quartic,
        };
    }
};

pub const Coordinate = struct {
    id: []const u8,
    scalar_index: u32,
    mass_dimension: i32,
    node: value.ValueId,
};

pub const Contribution = struct {
    value: value.ValueId,
    loop_order: u32,
    role: Role,
    depends_on_background: bool,
};

pub const AbsenceReason = enum {
    /// The model declares no tensor of this kind.
    tensor_absent,
    /// Every stored component contains a scalar whose background is fixed
    /// exactly to zero by the selected component slice.
    vanishes_on_slice,
};

pub const StructuralAbsence = struct {
    role: Role,
    reason: AbsenceReason,
};

pub const Derivatives = enum { none, gradient, gradient_hessian };

pub const DeriveOptions = struct {
    value_limits: value.ValueLimits = .{},
    limits: limits_module.CalculationLimits = .{},
    derivatives: Derivatives = .gradient_hessian,
    audit: bool = false,
};

pub const DeriveError = error{
    OutOfMemory,
    DiagnosticCapacityExceeded,
    RelatedLocationCapacityExceeded,
};

pub const DeriveResult = union(enum) {
    artifact: Artifact,
    diagnostics: foundation.Diagnostics,
};

pub const Artifact = struct {
    arena: *std.heap.ArenaAllocator,
    graph: value.Graph,
    model_fingerprint: model_module.ModelFingerprint,
    request_fingerprint: request_module.Fingerprint,
    background_mode: request_module.BackgroundMode,
    scheme: ?request_module.Scheme,
    coordinates: []const Coordinate,
    contributions: []const Contribution,
    absences: []const StructuralAbsence,
    total: value.ValueId,
    gradient: []const value.ValueId,
    hessian: []const value.ValueId,

    pub fn deinit(self: *Artifact) void {
        const allocator = self.arena.child_allocator;
        self.graph.deinit();
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn coordinateCount(self: *const Artifact) usize {
        return self.coordinates.len;
    }

    /// Contributions at exactly one loop order, in canonical order.
    ///
    /// Milestone 2 derives loop order zero only, so this is the whole list for
    /// order zero and empty otherwise.
    pub fn selectLoopOrder(
        self: *const Artifact,
        loop_order: u32,
        out: []Contribution,
    ) usize {
        var count: usize = 0;
        for (self.contributions) |item| {
            if (item.loop_order != loop_order) continue;
            if (count < out.len) out[count] = item;
            count += 1;
        }
        return count;
    }

    pub fn absence(self: *const Artifact, role: Role) ?StructuralAbsence {
        for (self.absences) |item| {
            if (item.role == role) return item;
        }
        return null;
    }

    pub fn contribution(self: *const Artifact, role: Role) ?Contribution {
        for (self.contributions) |item| {
            if (item.role == role) return item;
        }
        return null;
    }

    /// Structural invariants that construction promises.
    pub fn audit(self: *const Artifact) bool {
        if (!self.graph.audit()) return false;
        if (self.graph.massDimension(self.total) != potential_mass_dimension) return false;

        var previous: ?Role = null;
        for (self.contributions) |item| {
            if (item.loop_order != 0) return false;
            if (self.graph.massDimension(item.value) != potential_mass_dimension) {
                return false;
            }
            if (previous) |earlier| {
                if (@intFromEnum(earlier) >= @intFromEnum(item.role)) return false;
            }
            previous = item.role;
        }

        // A role is either derived or recorded absent, never both and never
        // silently missing.
        for (std.meta.tags(Role)) |role| {
            const derived = self.contribution(role) != null;
            const absent = self.absence(role) != null;
            if (derived == absent) return false;
        }

        for (self.gradient) |slot| {
            if (self.graph.massDimension(slot) !=
                potential_mass_dimension - scalar_mass_dimension) return false;
        }
        for (self.hessian) |slot| {
            if (self.graph.massDimension(slot) !=
                potential_mass_dimension - 2 * scalar_mass_dimension) return false;
        }
        return true;
    }

    pub fn writeInspection(
        self: *const Artifact,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("calculation classical_scalar_potential\n");
        try writer.writeAll("model_fingerprint ");
        try self.model_fingerprint.format(writer);
        try writer.writeAll("\nrequest_fingerprint ");
        try self.request_fingerprint.format(writer);
        try writer.print("\nbackground {s}\n", .{@tagName(self.background_mode)});
        for (self.coordinates, 0..) |coordinate, index| {
            try writer.print(
                "  {d} {s} scalar={d} dimension={d}\n",
                .{ index, coordinate.id, coordinate.scalar_index, coordinate.mass_dimension },
            );
        }
        try writer.print("contributions {d}\n", .{self.contributions.len});
        for (self.contributions) |item| {
            try writer.print(
                "  {s} loop_order={d} background_dependent={}\n",
                .{ @tagName(item.role), item.loop_order, item.depends_on_background },
            );
        }
        try writer.print("structural_absences {d}\n", .{self.absences.len});
        for (self.absences) |item| {
            try writer.print(
                "  {s} {s}\n",
                .{ @tagName(item.role), @tagName(item.reason) },
            );
        }
    }
};

pub fn deriveClassicalPotential(
    context: foundation.Context,
    source_model: *const model_module.Model,
    request: *const request_module.Request,
    options: DeriveOptions,
) DeriveError!DeriveResult {
    if (options.limits.validate()) |diagnostic| {
        return .{ .diagnostics = try oneDiagnostic(context, diagnostic) };
    }
    if (request.loop_order != 0) {
        return .{ .diagnostics = try codeDiagnostic(context, .unsupported_loop_order) };
    }

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    errdefer context.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer arena.deinit();

    var builder = try value.Builder.init(context.allocator, options.value_limits);
    var builder_live = true;
    errdefer if (builder_live) builder.deinit();

    const resolved = resolveCoordinates(
        arena.allocator(),
        source_model,
        request,
        &builder,
        options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownScalar => {
            builder.deinit();
            builder_live = false;
            arena.deinit();
            context.allocator.destroy(arena);
            return .{ .diagnostics = try codeDiagnostic(
                context,
                .invalid_background_coordinate,
            ) };
        },
        error.CapacityExceeded => {
            builder.deinit();
            builder_live = false;
            arena.deinit();
            context.allocator.destroy(arena);
            return .{ .diagnostics = try codeDiagnostic(context, .capacity_exceeded) };
        },
        else => {
            builder.deinit();
            builder_live = false;
            arena.deinit();
            context.allocator.destroy(arena);
            return .{ .diagnostics = try codeDiagnostic(context, .capacity_exceeded) };
        },
    };

    const derived = deriveContributions(
        arena.allocator(),
        source_model,
        resolved,
        &builder,
        options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            builder.deinit();
            builder_live = false;
            arena.deinit();
            context.allocator.destroy(arena);
            return .{ .diagnostics = try codeDiagnostic(context, .capacity_exceeded) };
        },
    };

    var graph = try builder.finish();
    builder_live = false;
    errdefer graph.deinit();

    const request_fingerprint = request.fingerprint(context.allocator) catch
        return error.OutOfMemory;

    var artifact = Artifact{
        .arena = arena,
        .graph = graph,
        .model_fingerprint = source_model.fingerprint(),
        .request_fingerprint = request_fingerprint,
        .background_mode = request.background_mode,
        .scheme = request.scheme,
        .coordinates = resolved,
        .contributions = derived.contributions,
        .absences = derived.absences,
        .total = derived.total,
        .gradient = derived.gradient,
        .hessian = derived.hessian,
    };
    if (options.audit and !artifact.audit()) @panic("classical potential audit failed");
    std.debug.assert(artifact.audit());
    return .{ .artifact = artifact };
}

const ResolveError = error{ OutOfMemory, UnknownScalar, CapacityExceeded } ||
    value.BuildError;

fn resolveCoordinates(
    allocator: std.mem.Allocator,
    source_model: *const model_module.Model,
    request: *const request_module.Request,
    builder: *value.Builder,
    options: DeriveOptions,
) ResolveError![]const Coordinate {
    const count = switch (request.background_mode) {
        .full_scalar_space => source_model.real_scalars.len,
        .component_slice => request.coordinates.len,
    };
    if (count > options.limits.background_coordinates) return error.CapacityExceeded;

    const coordinates = try allocator.alloc(Coordinate, count);
    switch (request.background_mode) {
        // Coordinate order is the model's real-scalar order and the embedding
        // is the identity.
        .full_scalar_space => {
            for (source_model.real_scalars, coordinates, 0..) |field, *coordinate, index| {
                coordinate.* = .{
                    .id = try allocator.dupe(u8, field.name),
                    .scalar_index = @intCast(index),
                    .mass_dimension = scalar_mass_dimension,
                    .node = try builder.background(
                        @intCast(index),
                        field.name,
                        scalar_mass_dimension,
                    ),
                };
            }
        },
        // Declared array order defines canonical coordinate order.
        .component_slice => {
            for (request.coordinates, coordinates, 0..) |declared, *coordinate, index| {
                const scalar_index = findScalar(source_model, declared.scalar) orelse
                    return error.UnknownScalar;
                coordinate.* = .{
                    .id = try allocator.dupe(u8, declared.id),
                    .scalar_index = scalar_index,
                    .mass_dimension = scalar_mass_dimension,
                    .node = try builder.background(
                        @intCast(index),
                        declared.id,
                        scalar_mass_dimension,
                    ),
                };
            }
        },
    }
    return coordinates;
}

fn findScalar(source_model: *const model_module.Model, name: []const u8) ?u32 {
    for (source_model.real_scalars) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.id;
    }
    return null;
}

const Derived = struct {
    contributions: []const Contribution,
    absences: []const StructuralAbsence,
    total: value.ValueId,
    gradient: []const value.ValueId,
    hessian: []const value.ValueId,
};

fn deriveContributions(
    allocator: std.mem.Allocator,
    source_model: *const model_module.Model,
    coordinates: []const Coordinate,
    builder: *value.Builder,
    options: DeriveOptions,
) !Derived {
    // Inverse embedding: which coordinate, if any, carries each model scalar.
    const selected = try allocator.alloc(?u32, source_model.real_scalars.len);
    @memset(selected, null);
    for (coordinates, 0..) |coordinate, index| {
        selected[coordinate.scalar_index] = @intCast(index);
    }

    var contributions = std.ArrayList(Contribution).empty;
    defer contributions.deinit(builder.allocator);
    var absences = std.ArrayList(StructuralAbsence).empty;
    defer absences.deinit(builder.allocator);
    var terms = std.ArrayList(value.ValueId).empty;
    defer terms.deinit(builder.allocator);

    for (std.meta.tags(TensorKind)) |kind| {
        const role = Role.fromTensor(kind);
        const tensor = source_model.tensor(kind) orelse {
            try absences.append(builder.allocator, .{
                .role = role,
                .reason = .tensor_absent,
            });
            continue;
        };

        terms.clearRetainingCapacity();
        for (tensor.components) |component| {
            const indices = component.indices[0..component.rank];
            if (!allSelected(indices, selected)) continue;

            const imported = try value.importExpression(
                builder,
                &source_model.expressions()[component.expression_index],
            );
            const term = try buildTerm(builder, imported, indices, selected, coordinates);
            try terms.append(builder.allocator, term);
        }

        if (terms.items.len == 0) {
            try absences.append(builder.allocator, .{
                .role = role,
                .reason = .vanishes_on_slice,
            });
            continue;
        }
        if (contributions.items.len >= options.limits.contributions) {
            return error.CapacityExceeded;
        }
        try contributions.append(builder.allocator, .{
            .value = try builder.add(terms.items),
            .loop_order = 0,
            .role = role,
            .depends_on_background = kind.rank() > 0,
        });
    }

    const total = if (contributions.items.len == 0)
        try builder.zero(potential_mass_dimension)
    else blk: {
        terms.clearRetainingCapacity();
        for (contributions.items) |item| {
            try terms.append(builder.allocator, item.value);
        }
        break :blk if (terms.items.len == 1)
            terms.items[0]
        else
            try builder.add(terms.items);
    };

    const count = coordinates.len;
    const gradient = try allocator.alloc(value.ValueId, switch (options.derivatives) {
        .none => 0,
        .gradient, .gradient_hessian => count,
    });
    if (options.derivatives != .none) {
        try value.gradient(builder, total, scalar_mass_dimension, gradient);
    }

    const hessian = try allocator.alloc(value.ValueId, switch (options.derivatives) {
        .none, .gradient => 0,
        .gradient_hessian => count * count,
    });
    if (options.derivatives == .gradient_hessian) {
        try value.hessian(builder, total, scalar_mass_dimension, count, hessian);
    }

    return .{
        .contributions = try allocator.dupe(Contribution, contributions.items),
        .absences = try allocator.dupe(StructuralAbsence, absences.items),
        .total = total,
        .gradient = gradient,
        .hessian = hessian,
    };
}

/// A monomial containing a scalar whose background is fixed exactly to zero is
/// structurally absent, not numerically small.
fn allSelected(indices: []const u32, selected: []const ?u32) bool {
    for (indices) |index| {
        if (selected[index] == null) return false;
    }
    return true;
}

/// Builds one stored component's contribution to the potential.
///
/// The orbit of a stored component holds `r! / prod(m_v!)` index tuples, which
/// against the defining `1 / r!` leaves a monomial coefficient of exactly
/// `1 / prod(m_v!)`.
fn buildTerm(
    builder: *value.Builder,
    expression_root: value.ValueId,
    indices: []const u32,
    selected: []const ?u32,
    coordinates: []const Coordinate,
) !value.ValueId {
    var factors = std.ArrayList(value.ValueId).empty;
    defer factors.deinit(builder.allocator);
    try factors.append(builder.allocator, expression_root);

    var denominator: u64 = 1;
    var start: usize = 0;
    // Stored indices are nondecreasing, so equal indices form one run.
    while (start < indices.len) {
        var end = start + 1;
        while (end < indices.len and indices[end] == indices[start]) end += 1;
        const multiplicity = end - start;
        denominator *= factorial(multiplicity);

        const coordinate = coordinates[selected[indices[start]].?];
        try factors.append(
            builder.allocator,
            try builder.power(coordinate.node, @intCast(multiplicity)),
        );
        start = end;
    }

    const product = try builder.multiply(factors.items);
    if (denominator == 1) return product;
    return builder.divide(product, try builder.integer(@intCast(denominator), 0));
}

fn factorial(value_in: usize) u64 {
    var result: u64 = 1;
    var index: usize = 2;
    while (index <= value_in) : (index += 1) result *= @intCast(index);
    return result;
}

fn codeDiagnostic(
    context: foundation.Context,
    code: foundation.Code,
) DeriveError!foundation.Diagnostics {
    return oneDiagnostic(context, .{ .code = code, .category = .calculation });
}

fn oneDiagnostic(
    context: foundation.Context,
    diagnostic: foundation.Diagnostic,
) DeriveError!foundation.Diagnostics {
    var builder = context.diagnosticBuilder();
    defer builder.deinit();
    builder.append(.{
        .code = diagnostic.code,
        .category = diagnostic.category,
        .severity = diagnostic.severity,
        .primary = diagnostic.primary,
        .detail = diagnostic.detail,
        .related = diagnostic.related,
        .cause = diagnostic.cause,
    }) catch |err| switch (err) {
        error.InvalidCause => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
        error.DiagnosticCapacityExceeded => return error.DiagnosticCapacityExceeded,
        error.RelatedLocationCapacityExceeded => return error.RelatedLocationCapacityExceeded,
    };
    return builder.finish();
}

// -- tests -----------------------------------------------------------------

test "orbit denominators follow the multiplicity rule" {
    // The rank-4 patterns of the multi-scalar fixture, whose fixture numerators
    // 1, 4, 6, 4, 1 are the complementary multinomial coefficients.
    try std.testing.expectEqual(@as(u64, 24), denominatorOf(&.{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 6), denominatorOf(&.{ 0, 0, 0, 1 }));
    try std.testing.expectEqual(@as(u64, 4), denominatorOf(&.{ 0, 0, 1, 1 }));
    try std.testing.expectEqual(@as(u64, 6), denominatorOf(&.{ 0, 1, 1, 1 }));
    try std.testing.expectEqual(@as(u64, 24), denominatorOf(&.{ 1, 1, 1, 1 }));

    // Rank 3 and rank 2.
    try std.testing.expectEqual(@as(u64, 6), denominatorOf(&.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 2), denominatorOf(&.{ 0, 0, 1 }));
    try std.testing.expectEqual(@as(u64, 2), denominatorOf(&.{ 0, 0 }));
    try std.testing.expectEqual(@as(u64, 1), denominatorOf(&.{ 0, 1 }));
    try std.testing.expectEqual(@as(u64, 1), denominatorOf(&.{}));
}

fn denominatorOf(indices: []const u32) u64 {
    var denominator: u64 = 1;
    var start: usize = 0;
    while (start < indices.len) {
        var end = start + 1;
        while (end < indices.len and indices[end] == indices[start]) end += 1;
        denominator *= factorial(end - start);
        start = end;
    }
    return denominator;
}

test "factorials cover the supported ranks" {
    try std.testing.expectEqual(@as(u64, 1), factorial(0));
    try std.testing.expectEqual(@as(u64, 1), factorial(1));
    try std.testing.expectEqual(@as(u64, 2), factorial(2));
    try std.testing.expectEqual(@as(u64, 6), factorial(3));
    try std.testing.expectEqual(@as(u64, 24), factorial(4));
}
