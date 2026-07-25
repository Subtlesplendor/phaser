const std = @import("std");
const foundation = @import("../foundation/root.zig");
const expression = @import("../expression/root.zig");
const limits_module = @import("limits.zig");

pub const ModelSource = struct {
    source_id: foundation.SourceId,
    bytes: []const u8,
};

pub const ModelLoadOptions = struct {
    limits: limits_module.ModelLimits = .{},
    audit: bool = false,
};

pub const ModelLoadResult = union(enum) {
    model: Model,
    diagnostics: foundation.Diagnostics,
};

pub const ModelLoadError = error{
    OutOfMemory,
    DiagnosticCapacityExceeded,
    RelatedLocationCapacityExceeded,
};

pub const ModelFingerprint = struct {
    bytes: [32]u8,

    pub fn format(self: ModelFingerprint, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.bytes) |byte| try writer.print("{x:0>2}", .{byte});
    }
};

pub const Parameter = struct {
    id: u32,
    name: []const u8,
    mass_dimension: i16,
    label: ?[]const u8 = null,
    latex: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const ScalarField = struct {
    id: u32,
    name: []const u8,
    label: ?[]const u8 = null,
    latex: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const TensorKind = enum(u8) {
    vacuum_energy,
    scalar_tadpole,
    scalar_mass_squared,
    scalar_cubic,
    scalar_quartic,

    pub fn rank(self: TensorKind) u8 {
        return switch (self) {
            .vacuum_energy => 0,
            .scalar_tadpole => 1,
            .scalar_mass_squared => 2,
            .scalar_cubic => 3,
            .scalar_quartic => 4,
        };
    }

    pub fn massDimension(self: TensorKind) i32 {
        return 4 - @as(i32, self.rank());
    }
};

pub const TensorComponent = struct {
    rank: u8,
    indices: [4]u32 = .{ 0, 0, 0, 0 },
    expression_index: u32,
};

pub const Tensor = struct {
    kind: TensorKind,
    components: []const TensorComponent,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    expression_storage: []expression.Expression,
    parameters: []const Parameter,
    real_scalars: []const ScalarField,
    tensors: []const Tensor,
    model_fingerprint: ModelFingerprint,
    persistent_bytes: usize,

    pub fn deinit(self: *Model) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn fingerprint(self: *const Model) ModelFingerprint {
        return self.model_fingerprint;
    }

    pub fn expressions(self: *const Model) []const expression.Expression {
        return self.expression_storage;
    }

    pub fn tensor(self: *const Model, kind: TensorKind) ?*const Tensor {
        for (self.tensors) |*item| {
            if (item.kind == kind) return item;
        }
        return null;
    }

    pub fn scalarTensorExpression(
        self: *const Model,
        kind: TensorKind,
        indices: []const u32,
    ) ?*const expression.Expression {
        if (indices.len != kind.rank() or indices.len > 4) return null;
        var canonical: [4]u32 = .{ 0, 0, 0, 0 };
        @memcpy(canonical[0..indices.len], indices);
        std.mem.sort(u32, canonical[0..indices.len], {}, std.sort.asc(u32));
        const selected = self.tensor(kind) orelse return null;
        for (selected.components) |component| {
            if (std.mem.eql(
                u32,
                component.indices[0..component.rank],
                canonical[0..indices.len],
            )) {
                return &self.expression_storage[component.expression_index];
            }
        }
        return null;
    }

    pub fn audit(self: *const Model) bool {
        for (self.parameters, 0..) |parameter, index| {
            if (parameter.id != index) return false;
            if (index != 0 and std.mem.order(
                u8,
                self.parameters[index - 1].name,
                parameter.name,
            ) != .lt) return false;
        }
        for (self.real_scalars, 0..) |field, index| {
            if (field.id != index) return false;
        }
        var previous_kind: ?TensorKind = null;
        for (self.tensors) |tensor_value| {
            if (previous_kind) |previous| {
                if (@intFromEnum(previous) >= @intFromEnum(tensor_value.kind)) return false;
            }
            previous_kind = tensor_value.kind;
            var previous: ?TensorComponent = null;
            for (tensor_value.components) |component| {
                if (component.rank != tensor_value.kind.rank()) return false;
                if (component.expression_index >= self.expression_storage.len) return false;
                for (component.indices[0..component.rank]) |index| {
                    if (index >= self.real_scalars.len) return false;
                }
                if (!isNondecreasing(component.indices[0..component.rank])) return false;
                if (previous) |old| {
                    if (!componentLess(old, component)) return false;
                }
                previous = component;
                if (!self.expression_storage[component.expression_index].audit()) return false;
            }
        }
        return true;
    }

    pub fn writeInspection(
        self: *const Model,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("schema phaser.qft-model/0.1\n");
        try writer.writeAll("fingerprint ");
        try self.model_fingerprint.format(writer);
        try writer.writeByte('\n');
        try writer.print("parameters {d}\n", .{self.parameters.len});
        for (self.parameters) |parameter| {
            try writer.print(
                "  {d} {s} dimension={d}\n",
                .{ parameter.id, parameter.name, parameter.mass_dimension },
            );
        }
        try writer.print("real_scalars {d}\n", .{self.real_scalars.len});
        for (self.real_scalars) |field| {
            try writer.print("  {d} {s}\n", .{ field.id, field.name });
        }
        for (self.tensors) |tensor_value| {
            try writer.print(
                "tensor {s} components={d}\n",
                .{ @tagName(tensor_value.kind), tensor_value.components.len },
            );
            for (tensor_value.components) |component| {
                try writer.writeAll("  [");
                for (component.indices[0..component.rank], 0..) |index, offset| {
                    if (offset != 0) try writer.writeByte(',');
                    try writer.writeAll(self.real_scalars[index].name);
                }
                try writer.writeAll("] = ");
                try self.expression_storage[component.expression_index].write(writer);
                try writer.writeByte('\n');
            }
        }
    }
};

const RawParameter = struct {
    name: []const u8,
    value: std.json.Value,
};

const BuildState = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    expressions: std.ArrayList(expression.Expression) = .empty,
    expression_failure: ?expression.Failure = null,
    value_nodes: usize = 0,

    fn cleanupExpressions(self: *BuildState) void {
        for (self.expressions.items) |*item| item.deinit();
        self.expressions.deinit(self.allocator);
    }
};

pub fn loadModel(
    context: foundation.Context,
    source: ModelSource,
    options: ModelLoadOptions,
) ModelLoadError!ModelLoadResult {
    if (options.limits.validate()) |diagnostic| {
        return .{ .diagnostics = try oneDiagnostic(context, diagnostic) };
    }
    if (source.bytes.len > options.limits.source_bytes) {
        return .{ .diagnostics = try capacityDiagnostics(
            context,
            source,
            .source_bytes,
            options.limits.source_bytes,
            source.bytes.len,
        ) };
    }
    if (source.bytes.len > options.limits.scratch_bytes) {
        return .{ .diagnostics = try capacityDiagnostics(
            context,
            source,
            .scratch_bytes,
            options.limits.scratch_bytes,
            source.bytes.len,
        ) };
    }

    if (try scanJson(context.allocator, source, options.limits)) |diagnostic| {
        return .{ .diagnostics = try oneDiagnostic(context, diagnostic) };
    }

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        context.allocator,
        source.bytes,
        .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
            .max_value_len = options.limits.source_bytes,
            .allocate = .alloc_always,
        },
    ) catch |err| {
        return .{ .diagnostics = try simpleDiagnostics(
            context,
            source,
            if (err == error.DuplicateField) .duplicate_property else .invalid_json,
            .json,
        ) };
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{ .diagnostics = try simpleDiagnostics(
            context,
            source,
            .invalid_property_type,
            .json,
        ) },
    };

    const model_arena = try context.allocator.create(std.heap.ArenaAllocator);
    errdefer context.allocator.destroy(model_arena);
    model_arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer model_arena.deinit();
    var state = BuildState{
        .allocator = context.allocator,
        .arena = model_arena,
    };
    errdefer state.cleanupExpressions();

    const built = buildModel(source, options, root, &state) catch |err| switch (err) {
        error.InvalidModelSchema,
        error.MissingProperty,
        error.UnknownProperty,
        error.InvalidPropertyType,
        error.InvalidIdentifier,
        error.ReservedIdentifier,
        error.UnsupportedSector,
        error.InvalidConvention,
        error.InvalidExpression,
        error.CapacityExceeded,
        error.CapacityOverflow,
        error.InvalidTensorComponent,
        error.DuplicateTensorOrbit,
        error.NoncanonicalTensorIndices,
        error.ExplicitZeroComponent,
        => {
            const expression_failure = state.expression_failure;
            state.cleanupExpressions();
            model_arena.deinit();
            context.allocator.destroy(model_arena);
            const failure = failureInfo(@errorCast(err));
            if (expression_failure) |detail| {
                const raw_span = foundation.SourceSpan.init(
                    source.source_id,
                    source.bytes.len,
                    0,
                    source.bytes.len,
                ) catch unreachable;
                return .{ .diagnostics = try oneDiagnostic(context, .{
                    .code = failure.code,
                    .category = failure.category,
                    .primary = detail.span,
                    .related = &.{raw_span},
                }) };
            }
            return .{ .diagnostics = try simpleDiagnostics(
                context,
                source,
                failure.code,
                failure.category,
            ) };
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const expressions = try model_arena.allocator().dupe(
        expression.Expression,
        state.expressions.items,
    );
    state.expressions.deinit(context.allocator);
    state.expressions = .empty;

    var model = Model{
        .allocator = context.allocator,
        .arena = model_arena,
        .expression_storage = expressions,
        .parameters = built.parameters,
        .real_scalars = built.real_scalars,
        .tensors = built.tensors,
        .model_fingerprint = undefined,
        .persistent_bytes = built.persistent_bytes,
    };
    if (model.persistent_bytes > options.limits.persistent_bytes) {
        model.deinit();
        return .{ .diagnostics = try capacityDiagnostics(
            context,
            source,
            .persistent_bytes,
            options.limits.persistent_bytes,
            built.persistent_bytes,
        ) };
    }
    model.model_fingerprint = computeFingerprint(
        &model,
        context.allocator,
    ) catch return error.OutOfMemory;
    if (options.audit and !model.audit()) @panic("canonical model audit failed");
    std.debug.assert(model.audit());
    return .{ .model = model };
}

const BuildFailure = error{
    InvalidModelSchema,
    MissingProperty,
    UnknownProperty,
    InvalidPropertyType,
    InvalidIdentifier,
    ReservedIdentifier,
    UnsupportedSector,
    InvalidConvention,
    InvalidExpression,
    CapacityExceeded,
    CapacityOverflow,
    InvalidTensorComponent,
    DuplicateTensorOrbit,
    NoncanonicalTensorIndices,
    ExplicitZeroComponent,
};

fn invalid(code: foundation.Code, category: foundation.Category) BuildFailure {
    _ = category;
    return switch (code) {
        .invalid_model_schema => error.InvalidModelSchema,
        .missing_property => error.MissingProperty,
        .unknown_property => error.UnknownProperty,
        .invalid_property_type => error.InvalidPropertyType,
        .invalid_identifier => error.InvalidIdentifier,
        .reserved_identifier => error.ReservedIdentifier,
        .unsupported_sector => error.UnsupportedSector,
        .invalid_convention => error.InvalidConvention,
        .invalid_expression => error.InvalidExpression,
        .capacity_exceeded => error.CapacityExceeded,
        .capacity_overflow => error.CapacityOverflow,
        .invalid_tensor_component => error.InvalidTensorComponent,
        .duplicate_tensor_orbit => error.DuplicateTensorOrbit,
        .noncanonical_tensor_indices => error.NoncanonicalTensorIndices,
        .explicit_zero_component => error.ExplicitZeroComponent,
        else => unreachable,
    };
}

fn failureInfo(failure: BuildFailure) struct {
    code: foundation.Code,
    category: foundation.Category,
} {
    return switch (failure) {
        error.InvalidModelSchema => .{ .code = .invalid_model_schema, .category = .model },
        error.MissingProperty => .{ .code = .missing_property, .category = .json },
        error.UnknownProperty => .{ .code = .unknown_property, .category = .json },
        error.InvalidPropertyType => .{ .code = .invalid_property_type, .category = .json },
        error.InvalidIdentifier => .{ .code = .invalid_identifier, .category = .model },
        error.ReservedIdentifier => .{ .code = .reserved_identifier, .category = .model },
        error.UnsupportedSector => .{ .code = .unsupported_sector, .category = .model },
        error.InvalidConvention => .{ .code = .invalid_convention, .category = .model },
        error.InvalidExpression => .{ .code = .invalid_expression, .category = .expression },
        error.CapacityExceeded => .{ .code = .capacity_exceeded, .category = .model },
        error.CapacityOverflow => .{ .code = .capacity_overflow, .category = .model },
        error.InvalidTensorComponent => .{ .code = .invalid_tensor_component, .category = .model },
        error.DuplicateTensorOrbit => .{ .code = .duplicate_tensor_orbit, .category = .model },
        error.NoncanonicalTensorIndices => .{ .code = .noncanonical_tensor_indices, .category = .model },
        error.ExplicitZeroComponent => .{ .code = .explicit_zero_component, .category = .model },
    };
}

const Built = struct {
    parameters: []const Parameter,
    real_scalars: []const ScalarField,
    tensors: []const Tensor,
    persistent_bytes: usize,
};

fn buildModel(
    source: ModelSource,
    options: ModelLoadOptions,
    root: std.json.ObjectMap,
    state: *BuildState,
) !Built {
    try rejectUnknown(
        root,
        &.{ "schema", "spacetime_dimension", "conventions", "parameters", "fields", "tensors" },
    );
    const schema = try requiredString(root, "schema");
    if (!std.mem.eql(u8, schema, "phaser.qft-model/0.1")) {
        return invalid(.invalid_model_schema, .model);
    }
    const dimension = try requiredInteger(i16, root, "spacetime_dimension");
    if (dimension != 4) return invalid(.unsupported_sector, .model);

    const conventions = try requiredObject(root, "conventions");
    try rejectUnknown(conventions, &.{ "metric", "scalar_representation", "fermions" });
    if (!std.mem.eql(u8, try requiredString(conventions, "metric"), "mostly_plus") or
        !std.mem.eql(
            u8,
            try requiredString(conventions, "scalar_representation"),
            "real_components",
        ) or
        !std.mem.eql(
            u8,
            try requiredString(conventions, "fermions"),
            "two_component_weyl",
        ))
    {
        return invalid(.invalid_convention, .model);
    }

    const allocator = state.arena.allocator();
    const parameters = try parseParameters(
        allocator,
        try requiredObject(root, "parameters"),
        options.limits,
    );
    const fields = try requiredObject(root, "fields");
    try rejectUnknown(fields, &.{ "real_scalars", "weyl_fermions", "gauge_vectors" });
    const scalars = try parseScalars(
        allocator,
        try requiredArray(fields, "real_scalars"),
        options.limits,
    );
    if ((try requiredArray(fields, "weyl_fermions")).len != 0 or
        (try requiredArray(fields, "gauge_vectors")).len != 0)
    {
        return invalid(.unsupported_sector, .model);
    }

    const tensors = try parseTensors(
        source,
        allocator,
        try requiredObject(root, "tensors"),
        parameters,
        scalars,
        options,
        state,
    );
    const persistent_bytes = estimatePersistentBytes(parameters, scalars, tensors, state.expressions.items);
    return .{
        .parameters = parameters,
        .real_scalars = scalars,
        .tensors = tensors,
        .persistent_bytes = persistent_bytes,
    };
}

fn parseParameters(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    limits: limits_module.ModelLimits,
) ![]const Parameter {
    if (object.count() > limits.parameters) return invalid(.capacity_exceeded, .model);
    var raw = try allocator.alloc(RawParameter, object.count());
    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        raw[index] = .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
    }
    std.mem.sort(RawParameter, raw, {}, struct {
        fn less(_: void, lhs: RawParameter, rhs: RawParameter) bool {
            return std.mem.order(u8, lhs.name, rhs.name) == .lt;
        }
    }.less);

    const parameters = try allocator.alloc(Parameter, raw.len);
    for (raw, parameters, 0..) |item, *parameter, parameter_index| {
        if (!validIdentifier(item.name)) return invalid(.invalid_identifier, .model);
        if (reservedIdentifier(item.name)) return invalid(.reserved_identifier, .model);
        const declaration = switch (item.value) {
            .object => |object_value| object_value,
            else => return invalid(.invalid_property_type, .json),
        };
        try rejectUnknown(
            declaration,
            &.{ "domain", "mass_dimension", "label", "latex", "description" },
        );
        if (!std.mem.eql(u8, try requiredString(declaration, "domain"), "real")) {
            return invalid(.invalid_property_type, .model);
        }
        parameter.* = .{
            .id = @intCast(parameter_index),
            .name = try allocator.dupe(u8, item.name),
            .mass_dimension = try requiredInteger(i16, declaration, "mass_dimension"),
            .label = try optionalStringCopy(allocator, declaration, "label"),
            .latex = try optionalStringCopy(allocator, declaration, "latex"),
            .description = try optionalStringCopy(allocator, declaration, "description"),
        };
    }
    return parameters;
}

fn parseScalars(
    allocator: std.mem.Allocator,
    array: []const std.json.Value,
    limits: limits_module.ModelLimits,
) ![]const ScalarField {
    if (array.len > limits.real_scalars) return invalid(.capacity_exceeded, .model);
    const scalars = try allocator.alloc(ScalarField, array.len);
    for (array, scalars, 0..) |item, *field, index| {
        const declaration = switch (item) {
            .object => |object| object,
            else => return invalid(.invalid_property_type, .json),
        };
        try rejectUnknown(declaration, &.{ "id", "label", "latex", "description" });
        const name = try requiredString(declaration, "id");
        if (!validIdentifier(name)) return invalid(.invalid_identifier, .model);
        for (scalars[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, name)) {
                return invalid(.invalid_identifier, .model);
            }
        }
        field.* = .{
            .id = @intCast(index),
            .name = try allocator.dupe(u8, name),
            .label = try optionalStringCopy(allocator, declaration, "label"),
            .latex = try optionalStringCopy(allocator, declaration, "latex"),
            .description = try optionalStringCopy(allocator, declaration, "description"),
        };
    }
    return scalars;
}

fn parseTensors(
    source: ModelSource,
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    parameters: []const Parameter,
    scalars: []const ScalarField,
    options: ModelLoadOptions,
    state: *BuildState,
) ![]const Tensor {
    if (object.count() > 5) return invalid(.unknown_property, .json);
    var tensors: std.ArrayList(Tensor) = .empty;
    var total_components: usize = 0;
    for (std.meta.tags(TensorKind)) |kind| {
        const value = object.get(@tagName(kind)) orelse continue;
        const tensor_object = switch (value) {
            .object => |map| map,
            else => return invalid(.invalid_property_type, .json),
        };
        if (kind == .vacuum_energy) {
            try rejectUnknown(tensor_object, &.{"value"});
            const expression_index = try parseModelExpression(
                source,
                try requiredString(tensor_object, "value"),
                kind,
                parameters,
                options,
                state,
            );
            if (state.expressions.items[expression_index].isZero()) {
                return invalid(.explicit_zero_component, .model);
            }
            const components = try allocator.alloc(TensorComponent, 1);
            components[0] = .{
                .rank = 0,
                .expression_index = expression_index,
            };
            try tensors.append(allocator, .{ .kind = kind, .components = components });
            total_components += 1;
            continue;
        }

        try rejectUnknown(tensor_object, &.{"components"});
        const raw_components = try requiredArray(tensor_object, "components");
        total_components = std.math.add(usize, total_components, raw_components.len) catch
            return invalid(.capacity_overflow, .model);
        if (total_components > options.limits.tensor_components) {
            return invalid(.capacity_exceeded, .model);
        }
        const components = try allocator.alloc(TensorComponent, raw_components.len);
        for (raw_components, components) |raw_component, *component| {
            const component_object = switch (raw_component) {
                .object => |map| map,
                else => return invalid(.invalid_property_type, .json),
            };
            try rejectUnknown(component_object, &.{ "indices", "value" });
            const raw_indices = try requiredArray(component_object, "indices");
            if (raw_indices.len != kind.rank()) {
                return invalid(.invalid_tensor_component, .model);
            }
            component.* = .{
                .rank = kind.rank(),
                .expression_index = try parseModelExpression(
                    source,
                    try requiredString(component_object, "value"),
                    kind,
                    parameters,
                    options,
                    state,
                ),
            };
            for (raw_indices, 0..) |raw_index, slot| {
                const field_name = switch (raw_index) {
                    .string => |string| string,
                    else => return invalid(.invalid_property_type, .json),
                };
                component.indices[slot] = findScalar(scalars, field_name) orelse
                    return invalid(.invalid_tensor_component, .model);
            }
            if (!isNondecreasing(component.indices[0..component.rank])) {
                return invalid(.noncanonical_tensor_indices, .model);
            }
            if (state.expressions.items[component.expression_index].isZero()) {
                return invalid(.explicit_zero_component, .model);
            }
        }
        std.mem.sort(TensorComponent, components, {}, struct {
            fn less(_: void, lhs: TensorComponent, rhs: TensorComponent) bool {
                return componentLess(lhs, rhs);
            }
        }.less);
        if (components.len > 1) {
            for (components[1..], components[0 .. components.len - 1]) |current, previous| {
                if (componentEqual(current, previous)) {
                    return invalid(.duplicate_tensor_orbit, .model);
                }
            }
        }
        try tensors.append(allocator, .{ .kind = kind, .components = components });
    }

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.stringToEnum(TensorKind, entry.key_ptr.*) == null) {
            return invalid(.unknown_property, .json);
        }
    }
    return tensors.items;
}

fn parseModelExpression(
    source: ModelSource,
    text: []const u8,
    kind: TensorKind,
    parameters: []const Parameter,
    options: ModelLoadOptions,
    state: *BuildState,
) !u32 {
    const expression_parameters = try state.arena.allocator().alloc(
        expression.Parameter,
        parameters.len,
    );
    for (parameters, expression_parameters) |parameter, *target| {
        target.* = .{
            .name = parameter.name,
            .id = parameter.id,
            .mass_dimension = parameter.mass_dimension,
        };
    }
    const expression_source_id = foundation.SourceId.fromUsize(
        source.source_id.toUsize() + state.expressions.items.len + 1,
    ) catch return invalid(.capacity_overflow, .model);
    const result = try expression.parse(
        state.arena.allocator(),
        expression_source_id,
        text,
        expression_parameters,
        .{
            .limits = options.limits,
            .required_dimension = kind.massDimension(),
        },
    );
    var parsed_expression = switch (result) {
        .expression => |item| item,
        .failure => |failure| {
            state.expression_failure = failure;
            return invalid(.invalid_expression, .expression);
        },
    };
    errdefer parsed_expression.deinit();
    const index = state.expressions.items.len;
    state.value_nodes = std.math.add(
        usize,
        state.value_nodes,
        parsed_expression.values.len,
    ) catch return invalid(.capacity_overflow, .model);
    if (state.value_nodes > options.limits.value_nodes) {
        return invalid(.capacity_exceeded, .model);
    }
    try state.expressions.append(state.allocator, parsed_expression);
    return @intCast(index);
}

fn scanJson(
    allocator: std.mem.Allocator,
    source: ModelSource,
    limits: limits_module.ModelLimits,
) !?foundation.Diagnostic {
    var scanner = std.json.Scanner.initCompleteInput(allocator, source.bytes);
    defer scanner.deinit();
    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);
    var token_count: usize = 0;
    var depth: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            allocator,
            .alloc_if_needed,
            limits.source_bytes,
        ) catch {
            return diagnosticAt(
                source,
                .invalid_json,
                .json,
                @intCast(@min(diagnostics.getByteOffset(), source.bytes.len)),
            );
        };
        defer switch (token) {
            .allocated_string => |slice| allocator.free(slice),
            .allocated_number => |slice| allocator.free(slice),
            else => {},
        };
        token_count += 1;
        if (token_count > limits.json_tokens) {
            return diagnosticAt(source, .capacity_exceeded, .json, scanner.cursor);
        }
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.json_nesting) {
                    return diagnosticAt(source, .capacity_exceeded, .json, scanner.cursor);
                }
            },
            .object_end, .array_end => depth -= 1,
            .end_of_document => break,
            else => {},
        }
    }
    return null;
}

fn computeFingerprint(model: *const Model, allocator: std.mem.Allocator) !ModelFingerprint {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("model-canonical/1\x00phaser.qft-model/0.1\x00");
    try output.writer.writeAll("4\x00mostly_plus\x00real_components\x00two_component_weyl\x00");
    for (model.parameters) |parameter| {
        try output.writer.print(
            "p:{d}:{s}:{d};",
            .{ parameter.name.len, parameter.name, parameter.mass_dimension },
        );
    }
    for (model.real_scalars) |field| {
        try output.writer.print("s:{d}:{s};", .{ field.name.len, field.name });
    }
    for (model.tensors) |tensor| {
        try output.writer.print("t:{s};", .{@tagName(tensor.kind)});
        for (tensor.components) |component| {
            try output.writer.writeByte('[');
            for (component.indices[0..component.rank]) |index| {
                try output.writer.print("{d},", .{index});
            }
            try output.writer.writeAll("]=");
            try model.expression_storage[component.expression_index].write(&output.writer);
            try output.writer.writeByte(';');
        }
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output.written(), &digest, .{});
    return .{ .bytes = digest };
}

fn estimatePersistentBytes(
    parameters: []const Parameter,
    scalars: []const ScalarField,
    tensors: []const Tensor,
    expressions: []const expression.Expression,
) usize {
    var total = parameters.len * @sizeOf(Parameter) +
        scalars.len * @sizeOf(ScalarField) +
        tensors.len * @sizeOf(Tensor) +
        expressions.len * @sizeOf(expression.Expression);
    for (parameters) |parameter| {
        total += parameter.name.len;
        if (parameter.label) |text| total += text.len;
        if (parameter.latex) |text| total += text.len;
        if (parameter.description) |text| total += text.len;
    }
    for (scalars) |field| {
        total += field.name.len;
        if (field.label) |text| total += text.len;
        if (field.latex) |text| total += text.len;
        if (field.description) |text| total += text.len;
    }
    for (tensors) |tensor| total += tensor.components.len * @sizeOf(TensorComponent);
    for (expressions) |item| {
        total += item.values.len * @sizeOf(expression.Value);
        for (item.values) |value| {
            switch (value.node) {
                .rational, .sqrt_rational => |rational| {
                    total += rational.numerator.len + rational.denominator.len;
                },
                .parameter => |parameter| total += parameter.name.len,
                .add, .multiply => |children| total += children.len * @sizeOf(expression.ValueId),
                else => {},
            }
        }
    }
    return total;
}

fn requiredObject(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse return invalid(.missing_property, .json);
    return switch (value) {
        .object => |map| map,
        else => invalid(.invalid_property_type, .json),
    };
}

fn requiredArray(object: std.json.ObjectMap, key: []const u8) ![]const std.json.Value {
    const value = object.get(key) orelse return invalid(.missing_property, .json);
    return switch (value) {
        .array => |array| array.items,
        else => invalid(.invalid_property_type, .json),
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return invalid(.missing_property, .json);
    return switch (value) {
        .string => |string| string,
        else => invalid(.invalid_property_type, .json),
    };
}

fn optionalStringCopy(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| try allocator.dupe(u8, string),
        else => invalid(.invalid_property_type, .json),
    };
}

fn requiredInteger(
    comptime T: type,
    object: std.json.ObjectMap,
    key: []const u8,
) !T {
    const value = object.get(key) orelse return invalid(.missing_property, .json);
    const number = switch (value) {
        .number_string => |string| string,
        else => return invalid(.invalid_property_type, .json),
    };
    return std.fmt.parseInt(T, number, 10) catch invalid(.invalid_property_type, .json);
}

fn rejectUnknown(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                found = true;
                break;
            }
        }
        if (!found) return invalid(.unknown_property, .json);
    }
}

fn validIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0) return false;
    if (!(std.ascii.isAlphabetic(identifier[0]) or identifier[0] == '_')) return false;
    for (identifier[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn reservedIdentifier(identifier: []const u8) bool {
    return std.mem.eql(u8, identifier, "pi") or
        std.mem.eql(u8, identifier, "sqrt") or
        std.mem.eql(u8, identifier, "i");
}

fn findScalar(scalars: []const ScalarField, name: []const u8) ?u32 {
    for (scalars) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.id;
    }
    return null;
}

fn isNondecreasing(indices: []const u32) bool {
    if (indices.len < 2) return true;
    for (indices[1..], indices[0 .. indices.len - 1]) |current, previous| {
        if (current < previous) return false;
    }
    return true;
}

fn componentLess(lhs: TensorComponent, rhs: TensorComponent) bool {
    for (lhs.indices[0..lhs.rank], rhs.indices[0..rhs.rank]) |left, right| {
        if (left != right) return left < right;
    }
    return false;
}

fn componentEqual(lhs: TensorComponent, rhs: TensorComponent) bool {
    return std.mem.eql(u32, lhs.indices[0..lhs.rank], rhs.indices[0..rhs.rank]);
}

fn diagnosticAt(
    source: ModelSource,
    code: foundation.Code,
    category: foundation.Category,
    offset: usize,
) foundation.Diagnostic {
    return .{
        .code = code,
        .category = category,
        .primary = foundation.SourceSpan.init(
            source.source_id,
            source.bytes.len,
            @min(offset, source.bytes.len),
            @min(offset + @intFromBool(offset < source.bytes.len), source.bytes.len),
        ) catch unreachable,
    };
}

fn simpleDiagnostics(
    context: foundation.Context,
    source: ModelSource,
    code: foundation.Code,
    category: foundation.Category,
) ModelLoadError!foundation.Diagnostics {
    return oneDiagnostic(context, diagnosticAt(source, code, category, 0));
}

fn capacityDiagnostics(
    context: foundation.Context,
    source: ModelSource,
    resource: foundation.Resource,
    limit: usize,
    requested: usize,
) ModelLoadError!foundation.Diagnostics {
    var diagnostic = diagnosticAt(source, .capacity_exceeded, .model, 0);
    diagnostic.detail = .{ .capacity = .{
        .resource = resource,
        .limit = limit,
        .current = 0,
        .requested = requested,
    } };
    return oneDiagnostic(context, diagnostic);
}

fn oneDiagnostic(
    context: foundation.Context,
    diagnostic: foundation.Diagnostic,
) ModelLoadError!foundation.Diagnostics {
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

test "model loader parses and fingerprints the phi4 fixture" {
    const source =
        \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
        \\"conventions":{"metric":"mostly_plus","scalar_representation":"real_components","fermions":"two_component_weyl"},
        \\"parameters":{"lambda":{"domain":"real","mass_dimension":0},"m2":{"domain":"real","mass_dimension":2},"omega":{"domain":"real","mass_dimension":4}},
        \\"fields":{"real_scalars":[{"id":"phi"}],"weyl_fermions":[],"gauge_vectors":[]},
        \\"tensors":{"vacuum_energy":{"value":"omega"},"scalar_mass_squared":{"components":[{"indices":["phi","phi"],"value":"m2"}]},"scalar_quartic":{"components":[{"indices":["phi","phi","phi","phi"],"value":"lambda"}]}}}
    ;
    const context = switch (foundation.Context.init(std.testing.allocator, .{
        .max_diagnostics = 16,
        .max_related_locations = 16,
    })) {
        .context => |context| context,
        .failure => return error.TestUnexpectedResult,
    };
    const source_id = try foundation.SourceId.fromUsize(0);
    const result = try loadModel(context, .{
        .source_id = source_id,
        .bytes = source,
    }, .{ .audit = true });
    var model = switch (result) {
        .model => |model| model,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 3), model.parameters.len);
    try std.testing.expectEqualStrings("lambda", model.parameters[0].name);
    try std.testing.expectEqual(@as(usize, 1), model.real_scalars.len);
    try std.testing.expect(model.audit());
}

test "model loader rejects unsupported field sectors" {
    const source =
        \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
        \\"conventions":{"metric":"mostly_plus","scalar_representation":"real_components","fermions":"two_component_weyl"},
        \\"parameters":{},"fields":{"real_scalars":[],"weyl_fermions":[{"id":"x"}],"gauge_vectors":[]},"tensors":{}}
    ;
    const context = switch (foundation.Context.init(std.testing.allocator, .{
        .max_diagnostics = 4,
        .max_related_locations = 4,
    })) {
        .context => |context| context,
        .failure => return error.TestUnexpectedResult,
    };
    const result = try loadModel(context, .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = source,
    }, .{});
    var diagnostics = switch (result) {
        .model => |model| {
            var owned = model;
            defer owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| diagnostics,
    };
    defer diagnostics.deinit();
    try std.testing.expectEqual(foundation.Code.unsupported_sector, diagnostics.items[0].code);
}

test "model loader distinguishes duplicate JSON members" {
    const source = "{\"schema\":\"phaser.qft-model/0.1\",\"schema\":\"phaser.qft-model/0.1\"}";
    const context = switch (foundation.Context.init(std.testing.allocator, .{
        .max_diagnostics = 4,
        .max_related_locations = 4,
    })) {
        .context => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    const result = try loadModel(context, .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = source,
    }, .{});
    var diagnostics = switch (result) {
        .diagnostics => |value| value,
        .model => |model| {
            var owned = model;
            defer owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer diagnostics.deinit();
    try std.testing.expectEqual(
        foundation.Code.duplicate_property,
        diagnostics.items[0].code,
    );
}

test "representative allocation failures never publish a partial model" {
    const source =
        \\{"schema":"phaser.qft-model/0.1","spacetime_dimension":4,
        \\"conventions":{"metric":"mostly_plus","scalar_representation":"real_components","fermions":"two_component_weyl"},
        \\"parameters":{},"fields":{"real_scalars":[],"weyl_fermions":[],"gauge_vectors":[]},"tensors":{}}
    ;
    for (0..24) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const context = switch (foundation.Context.init(failing.allocator(), .{
            .max_diagnostics = 4,
            .max_related_locations = 4,
        })) {
            .context => |value| value,
            .failure => unreachable,
        };
        const result = loadModel(context, .{
            .source_id = try foundation.SourceId.fromUsize(0),
            .bytes = source,
        }, .{}) catch |err| {
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            continue;
        };
        switch (result) {
            .model => |model| {
                var owned = model;
                owned.deinit();
            },
            .diagnostics => |diagnostics| {
                var owned = diagnostics;
                owned.deinit();
            },
        }
    }
}
