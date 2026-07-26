//! Immutable bound parameter context.
//!
//! Follows `docs/architecture/EVALUATION_LIFECYCLE.md` section 3.6: a binding
//! associates a kernel with model parameters at the intended scale, may
//! precompute values depending only on those inputs, and must not perform
//! background-dependent work.
//!
//! Version 0.1 creates a new binding for a new parameter point. Mutable
//! in-place rebinding is a future measured optimization, not a current
//! capability.

const std = @import("std");
const calculation = @import("../calculation/root.zig");
const model_module = @import("../model/root.zig");
const error_injection = @import("../testing/error_injection.zig");
const program_module = @import("program.zig");
const interpret_module = @import("interpret.zig");
const potential_module = @import("potential.zig");

const Scalar = program_module.Scalar;
const Kernel = potential_module.Kernel;

pub const BindError = error{
    OutOfMemory,
    /// The point does not cover every model parameter exactly once.
    MissingParameterValue,
    UnknownParameterValue,
    /// The point's scheme differs from the one the artifact declared.
    SchemeMismatch,
};

const bind_tw = error_injection.module(enum {
    parameter_storage,
    prologue_storage,
    publish,
}, error{OutOfMemory});

pub const Binding = struct {
    arena: *std.heap.ArenaAllocator,
    /// Copy of the kernel's lowered program.
    ///
    /// The struct is copied but its instructions, constants, and output tables
    /// are not: those live in the kernel's arena. Holding the program by value
    /// rather than holding a pointer to the kernel means a binding survives the
    /// kernel struct being moved, which is the ordinary thing to do with a value
    /// returned from `compile`. The requirement is that the kernel's storage
    /// outlive the binding, not that its address stay fixed.
    program: program_module.Program,
    coordinate_count: usize,
    /// Packed parameter channel values, in kernel channel order.
    parameters: []const Scalar,
    /// The temporary array after the parameter stage has run. Copied into
    /// workspace at the start of each evaluation.
    prologue: []const Scalar,
    /// Status produced while constructing `prologue`. It applies to every
    /// background point evaluated from this binding.
    prologue_status: program_module.Status,
    scheme: calculation.Scheme,
    reference_scale: Scalar,

    pub fn deinit(self: *Binding) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn workspaceLayout(
        self: *const Binding,
        point_count: usize,
    ) program_module.WorkspaceLayout {
        return self.program.workspaceLayout(point_count);
    }

    pub fn coordinateCount(self: *const Binding) usize {
        return self.coordinate_count;
    }

    /// Evaluates background points against this bound parameter context.
    ///
    /// The parameter-dependent work was already done at bind time, so a batch
    /// pays for it once rather than once per point. Results are bitwise
    /// identical to the unstaged path.
    pub fn evaluate(
        self: *const Binding,
        backgrounds: []const Scalar,
        point_count: usize,
        workspace: []u8,
        outputs: interpret_module.OutputBuffers,
    ) interpret_module.CallError!void {
        return interpret_module.evaluateStaged(
            &self.program,
            self.prologue,
            self.prologue_status,
            backgrounds,
            point_count,
            workspace,
            outputs,
        );
    }
};

/// Binds a validated parameter point to a kernel.
///
/// The point is validated against the complete model, not merely against the
/// channels this kernel happens to use, so a kernel that depends on a subset
/// still requires a complete and consistent point.
pub fn bind(
    allocator: std.mem.Allocator,
    kernel: *const Kernel,
    source_model: *const model_module.Model,
    point: *const calculation.ParameterPoint,
) BindError!Binding {
    try calculation.validateCoverage(point, source_model);

    // A single evaluation must not mix schemes. The values carry their own
    // scheme; when the artifact also declared one, they must agree.
    if (kernel.scheme) |declared| {
        if (declared != point.scheme) return error.SchemeMismatch;
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    try bind_tw.check(.parameter_storage);
    const parameters = try arena.allocator().alloc(Scalar, kernel.parameters.len);
    for (kernel.parameters, parameters) |channel, *slot| {
        // Channel names come from the model, so coverage validation above
        // guarantees the lookup succeeds.
        slot.* = point.lookup(channel.name) orelse return error.MissingParameterValue;
    }

    try bind_tw.check(.prologue_storage);
    const prologue = try arena.allocator().alloc(
        Scalar,
        kernel.program.temporary_count,
    );
    @memset(prologue, 0);
    const prologue_status = interpret_module.runParameterStage(
        &kernel.program,
        parameters,
        prologue,
    );

    try bind_tw.check(.publish);
    return .{
        .arena = arena,
        .program = kernel.program,
        .coordinate_count = kernel.coordinateCount(),
        .parameters = parameters,
        .prologue = prologue,
        .prologue_status = prologue_status,
        .scheme = point.scheme,
        .reference_scale = point.reference_scale,
    };
}

test "tripwires exercise every parameter binding rollback boundary" {
    const channels = [_]potential_module.Channel{.{
        .name = "lambda",
        .offset = 0,
        .mass_dimension = 0,
    }};
    const source_parameters = [_]model_module.Parameter{.{
        .id = 0,
        .name = "lambda",
        .mass_dimension = 0,
    }};
    const entries = [_]calculation.parameter_point.Entry{.{
        .name = "lambda",
        .value = 0.25,
    }};

    const kernel = Kernel{
        .arena = undefined,
        .program = .{
            .arena = undefined,
            .instructions = &.{},
            .constants = &.{},
            .outputs = .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
            .capability = .value,
            .parameter_stage_count = 0,
            .temporary_count = 1,
            .parameter_count = 1,
            .background_count = 1,
            .coordinate_count = 1,
        },
        .model_fingerprint = [_]u8{0} ** 32,
        .request_fingerprint = [_]u8{0} ** 32,
        .background_mode = .full_scalar_space,
        .scheme = null,
        .parameters = &channels,
        .coordinates = &.{},
    };
    var source_model: model_module.Model = undefined;
    source_model.parameters = &source_parameters;
    var point: calculation.ParameterPoint = undefined;
    point.scheme = .msbar;
    point.reference_scale = 125.0;
    point.entries = &entries;

    for (std.meta.tags(bind_tw.FailPoint)) |fail_point| {
        bind_tw.errorAlways(fail_point, error.OutOfMemory);
        defer bind_tw.reset();
        try std.testing.expectError(
            error.OutOfMemory,
            bind(
                std.testing.allocator,
                &kernel,
                &source_model,
                &point,
            ),
        );
        try bind_tw.end(.reset);
    }
}
