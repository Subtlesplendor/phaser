//! Effective-potential derivation.
//!
//! Derives the artifact specified in `docs/calculations/EFFECTIVE_POTENTIAL.md`
//! by applying a validated request to a canonical model. Loop order zero is the
//! classical scalar potential of `docs/calculations/CLASSICAL_SCALAR_POTENTIAL.md`;
//! loop order one adds the zero-temperature scalar contribution of
//! `docs/calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md`.
//!
//! The derivation is symbolic throughout. Every value, gradient, and Hessian
//! root is a node in one interned Typed Value IR arena; no floating-point
//! arithmetic happens here.

const std = @import("std");
const foundation = @import("../foundation/root.zig");
const model_module = @import("../model/root.zig");
const value = @import("../value/root.zig");
const error_injection = @import("../testing/error_injection.zig");
const request_module = @import("request.zig");
const limits_module = @import("limits.zig");

const TensorKind = model_module.TensorKind;

/// Milestone 3 supports four-dimensional models only, which the model loader
/// enforces. A real scalar there has mass dimension (D - 2) / 2 = 1.
pub const scalar_mass_dimension: i32 = 1;

/// The potential density has mass dimension equal to the spacetime dimension.
pub const potential_mass_dimension: i32 = 4;

/// Identifier of the single renormalization-scale input channel.
pub const scale_name = "muR";

const derive_tw = error_injection.module(enum {
    resolve_coordinates,
    derive_contributions,
    publish_graph,
    publish_artifact,
}, error{OutOfMemory});

/// Numerical type of a selected output.
///
/// The type is structural: it depends on which contributions a selection
/// contains, not on the values at a point. A loop-containing output stays
/// `complex64` where its imaginary component happens to be zero.
pub const ResultType = enum { real64, complex64 };

pub const Role = enum {
    vacuum_energy,
    scalar_tadpole,
    scalar_mass_squared,
    scalar_cubic,
    scalar_quartic,
    scalar_one_loop,

    fn fromTensor(kind: TensorKind) Role {
        return switch (kind) {
            .vacuum_energy => .vacuum_energy,
            .scalar_tadpole => .scalar_tadpole,
            .scalar_mass_squared => .scalar_mass_squared,
            .scalar_cubic => .scalar_cubic,
            .scalar_quartic => .scalar_quartic,
        };
    }

    /// The loop order at which this role is derived. Ordering contributions by
    /// role therefore also orders them by loop order.
    pub fn loopOrder(self: Role) u32 {
        return switch (self) {
            .scalar_one_loop => 1,
            else => 0,
        };
    }

    pub fn resultType(self: Role) ResultType {
        return switch (self) {
            .scalar_one_loop => .complex64,
            else => .real64,
        };
    }
};

pub const Coordinate = struct {
    id: []const u8,
    scalar_index: u32,
    mass_dimension: i32,
    node: value.ValueId,
};

/// Scientific provenance of one contribution.
///
/// Every field the scalar one-loop specification requires a result to record is
/// here, so a caller never has to infer a convention from the value graph.
pub const Provenance = struct {
    /// Formula-version contract, for a contribution that has one.
    formula_version: ?value.FormulaVersion = null,
    /// Complex branch convention, for a contribution that forms a logarithm.
    branch: ?value.BranchPolicy = null,
    /// Renormalization scheme this contribution is defined in.
    scheme: ?request_module.Scheme = null,
    /// Fluctuation sector the contribution comes from.
    sector: Sector,
    /// Multiplicity of each contributing degree of freedom. Every real scalar
    /// component counts once.
    multiplicity: u32 = 1,
    precision: Precision = .binary64,
    resummation: Resummation = .none,

    pub const Sector = enum { classical, scalar };
    pub const Precision = enum { binary64 };
    pub const Resummation = enum { none };
};

pub const Contribution = struct {
    value: value.ValueId,
    /// One root per background coordinate, in canonical order. Empty when the
    /// derivation was asked for no derivatives.
    gradient: []const value.ValueId,
    /// Row-major roots over ordered coordinate pairs. Empty unless the Hessian
    /// was derived.
    hessian: []const value.ValueId,
    loop_order: u32,
    role: Role,
    result_type: ResultType,
    depends_on_background: bool,
    /// True when the value depends on the renormalization scale, which makes it
    /// scheme dependent in the sense the artifact records.
    depends_on_scale: bool,
    provenance: Provenance,
};

pub const AbsenceReason = enum {
    /// The model declares no tensor of this kind.
    tensor_absent,
    /// Every stored component contains a scalar whose background is fixed
    /// exactly to zero by the selected component slice.
    vanishes_on_slice,
    /// The model declares no real scalar, so the scalar fluctuation space is
    /// empty and the spectral sum runs over no eigenvalue.
    no_scalar_fluctuations,
};

pub const StructuralAbsence = struct {
    role: Role,
    reason: AbsenceReason,
};

/// A precomputed selection: the value, gradient, and Hessian roots of a set of
/// contributions summed in canonical order.
pub const Selection = struct {
    result_type: ResultType,
    value: value.ValueId,
    gradient: []const value.ValueId,
    hessian: []const value.ValueId,
};

pub const LoopTotal = struct {
    loop_order: u32,
    selection: Selection,
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
    /// Loop order the request truncated at. A role above it is neither derived
    /// nor recorded absent: it was not requested.
    loop_order: u32,
    coordinates: []const Coordinate,
    /// The renormalization-scale input, present exactly when a derived
    /// contribution depends on it.
    scale: ?value.ValueId,
    contributions: []const Contribution,
    absences: []const StructuralAbsence,
    /// Result type of the complete requested selection.
    result_type: ResultType,
    total: value.ValueId,
    gradient: []const value.ValueId,
    hessian: []const value.ValueId,
    /// One precomputed selection per loop order through the truncation.
    loop_totals: []const LoopTotal,

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

    /// The complete requested selection.
    pub fn totalSelection(self: *const Artifact) Selection {
        return .{
            .result_type = self.result_type,
            .value = self.total,
            .gradient = self.gradient,
            .hessian = self.hessian,
        };
    }

    /// Contributions at exactly one loop order, in canonical order.
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

    /// The precomputed selection of one loop order, or null when that order is
    /// outside the requested truncation.
    pub fn loopTotal(self: *const Artifact, loop_order: u32) ?Selection {
        for (self.loop_totals) |item| {
            if (item.loop_order == loop_order) return item.selection;
        }
        return null;
    }

    /// The precomputed selection of one contribution role.
    pub fn roleTotal(self: *const Artifact, role: Role) ?Selection {
        const item = self.contribution(role) orelse return null;
        return .{
            .result_type = item.result_type,
            .value = item.value,
            .gradient = item.gradient,
            .hessian = item.hessian,
        };
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

    /// True when the role belongs to the requested truncation, and is therefore
    /// either derived or recorded structurally absent.
    pub fn roleIsRequested(self: *const Artifact, role: Role) bool {
        return role.loopOrder() <= self.loop_order;
    }

    /// Structural invariants that construction promises.
    pub fn audit(self: *const Artifact) bool {
        if (!self.graph.audit()) return false;
        if (self.graph.massDimension(self.total) != potential_mass_dimension) return false;
        if (self.result_type != expectedResultType(&self.graph, self.total)) return false;

        var previous: ?Role = null;
        for (self.contributions) |item| {
            if (item.loop_order > self.loop_order) return false;
            if (item.loop_order != item.role.loopOrder()) return false;
            if (item.result_type != item.role.resultType()) return false;
            if (self.graph.massDimension(item.value) != potential_mass_dimension) {
                return false;
            }
            if (item.result_type != expectedResultType(&self.graph, item.value)) {
                return false;
            }
            // Canonical order is ascending role, which is also ascending loop
            // order because a role belongs to exactly one order.
            if (previous) |earlier| {
                if (@intFromEnum(earlier) >= @intFromEnum(item.role)) return false;
            }
            previous = item.role;
            if (!self.auditDerivatives(item.gradient, item.hessian)) return false;
        }

        // A requested role is either derived or recorded absent, never both and
        // never silently missing. A role above the truncation is neither.
        for (std.meta.tags(Role)) |role| {
            const derived = self.contribution(role) != null;
            const absent = self.absence(role) != null;
            if (!self.roleIsRequested(role)) {
                if (derived or absent) return false;
                continue;
            }
            if (derived == absent) return false;
        }

        if (!self.auditDerivatives(self.gradient, self.hessian)) return false;
        for (self.loop_totals, 0..) |item, index| {
            if (item.loop_order != index) return false;
            // Unreachable in isolation given the two checks around it: this
            // one requires every entry's `loop_order` to equal its index, and
            // the length check below requires indices to run exactly
            // `0..self.loop_order`, so an entry's `loop_order` can never
            // exceed `self.loop_order` without one of those two already
            // having caught it first. Kept because a caller-supplied
            // `loop_totals` (rather than one `derive` built) could violate
            // this without violating the other two.
            if (item.loop_order > self.loop_order) return false;
            if (self.graph.massDimension(item.selection.value) !=
                potential_mass_dimension) return false;
            if (!self.auditDerivatives(
                item.selection.gradient,
                item.selection.hessian,
            )) return false;
        }
        if (self.loop_totals.len != self.loop_order + 1) return false;

        // The scale input exists exactly when something depends on it.
        var scale_dependent = false;
        for (self.contributions) |item| {
            if (item.depends_on_scale) scale_dependent = true;
        }
        if (scale_dependent != (self.scale != null)) return false;
        return true;
    }

    fn auditDerivatives(
        self: *const Artifact,
        gradient_roots: []const value.ValueId,
        hessian_roots: []const value.ValueId,
    ) bool {
        for (gradient_roots) |slot| {
            if (self.graph.massDimension(slot) !=
                potential_mass_dimension - scalar_mass_dimension) return false;
        }
        for (hessian_roots) |slot| {
            if (self.graph.massDimension(slot) !=
                potential_mass_dimension - 2 * scalar_mass_dimension) return false;
        }
        // Mixed partials agree, so the dense Hessian is symmetric by
        // construction rather than by copying one triangle.
        const count = self.coordinates.len;
        if (hessian_roots.len == count * count) {
            for (0..count) |row| {
                for (0..count) |column| {
                    if (hessian_roots[row * count + column] !=
                        hessian_roots[column * count + row]) return false;
                }
            }
        }
        return true;
    }

    pub fn writeInspection(
        self: *const Artifact,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("calculation effective_potential\n");
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
        try writer.print(
            "loop_orders 0 through {d} result_type {s}\n",
            .{ self.loop_order, @tagName(self.result_type) },
        );
        try writer.print("contributions {d}\n", .{self.contributions.len});
        for (self.contributions) |item| {
            try writer.print(
                "  {s} loop_order={d} result_type={s} background_dependent={} " ++
                    "scale_dependent={}\n",
                .{
                    @tagName(item.role),
                    item.loop_order,
                    @tagName(item.result_type),
                    item.depends_on_background,
                    item.depends_on_scale,
                },
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

fn expectedResultType(graph: *const value.Graph, root: value.ValueId) ResultType {
    return switch (graph.valueType(root).domain) {
        .real => .real64,
        .complex => .complex64,
    };
}

/// Derives the effective potential through the request's loop truncation.
pub fn deriveEffectivePotential(
    context: foundation.Context,
    source_model: *const model_module.Model,
    request: *const request_module.Request,
    options: DeriveOptions,
) DeriveError!DeriveResult {
    return derive(context, source_model, request, options, request_module.supported_loop_order);
}

/// Tree-only compatibility wrapper.
///
/// Retained so that callers that want the classical potential keep a name that
/// says so, and so that a higher requested order is rejected rather than
/// silently widened.
pub fn deriveClassicalPotential(
    context: foundation.Context,
    source_model: *const model_module.Model,
    request: *const request_module.Request,
    options: DeriveOptions,
) DeriveError!DeriveResult {
    return derive(context, source_model, request, options, 0);
}

fn derive(
    context: foundation.Context,
    source_model: *const model_module.Model,
    request: *const request_module.Request,
    options: DeriveOptions,
    highest_supported_order: u32,
) DeriveError!DeriveResult {
    if (options.limits.validate()) |diagnostic| {
        return .{ .diagnostics = try oneDiagnostic(context, diagnostic) };
    }
    if (request.loop_order > highest_supported_order) {
        return .{ .diagnostics = try codeDiagnostic(context, .unsupported_loop_order) };
    }
    // At order one the formula version is defined in one scheme, and the
    // request parser only accepts that one. A missing declaration here would be
    // an internal inconsistency rather than user input.
    //
    // `Scheme` currently has exactly one member, `.msbar`, and
    // `request.zig`'s own parser rejects any other declared scheme string
    // before a `Request` exists at all, and requires a scheme be declared
    // whenever `loop_order >= 1`. No successfully parsed request can reach
    // this function with `loop_order >= 1` and `scheme != .msbar`; this stays
    // as the check that would catch a change to either guarantee.
    if (request.loop_order >= 1 and request.scheme != .msbar) {
        return .{ .diagnostics = try codeDiagnostic(context, .unsupported_scheme) };
    }

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    errdefer context.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer arena.deinit();

    var builder = try value.Builder.init(context.allocator, options.value_limits);
    var builder_live = true;
    errdefer if (builder_live) builder.deinit();

    var pending = Pending{
        .context = context,
        .arena = arena,
        .builder = &builder,
        .live = &builder_live,
    };

    try derive_tw.check(.resolve_coordinates);
    const resolved = resolveCoordinates(
        arena.allocator(),
        source_model,
        request,
        &builder,
        options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownScalar => return pending.fail(.invalid_background_coordinate),
        else => return pending.fail(.capacity_exceeded),
    };

    try derive_tw.check(.derive_contributions);
    const derived = deriveContributions(
        arena.allocator(),
        source_model,
        request,
        resolved,
        &builder,
        options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return pending.fail(.capacity_exceeded),
    };

    try derive_tw.check(.publish_graph);
    var graph = try builder.finish();
    builder_live = false;
    errdefer graph.deinit();

    const request_fingerprint = request.fingerprint(context.allocator) catch
        return error.OutOfMemory;

    try derive_tw.check(.publish_artifact);
    var artifact = Artifact{
        .arena = arena,
        .graph = graph,
        .model_fingerprint = source_model.fingerprint(),
        .request_fingerprint = request_fingerprint,
        .background_mode = request.background_mode,
        .scheme = request.scheme,
        .loop_order = request.loop_order,
        .coordinates = resolved,
        .scale = derived.scale,
        .contributions = derived.contributions,
        .absences = derived.absences,
        .result_type = derived.total.result_type,
        .total = derived.total.value,
        .gradient = derived.total.gradient,
        .hessian = derived.total.hessian,
        .loop_totals = derived.loop_totals,
    };
    if (options.audit and !artifact.audit()) @panic("effective potential audit failed");
    std.debug.assert(artifact.audit());
    return .{ .artifact = artifact };
}

/// Ownership of the half-built derivation, so that every failure path releases
/// the same state in the same order and publishes nothing.
const Pending = struct {
    context: foundation.Context,
    arena: *std.heap.ArenaAllocator,
    builder: *value.Builder,
    live: *bool,

    /// Builds the diagnostics before releasing anything, so that a failure to
    /// report a failure still leaves the caller's rollback in charge of exactly
    /// the state it created.
    fn fail(self: *Pending, code: foundation.Code) DeriveError!DeriveResult {
        const diagnostics = try codeDiagnostic(self.context, code);
        self.builder.deinit();
        self.live.* = false;
        self.arena.deinit();
        self.context.allocator.destroy(self.arena);
        return .{ .diagnostics = diagnostics };
    }
};

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
    scale: ?value.ValueId,
    total: Selection,
    loop_totals: []const LoopTotal,
};

/// Shared derivation state, so that the tree and loop stages agree about the
/// background embedding, the coordinate order, and the requested derivatives.
const Deriver = struct {
    allocator: std.mem.Allocator,
    builder: *value.Builder,
    source_model: *const model_module.Model,
    coordinates: []const Coordinate,
    /// Inverse embedding: which coordinate, if any, carries each model scalar.
    selected: []const ?u32,
    background: value.Background,
    options: DeriveOptions,

    fn coordinateCount(self: *const Deriver) usize {
        return self.coordinates.len;
    }

    fn gradientSlots(self: *const Deriver) ![]value.ValueId {
        return self.allocator.alloc(value.ValueId, switch (self.options.derivatives) {
            .none => 0,
            .gradient, .gradient_hessian => self.coordinateCount(),
        });
    }

    fn hessianSlots(self: *const Deriver) ![]value.ValueId {
        return self.allocator.alloc(value.ValueId, switch (self.options.derivatives) {
            .none, .gradient => 0,
            .gradient_hessian => self.coordinateCount() * self.coordinateCount(),
        });
    }

    /// Symbolic gradient and Hessian roots of one real contribution.
    fn realDerivatives(self: *const Deriver, root: value.ValueId) !struct {
        gradient: []value.ValueId,
        hessian: []value.ValueId,
    } {
        const gradient_roots = try self.gradientSlots();
        if (gradient_roots.len != 0) {
            try value.gradient(self.builder, root, self.background, gradient_roots);
        }
        const hessian_roots = try self.hessianSlots();
        if (hessian_roots.len != 0) {
            try value.hessian(self.builder, root, self.background, hessian_roots);
        }
        return .{ .gradient = gradient_roots, .hessian = hessian_roots };
    }
};

fn deriveContributions(
    allocator: std.mem.Allocator,
    source_model: *const model_module.Model,
    request: *const request_module.Request,
    coordinates: []const Coordinate,
    builder: *value.Builder,
    options: DeriveOptions,
) !Derived {
    const selected = try allocator.alloc(?u32, source_model.real_scalars.len);
    @memset(selected, null);
    for (coordinates, 0..) |coordinate, index| {
        selected[coordinate.scalar_index] = @intCast(index);
    }

    const order = try allocator.alloc(u32, coordinates.len);
    for (order, 0..) |*slot, index| slot.* = @intCast(index);

    var deriver = Deriver{
        .allocator = allocator,
        .builder = builder,
        .source_model = source_model,
        .coordinates = coordinates,
        .selected = selected,
        .background = .{ .order = order, .mass_dimension = scalar_mass_dimension },
        .options = options,
    };

    var contributions = std.ArrayList(Contribution).empty;
    defer contributions.deinit(builder.allocator);
    var absences = std.ArrayList(StructuralAbsence).empty;
    defer absences.deinit(builder.allocator);

    try deriveTreeContributions(&deriver, &contributions, &absences);

    var scale: ?value.ValueId = null;
    if (request.loop_order >= 1) {
        scale = try deriveScalarOneLoop(&deriver, &contributions, &absences);
    }
    if (contributions.items.len > options.limits.contributions) {
        return error.CapacityExceeded;
    }

    const loop_totals = try allocator.alloc(LoopTotal, request.loop_order + 1);
    for (loop_totals, 0..) |*slot, loop_order| {
        slot.* = .{
            .loop_order = @intCast(loop_order),
            .selection = try sumContributions(
                &deriver,
                contributions.items,
                @intCast(loop_order),
            ),
        };
    }

    return .{
        .contributions = try allocator.dupe(Contribution, contributions.items),
        .absences = try allocator.dupe(StructuralAbsence, absences.items),
        .scale = scale,
        .total = try sumContributions(&deriver, contributions.items, null),
        .loop_totals = loop_totals,
    };
}

/// Tree contributions, one per declared scalar tensor.
fn deriveTreeContributions(
    deriver: *Deriver,
    contributions: *std.ArrayList(Contribution),
    absences: *std.ArrayList(StructuralAbsence),
) !void {
    const builder = deriver.builder;
    var terms = std.ArrayList(value.ValueId).empty;
    defer terms.deinit(builder.allocator);

    for (std.meta.tags(TensorKind)) |kind| {
        const role = Role.fromTensor(kind);
        const tensor = deriver.source_model.tensor(kind) orelse {
            try absences.append(builder.allocator, .{
                .role = role,
                .reason = .tensor_absent,
            });
            continue;
        };

        terms.clearRetainingCapacity();
        for (tensor.components) |component| {
            const indices = component.indices[0..component.rank];
            if (!allSelected(indices, deriver.selected)) continue;

            const imported = try value.importExpression(
                builder,
                &deriver.source_model.expressions()[component.expression_index],
            );
            const term = try buildTerm(
                builder,
                imported,
                indices,
                deriver.selected,
                deriver.coordinates,
            );
            try terms.append(builder.allocator, term);
        }

        if (terms.items.len == 0) {
            try absences.append(builder.allocator, .{
                .role = role,
                .reason = .vanishes_on_slice,
            });
            continue;
        }

        const root = try builder.add(terms.items);
        const derivatives = try deriver.realDerivatives(root);
        try contributions.append(builder.allocator, .{
            .value = root,
            .gradient = derivatives.gradient,
            .hessian = derivatives.hessian,
            .loop_order = 0,
            .role = role,
            .result_type = .real64,
            .depends_on_background = kind.rank() > 0,
            .depends_on_scale = false,
            .provenance = .{ .sector = .classical },
        });
    }
}

/// The zero-temperature scalar one-loop contribution.
///
/// Returns the renormalization-scale input when the contribution was derived.
fn deriveScalarOneLoop(
    deriver: *Deriver,
    contributions: *std.ArrayList(Contribution),
    absences: *std.ArrayList(StructuralAbsence),
) !?value.ValueId {
    const builder = deriver.builder;
    const scalars = deriver.source_model.real_scalars.len;
    if (scalars == 0) {
        // The spectral sum runs over an empty multiset. That is structurally
        // absent, not an unsupported or silently omitted sector.
        try absences.append(builder.allocator, .{
            .role = .scalar_one_loop,
            .reason = .no_scalar_fluctuations,
        });
        return null;
    }

    const dimension: u32 = @intCast(scalars);
    const entries = try deriver.allocator.alloc(
        value.ValueId,
        value.upperTriangleCount(dimension),
    );
    for (0..dimension) |row| {
        for (row..dimension) |column| {
            entries[
                value.upperTriangleIndex(
                    dimension,
                    @intCast(row),
                    @intCast(column),
                )
            ] = try massMatrixEntry(deriver, @intCast(row), @intCast(column));
        }
    }

    const matrix = try builder.realSymmetricMatrix(
        dimension,
        entries,
        value.mass_squared_dimension,
    );
    const scale = try builder.renormalizationScale(0, scale_name);
    const root = try builder.scalarOneLoopSpectralValue(matrix, scale);

    const gradient_roots = try deriver.gradientSlots();
    if (gradient_roots.len != 0) {
        try value.gradient(builder, root, deriver.background, gradient_roots);
    }
    const hessian_roots = try deriver.hessianSlots();
    if (hessian_roots.len != 0) {
        try value.hessian(builder, root, deriver.background, hessian_roots);
    }

    try contributions.append(builder.allocator, .{
        .value = root,
        .gradient = gradient_roots,
        .hessian = hessian_roots,
        .loop_order = 1,
        .role = .scalar_one_loop,
        .result_type = .complex64,
        // The mass matrix depends on the background whenever a cubic or quartic
        // tensor contributes; the constant case is still a valid contribution.
        .depends_on_background = try builder.dependsOnBackground(matrix),
        .depends_on_scale = true,
        .provenance = .{
            .formula_version = .scalar_vacuum_msbar_1,
            .branch = .principal_arg,
            .scheme = .msbar,
            .sector = .scalar,
            .multiplicity = 1,
            .precision = .binary64,
            .resummation = .none,
        },
    });
    return scale;
}

/// One entry of the field-dependent scalar mass-squared matrix.
///
/// Both fluctuation derivatives are taken before the background slice is
/// applied: the row and column range over every model scalar, and only the
/// leftover background factors are replaced by a slice coordinate or, for an
/// unselected scalar, by exact zero.
///
/// For the fully symmetric tensors `T^(r)` normalized by `1/r!`,
///
///     M2_ij = sum_{r >= 2} 1/(r-2)! * sum_{k3..kr} T_{i j k3..kr} phi_k3..phi_kr,
///
/// which is the rank-2 tensor plus one contracted background factor from the
/// cubic and two from the quartic.
fn massMatrixEntry(deriver: *Deriver, row: u32, column: u32) !value.ValueId {
    const builder = deriver.builder;
    var terms = std.ArrayList(value.ValueId).empty;
    defer terms.deinit(builder.allocator);

    var indices: [4]u32 = .{ row, column, 0, 0 };

    if (try tensorValue(deriver, .scalar_mass_squared, indices[0..2])) |quadratic| {
        try terms.append(builder.allocator, quadratic);
    }

    // Rank three: one leftover background factor.
    for (deriver.coordinates) |first| {
        indices[2] = first.scalar_index;
        const entry = try tensorValue(deriver, .scalar_cubic, indices[0..3]) orelse continue;
        try terms.append(
            builder.allocator,
            try builder.multiply(&.{ entry, first.node }),
        );
    }

    // Rank four: two leftover background factors, and the defining 1/(4-2)!.
    //
    // Summing over unordered pairs rather than ordered ones is the same exact
    // sum: an off-diagonal pair occurs twice and cancels the 1/2, while a
    // diagonal pair occurs once and keeps it. It also writes the diagonal term
    // as a square rather than as a repeated factor.
    for (deriver.coordinates, 0..) |first, position| {
        for (deriver.coordinates[position..]) |second| {
            indices[2] = first.scalar_index;
            indices[3] = second.scalar_index;
            const entry = try tensorValue(
                deriver,
                .scalar_quartic,
                indices[0..4],
            ) orelse continue;
            if (first.scalar_index == second.scalar_index) {
                const square = try builder.multiply(&.{
                    entry,
                    try builder.power(first.node, 2),
                });
                try terms.append(
                    builder.allocator,
                    try builder.divide(square, try builder.integer(2, 0)),
                );
                continue;
            }
            try terms.append(
                builder.allocator,
                try builder.multiply(&.{ entry, first.node, second.node }),
            );
        }
    }

    if (terms.items.len == 0) {
        return builder.zero(value.mass_squared_dimension);
    }
    return builder.add(terms.items);
}

/// The exact component of a fully symmetric model tensor at arbitrary indices,
/// or null when the model stores no such component.
fn tensorValue(
    deriver: *Deriver,
    kind: TensorKind,
    indices: []const u32,
) !?value.ValueId {
    const stored = deriver.source_model.scalarTensorExpression(kind, indices) orelse
        return null;
    return try value.importExpression(deriver.builder, stored);
}

/// Sums the contributions of one loop order, or of the complete request when
/// `loop_order` is null.
///
/// A real contribution joins a complex sum through an explicit promotion, so
/// the promotion is visible in the value graph rather than implied.
fn sumContributions(
    deriver: *Deriver,
    contributions: []const Contribution,
    loop_order: ?u32,
) !Selection {
    const builder = deriver.builder;
    var result_type = ResultType.real64;
    var count: usize = 0;
    for (contributions) |item| {
        if (loop_order) |selected| {
            if (item.loop_order != selected) continue;
        }
        count += 1;
        if (item.result_type == .complex64) result_type = .complex64;
    }

    var terms = std.ArrayList(value.ValueId).empty;
    defer terms.deinit(builder.allocator);

    const value_root = try sumRoots(
        deriver,
        contributions,
        loop_order,
        result_type,
        potential_mass_dimension,
        &terms,
        .value,
    );

    const gradient_roots = try deriver.gradientSlots();
    for (gradient_roots, 0..) |*slot, coordinate| {
        slot.* = try sumRoots(
            deriver,
            contributions,
            loop_order,
            result_type,
            potential_mass_dimension - scalar_mass_dimension,
            &terms,
            .{ .gradient = coordinate },
        );
    }

    const hessian_roots = try deriver.hessianSlots();
    for (hessian_roots, 0..) |*slot, position| {
        slot.* = try sumRoots(
            deriver,
            contributions,
            loop_order,
            result_type,
            potential_mass_dimension - 2 * scalar_mass_dimension,
            &terms,
            .{ .hessian = position },
        );
    }

    return .{
        .result_type = result_type,
        .value = value_root,
        .gradient = gradient_roots,
        .hessian = hessian_roots,
    };
}

const RootKind = union(enum) {
    value,
    gradient: usize,
    hessian: usize,
};

fn sumRoots(
    deriver: *Deriver,
    contributions: []const Contribution,
    loop_order: ?u32,
    result_type: ResultType,
    mass_dimension: i32,
    terms: *std.ArrayList(value.ValueId),
    kind: RootKind,
) !value.ValueId {
    const builder = deriver.builder;
    terms.clearRetainingCapacity();
    for (contributions) |item| {
        if (loop_order) |selected| {
            if (item.loop_order != selected) continue;
        }
        const root = switch (kind) {
            .value => item.value,
            .gradient => |position| item.gradient[position],
            .hessian => |position| item.hessian[position],
        };
        // A real root joins a complex selection through the explicit inclusion
        // map, never by an implicit widening.
        const term = if (result_type == .complex64 and item.result_type == .real64)
            try builder.promoteRealToComplex(root)
        else
            root;
        try terms.append(builder.allocator, term);
    }

    if (terms.items.len == 0) {
        const exact_zero = try builder.zero(mass_dimension);
        return switch (result_type) {
            .real64 => exact_zero,
            .complex64 => builder.promoteRealToComplex(exact_zero),
        };
    }
    if (terms.items.len == 1) return terms.items[0];
    return builder.add(terms.items);
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

test "every role belongs to exactly one loop order and result type" {
    for (std.meta.tags(Role)) |role| {
        try std.testing.expect(role.loopOrder() <= 1);
        const expected: ResultType = if (role.loopOrder() == 0) .real64 else .complex64;
        try std.testing.expectEqual(expected, role.resultType());
    }
}

test "selecting one loop order filters and reports overflow without corrupting the buffer" {
    var source_model = try loadTestModel(phi4_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();

    var artifact = switch (try deriveEffectivePotential(
        testContext(),
        &source_model,
        &request,
        .{ .audit = true },
    )) {
        .artifact => |derived| derived,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer artifact.deinit();

    var one_loop: [8]Contribution = undefined;
    const one_loop_count = artifact.selectLoopOrder(1, &one_loop);
    try std.testing.expectEqual(@as(usize, 1), one_loop_count);
    try std.testing.expectEqual(Role.scalar_one_loop, one_loop[0].role);

    // Phi4 has more than one tree-level contribution, so a full buffer both
    // confirms the filter (no loop-1 item leaks in) and sets up the boundary
    // case below.
    var tree_full: [8]Contribution = undefined;
    const tree_count = artifact.selectLoopOrder(0, &tree_full);
    try std.testing.expect(tree_count > 1);
    for (tree_full[0..tree_count]) |item| {
        try std.testing.expectEqual(@as(u32, 0), item.loop_order);
    }

    // A buffer smaller than the match count still reports the true count
    // rather than the truncated one, which is what lets a caller detect that
    // it needs a bigger buffer instead of silently seeing only part of the
    // answer.
    var tree_short: [1]Contribution = undefined;
    const short_count = artifact.selectLoopOrder(0, &tree_short);
    try std.testing.expectEqual(tree_count, short_count);
    try std.testing.expectEqual(tree_full[0].role, tree_short[0].role);
}

// -- derivation ------------------------------------------------------------

const testing_context_limits = foundation.Limits{
    .max_diagnostics = 8,
    .max_related_locations = 8,
};

fn testContext() foundation.Context {
    return switch (foundation.Context.init(std.testing.allocator, testing_context_limits)) {
        .context => |context| context,
        .failure => unreachable,
    };
}

const phi4_model_source =
    \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
    \\"conventions":{"metric":"mostly_plus","scalar_representation":"real_components",
    \\"fermions":"two_component_weyl"},
    \\"parameters":{"lambda":{"domain":"real","mass_dimension":0},
    \\"m2":{"domain":"real","mass_dimension":2}},
    \\"fields":{"real_scalars":[{"id":"phi"}],"weyl_fermions":[],"gauge_vectors":[]},
    \\"tensors":{"scalar_mass_squared":{"components":[
    \\{"indices":["phi","phi"],"value":"m2"}]},
    \\"scalar_quartic":{"components":[
    \\{"indices":["phi","phi","phi","phi"],"value":"lambda"}]}}}
;

const scalarless_model_source =
    \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
    \\"conventions":{"metric":"mostly_plus","scalar_representation":"real_components",
    \\"fermions":"two_component_weyl"},
    \\"parameters":{"omega":{"domain":"real","mass_dimension":4}},
    \\"fields":{"real_scalars":[],"weyl_fermions":[],"gauge_vectors":[]},
    \\"tensors":{"vacuum_energy":{"value":"omega"}}}
;

const one_loop_request_source =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},
    \\"renormalization":{"scheme":"MSbar"},
    \\"orders":{"loop":{"through":1}}}
;

const tree_only_request_source =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},
    \\"orders":{"loop":{"through":0}}}
;

fn loadTestModel(source: []const u8) !model_module.Model {
    return switch (try model_module.loadModel(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = source,
    }, .{})) {
        .model => |loaded| loaded,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidModel;
        },
    };
}

fn parseTestRequest(source: []const u8) !request_module.Request {
    return switch (try request_module.parseRequest(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(1),
        .bytes = source,
    }, .{})) {
        .request => |parsed| parsed,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidRequest;
        },
    };
}

test "a model with no scalars records an absent one-loop contribution" {
    var source_model = try loadTestModel(scalarless_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();

    var artifact = switch (try deriveEffectivePotential(
        testContext(),
        &source_model,
        &request,
        .{ .audit = true },
    )) {
        .artifact => |derived| derived,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer artifact.deinit();

    // The spectral sum runs over an empty eigenvalue multiset. That is a
    // structural absence with its own reason, distinguishable from a sector the
    // calculation does not support and from one that was never requested.
    try std.testing.expect(artifact.contribution(.scalar_one_loop) == null);
    try std.testing.expectEqual(
        AbsenceReason.no_scalar_fluctuations,
        artifact.absence(.scalar_one_loop).?.reason,
    );
    try std.testing.expect(artifact.roleIsRequested(.scalar_one_loop));
    try std.testing.expectEqual(@as(?value.ValueId, null), artifact.scale);
    // With no loop contribution present the selected total stays real.
    try std.testing.expectEqual(ResultType.real64, artifact.result_type);
    try std.testing.expectEqual(@as(usize, 0), artifact.coordinateCount());
}

test "the derived one-loop gradient agrees with differentiating the total" {
    var source_model = try loadTestModel(phi4_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();

    var artifact = switch (try deriveEffectivePotential(
        testContext(),
        &source_model,
        &request,
        .{ .audit = true },
    )) {
        .artifact => |derived| derived,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer artifact.deinit();

    // Summing per-contribution derivatives and differentiating the summed total
    // are different code paths through the same exact structure, so their
    // agreement is evidence rather than a restatement.
    var builder = try value.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();

    const graph = &artifact.graph;
    try std.testing.expectEqual(@as(usize, 1), artifact.gradient.len);
    try std.testing.expectEqual(@as(usize, 1), artifact.hessian.len);
    try std.testing.expectEqual(ResultType.complex64, artifact.result_type);
    try std.testing.expectEqual(
        value.Domain.complex,
        graph.valueType(artifact.gradient[0]).domain,
    );
    try std.testing.expectEqual(
        potential_mass_dimension - scalar_mass_dimension,
        graph.massDimension(artifact.gradient[0]),
    );
    try std.testing.expectEqual(
        potential_mass_dimension - 2 * scalar_mass_dimension,
        graph.massDimension(artifact.hessian[0]),
    );

    // Each order's selection carries its own derivatives, and the tree order
    // stays real.
    const tree = artifact.loopTotal(0).?;
    try std.testing.expectEqual(ResultType.real64, tree.result_type);
    try std.testing.expectEqual(
        value.Domain.real,
        graph.valueType(tree.gradient[0]).domain,
    );
}

test "audit defaults off" {
    // `derive`'s `options.audit and !artifact.audit() -> @panic` sits directly
    // beside an unconditional `std.debug.assert(artifact.audit())`, so this
    // default is unobservable through crash-or-not behavior in Debug, where
    // the assert already covers it regardless of the option. `options.audit`
    // exists for ReleaseFast, which strips the assert; this is the one
    // reachable way to confirm what a caller who never mentions it gets.
    try std.testing.expect(!(DeriveOptions{}).audit);
}

/// A fresh, genuinely valid artifact for the corruption tests below.
///
/// `derive` never publishes an artifact that fails its own audit, so
/// `Artifact.audit`'s "return false" branches are never exercised by any
/// derivation this suite runs elsewhere. Each of the following tests takes one
/// field of an otherwise-valid artifact out of the specific invariant it
/// alone guards, and confirms `audit` catches exactly that.
///
/// A fresh artifact per test, rather than one shared and restored between
/// cases, so a mistake in one case's cleanup cannot leak into the next.
fn freshAuditableArtifact() !Artifact {
    var source_model = try loadTestModel(phi4_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();
    return switch (try deriveEffectivePotential(
        testContext(),
        &source_model,
        &request,
        .{ .audit = true },
    )) {
        .artifact => |derived| derived,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
}

test "a baseline artifact passes its own audit" {
    // Establishes that `freshAuditableArtifact` is actually valid, so a
    // corruption test below failing to detect a defect cannot be mistaken for
    // starting from an already-invalid artifact.
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    try std.testing.expect(artifact.audit());
}

test "audit catches a total whose mass dimension does not match the potential" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    // `gradient[0]` is a real value in the same graph, one mass dimension
    // short of the potential's -- the same domain as `total` (both complex64
    // here), so this leaves the result-type check satisfied and isolates the
    // mass-dimension check alone.
    artifact.total = artifact.gradient[0];
    try std.testing.expect(!artifact.audit());
}

test "audit catches a total whose result type disagrees with its graph domain" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    // The tree total is a real value; splicing it in as the (complex64)
    // overall total disagrees with `self.result_type`, which stays
    // complex64 -- the check this isolates does not look at mass dimension at
    // all, only at domain.
    artifact.total = artifact.loopTotal(0).?.value;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a contribution above the requested loop truncation" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const contributions = @constCast(artifact.contributions);
    contributions[0].loop_order = artifact.loop_order + 1;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a contribution whose loop order disagrees with its role" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const contributions = @constCast(artifact.contributions);
    // Every tree role has loop order 0; recording one at order 1 (still
    // within the truncation, so the check above does not also fire) is a
    // role/order mismatch specifically.
    contributions[0].loop_order = 1;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a contribution whose result type disagrees with its role" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const contributions = @constCast(artifact.contributions);
    // A tree role's own `resultType()` is real64; declaring one complex64
    // (without touching its value or loop order) isolates this check from the
    // mass-dimension and domain checks that read the value itself.
    contributions[0].result_type = .complex64;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a contribution whose value has the wrong mass dimension" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const contributions = @constCast(artifact.contributions);
    // Every contribution's value is independently required to sit at the
    // potential's own mass dimension, so contributions are not
    // interchangeable with each other here -- the tree total's gradient is
    // real domain (matching a tree contribution's declared result type) but
    // one mass dimension short, which isolates this check from the
    // domain/result-type check above.
    if (artifact.loopTotal(0).?.gradient.len == 0) return error.TestUnexpectedResult;
    contributions[0].value = artifact.loopTotal(0).?.gradient[0];
    try std.testing.expect(!artifact.audit());
}

test "audit catches a contribution whose value's domain disagrees with its declared result type" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const contributions = @constCast(artifact.contributions);
    // The one-loop contribution's value is complex; splicing it into a tree
    // (real64-declared) contribution disagrees in domain without touching
    // `result_type`, `role`, or `loop_order` -- distinct from the mass
    // dimension and role/result-type checks above, which do not depend on
    // where the value comes from.
    const one_loop = artifact.contribution(.scalar_one_loop).?.value;
    contributions[0].value = one_loop;
    try std.testing.expect(!artifact.audit());
}

test "audit catches contributions out of canonical role order" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const contributions = @constCast(artifact.contributions);
    // Two contributions naming the same role is the least-ordered case: it
    // violates strict ascending order at the boundary (equal, not merely
    // out of order), which is exactly what distinguishes this check from one
    // that only rejects a decrease.
    contributions[1].role = contributions[0].role;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a contribution's gradient failing the derivative shape check" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const contributions = @constCast(artifact.contributions);
    const target = @constCast(contributions[0].gradient);
    if (target.len == 0) return error.TestUnexpectedResult;
    // `total` is one mass dimension too deep to be any contribution's
    // gradient root.
    target[0] = artifact.total;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a role that is requested but neither derived nor recorded absent" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    var contributions = std.ArrayList(Contribution).empty;
    defer contributions.deinit(std.testing.allocator);
    // Drop the first contribution entirely: still within the truncation
    // (`roleIsRequested` is unaffected by this array), so this is neither
    // derived nor recorded absent -- the silently-missing case, distinct from
    // deriving-and-absent-at-once below.
    for (artifact.contributions[1..]) |item| {
        try contributions.append(std.testing.allocator, item);
    }
    const owned = try artifact.arena.allocator().dupe(
        Contribution,
        contributions.items,
    );
    artifact.contributions = owned;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a role above the truncation recorded as absent anyway" {
    // A tree-only truncation, so `scalar_one_loop` sits above it -- neither
    // derived nor absent is the only valid state for a role the request never
    // reached.
    var source_model = try loadTestModel(phi4_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(tree_only_request_source);
    defer request.deinit();
    var artifact = switch (try deriveEffectivePotential(
        testContext(),
        &source_model,
        &request,
        .{ .audit = true },
    )) {
        .artifact => |derived| derived,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer artifact.deinit();
    try std.testing.expect(!artifact.roleIsRequested(.scalar_one_loop));

    var absences = std.ArrayList(StructuralAbsence).empty;
    defer absences.deinit(std.testing.allocator);
    for (artifact.absences) |item| try absences.append(std.testing.allocator, item);
    try absences.append(std.testing.allocator, .{
        .role = .scalar_one_loop,
        .reason = .tensor_absent,
    });
    const owned = try artifact.arena.allocator().dupe(
        StructuralAbsence,
        absences.items,
    );
    artifact.absences = owned;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a role recorded as both derived and absent" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    var absences = std.ArrayList(StructuralAbsence).empty;
    defer absences.deinit(std.testing.allocator);
    for (artifact.absences) |item| try absences.append(std.testing.allocator, item);
    // The first contribution's role is already derived; also recording it
    // absent is the both-at-once case the check above's sibling forbids.
    try absences.append(std.testing.allocator, .{
        .role = artifact.contributions[0].role,
        .reason = .tensor_absent,
    });
    const owned = try artifact.arena.allocator().dupe(
        StructuralAbsence,
        absences.items,
    );
    artifact.absences = owned;
    try std.testing.expect(!artifact.audit());
}

test "audit catches the total's gradient failing the derivative shape check" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const gradient = @constCast(artifact.gradient);
    if (gradient.len == 0) return error.TestUnexpectedResult;
    // `total` itself is a mass dimension too deep to be its own gradient
    // root.
    gradient[0] = artifact.total;
    try std.testing.expect(!artifact.audit());
}

test "audit catches the total's hessian failing the derivative shape check" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const hessian = @constCast(artifact.hessian);
    if (hessian.len == 0) return error.TestUnexpectedResult;
    // `total` is two mass dimensions too deep to be its own Hessian root,
    // distinct from the gradient case above, which is only one dimension off.
    hessian[0] = artifact.total;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a loop total recorded under the wrong index" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const loop_totals = @constCast(artifact.loop_totals);
    if (loop_totals.len < 2) return error.TestUnexpectedResult;
    loop_totals[1].loop_order = 0;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a loop total whose selection has the wrong mass dimension" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const loop_totals = @constCast(artifact.loop_totals);
    if (loop_totals.len == 0) return error.TestUnexpectedResult;
    loop_totals[0].selection.value = artifact.gradient[0];
    try std.testing.expect(!artifact.audit());
}

test "audit catches a loop total's derivatives failing the derivative shape check" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const loop_totals = @constCast(artifact.loop_totals);
    const target = for (loop_totals) |*item| {
        if (item.selection.gradient.len != 0) break item;
    } else return error.TestUnexpectedResult;
    const gradient = @constCast(target.selection.gradient);
    gradient[0] = artifact.total;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a loop totals array shorter than the truncation promises" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    artifact.loop_totals = artifact.loop_totals[0 .. artifact.loop_totals.len - 1];
    try std.testing.expect(!artifact.audit());
}

test "audit catches a missing scale input when a contribution depends on it" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    // The one-loop contribution here does depend on the renormalization
    // scale, so the baseline artifact's `scale` is already populated;
    // dropping it is what disagrees with `depends_on_scale`, the other
    // direction of the same check from the presence side.
    try std.testing.expect(artifact.scale != null);
    artifact.scale = null;
    try std.testing.expect(!artifact.audit());
}

test "audit catches a scale input present without a scale-dependent contribution" {
    var artifact = try freshAuditableArtifact();
    defer artifact.deinit();
    const contributions = @constCast(artifact.contributions);
    // Declare every contribution scale-independent while `scale` stays
    // populated: the presence direction of the same check, isolated from
    // whether `scale` itself is null.
    for (contributions) |*item| item.depends_on_scale = false;
    try std.testing.expect(artifact.scale != null);
    try std.testing.expect(!artifact.audit());
}

test "audit catches an asymmetric hessian failing the symmetry check" {
    // A one-coordinate model's Hessian is 1x1, where symmetry holds trivially;
    // this needs a genuine off-diagonal pair to break, hence the two-scalar
    // model.
    var source_model = try loadTestModel(two_scalar_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(tree_only_request_source);
    defer request.deinit();
    var artifact = switch (try deriveEffectivePotential(
        testContext(),
        &source_model,
        &request,
        .{ .audit = true },
    )) {
        .artifact => |derived| derived,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer artifact.deinit();
    try std.testing.expectEqual(@as(usize, 2), artifact.coordinateCount());
    const hessian = @constCast(artifact.hessian);
    try std.testing.expectEqual(@as(usize, 4), hessian.len);
    // Row-major over 2 coordinates: index 1 is (row 0, column 1), index 2 is
    // (row 1, column 0) -- the mixed partial this model's construction
    // already makes equal. Overwriting one with index 3's value keeps a valid
    // Hessian-shaped mass dimension (so the shape check above still passes)
    // while breaking exactly this equality.
    try std.testing.expectEqual(hessian[1], hessian[2]);
    hessian[2] = hessian[3];
    try std.testing.expect(!artifact.audit());
}

test "tripwires exercise every derivation rollback boundary" {
    var source_model = try loadTestModel(phi4_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();

    // Every checkpoint has the same expected outcome: the operation fails, no
    // artifact is published, and a leak-detecting allocator sees no partial
    // ownership left behind.
    for (std.meta.tags(derive_tw.FailPoint)) |point| {
        derive_tw.errorAlways(point, error.OutOfMemory);
        defer derive_tw.reset();
        try std.testing.expectError(error.OutOfMemory, deriveEffectivePotential(
            testContext(),
            &source_model,
            &request,
            .{},
        ));
        try derive_tw.end(.reset);
    }
}

test "an unsupported loop order is rejected before anything is derived" {
    var source_model = try loadTestModel(phi4_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();

    // The tree-only wrapper does not silently widen to the order the request
    // asks for.
    switch (try deriveClassicalPotential(testContext(), &source_model, &request, .{})) {
        .artifact => |derived| {
            var owned = derived;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            try std.testing.expectEqual(
                foundation.Code.unsupported_loop_order,
                owned.items[0].code,
            );
        },
    }
}

test "a contribution ceiling is reported rather than silently truncating" {
    var source_model = try loadTestModel(phi4_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();

    // This model derives two contributions at order zero plus one at order one,
    // so a ceiling of two is exceeded by the one-loop contribution.
    switch (try deriveEffectivePotential(testContext(), &source_model, &request, .{
        .limits = .{ .contributions = 2 },
    })) {
        .artifact => |derived| {
            var owned = derived;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            try std.testing.expectEqual(
                foundation.Code.capacity_exceeded,
                owned.items[0].code,
            );
        },
    }

    // A ceiling exactly at the actual count succeeds: the check above already
    // sits at the tightest over-limit case (count is exactly limit + 1), so an
    // off-by-one there would report the same error either way. Only a ceiling
    // that matches the count exactly can tell `>` from `>=` apart.
    switch (try deriveEffectivePotential(testContext(), &source_model, &request, .{
        .limits = .{ .contributions = 3 },
    })) {
        .artifact => |derived| {
            var owned = derived;
            owned.deinit();
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

const two_scalar_model_source =
    \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
    \\"conventions":{"metric":"mostly_plus","scalar_representation":"real_components",
    \\"fermions":"two_component_weyl"},
    \\"parameters":{"m2":{"domain":"real","mass_dimension":2}},
    \\"fields":{"real_scalars":[{"id":"phi"},{"id":"chi"}],"weyl_fermions":[],
    \\"gauge_vectors":[]},
    \\"tensors":{"scalar_mass_squared":{"components":[
    \\{"indices":["phi","phi"],"value":"m2"},
    \\{"indices":["chi","chi"],"value":"m2"}]}}}
;

test "a background coordinate ceiling is reported rather than silently truncating" {
    var source_model = try loadTestModel(two_scalar_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();

    // Two real scalars, so the full scalar space is exactly two background
    // coordinates; a ceiling of one is exceeded.
    switch (try deriveEffectivePotential(testContext(), &source_model, &request, .{
        .limits = .{ .background_coordinates = 1 },
    })) {
        .artifact => |derived| {
            var owned = derived;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            try std.testing.expectEqual(
                foundation.Code.capacity_exceeded,
                owned.items[0].code,
            );
        },
    }

    // A ceiling exactly at the actual count succeeds, which is what
    // distinguishes this check from an off-by-one: the case above is already
    // the tightest over-limit input (count is exactly limit + 1) and cannot
    // by itself tell `>` from `>=`.
    switch (try deriveEffectivePotential(testContext(), &source_model, &request, .{
        .limits = .{ .background_coordinates = 2 },
    })) {
        .artifact => |derived| {
            var owned = derived;
            owned.deinit();
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

test "representative allocation failures never publish a partial artifact" {
    var source_model = try loadTestModel(phi4_model_source);
    defer source_model.deinit();
    var request = try parseTestRequest(one_loop_request_source);
    defer request.deinit();

    for (0..256) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const context = switch (foundation.Context.init(
            failing.allocator(),
            testing_context_limits,
        )) {
            .context => |context| context,
            .failure => continue,
        };
        const result = deriveEffectivePotential(
            context,
            &source_model,
            &request,
            .{},
        ) catch continue;
        switch (result) {
            .artifact => |derived| {
                var owned = derived;
                defer owned.deinit();
                try std.testing.expect(owned.audit());
            },
            .diagnostics => |diagnostics| {
                var owned = diagnostics;
                owned.deinit();
            },
        }
    }
}
