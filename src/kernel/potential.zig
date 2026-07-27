//! Potential Kernel: the potential-specific interface over a lowered program.
//!
//! Compiled from a classical-potential artifact and an explicit configuration,
//! following `docs/architecture/POTENTIAL_KERNEL.md`. The kernel is immutable
//! and reusable across parameter points and background batches; a dynamic value
//! becoming zero never triggers recompilation.

const std = @import("std");
const calculation = @import("../calculation/root.zig");
const error_injection = @import("../testing/error_injection.zig");
const value = @import("../value/root.zig");
const program_module = @import("program.zig");
const lower_module = @import("lower.zig");
const interpret_module = @import("interpret.zig");

pub const Scalar = program_module.Scalar;
pub const Complex64 = program_module.Complex64;
pub const ResultType = program_module.ResultType;
pub const Capability = program_module.Capability;
pub const Status = program_module.Status;
pub const WorkspaceLayout = program_module.WorkspaceLayout;
pub const CallError = interpret_module.CallError;
pub const OutputBuffers = interpret_module.OutputBuffers;
pub const ComplexOutputBuffers = interpret_module.ComplexOutputBuffers;

pub const CompileError = lower_module.LowerError ||
    program_module.ValidationError ||
    error{
        CapabilityNotDerived,
        /// The artifact records no contribution for the requested selection.
        SelectionNotDerived,
        OutOfMemory,
    };

/// Which of an artifact's contributions a kernel evaluates.
///
/// Selection is explicit and never widened: `total` means the complete
/// requested truncation, not "whatever is available".
pub const Selection = union(enum) {
    /// The complete requested truncation.
    total,
    /// Exactly one loop order.
    loop_order: u32,
    /// Exactly one contribution role.
    role: calculation.Role,
};

pub const Configuration = struct {
    capability: Capability = .value_gradient_hessian,
    selection: Selection = .total,
    lowering: lower_module.LowerOptions = .{},
};

const compile_tw = error_injection.module(enum {
    parameter_channels,
    coordinate_channels,
    lower_program,
    validate_program,
    publish,
}, error{OutOfMemory});

/// Describes one packed input channel, so callers can pack by semantic
/// identity rather than by guessing an offset.
pub const Channel = struct {
    name: []const u8,
    /// Offset into the packed buffer for this channel's category.
    offset: u32,
    mass_dimension: i32,
};

pub const Kernel = struct {
    arena: *std.heap.ArenaAllocator,
    program: program_module.Program,
    model_fingerprint: [32]u8,
    request_fingerprint: [32]u8,
    background_mode: calculation.BackgroundMode,
    /// Present when the artifact declared a renormalization scheme. Binding
    /// rejects a parameter point whose scheme differs, so one evaluation cannot
    /// mix schemes.
    scheme: ?calculation.Scheme,
    /// The contribution set this kernel evaluates.
    selection: Selection,
    parameters: []const Channel,
    coordinates: []const Channel,
    /// The renormalization-scale channel, present exactly when the selected
    /// contributions depend on it.
    scale: ?Channel,

    pub fn deinit(self: *Kernel) void {
        const allocator = self.arena.child_allocator;
        self.program.deinit();
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn capability(self: *const Kernel) Capability {
        return self.program.capability;
    }

    pub fn coordinateCount(self: *const Kernel) usize {
        return self.coordinates.len;
    }

    pub fn parameterCount(self: *const Kernel) usize {
        return self.parameters.len;
    }

    pub fn workspaceLayout(self: *const Kernel, point_count: usize) WorkspaceLayout {
        return self.program.workspaceLayout(point_count);
    }

    /// The element type of this kernel's outputs.
    ///
    /// Fixed by the selected contributions rather than by a point's values, so
    /// a caller chooses its buffers once.
    pub fn resultType(self: *const Kernel) ResultType {
        return self.program.result_type;
    }

    /// Evaluates a batch of independent background points into real buffers.
    ///
    /// Output order equals input point order. Execution allocates nothing.
    pub fn evaluate(
        self: *const Kernel,
        inputs: interpret_module.Inputs,
        point_count: usize,
        workspace: []u8,
        outputs: OutputBuffers,
    ) CallError!void {
        return interpret_module.evaluate(
            &self.program,
            inputs,
            point_count,
            workspace,
            outputs,
        );
    }

    /// Evaluates a batch of independent background points into `Complex64`
    /// buffers.
    pub fn evaluateComplex(
        self: *const Kernel,
        inputs: interpret_module.Inputs,
        point_count: usize,
        workspace: []u8,
        outputs: ComplexOutputBuffers,
    ) CallError!void {
        return interpret_module.evaluateComplex(
            &self.program,
            inputs,
            point_count,
            workspace,
            outputs,
        );
    }
};

/// Compiles a kernel from a derived artifact.
///
/// The artifact must already carry the derivatives the requested capability
/// needs; lowering does not derive new structure.
pub fn compile(
    allocator: std.mem.Allocator,
    artifact: *const calculation.Artifact,
    configuration: Configuration,
) CompileError!Kernel {
    const selected = switch (configuration.selection) {
        .total => artifact.totalSelection(),
        .loop_order => |order| artifact.loopTotal(order) orelse
            return error.SelectionNotDerived,
        .role => |role| artifact.roleTotal(role) orelse
            return error.SelectionNotDerived,
    };

    const coordinate_count = artifact.coordinates.len;
    if (configuration.capability.includesGradient() and
        selected.gradient.len != coordinate_count)
    {
        return error.CapabilityNotDerived;
    }
    if (configuration.capability.includesHessian() and
        selected.hessian.len != coordinate_count * coordinate_count)
    {
        return error.CapabilityNotDerived;
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Parameter channels follow the model's canonical parameter order, which
    // the value graph's parameter identifiers index directly.
    var highest_parameter: u32 = 0;
    for (artifact.graph.values) |item| {
        switch (item.node) {
            .parameter => |input| highest_parameter = @max(highest_parameter, input.id + 1),
            else => {},
        }
    }

    try compile_tw.check(.parameter_channels);
    const parameters = try arena.allocator().alloc(Channel, highest_parameter);
    for (parameters, 0..) |*channel, index| {
        channel.* = .{ .name = "", .offset = @intCast(index), .mass_dimension = 0 };
    }
    for (artifact.graph.values) |item| {
        switch (item.node) {
            .parameter => |input| parameters[input.id] = .{
                .name = try arena.allocator().dupe(u8, input.name),
                .offset = input.id,
                .mass_dimension = item.mass_dimension,
            },
            else => {},
        }
    }

    try compile_tw.check(.coordinate_channels);
    const coordinates = try arena.allocator().alloc(Channel, coordinate_count);
    for (artifact.coordinates, coordinates, 0..) |declared, *channel, index| {
        channel.* = .{
            .name = try arena.allocator().dupe(u8, declared.id),
            .offset = @intCast(index),
            .mass_dimension = declared.mass_dimension,
        };
    }

    const gradient_roots = if (configuration.capability.includesGradient())
        selected.gradient
    else
        &.{};
    const hessian_roots = if (configuration.capability.includesHessian())
        selected.hessian
    else
        &.{};

    try compile_tw.check(.lower_program);
    var program = try lower_module.lower(allocator, .{
        .graph = &artifact.graph,
        .capability = configuration.capability,
        .value_root = selected.value,
        .gradient_roots = gradient_roots,
        .hessian_roots = hessian_roots,
        .parameter_count = highest_parameter,
        .background_count = @intCast(coordinate_count),
        .coordinate_count = @intCast(coordinate_count),
    }, configuration.lowering);
    errdefer program.deinit();

    try compile_tw.check(.validate_program);
    try program.validate(allocator, configuration.lowering.exponent_limit);

    // A scale channel exists exactly when the lowered program reads one, so a
    // selection whose contributions carry no scale dependence declares none.
    const scale: ?Channel = if (program.scale_count == 0) null else .{
        .name = try arena.allocator().dupe(u8, calculation.scale_name),
        .offset = 0,
        .mass_dimension = value.scale_mass_dimension,
    };

    try compile_tw.check(.publish);
    return .{
        .arena = arena,
        .program = program,
        .model_fingerprint = artifact.model_fingerprint.bytes,
        .request_fingerprint = artifact.request_fingerprint.bytes,
        .background_mode = artifact.background_mode,
        .scheme = artifact.scheme,
        .selection = configuration.selection,
        .parameters = parameters,
        .coordinates = coordinates,
        .scale = scale,
    };
}

fn testArtifact(allocator: std.mem.Allocator) !calculation.Artifact {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var builder = try value.Builder.init(allocator, .{});
    errdefer builder.deinit();
    const phi = try builder.background(0, "phi", 1);
    const lambda = try builder.parameter(0, "lambda", 0);
    const total = try builder.multiply(&.{
        lambda,
        try builder.power(phi, 4),
    });
    var graph = try builder.finish();
    errdefer graph.deinit();

    const coordinates = try arena.allocator().alloc(calculation.Coordinate, 1);
    coordinates[0] = .{
        .id = "phi",
        .scalar_index = 0,
        .mass_dimension = 1,
        .node = phi,
    };

    const loop_totals = try arena.allocator().alloc(calculation.LoopTotal, 1);
    loop_totals[0] = .{
        .loop_order = 0,
        .selection = .{
            .result_type = .real64,
            .value = total,
            .gradient = &.{},
            .hessian = &.{},
        },
    };

    return .{
        .arena = arena,
        .graph = graph,
        .model_fingerprint = .{ .bytes = [_]u8{0} ** 32 },
        .request_fingerprint = .{ .bytes = [_]u8{0} ** 32 },
        .background_mode = .full_scalar_space,
        .scheme = null,
        .loop_order = 0,
        .coordinates = coordinates,
        .scale = null,
        .contributions = &.{},
        .absences = &.{},
        .result_type = .real64,
        .total = total,
        .gradient = &.{},
        .hessian = &.{},
        .loop_totals = loop_totals,
    };
}

test "tripwires exercise every kernel compilation rollback boundary" {
    var artifact = try testArtifact(std.testing.allocator);
    defer artifact.deinit();

    for (std.meta.tags(compile_tw.FailPoint)) |point| {
        compile_tw.errorAlways(point, error.OutOfMemory);
        defer compile_tw.reset();
        try std.testing.expectError(
            error.OutOfMemory,
            compile(std.testing.allocator, &artifact, .{ .capability = .value }),
        );
        try compile_tw.end(.reset);
    }
}
