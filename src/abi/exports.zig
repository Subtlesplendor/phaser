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
    reserved: u32,
};

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
    }

    const compiled = kernel_module.compile(
        context.backing.allocator(),
        &artifact.value,
        .{ .capability = capability },
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
