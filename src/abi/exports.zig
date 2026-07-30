//! The exported C ABI surface.
//!
//! This file adapts the Phaser core to the boundary specified in
//! docs/architecture/LANGUAGE_AND_INTEROPERABILITY.md section 5 and fixed by
//! docs/decisions/0013-c-abi-v0-surface.md. It contains no physics, no
//! canonicalization, and no numerical evaluation: every scientific result comes
//! from the same core the CLI and the Zig tests use.
//!
//! Two rules shape most of the code here:
//!
//!  * No Zig error, panic, or trap caused by unvalidated client input may cross
//!    the boundary. Every entry point validates its arguments before touching
//!    them and returns a status.
//!  * Failure is atomic at the boundary. An entry point writes its out
//!    parameters only on the path that succeeds, so a caller that ignores the
//!    status still cannot read a half-built result.

const std = @import("std");
const builtin = @import("builtin");

const foundation = @import("../foundation/root.zig");
const model_module = @import("../model/root.zig");
const calculation_module = @import("../calculation/root.zig");
const kernel_module = @import("../kernel/root.zig");
const symbolic_module = @import("../export/root.zig");
const handle = @import("handle.zig");
const status_module = @import("status.zig");

const Status = status_module.Status;

/// Library version, reported separately from the ABI version.
const library_version = struct {
    const major: u32 = 0;
    const minor: u32 = 0;
    const patch: u32 = 0;
};

const abi_version: u32 = 0;

/// Defaults used when the caller passes no options.
const default_max_diagnostics: usize = 64;
const default_max_related_locations: usize = 256;

// ---------------------------------------------------------------------------
// Handle representations
//
// These are private. C sees incomplete struct types and only ever holds
// pointers.
// ---------------------------------------------------------------------------

const Context = struct {
    tag: u32,
    /// Backing allocator for everything this context owns. Custom allocator
    /// hooks are deferred by the interoperability specification, so version 0
    /// owns its allocator rather than accepting one. It is per-context, not
    /// process-global, which is what keeps separate contexts independent.
    backing: std.heap.DebugAllocator(.{}),
    limits: foundation.Limits,

    fn core(self: *Context) foundation.Context {
        return .{
            .allocator = self.backing.allocator(),
            .limits = self.limits,
        };
    }
};

const Model = struct {
    tag: u32,
    /// The context that created this model. A model must not outlive it; the
    /// handle is kept so destruction returns memory to the right allocator.
    owner: *Context,
    value: model_module.Model,
};

const Diagnostics = struct {
    tag: u32,
    owner: *Context,
    value: foundation.Diagnostics,
};

const Request = struct {
    tag: u32,
    owner: *Context,
    value: calculation_module.Request,
};

const Artifact = struct {
    tag: u32,
    owner: *Context,
    value: calculation_module.Artifact,
};

const Kernel = struct {
    tag: u32,
    owner: *Context,
    value: kernel_module.Kernel,
};

const Point = struct {
    tag: u32,
    owner: *Context,
    value: calculation_module.ParameterPoint,
};

const Binding = struct {
    tag: u32,
    owner: *Context,
    value: kernel_module.Binding,
};

// ---------------------------------------------------------------------------
// Argument validation
// ---------------------------------------------------------------------------

fn checkedContext(pointer: ?*Context) ?*Context {
    const context = pointer orelse return null;
    if (!handle.matches(context.tag, handle.context)) return null;
    return context;
}

fn checkedModel(pointer: ?*const Model) ?*const Model {
    const model = pointer orelse return null;
    if (!handle.matches(model.tag, handle.model)) return null;
    return model;
}

fn checkedDiagnostics(pointer: ?*const Diagnostics) ?*const Diagnostics {
    const diagnostics = pointer orelse return null;
    if (!handle.matches(diagnostics.tag, handle.diagnostics)) return null;
    return diagnostics;
}

fn checkedRequest(pointer: ?*const Request) ?*const Request {
    const request = pointer orelse return null;
    if (!handle.matches(request.tag, handle.request)) return null;
    return request;
}

fn checkedArtifact(pointer: ?*const Artifact) ?*const Artifact {
    const artifact = pointer orelse return null;
    if (!handle.matches(artifact.tag, handle.artifact)) return null;
    return artifact;
}

fn checkedKernel(pointer: ?*const Kernel) ?*const Kernel {
    const kernel = pointer orelse return null;
    if (!handle.matches(kernel.tag, handle.kernel)) return null;
    return kernel;
}

fn checkedPoint(pointer: ?*const Point) ?*const Point {
    const point = pointer orelse return null;
    if (!handle.matches(point.tag, handle.point)) return null;
    return point;
}

fn checkedBinding(pointer: ?*const Binding) ?*const Binding {
    const binding = pointer orelse return null;
    if (!handle.matches(binding.tag, handle.binding)) return null;
    return binding;
}

/// Maps a parse or derivation error to a status.
///
/// Running out of room to describe a failure is a limit the caller configured,
/// so it is reported as one rather than as a source failure with no diagnostics
/// to show for itself.
fn diagnosticError(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.DiagnosticCapacityExceeded,
        error.RelatedLocationCapacityExceeded,
        => .limit_exceeded,
        else => .internal,
    };
}

/// Renders through a measure-then-fill pass shared by every text export.
///
/// The sizing call passes a null buffer and reads the length, so the rendering
/// has to be counted without being stored. Capacity failures are reported
/// before anything is written.
fn renderInto(
    buffer: ?[*]u8,
    capacity: usize,
    out_length: ?*usize,
    context: anytype,
    comptime write: fn (@TypeOf(context), *std.Io.Writer) anyerror!void,
) Status {
    var counting = std.Io.Writer.Discarding.init(&.{});
    write(context, &counting.writer) catch return .internal;
    const required = counting.count + counting.writer.end;

    if (out_length) |out| out.* = required;

    const destination = buffer orelse return .insufficient_space;
    if (capacity < required) return .insufficient_space;

    var fixed = std.Io.Writer.fixed(destination[0..capacity]);
    write(context, &fixed) catch return .internal;
    return .ok;
}

// ---------------------------------------------------------------------------
// Extensible structures
//
// The caller sets `struct_size` to the size of the struct it compiled against.
// A smaller value than the fixed prologue is malformed; a larger one than this
// version knows means the caller is newer than the library, which version 0
// rejects rather than guessing about.
// ---------------------------------------------------------------------------

const ContextOptions = extern struct {
    struct_size: u32,
    abi_version: u32,
    max_diagnostics: u64,
    max_related_locations: u64,
};

const Diagnostic = extern struct {
    struct_size: u32,
    abi_version: u32,
    code: u32,
    category: i32,
    severity: i32,
    has_primary: i32,
    primary_source_id: u32,
    primary_start: u32,
    primary_end: u32,
    related_count: u32,
    reserved: u32,
};

const prologue_size: u32 = @sizeOf(u32) * 2;

fn prologueValid(struct_size: u32, full_size: u32) bool {
    return struct_size >= prologue_size and struct_size <= full_size;
}

// ---------------------------------------------------------------------------
// Version and capability queries
// ---------------------------------------------------------------------------

export fn phaser_abi_version() callconv(.c) u32 {
    return abi_version;
}

export fn phaser_abi_experimental() callconv(.c) c_int {
    // Version 0 is experimental by definition. This stays a separate query from
    // the version so that declaring version 1 and dropping the experimental
    // marker remain distinguishable events.
    return 1;
}

export fn phaser_library_version(
    major: ?*u32,
    minor: ?*u32,
    patch: ?*u32,
) callconv(.c) void {
    if (major) |out| out.* = library_version.major;
    if (minor) |out| out.* = library_version.minor;
    if (patch) |out| out.* = library_version.patch;
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

export fn phaser_context_create(
    options: ?*const ContextOptions,
    out_context: ?*?*Context,
) callconv(.c) Status {
    const out = out_context orelse return .invalid_argument;
    out.* = null;

    var max_diagnostics: usize = default_max_diagnostics;
    var max_related_locations: usize = default_max_related_locations;

    if (options) |supplied| {
        if (!prologueValid(supplied.struct_size, @sizeOf(ContextOptions))) {
            return .invalid_argument;
        }
        if (supplied.abi_version != abi_version) return .invalid_argument;

        if (supplied.struct_size >= @offsetOf(ContextOptions, "max_diagnostics") +
            @sizeOf(u64))
        {
            max_diagnostics = std.math.cast(usize, supplied.max_diagnostics) orelse
                return .invalid_argument;
        }
        if (supplied.struct_size >= @offsetOf(ContextOptions, "max_related_locations") +
            @sizeOf(u64))
        {
            max_related_locations = std.math.cast(usize, supplied.max_related_locations) orelse
                return .invalid_argument;
        }
    }

    // The core rejects a zero diagnostic limit. Checking here keeps the reason
    // a caller-argument problem rather than an opaque construction failure.
    if (max_diagnostics == 0) return .invalid_argument;

    const context = std.heap.page_allocator.create(Context) catch return .out_of_memory;
    context.* = .{
        .tag = handle.context,
        .backing = .init,
        .limits = .{
            .max_diagnostics = max_diagnostics,
            .max_related_locations = max_related_locations,
        },
    };

    switch (foundation.Context.init(context.backing.allocator(), context.limits)) {
        .context => {},
        .failure => {
            _ = context.backing.deinit();
            std.heap.page_allocator.destroy(context);
            return .invalid_argument;
        },
    }

    out.* = context;
    return .ok;
}

export fn phaser_context_destroy(context_pointer: ?*Context) callconv(.c) void {
    const context = checkedContext(context_pointer) orelse return;
    context.tag = handle.destroyed;
    _ = context.backing.deinit();
    std.heap.page_allocator.destroy(context);
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

export fn phaser_model_load(
    context_pointer: ?*Context,
    source: ?*const anyopaque,
    source_length: usize,
    out_model: ?*?*Model,
    out_diagnostics: ?*?*Diagnostics,
) callconv(.c) Status {
    // Clear the out parameters first, so a caller that ignores the status reads
    // null rather than whatever was on its stack.
    if (out_model) |out| out.* = null;
    if (out_diagnostics) |out| out.* = null;

    const context = checkedContext(context_pointer) orelse return .invalid_argument;
    const out = out_model orelse return .invalid_argument;
    if (source == null and source_length != 0) return .invalid_argument;

    const bytes: []const u8 = if (source_length == 0)
        &.{}
    else
        @as([*]const u8, @ptrCast(source.?))[0..source_length];

    const source_id = foundation.SourceId.fromUsize(0) catch return .internal;

    const result = model_module.loadModel(
        context.core(),
        .{ .source_id = source_id, .bytes = bytes },
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        // The core ran out of room to describe the failure rather than failing
        // the parse. That is a limit the caller configured, so it is reported as
        // one instead of as a parse failure with no diagnostics to show.
        error.DiagnosticCapacityExceeded,
        error.RelatedLocationCapacityExceeded,
        => .limit_exceeded,
    };

    switch (result) {
        .model => |loaded| {
            const wrapper = context.backing.allocator().create(Model) catch {
                var owned = loaded;
                owned.deinit();
                return .out_of_memory;
            };
            wrapper.* = .{ .tag = handle.model, .owner = context, .value = loaded };
            out.* = wrapper;
            // Diagnostics stay null on success: only invalid_source promises
            // them, and the out parameter was already cleared above.
            return .ok;
        },
        .diagnostics => |produced| {
            var owned = produced;
            const slot = out_diagnostics orelse {
                // The caller does not want diagnostics. Release them rather
                // than leaking, and still report the parse failure.
                owned.deinit();
                return .invalid_source;
            };
            const wrapper = context.backing.allocator().create(Diagnostics) catch {
                owned.deinit();
                return .out_of_memory;
            };
            wrapper.* = .{ .tag = handle.diagnostics, .owner = context, .value = owned };
            slot.* = wrapper;
            return .invalid_source;
        },
    }
}

export fn phaser_model_destroy(model_pointer: ?*Model) callconv(.c) void {
    const model = model_pointer orelse return;
    if (!handle.matches(model.tag, handle.model)) return;
    model.tag = handle.destroyed;
    model.value.deinit();
    model.owner.backing.allocator().destroy(model);
}

export fn phaser_model_fingerprint(
    model_pointer: ?*const Model,
    out_bytes: ?[*]u8,
    capacity: usize,
) callconv(.c) Status {
    const model = checkedModel(model_pointer) orelse return .invalid_argument;
    const bytes = out_bytes orelse return .invalid_argument;

    const fingerprint = model.value.fingerprint();
    if (capacity < fingerprint.bytes.len) return .insufficient_space;

    @memcpy(bytes[0..fingerprint.bytes.len], &fingerprint.bytes);
    return .ok;
}

export fn phaser_model_parameter_count(
    model_pointer: ?*const Model,
    out_count: ?*usize,
) callconv(.c) Status {
    const model = checkedModel(model_pointer) orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = model.value.parameters.len;
    return .ok;
}

export fn phaser_model_scalar_field_count(
    model_pointer: ?*const Model,
    out_count: ?*usize,
) callconv(.c) Status {
    const model = checkedModel(model_pointer) orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = model.value.real_scalars.len;
    return .ok;
}

// ---------------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------------

export fn phaser_request_parse(
    context_pointer: ?*Context,
    source: ?*const anyopaque,
    source_length: usize,
    out_request: ?*?*Request,
    out_diagnostics: ?*?*Diagnostics,
) callconv(.c) Status {
    if (out_request) |out| out.* = null;
    if (out_diagnostics) |out| out.* = null;

    const context = checkedContext(context_pointer) orelse return .invalid_argument;
    const out = out_request orelse return .invalid_argument;
    if (source == null and source_length != 0) return .invalid_argument;

    const bytes: []const u8 = if (source_length == 0)
        &.{}
    else
        @as([*]const u8, @ptrCast(source.?))[0..source_length];

    const source_id = foundation.SourceId.fromUsize(0) catch return .internal;

    const result = calculation_module.parseRequest(
        context.core(),
        .{ .source_id = source_id, .bytes = bytes },
        .{},
    ) catch |err| return diagnosticError(err);

    switch (result) {
        .request => |parsed| {
            const wrapper = context.backing.allocator().create(Request) catch {
                var owned = parsed;
                owned.deinit();
                return .out_of_memory;
            };
            wrapper.* = .{ .tag = handle.request, .owner = context, .value = parsed };
            out.* = wrapper;
            return .ok;
        },
        .diagnostics => |produced| {
            var owned = produced;
            const slot = out_diagnostics orelse {
                owned.deinit();
                return .invalid_source;
            };
            const wrapper = context.backing.allocator().create(Diagnostics) catch {
                owned.deinit();
                return .out_of_memory;
            };
            wrapper.* = .{ .tag = handle.diagnostics, .owner = context, .value = owned };
            slot.* = wrapper;
            return .invalid_source;
        },
    }
}

export fn phaser_request_destroy(request_pointer: ?*Request) callconv(.c) void {
    const request = request_pointer orelse return;
    if (!handle.matches(request.tag, handle.request)) return;
    request.tag = handle.destroyed;
    request.value.deinit();
    request.owner.backing.allocator().destroy(request);
}

export fn phaser_request_loop_order(
    request_pointer: ?*const Request,
    out_loop_order: ?*u32,
) callconv(.c) Status {
    const request = checkedRequest(request_pointer) orelse return .invalid_argument;
    const out = out_loop_order orelse return .invalid_argument;
    out.* = request.value.loop_order;
    return .ok;
}

export fn phaser_request_coordinate_count(
    request_pointer: ?*const Request,
    out_count: ?*usize,
) callconv(.c) Status {
    const request = checkedRequest(request_pointer) orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = request.value.coordinates.len;
    return .ok;
}

// ---------------------------------------------------------------------------
// Artifact
// ---------------------------------------------------------------------------

export fn phaser_artifact_derive(
    context_pointer: ?*Context,
    model_pointer: ?*const Model,
    request_pointer: ?*const Request,
    out_artifact: ?*?*Artifact,
    out_diagnostics: ?*?*Diagnostics,
) callconv(.c) Status {
    if (out_artifact) |out| out.* = null;
    if (out_diagnostics) |out| out.* = null;

    const context = checkedContext(context_pointer) orelse return .invalid_argument;
    const model = checkedModel(model_pointer) orelse return .invalid_argument;
    const request = checkedRequest(request_pointer) orelse return .invalid_argument;
    const out = out_artifact orelse return .invalid_argument;

    const result = calculation_module.deriveEffectivePotential(
        context.core(),
        &model.value,
        &request.value,
        .{},
    ) catch |err| return diagnosticError(err);

    switch (result) {
        .artifact => |derived| {
            const wrapper = context.backing.allocator().create(Artifact) catch {
                var owned = derived;
                owned.deinit();
                return .out_of_memory;
            };
            wrapper.* = .{ .tag = handle.artifact, .owner = context, .value = derived };
            out.* = wrapper;
            return .ok;
        },
        .diagnostics => |produced| {
            var owned = produced;
            const slot = out_diagnostics orelse {
                owned.deinit();
                return .invalid_source;
            };
            const wrapper = context.backing.allocator().create(Diagnostics) catch {
                owned.deinit();
                return .out_of_memory;
            };
            wrapper.* = .{ .tag = handle.diagnostics, .owner = context, .value = owned };
            slot.* = wrapper;
            return .invalid_source;
        },
    }
}

export fn phaser_artifact_destroy(artifact_pointer: ?*Artifact) callconv(.c) void {
    const artifact = artifact_pointer orelse return;
    if (!handle.matches(artifact.tag, handle.artifact)) return;
    artifact.tag = handle.destroyed;
    artifact.value.deinit();
    artifact.owner.backing.allocator().destroy(artifact);
}

export fn phaser_artifact_loop_order(
    artifact_pointer: ?*const Artifact,
    out_loop_order: ?*u32,
) callconv(.c) Status {
    const artifact = checkedArtifact(artifact_pointer) orelse return .invalid_argument;
    const out = out_loop_order orelse return .invalid_argument;
    out.* = artifact.value.loop_order;
    return .ok;
}

export fn phaser_artifact_coordinate_count(
    artifact_pointer: ?*const Artifact,
    out_count: ?*usize,
) callconv(.c) Status {
    const artifact = checkedArtifact(artifact_pointer) orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = artifact.value.coordinates.len;
    return .ok;
}

export fn phaser_artifact_contribution_count(
    artifact_pointer: ?*const Artifact,
    out_count: ?*usize,
) callconv(.c) Status {
    const artifact = checkedArtifact(artifact_pointer) orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = artifact.value.contributions.len;
    return .ok;
}

export fn phaser_artifact_result_type(
    artifact_pointer: ?*const Artifact,
    out_result_type: ?*i32,
) callconv(.c) Status {
    const artifact = checkedArtifact(artifact_pointer) orelse return .invalid_argument;
    const out = out_result_type orelse return .invalid_argument;
    out.* = @intFromEnum(
        status_module.fromArtifactResultType(artifact.value.result_type),
    );
    return .ok;
}

const ExportContext = struct {
    artifact: *const calculation_module.Artifact,
    allocator: std.mem.Allocator,
    target: symbolic_module.Target,
};

fn writeExport(context: ExportContext, writer: *std.Io.Writer) anyerror!void {
    try symbolic_module.writePotential(
        context.artifact,
        context.allocator,
        .{ .target = context.target },
        writer,
    );
}

export fn phaser_artifact_export(
    artifact_pointer: ?*const Artifact,
    target: i32,
    buffer: ?[*]u8,
    capacity: usize,
    out_length: ?*usize,
) callconv(.c) Status {
    const artifact = checkedArtifact(artifact_pointer) orelse return .invalid_argument;
    const resolved: symbolic_module.Target = switch (target) {
        0 => .phaser,
        1 => .latex,
        // An unrecognized target is a caller mistake, not a reason to pick one.
        else => return .invalid_argument,
    };

    return renderInto(
        buffer,
        capacity,
        out_length,
        ExportContext{
            .artifact = &artifact.value,
            .allocator = artifact.owner.backing.allocator(),
            .target = resolved,
        },
        writeExport,
    );
}

// ---------------------------------------------------------------------------
// Kernel
// ---------------------------------------------------------------------------

const KernelOptions = extern struct {
    struct_size: u32,
    abi_version: u32,
    capability: i32,
    selection_kind: i32,
    selection_value: u32,
    reserved: u32,
};

/// Decodes the selection an options struct describes.
///
/// Returns null for anything this version does not publish, which the caller
/// turns into `invalid_argument`. A selection is never resolved to `total` on
/// a value that was not understood: choosing silently would answer a different
/// question than the caller asked.
fn decodeSelection(options: *const KernelOptions) ?kernel_module.Selection {
    return switch (options.selection_kind) {
        // A payload alongside `total` means the caller described something it
        // did not get, so it is rejected rather than ignored.
        @intFromEnum(status_module.SelectionKind.total) => if (options.selection_value == 0)
            .total
        else
            null,
        @intFromEnum(status_module.SelectionKind.loop_order) => .{
            .loop_order = options.selection_value,
        },
        @intFromEnum(status_module.SelectionKind.role) => .{
            .role = status_module.toRole(options.selection_value) orelse return null,
        },
        else => null,
    };
}

export fn phaser_kernel_compile(
    context_pointer: ?*Context,
    artifact_pointer: ?*const Artifact,
    options: ?*const KernelOptions,
    out_kernel: ?*?*Kernel,
) callconv(.c) Status {
    if (out_kernel) |out| out.* = null;

    const context = checkedContext(context_pointer) orelse return .invalid_argument;
    const artifact = checkedArtifact(artifact_pointer) orelse return .invalid_argument;
    const out = out_kernel orelse return .invalid_argument;

    var capability: kernel_module.Capability = .value_gradient_hessian;
    var selection: kernel_module.Selection = .total;
    if (options) |supplied| {
        if (!prologueValid(supplied.struct_size, @sizeOf(KernelOptions))) {
            return .invalid_argument;
        }
        if (supplied.abi_version != abi_version) return .invalid_argument;
        if (supplied.struct_size >= @offsetOf(KernelOptions, "capability") +
            @sizeOf(i32))
        {
            capability = switch (supplied.capability) {
                0 => .value,
                1 => .value_gradient,
                2 => .value_gradient_hessian,
                else => return .invalid_argument,
            };
        }
        // Both selection fields are read together or not at all: a struct
        // carrying a kind without its value would describe half a selection.
        if (supplied.struct_size >= @offsetOf(KernelOptions, "selection_value") +
            @sizeOf(u32))
        {
            selection = decodeSelection(supplied) orelse return .invalid_argument;
        }
    }

    const compiled = kernel_module.compile(
        context.backing.allocator(),
        &artifact.value,
        .{ .capability = capability, .selection = selection },
    ) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        // The request was well formed; the artifact simply does not carry what
        // it asked for. That is a domain answer, not a bad argument.
        error.SelectionNotDerived,
        error.CapabilityNotDerived,
        => .unsupported,
        else => .internal,
    };

    const wrapper = context.backing.allocator().create(Kernel) catch {
        var owned = compiled;
        owned.deinit();
        return .out_of_memory;
    };
    wrapper.* = .{ .tag = handle.kernel, .owner = context, .value = compiled };
    out.* = wrapper;
    return .ok;
}

export fn phaser_kernel_destroy(kernel_pointer: ?*Kernel) callconv(.c) void {
    const kernel = kernel_pointer orelse return;
    if (!handle.matches(kernel.tag, handle.kernel)) return;
    kernel.tag = handle.destroyed;
    kernel.value.deinit();
    kernel.owner.backing.allocator().destroy(kernel);
}

export fn phaser_kernel_result_type(
    kernel_pointer: ?*const Kernel,
    out_result_type: ?*i32,
) callconv(.c) Status {
    const kernel = checkedKernel(kernel_pointer) orelse return .invalid_argument;
    const out = out_result_type orelse return .invalid_argument;
    out.* = @intFromEnum(status_module.fromResultType(kernel.value.resultType()));
    return .ok;
}

export fn phaser_kernel_capability(
    kernel_pointer: ?*const Kernel,
    out_capability: ?*i32,
) callconv(.c) Status {
    const kernel = checkedKernel(kernel_pointer) orelse return .invalid_argument;
    const out = out_capability orelse return .invalid_argument;
    out.* = @intFromEnum(status_module.fromCapability(kernel.value.capability()));
    return .ok;
}

export fn phaser_kernel_coordinate_count(
    kernel_pointer: ?*const Kernel,
    out_count: ?*usize,
) callconv(.c) Status {
    const kernel = checkedKernel(kernel_pointer) orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = kernel.value.coordinateCount();
    return .ok;
}

export fn phaser_kernel_parameter_count(
    kernel_pointer: ?*const Kernel,
    out_count: ?*usize,
) callconv(.c) Status {
    const kernel = checkedKernel(kernel_pointer) orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = kernel.value.parameterCount();
    return .ok;
}

// ---------------------------------------------------------------------------
// Parameter point
// ---------------------------------------------------------------------------

export fn phaser_point_parse(
    context_pointer: ?*Context,
    source: ?*const anyopaque,
    source_length: usize,
    out_point: ?*?*Point,
    out_diagnostics: ?*?*Diagnostics,
) callconv(.c) Status {
    if (out_point) |out| out.* = null;
    if (out_diagnostics) |out| out.* = null;

    const context = checkedContext(context_pointer) orelse return .invalid_argument;
    const out = out_point orelse return .invalid_argument;
    if (source == null and source_length != 0) return .invalid_argument;

    const bytes: []const u8 = if (source_length == 0)
        &.{}
    else
        @as([*]const u8, @ptrCast(source.?))[0..source_length];

    const source_id = foundation.SourceId.fromUsize(0) catch return .internal;

    const result = calculation_module.parseParameterPoint(
        context.core(),
        .{ .source_id = source_id, .bytes = bytes },
        .{},
    ) catch |err| return diagnosticError(err);

    switch (result) {
        .point => |parsed| {
            const wrapper = context.backing.allocator().create(Point) catch {
                var owned = parsed;
                owned.deinit();
                return .out_of_memory;
            };
            wrapper.* = .{ .tag = handle.point, .owner = context, .value = parsed };
            out.* = wrapper;
            return .ok;
        },
        .diagnostics => |produced| {
            var owned = produced;
            const slot = out_diagnostics orelse {
                owned.deinit();
                return .invalid_source;
            };
            const wrapper = context.backing.allocator().create(Diagnostics) catch {
                owned.deinit();
                return .out_of_memory;
            };
            wrapper.* = .{ .tag = handle.diagnostics, .owner = context, .value = owned };
            slot.* = wrapper;
            return .invalid_source;
        },
    }
}

export fn phaser_point_destroy(point_pointer: ?*Point) callconv(.c) void {
    const point = point_pointer orelse return;
    if (!handle.matches(point.tag, handle.point)) return;
    point.tag = handle.destroyed;
    point.value.deinit();
    point.owner.backing.allocator().destroy(point);
}

export fn phaser_point_reference_scale(
    point_pointer: ?*const Point,
    out_scale: ?*f64,
) callconv(.c) Status {
    const point = checkedPoint(point_pointer) orelse return .invalid_argument;
    const out = out_scale orelse return .invalid_argument;
    out.* = point.value.reference_scale;
    return .ok;
}

// ---------------------------------------------------------------------------
// Binding
// ---------------------------------------------------------------------------

export fn phaser_binding_create(
    context_pointer: ?*Context,
    kernel_pointer: ?*const Kernel,
    model_pointer: ?*const Model,
    point_pointer: ?*const Point,
    out_binding: ?*?*Binding,
) callconv(.c) Status {
    if (out_binding) |out| out.* = null;

    const context = checkedContext(context_pointer) orelse return .invalid_argument;
    const kernel = checkedKernel(kernel_pointer) orelse return .invalid_argument;
    const model = checkedModel(model_pointer) orelse return .invalid_argument;
    const point = checkedPoint(point_pointer) orelse return .invalid_argument;
    const out = out_binding orelse return .invalid_argument;

    const bound = kernel_module.bind(
        context.backing.allocator(),
        &kernel.value,
        &model.value,
        &point.value,
    ) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        // Each of these is a mismatch between the point the caller supplied and
        // what the kernel requires, which is an argument problem rather than an
        // unsupported calculation.
        error.MissingParameterValue,
        error.UnknownParameterValue,
        error.SchemeMismatch,
        error.InvalidScale,
        => .invalid_argument,
    };

    const wrapper = context.backing.allocator().create(Binding) catch {
        var owned = bound;
        owned.deinit();
        return .out_of_memory;
    };
    wrapper.* = .{ .tag = handle.binding, .owner = context, .value = bound };
    out.* = wrapper;
    return .ok;
}

export fn phaser_binding_destroy(binding_pointer: ?*Binding) callconv(.c) void {
    const binding = binding_pointer orelse return;
    if (!handle.matches(binding.tag, handle.binding)) return;
    binding.tag = handle.destroyed;
    binding.value.deinit();
    binding.owner.backing.allocator().destroy(binding);
}

/// Bytes of status scratch this boundary needs for `point_count` points.
///
/// The kernel writes its own status enum, one byte wide; the ABI publishes
/// `int32_t`, because a client must not have to know the width of an internal
/// tag. Evaluation may not allocate, so the widening needs scratch, and the
/// only buffer available is the caller's workspace.
///
/// This is why the ABI's workspace query is not simply the core's. The caller
/// queries and passes the number back, and does not need to know the reason.
fn statusScratchBytes(point_count: usize) ?usize {
    return std.math.mul(usize, point_count, @sizeOf(kernel_module.Status)) catch null;
}

fn abiWorkspaceLayout(
    binding: *const kernel_module.Binding,
    point_count: usize,
) ?kernel_module.WorkspaceLayout {
    const core = binding.workspaceLayout(point_count);
    const scratch = statusScratchBytes(point_count) orelse return null;
    // The status scratch is byte-aligned, so it can sit at the tail without
    // disturbing the core region's alignment.
    const total = std.math.add(usize, core.bytes, scratch) catch return null;
    return .{ .bytes = total, .alignment = core.alignment };
}

export fn phaser_binding_workspace(
    binding_pointer: ?*const Binding,
    point_count: usize,
    out_bytes: ?*usize,
    out_alignment: ?*usize,
) callconv(.c) Status {
    const binding = checkedBinding(binding_pointer) orelse return .invalid_argument;
    const layout = abiWorkspaceLayout(&binding.value, point_count) orelse
        return .limit_exceeded;
    if (out_bytes) |out| out.* = layout.bytes;
    if (out_alignment) |out| out.* = layout.alignment;
    return .ok;
}

export fn phaser_binding_coordinate_count(
    binding_pointer: ?*const Binding,
    out_count: ?*usize,
) callconv(.c) Status {
    const binding = checkedBinding(binding_pointer) orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = binding.value.coordinateCount();
    return .ok;
}

/// The capability decides the exact gradient and Hessian lengths evaluation
/// requires, so a caller holding only a binding needs it to size the output
/// buffers. It is read from the binding's compiled program rather than taken
/// on trust from whichever kernel the caller believes it used.
export fn phaser_binding_capability(
    binding_pointer: ?*const Binding,
    out_capability: ?*i32,
) callconv(.c) Status {
    const binding = checkedBinding(binding_pointer) orelse return .invalid_argument;
    const out = out_capability orelse return .invalid_argument;
    out.* = @intFromEnum(
        status_module.fromCapability(binding.value.program.capability),
    );
    return .ok;
}

export fn phaser_binding_result_type(
    binding_pointer: ?*const Binding,
    out_result_type: ?*i32,
) callconv(.c) Status {
    const binding = checkedBinding(binding_pointer) orelse return .invalid_argument;
    const out = out_result_type orelse return .invalid_argument;
    out.* = @intFromEnum(status_module.fromResultType(binding.value.resultType()));
    return .ok;
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

const Outputs = extern struct {
    struct_size: u32,
    abi_version: u32,
    values: ?[*]f64,
    value_count: usize,
    gradients: ?[*]f64,
    gradient_count: usize,
    hessians: ?[*]f64,
    hessian_count: usize,
    statuses: ?[*]i32,
    status_count: usize,
};

const ComplexOutputs = extern struct {
    struct_size: u32,
    abi_version: u32,
    values: ?[*]kernel_module.Complex64,
    value_count: usize,
    gradients: ?[*]kernel_module.Complex64,
    gradient_count: usize,
    hessians: ?[*]kernel_module.Complex64,
    hessian_count: usize,
    statuses: ?[*]i32,
    status_count: usize,
};

/// Splits the caller's workspace into the core region and the status scratch.
const SplitWorkspace = struct {
    core: []u8,
    statuses: []kernel_module.Status,
};

fn splitWorkspace(
    binding: *const kernel_module.Binding,
    workspace: ?[*]u8,
    workspace_bytes: usize,
    point_count: usize,
) ?SplitWorkspace {
    const layout = abiWorkspaceLayout(binding, point_count) orelse return null;
    if (workspace_bytes < layout.bytes) return null;
    const base = workspace orelse return null;

    // The alignment the query reported is a promise the caller made.
    const address = @intFromPtr(base);
    if (layout.alignment != 0 and address % layout.alignment != 0) return null;

    const core_bytes = binding.workspaceLayout(point_count).bytes;
    const scratch = base[core_bytes..layout.bytes];
    return .{
        .core = base[0..core_bytes],
        .statuses = @as(
            [*]kernel_module.Status,
            @ptrCast(scratch.ptr),
        )[0..point_count],
    };
}

/// Widens the kernel's statuses into the caller's `int32_t` array.
fn publishStatuses(internal: []const kernel_module.Status, out: [*]i32) void {
    for (internal, 0..) |item, index| {
        out[index] = @intFromEnum(status_module.fromKernelStatus(item));
    }
}

/// Validates the parts of an output description that do not depend on element
/// type, and returns the expected element counts.
const Shape = struct {
    values: usize,
    gradients: usize,
    hessians: usize,
};

fn outputShape(
    binding: *const kernel_module.Binding,
    point_count: usize,
    capability: kernel_module.Capability,
) ?Shape {
    const coordinates = binding.coordinateCount();
    const gradients = if (capability.includesGradient())
        std.math.mul(usize, point_count, coordinates) catch return null
    else
        0;
    const hessians = if (capability.includesHessian()) blk: {
        const square = std.math.mul(usize, coordinates, coordinates) catch return null;
        break :blk std.math.mul(usize, point_count, square) catch return null;
    } else 0;
    return .{ .values = point_count, .gradients = gradients, .hessians = hessians };
}

fn callError(err: anyerror) Status {
    return switch (err) {
        error.WorkspaceTooSmall,
        error.WorkspaceMisaligned,
        => .insufficient_space,
        error.ShapeMismatch,
        error.ForbiddenAliasing,
        error.ResultTypeMismatch,
        error.InvalidScale,
        => .invalid_argument,
        error.SizeOverflow => .limit_exceeded,
        error.UnavailableCapability => .unsupported,
        else => .internal,
    };
}

export fn phaser_evaluate(
    binding_pointer: ?*const Binding,
    backgrounds: ?[*]const f64,
    background_count: usize,
    point_count: usize,
    workspace: ?[*]u8,
    workspace_bytes: usize,
    outputs: ?*Outputs,
) callconv(.c) Status {
    const binding = checkedBinding(binding_pointer) orelse return .invalid_argument;
    const out = outputs orelse return .invalid_argument;
    if (!prologueValid(out.struct_size, @sizeOf(Outputs))) return .invalid_argument;

    // The real entry point on a complex kernel is refused rather than answered
    // with a projection. Discarding the imaginary component is precisely the
    // substitution the conformance suite exists to detect internally, and it
    // must not become reachable here.
    if (binding.value.resultType() != .real64) return .invalid_argument;

    const capability = binding.value.program.capability;
    const shape = outputShape(&binding.value, point_count, capability) orelse
        return .limit_exceeded;

    const expected_backgrounds = std.math.mul(
        usize,
        point_count,
        binding.value.coordinateCount(),
    ) catch return .limit_exceeded;
    if (background_count != expected_backgrounds) return .invalid_argument;
    if (backgrounds == null and expected_backgrounds != 0) return .invalid_argument;

    const values = out.values orelse return .invalid_argument;
    if (out.value_count != shape.values) return .invalid_argument;
    const statuses = out.statuses orelse return .invalid_argument;
    // An unwritten status entry must never be mistaken for success, so the
    // array's length is required to match rather than merely to suffice.
    if (out.status_count != point_count) return .invalid_argument;

    if (shape.gradients != 0 and out.gradients == null) return .invalid_argument;
    if (out.gradient_count != shape.gradients) return .invalid_argument;
    if (shape.hessians != 0 and out.hessians == null) return .invalid_argument;
    if (out.hessian_count != shape.hessians) return .invalid_argument;

    const split = splitWorkspace(
        &binding.value,
        workspace,
        workspace_bytes,
        point_count,
    ) orelse return .insufficient_space;

    const background_slice: []const f64 = if (expected_backgrounds == 0)
        &.{}
    else
        backgrounds.?[0..expected_backgrounds];

    binding.value.evaluate(
        background_slice,
        point_count,
        split.core,
        .{
            .values = values[0..shape.values],
            .gradients = if (shape.gradients == 0)
                &.{}
            else
                out.gradients.?[0..shape.gradients],
            .hessians = if (shape.hessians == 0)
                &.{}
            else
                out.hessians.?[0..shape.hessians],
            .statuses = split.statuses,
        },
    ) catch |err| return callError(err);

    publishStatuses(split.statuses, statuses);
    return .ok;
}

export fn phaser_evaluate_complex(
    binding_pointer: ?*const Binding,
    backgrounds: ?[*]const f64,
    background_count: usize,
    point_count: usize,
    workspace: ?[*]u8,
    workspace_bytes: usize,
    outputs: ?*ComplexOutputs,
) callconv(.c) Status {
    const binding = checkedBinding(binding_pointer) orelse return .invalid_argument;
    const out = outputs orelse return .invalid_argument;
    if (!prologueValid(out.struct_size, @sizeOf(ComplexOutputs))) {
        return .invalid_argument;
    }
    if (binding.value.resultType() != .complex64) return .invalid_argument;

    const capability = binding.value.program.capability;
    const shape = outputShape(&binding.value, point_count, capability) orelse
        return .limit_exceeded;

    const expected_backgrounds = std.math.mul(
        usize,
        point_count,
        binding.value.coordinateCount(),
    ) catch return .limit_exceeded;
    if (background_count != expected_backgrounds) return .invalid_argument;
    if (backgrounds == null and expected_backgrounds != 0) return .invalid_argument;

    const values = out.values orelse return .invalid_argument;
    if (out.value_count != shape.values) return .invalid_argument;
    const statuses = out.statuses orelse return .invalid_argument;
    if (out.status_count != point_count) return .invalid_argument;

    if (shape.gradients != 0 and out.gradients == null) return .invalid_argument;
    if (out.gradient_count != shape.gradients) return .invalid_argument;
    if (shape.hessians != 0 and out.hessians == null) return .invalid_argument;
    if (out.hessian_count != shape.hessians) return .invalid_argument;

    const split = splitWorkspace(
        &binding.value,
        workspace,
        workspace_bytes,
        point_count,
    ) orelse return .insufficient_space;

    const background_slice: []const f64 = if (expected_backgrounds == 0)
        &.{}
    else
        backgrounds.?[0..expected_backgrounds];

    binding.value.evaluateComplex(
        background_slice,
        point_count,
        split.core,
        .{
            .values = values[0..shape.values],
            .gradients = if (shape.gradients == 0)
                &.{}
            else
                out.gradients.?[0..shape.gradients],
            .hessians = if (shape.hessians == 0)
                &.{}
            else
                out.hessians.?[0..shape.hessians],
            .statuses = split.statuses,
        },
    ) catch |err| return callError(err);

    publishStatuses(split.statuses, statuses);
    return .ok;
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

export fn phaser_diagnostics_destroy(
    diagnostics_pointer: ?*Diagnostics,
) callconv(.c) void {
    const diagnostics = diagnostics_pointer orelse return;
    if (!handle.matches(diagnostics.tag, handle.diagnostics)) return;
    diagnostics.tag = handle.destroyed;
    diagnostics.value.deinit();
    diagnostics.owner.backing.allocator().destroy(diagnostics);
}

export fn phaser_diagnostics_count(
    diagnostics_pointer: ?*const Diagnostics,
    out_count: ?*usize,
) callconv(.c) Status {
    const diagnostics = checkedDiagnostics(diagnostics_pointer) orelse
        return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = diagnostics.value.items.len;
    return .ok;
}

export fn phaser_diagnostics_at(
    diagnostics_pointer: ?*const Diagnostics,
    index: usize,
    out_diagnostic: ?*Diagnostic,
) callconv(.c) Status {
    const diagnostics = checkedDiagnostics(diagnostics_pointer) orelse
        return .invalid_argument;
    const out = out_diagnostic orelse return .invalid_argument;
    if (!prologueValid(out.struct_size, @sizeOf(Diagnostic))) return .invalid_argument;
    if (index >= diagnostics.value.items.len) return .invalid_argument;

    const item = diagnostics.value.items[index];
    var filled = Diagnostic{
        .struct_size = out.struct_size,
        .abi_version = abi_version,
        .code = @intFromEnum(item.code),
        .category = @intFromEnum(status_module.fromCategory(item.category)),
        .severity = @intFromEnum(status_module.fromSeverity(item.severity)),
        .has_primary = if (item.primary != null) 1 else 0,
        .primary_source_id = 0,
        .primary_start = 0,
        .primary_end = 0,
        .related_count = std.math.cast(u32, item.related.len) orelse
            std.math.maxInt(u32),
        .reserved = 0,
    };
    if (item.primary) |span| {
        filled.primary_source_id = span.source_id.toU32();
        filled.primary_start = span.start;
        filled.primary_end = span.end;
    }

    // Copy only the prefix the caller's struct actually has room for.
    const writable = @min(@as(usize, out.struct_size), @sizeOf(Diagnostic));
    const source_bytes = std.mem.asBytes(&filled);
    const destination = @as([*]u8, @ptrCast(out))[0..writable];
    @memcpy(destination, source_bytes[0..writable]);
    return .ok;
}

export fn phaser_diagnostics_render(
    diagnostics_pointer: ?*const Diagnostics,
    index: usize,
    buffer: ?[*]u8,
    capacity: usize,
    out_length: ?*usize,
) callconv(.c) Status {
    const diagnostics = checkedDiagnostics(diagnostics_pointer) orelse
        return .invalid_argument;
    if (index >= diagnostics.value.items.len) return .invalid_argument;

    const item = diagnostics.value.items[index];
    return renderInto(buffer, capacity, out_length, item, writeDiagnostic);
}

fn writeDiagnostic(item: foundation.Diagnostic, writer: *std.Io.Writer) anyerror!void {
    try item.render(writer);
}

test {
    _ = handle;
    _ = status_module;
}
