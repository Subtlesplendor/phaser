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

pub const Binding = struct {
    arena: *std.heap.ArenaAllocator,
    /// Borrowed. The kernel must outlive the binding.
    kernel: *const Kernel,
    /// Packed parameter channel values, in kernel channel order.
    parameters: []const Scalar,
    /// The temporary array after the parameter stage has run. Copied into
    /// workspace at the start of each evaluation.
    prologue: []const Scalar,
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
        return self.kernel.workspaceLayout(point_count);
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
            &self.kernel.program,
            self.prologue,
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

    const parameters = try arena.allocator().alloc(Scalar, kernel.parameters.len);
    for (kernel.parameters, parameters) |channel, *slot| {
        // Channel names come from the model, so coverage validation above
        // guarantees the lookup succeeds.
        slot.* = point.lookup(channel.name) orelse return error.MissingParameterValue;
    }

    const prologue = try arena.allocator().alloc(
        Scalar,
        kernel.program.temporary_count,
    );
    @memset(prologue, 0);
    _ = interpret_module.runParameterStage(&kernel.program, parameters, prologue);

    return .{
        .arena = arena,
        .kernel = kernel,
        .parameters = parameters,
        .prologue = prologue,
        .scheme = point.scheme,
        .reference_scale = point.reference_scale,
    };
}
