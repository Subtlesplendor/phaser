//! Potential Kernel: the potential-specific interface over a lowered program.
//!
//! Compiled from a classical-potential artifact and an explicit configuration,
//! following `docs/architecture/POTENTIAL_KERNEL.md`. The kernel is immutable
//! and reusable across parameter points and background batches; a dynamic value
//! becoming zero never triggers recompilation.

const std = @import("std");
const calculation = @import("../calculation/root.zig");
const program_module = @import("program.zig");
const lower_module = @import("lower.zig");
const interpret_module = @import("interpret.zig");

pub const Scalar = program_module.Scalar;
pub const Capability = program_module.Capability;
pub const Status = program_module.Status;
pub const WorkspaceLayout = program_module.WorkspaceLayout;
pub const CallError = interpret_module.CallError;
pub const OutputBuffers = interpret_module.OutputBuffers;

pub const CompileError = lower_module.LowerError ||
    program_module.ValidationError ||
    error{ CapabilityNotDerived, OutOfMemory };

pub const Configuration = struct {
    capability: Capability = .value_gradient_hessian,
    lowering: lower_module.LowerOptions = .{},
};

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
    parameters: []const Channel,
    coordinates: []const Channel,

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

    /// Evaluates a batch of independent background points.
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
    const coordinate_count = artifact.coordinates.len;
    if (configuration.capability.includesGradient() and
        artifact.gradient.len != coordinate_count)
    {
        return error.CapabilityNotDerived;
    }
    if (configuration.capability.includesHessian() and
        artifact.hessian.len != coordinate_count * coordinate_count)
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

    const coordinates = try arena.allocator().alloc(Channel, coordinate_count);
    for (artifact.coordinates, coordinates, 0..) |declared, *channel, index| {
        channel.* = .{
            .name = try arena.allocator().dupe(u8, declared.id),
            .offset = @intCast(index),
            .mass_dimension = declared.mass_dimension,
        };
    }

    const gradient_roots = if (configuration.capability.includesGradient())
        artifact.gradient
    else
        &.{};
    const hessian_roots = if (configuration.capability.includesHessian())
        artifact.hessian
    else
        &.{};

    var program = try lower_module.lower(allocator, .{
        .graph = &artifact.graph,
        .capability = configuration.capability,
        .value_root = artifact.total,
        .gradient_roots = gradient_roots,
        .hessian_roots = hessian_roots,
        .parameter_count = highest_parameter,
        .background_count = @intCast(coordinate_count),
        .coordinate_count = @intCast(coordinate_count),
    }, configuration.lowering);
    errdefer program.deinit();

    try program.validate(allocator, configuration.lowering.exponent_limit);

    return .{
        .arena = arena,
        .program = program,
        .model_fingerprint = artifact.model_fingerprint.bytes,
        .request_fingerprint = artifact.request_fingerprint.bytes,
        .background_mode = artifact.background_mode,
        .parameters = parameters,
        .coordinates = coordinates,
    };
}
