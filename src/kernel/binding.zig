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
const optimized_plan_module = @import("optimized_plan.zig");
const optimized_interpret_module = @import("optimized_interpret.zig");
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
    /// The point's reference scale is not finite and positive, which the
    /// scalar one-loop formula version requires.
    InvalidScale,
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
    backend: program_module.Backend,
    /// Borrowed immutable plan storage owned by the kernel. As with `program`,
    /// the kernel's allocation must outlive the binding, but its struct may move.
    optimized_plan: ?optimized_plan_module.ExecutionPlan,
    coordinate_count: usize,
    /// Packed parameter channel values, in kernel channel order.
    parameters: []const Scalar,
    /// Packed renormalization-scale channel values. Empty when the kernel
    /// declares no scale channel.
    scales: []const Scalar,
    /// Parameter-stage state needed by later instructions, as bytes. The
    /// reference backend stores the complete frame; the optimized backend
    /// stores only live regions selected by its immutable execution plan.
    prologue: []align(@alignOf(Scalar)) const u8,
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
        return switch (self.backend) {
            .reference_interpreter => self.program.workspaceLayout(point_count),
            .optimized_interpreter => self.optimized_plan.?.workspaceLayout(point_count),
        };
    }

    pub fn coordinateCount(self: *const Binding) usize {
        return self.coordinate_count;
    }

    pub fn resultType(self: *const Binding) program_module.ResultType {
        return self.program.result_type;
    }

    pub fn backendKind(self: *const Binding) program_module.Backend {
        return self.backend;
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
        return switch (self.backend) {
            .reference_interpreter => interpret_module.evaluateStaged(
                &self.program,
                self.prologue,
                self.prologue_status,
                backgrounds,
                point_count,
                workspace,
                outputs,
            ),
            .optimized_interpreter => optimized_interpret_module.evaluateStaged(
                &self.optimized_plan.?,
                self.prologue,
                self.prologue_status,
                backgrounds,
                point_count,
                workspace,
                outputs,
            ),
        };
    }

    /// The `Complex64` counterpart of `evaluate`.
    pub fn evaluateComplex(
        self: *const Binding,
        backgrounds: []const Scalar,
        point_count: usize,
        workspace: []u8,
        outputs: interpret_module.ComplexOutputBuffers,
    ) interpret_module.CallError!void {
        return switch (self.backend) {
            .reference_interpreter => interpret_module.evaluateStagedComplex(
                &self.program,
                self.prologue,
                self.prologue_status,
                backgrounds,
                point_count,
                workspace,
                outputs,
            ),
            .optimized_interpreter => optimized_interpret_module.evaluateStagedComplex(
                &self.optimized_plan.?,
                self.prologue,
                self.prologue_status,
                backgrounds,
                point_count,
                workspace,
                outputs,
            ),
        };
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

    // The scale is a distinct input category from a model parameter, and the
    // restricted one-loop logarithm is defined only for a finite positive one,
    // so it is validated here rather than at every point.
    const scales = try arena.allocator().alloc(Scalar, kernel.program.scale_count);
    if (scales.len != 0) {
        if (!std.math.isFinite(point.reference_scale) or point.reference_scale <= 0) {
            return error.InvalidScale;
        }
        @memset(scales, point.reference_scale);
    }

    try bind_tw.check(.prologue_storage);
    // The reference backend snapshots the complete typed frame. The optimized
    // backend stores only parameter-stage regions live into point execution or
    // final publication.
    const prologue_bytes = switch (kernel.backend()) {
        .reference_interpreter => kernel.program.frame_bytes,
        .optimized_interpreter => kernel.optimized_plan.?.prologueBytes(),
    };
    const prologue = try arena.allocator().alignedAlloc(
        u8,
        .of(Scalar),
        prologue_bytes,
    );
    @memset(prologue, 0);
    const prologue_status = switch (kernel.backend()) {
        .reference_interpreter => blk: {
            const scratch = try arena.allocator().alignedAlloc(
                u8,
                .of(Scalar),
                kernel.program.scratch_bytes,
            );
            break :blk interpret_module.runParameterStage(
                &kernel.program,
                .{ .parameters = parameters, .scales = scales, .backgrounds = &.{} },
                prologue,
                scratch,
            );
        },
        .optimized_interpreter => blk: {
            const plan = &kernel.optimized_plan.?;
            const temporary = try allocator.alignedAlloc(
                u8,
                .of(@Vector(2, Scalar)),
                plan.workspace_bytes,
            );
            defer allocator.free(temporary);
            break :blk optimized_interpret_module.runParameterStage(
                plan,
                .{ .parameters = parameters, .scales = scales, .backgrounds = &.{} },
                temporary,
                prologue,
            );
        },
    };

    try bind_tw.check(.publish);
    return .{
        .arena = arena,
        .program = kernel.program,
        .backend = kernel.backend(),
        .optimized_plan = kernel.optimized_plan,
        .coordinate_count = kernel.coordinateCount(),
        .parameters = parameters,
        .scales = scales,
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

    const temporaries = [_]program_module.Temporary{.{
        .kind = .real,
        .alignment = @alignOf(Scalar),
        .offset = 0,
        .bytes = @sizeOf(Scalar),
        .live = .{ .first_write = 0, .last_use = 0 },
    }};
    const kernel = Kernel{
        .arena = undefined,
        .program = .{
            .arena = undefined,
            .instructions = &.{},
            .constants = &.{},
            .temporaries = &temporaries,
            .outputs = .{ .value = 0, .gradient = &.{}, .hessian = &.{} },
            .capability = .value,
            .result_type = .real64,
            .frame_bytes = @sizeOf(Scalar),
            .scratch_offset = @sizeOf(Scalar),
            .scratch_bytes = 0,
            .parameter_stage_count = 0,
            .parameter_count = 1,
            .scale_count = 0,
            .background_count = 1,
            .coordinate_count = 1,
        },
        .model_fingerprint = [_]u8{0} ** 32,
        .request_fingerprint = [_]u8{0} ** 32,
        .background_mode = .full_scalar_space,
        .scheme = null,
        .selection = .total,
        .parameters = &channels,
        .coordinates = &.{},
        .scale = null,
        .backend_kind = .reference_interpreter,
        .optimized_plan = null,
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
