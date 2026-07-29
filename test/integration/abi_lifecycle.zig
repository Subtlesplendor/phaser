//! Ownership, diagnostics, and invalid-argument behavior across the C ABI.
//!
//! Every call here goes through an `extern` declaration with opaque handles, so
//! the tests exercise the boundary as a C caller reaches it rather than the Zig
//! types behind it. The oracle throughout is the contract stated in
//! include/phaser.h and docs/decisions/0013-c-abi-v0-surface.md, not the
//! implementation's current behavior.

const std = @import("std");

const PhaserContext = opaque {};
const PhaserModel = opaque {};
const PhaserDiagnostics = opaque {};
const PhaserRequest = opaque {};
const PhaserArtifact = opaque {};
const PhaserKernel = opaque {};

const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    invalid_source = 2,
    unsupported = 3,
    limit_exceeded = 4,
    insufficient_space = 5,
    out_of_memory = 6,
    internal = 7,
};

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

extern fn phaser_context_create(
    options: ?*const ContextOptions,
    out_context: ?*?*PhaserContext,
) callconv(.c) Status;
extern fn phaser_context_destroy(context: ?*PhaserContext) callconv(.c) void;

extern fn phaser_model_load(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_model: ?*?*PhaserModel,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_model_destroy(model: ?*PhaserModel) callconv(.c) void;
extern fn phaser_model_fingerprint(
    model: ?*const PhaserModel,
    out_bytes: ?[*]u8,
    capacity: usize,
) callconv(.c) Status;
extern fn phaser_model_parameter_count(
    model: ?*const PhaserModel,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_model_scalar_field_count(
    model: ?*const PhaserModel,
    out_count: ?*usize,
) callconv(.c) Status;

const KernelOptions = extern struct {
    struct_size: u32,
    abi_version: u32,
    capability: i32,
    reserved: u32,
};

extern fn phaser_request_parse(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_request: ?*?*PhaserRequest,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_request_destroy(request: ?*PhaserRequest) callconv(.c) void;
extern fn phaser_request_loop_order(
    request: ?*const PhaserRequest,
    out_loop_order: ?*u32,
) callconv(.c) Status;
extern fn phaser_request_coordinate_count(
    request: ?*const PhaserRequest,
    out_count: ?*usize,
) callconv(.c) Status;

extern fn phaser_artifact_derive(
    context: ?*PhaserContext,
    model: ?*const PhaserModel,
    request: ?*const PhaserRequest,
    out_artifact: ?*?*PhaserArtifact,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_artifact_destroy(artifact: ?*PhaserArtifact) callconv(.c) void;
extern fn phaser_artifact_loop_order(
    artifact: ?*const PhaserArtifact,
    out_loop_order: ?*u32,
) callconv(.c) Status;
extern fn phaser_artifact_coordinate_count(
    artifact: ?*const PhaserArtifact,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_artifact_contribution_count(
    artifact: ?*const PhaserArtifact,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_artifact_result_type(
    artifact: ?*const PhaserArtifact,
    out_result_type: ?*i32,
) callconv(.c) Status;
extern fn phaser_artifact_export(
    artifact: ?*const PhaserArtifact,
    target: i32,
    buffer: ?[*]u8,
    capacity: usize,
    out_length: ?*usize,
) callconv(.c) Status;

extern fn phaser_kernel_compile(
    context: ?*PhaserContext,
    artifact: ?*const PhaserArtifact,
    options: ?*const KernelOptions,
    out_kernel: ?*?*PhaserKernel,
) callconv(.c) Status;
extern fn phaser_kernel_destroy(kernel: ?*PhaserKernel) callconv(.c) void;
extern fn phaser_kernel_result_type(
    kernel: ?*const PhaserKernel,
    out_result_type: ?*i32,
) callconv(.c) Status;
extern fn phaser_kernel_capability(
    kernel: ?*const PhaserKernel,
    out_capability: ?*i32,
) callconv(.c) Status;
extern fn phaser_kernel_coordinate_count(
    kernel: ?*const PhaserKernel,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_kernel_parameter_count(
    kernel: ?*const PhaserKernel,
    out_count: ?*usize,
) callconv(.c) Status;

extern fn phaser_diagnostics_destroy(
    diagnostics: ?*PhaserDiagnostics,
) callconv(.c) void;
extern fn phaser_diagnostics_count(
    diagnostics: ?*const PhaserDiagnostics,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_diagnostics_at(
    diagnostics: ?*const PhaserDiagnostics,
    index: usize,
    out_diagnostic: ?*Diagnostic,
) callconv(.c) Status;
extern fn phaser_diagnostics_render(
    diagnostics: ?*const PhaserDiagnostics,
    index: usize,
    buffer: ?[*]u8,
    capacity: usize,
    out_length: ?*usize,
) callconv(.c) Status;

/// A small valid model, transcribed here rather than shared with the example
/// fixtures so that a change to an example cannot silently change what these
/// tests assert. Two parameters and one scalar field, which is what the count
/// queries below check against.
const valid_model =
    \\{
    \\  "schema": "phaser.qft-model/0.1",
    \\  "spacetime_dimension": 4,
    \\  "conventions": {
    \\    "metric": "mostly_plus",
    \\    "scalar_representation": "real_components",
    \\    "fermions": "two_component_weyl"
    \\  },
    \\  "parameters": {
    \\    "lambda": {"domain": "real", "mass_dimension": 0},
    \\    "m2": {"domain": "real", "mass_dimension": 2}
    \\  },
    \\  "fields": {
    \\    "real_scalars": [{"id": "phi"}],
    \\    "weyl_fermions": [],
    \\    "gauge_vectors": []
    \\  },
    \\  "tensors": {
    \\    "scalar_mass_squared": {
    \\      "components": [{"indices": ["phi", "phi"], "value": "m2"}]
    \\    },
    \\    "scalar_quartic": {
    \\      "components": [{"indices": ["phi", "phi", "phi", "phi"], "value": "lambda"}]
    \\    }
    \\  }
    \\}
;

/// A one-loop request over the full scalar background space.
const one_loop_request =
    \\{
    \\  "schema": "phaser.calculation/0.1",
    \\  "kind": "effective_potential",
    \\  "background": { "mode": "full_scalar_space" },
    \\  "environment": { "kind": "vacuum" },
    \\  "renormalization": { "scheme": "MSbar" },
    \\  "orders": { "loop": { "through": 1 } }
    \\}
;

/// The same calculation truncated at tree level, which is real rather than
/// complex and carries one contribution instead of two.
const tree_request =
    \\{
    \\  "schema": "phaser.calculation/0.1",
    \\  "kind": "effective_potential",
    \\  "background": { "mode": "full_scalar_space" },
    \\  "environment": { "kind": "vacuum" },
    \\  "orders": { "loop": { "through": 0 } }
    \\}
;

fn createContext() !*PhaserContext {
    var context: ?*PhaserContext = null;
    try std.testing.expectEqual(Status.ok, phaser_context_create(null, &context));
    return context orelse error.TestUnexpectedResult;
}

test "a context is created with defaults and destroyed" {
    const context = try createContext();
    phaser_context_destroy(context);
}

test "context creation rejects a null out parameter rather than faulting" {
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_context_create(null, null),
    );
}

test "context creation clears the out parameter before it can fail" {
    // A caller that ignores the status must read null, not a stale pointer from
    // its own stack. The sentinel is what a careless caller's uninitialized
    // variable stands in for here.
    const sentinel: *PhaserContext = @ptrFromInt(0xdead_0000);
    var context: ?*PhaserContext = sentinel;

    var options = ContextOptions{
        .struct_size = @sizeOf(ContextOptions),
        .abi_version = 0,
        .max_diagnostics = 0, // rejected: the core requires a nonzero limit
        .max_related_locations = 8,
    };
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_context_create(&options, &context),
    );
    try std.testing.expectEqual(@as(?*PhaserContext, null), context);
}

test "context options are validated against the extensible-structure rule" {
    var context: ?*PhaserContext = null;

    // struct_size below the fixed prologue is malformed.
    var too_small = ContextOptions{
        .struct_size = 4,
        .abi_version = 0,
        .max_diagnostics = 8,
        .max_related_locations = 8,
    };
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_context_create(&too_small, &context),
    );

    // struct_size larger than this version understands means the caller is
    // newer than the library. Version 0 rejects rather than guessing.
    var too_large = ContextOptions{
        .struct_size = @sizeOf(ContextOptions) + 8,
        .abi_version = 0,
        .max_diagnostics = 8,
        .max_related_locations = 8,
    };
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_context_create(&too_large, &context),
    );

    // A mismatched ABI version is refused outright.
    var wrong_version = ContextOptions{
        .struct_size = @sizeOf(ContextOptions),
        .abi_version = 1,
        .max_diagnostics = 8,
        .max_related_locations = 8,
    };
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_context_create(&wrong_version, &context),
    );
}

test "a context honoring only the prologue gets documented defaults" {
    // A caller compiled against a hypothetical earlier header that had only the
    // prologue must still work; the fields it does not carry take defaults.
    var options = ContextOptions{
        .struct_size = 8,
        .abi_version = 0,
        .max_diagnostics = 0,
        .max_related_locations = 0,
    };
    var context: ?*PhaserContext = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_context_create(&options, &context),
    );
    defer phaser_context_destroy(context);
    try std.testing.expect(context != null);
}

test "destroying a null handle is a no-op for every handle type" {
    // The contract says NULL is accepted everywhere. A crash here would make
    // ordinary C cleanup patterns unsafe.
    phaser_context_destroy(null);
    phaser_model_destroy(null);
    phaser_diagnostics_destroy(null);
}

test "a valid model loads, answers typed queries, and is destroyed" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var model: ?*PhaserModel = null;
    var diagnostics: ?*PhaserDiagnostics = null;
    const status = phaser_model_load(
        context,
        valid_model.ptr,
        valid_model.len,
        &model,
        &diagnostics,
    );
    try std.testing.expectEqual(Status.ok, status);
    try std.testing.expect(model != null);
    // Success promises no diagnostics; only invalid_source does.
    try std.testing.expectEqual(@as(?*PhaserDiagnostics, null), diagnostics);
    defer phaser_model_destroy(model);

    var parameters: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_parameter_count(model, &parameters),
    );
    try std.testing.expectEqual(@as(usize, 2), parameters);

    var scalars: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_scalar_field_count(model, &scalars),
    );
    try std.testing.expectEqual(@as(usize, 1), scalars);
}

test "a model does not borrow from the source buffer it was parsed from" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    // The contract says the caller may free the source immediately. A copy on
    // the heap makes a borrow detectable: the allocator poisons freed memory in
    // Debug, so a fingerprint read from borrowed bytes would change or trap.
    const copy = try std.testing.allocator.dupe(u8, valid_model);
    var model: ?*PhaserModel = null;
    const status = phaser_model_load(context, copy.ptr, copy.len, &model, null);
    try std.testing.expectEqual(Status.ok, status);
    defer phaser_model_destroy(model);

    var before: [32]u8 = undefined;
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_fingerprint(model, &before, before.len),
    );

    std.testing.allocator.free(copy);

    var after: [32]u8 = undefined;
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_fingerprint(model, &after, after.len),
    );
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "fingerprint reports insufficient space without writing a partial value" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var model: ?*PhaserModel = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_load(context, valid_model.ptr, valid_model.len, &model, null),
    );
    defer phaser_model_destroy(model);

    var small: [31]u8 = @splat(0xaa);
    try std.testing.expectEqual(
        Status.insufficient_space,
        phaser_model_fingerprint(model, &small, small.len),
    );
    // Capacity failures are reported before anything is written.
    for (small) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);

    // Exactly the required size succeeds, and one byte less does not.
    var exact: [32]u8 = @splat(0);
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_fingerprint(model, &exact, exact.len),
    );
    try std.testing.expectEqual(
        Status.insufficient_space,
        phaser_model_fingerprint(model, &exact, exact.len - 1),
    );
}

test "invalid source produces diagnostics that outlive the source bytes" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    const broken = try std.testing.allocator.dupe(u8, "{ not valid json");
    var model: ?*PhaserModel = null;
    var diagnostics: ?*PhaserDiagnostics = null;
    const status = phaser_model_load(
        context,
        broken.ptr,
        broken.len,
        &model,
        &diagnostics,
    );
    try std.testing.expectEqual(Status.invalid_source, status);
    try std.testing.expectEqual(@as(?*PhaserModel, null), model);
    try std.testing.expect(diagnostics != null);
    defer phaser_diagnostics_destroy(diagnostics);

    // The handle is documented not to borrow from the source it describes.
    std.testing.allocator.free(broken);

    var count: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_diagnostics_count(diagnostics, &count),
    );
    try std.testing.expect(count > 0);

    var entry = Diagnostic{
        .struct_size = @sizeOf(Diagnostic),
        .abi_version = 0,
        .code = 0,
        .category = -1,
        .severity = -1,
        .has_primary = -1,
        .primary_source_id = 0,
        .primary_start = 0,
        .primary_end = 0,
        .related_count = 0,
        .reserved = 0,
    };
    try std.testing.expectEqual(
        Status.ok,
        phaser_diagnostics_at(diagnostics, 0, &entry),
    );
    try std.testing.expect(entry.code != 0);
    try std.testing.expectEqual(@as(u32, 0), entry.abi_version);
    // Severity and category must have been written to real enum values.
    try std.testing.expect(entry.severity >= 0 and entry.severity <= 2);
    try std.testing.expect(entry.category >= 0 and entry.category <= 7);
    try std.testing.expect(entry.has_primary == 0 or entry.has_primary == 1);
}

test "diagnostics reject an out-of-range index" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var diagnostics: ?*PhaserDiagnostics = null;
    var model: ?*PhaserModel = null;
    try std.testing.expectEqual(
        Status.invalid_source,
        phaser_model_load(context, "{", 1, &model, &diagnostics),
    );
    defer phaser_diagnostics_destroy(diagnostics);

    var count: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_diagnostics_count(diagnostics, &count),
    );

    var entry = Diagnostic{
        .struct_size = @sizeOf(Diagnostic),
        .abi_version = 0,
        .code = 0,
        .category = 0,
        .severity = 0,
        .has_primary = 0,
        .primary_source_id = 0,
        .primary_start = 0,
        .primary_end = 0,
        .related_count = 0,
        .reserved = 0,
    };
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_diagnostics_at(diagnostics, count, &entry),
    );
}

test "rendering sizes with a null buffer and then fills exactly" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var diagnostics: ?*PhaserDiagnostics = null;
    var model: ?*PhaserModel = null;
    try std.testing.expectEqual(
        Status.invalid_source,
        phaser_model_load(context, "{", 1, &model, &diagnostics),
    );
    defer phaser_diagnostics_destroy(diagnostics);

    // The ordinary sizing call: null buffer, read the required length.
    var required: usize = 0;
    try std.testing.expectEqual(
        Status.insufficient_space,
        phaser_diagnostics_render(diagnostics, 0, null, 0, &required),
    );
    try std.testing.expect(required > 0);

    const buffer = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(buffer);

    var written: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_diagnostics_render(diagnostics, 0, buffer.ptr, buffer.len, &written),
    );
    try std.testing.expectEqual(required, written);
    // No null terminator is written; the length is authoritative.
    try std.testing.expect(buffer[buffer.len - 1] != 0);

    // One byte short is a reported capacity failure, not a truncation.
    try std.testing.expectEqual(
        Status.insufficient_space,
        phaser_diagnostics_render(diagnostics, 0, buffer.ptr, buffer.len - 1, &written),
    );
    try std.testing.expectEqual(required, written);
}

test "every query rejects a null handle and a null out parameter" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var model: ?*PhaserModel = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_load(context, valid_model.ptr, valid_model.len, &model, null),
    );
    defer phaser_model_destroy(model);

    var count: usize = 0;
    var bytes: [32]u8 = undefined;

    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_model_parameter_count(null, &count),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_model_parameter_count(model, null),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_model_scalar_field_count(null, &count),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_model_fingerprint(null, &bytes, bytes.len),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_model_fingerprint(model, null, 32),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_diagnostics_count(null, &count),
    );

    // A separate slot, deliberately. `phaser_model_load` clears its out
    // parameter before it validates anything, so passing `&model` here would
    // null the live handle above and leak it. That is the documented contract
    // working as intended -- a caller that ignores the status reads null rather
    // than a stale pointer -- and the cost is that an out parameter must not
    // alias a handle the caller still owns.
    var rejected: ?*PhaserModel = null;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_model_load(null, valid_model.ptr, valid_model.len, &rejected, null),
    );
    try std.testing.expectEqual(@as(?*PhaserModel, null), rejected);
}

test "a null source with a nonzero length is rejected, and an empty one is not" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var model: ?*PhaserModel = null;
    var diagnostics: ?*PhaserDiagnostics = null;

    // A null pointer with a claimed length is a caller mistake, and one that
    // would otherwise be a read of address zero.
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_model_load(context, null, 16, &model, &diagnostics),
    );

    // Zero bytes is a well-formed call describing an empty document, which the
    // parser then rejects on its own terms. The distinction matters: one is an
    // ABI misuse, the other is invalid input with a diagnostic to show.
    try std.testing.expectEqual(
        Status.invalid_source,
        phaser_model_load(context, null, 0, &model, &diagnostics),
    );
    defer phaser_diagnostics_destroy(diagnostics);
    try std.testing.expect(diagnostics != null);
}

test "invalid source without a diagnostics slot still reports and does not leak" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    // A caller that does not want diagnostics passes null. The parse failure is
    // still reported, and the diagnostics the core built must be released
    // rather than leaked -- which the context's leak-checking allocator asserts
    // when it is destroyed.
    var model: ?*PhaserModel = null;
    try std.testing.expectEqual(
        Status.invalid_source,
        phaser_model_load(context, "{", 1, &model, null),
    );
    try std.testing.expectEqual(@as(?*PhaserModel, null), model);
}

test "handles of the wrong type are rejected rather than dereferenced" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var model: ?*PhaserModel = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_load(context, valid_model.ptr, valid_model.len, &model, null),
    );
    defer phaser_model_destroy(model);

    // A context passed where a model is expected. Each handle carries a
    // distinct tag precisely so this is a reported error rather than a
    // misinterpreted struct.
    const misused: *const PhaserModel = @ptrCast(context);
    var count: usize = 0;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_model_parameter_count(misused, &count),
    );

    const misused_diagnostics: *const PhaserDiagnostics = @ptrCast(context);
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_diagnostics_count(misused_diagnostics, &count),
    );
}

// ---------------------------------------------------------------------------
// The calculation lifecycle: request, artifact, kernel.
// ---------------------------------------------------------------------------

const Chain = struct {
    context: *PhaserContext,
    model: ?*PhaserModel = null,
    request: ?*PhaserRequest = null,
    artifact: ?*PhaserArtifact = null,

    fn deinit(self: *Chain) void {
        // Destroyed in reverse construction order, which is the ordering the
        // handles' outlives-relationships require.
        phaser_artifact_destroy(self.artifact);
        phaser_request_destroy(self.request);
        phaser_model_destroy(self.model);
        phaser_context_destroy(self.context);
    }
};

/// Builds model -> request -> artifact for `request_source`.
fn derive(request_source: []const u8) !Chain {
    var chain = Chain{ .context = try createContext() };
    errdefer chain.deinit();

    try std.testing.expectEqual(
        Status.ok,
        phaser_model_load(
            chain.context,
            valid_model.ptr,
            valid_model.len,
            &chain.model,
            null,
        ),
    );
    try std.testing.expectEqual(
        Status.ok,
        phaser_request_parse(
            chain.context,
            request_source.ptr,
            request_source.len,
            &chain.request,
            null,
        ),
    );
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_derive(
            chain.context,
            chain.model,
            chain.request,
            &chain.artifact,
            null,
        ),
    );
    return chain;
}

test "a request parses and reports its truncation" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var request: ?*PhaserRequest = null;
    var diagnostics: ?*PhaserDiagnostics = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_request_parse(
            context,
            one_loop_request.ptr,
            one_loop_request.len,
            &request,
            &diagnostics,
        ),
    );
    try std.testing.expectEqual(@as(?*PhaserDiagnostics, null), diagnostics);
    defer phaser_request_destroy(request);

    var loop_order: u32 = 99;
    try std.testing.expectEqual(
        Status.ok,
        phaser_request_loop_order(request, &loop_order),
    );
    try std.testing.expectEqual(@as(u32, 1), loop_order);
}

test "an invalid request reports diagnostics and no handle" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var request: ?*PhaserRequest = null;
    var diagnostics: ?*PhaserDiagnostics = null;
    try std.testing.expectEqual(
        Status.invalid_source,
        phaser_request_parse(context, "{}", 2, &request, &diagnostics),
    );
    try std.testing.expectEqual(@as(?*PhaserRequest, null), request);
    try std.testing.expect(diagnostics != null);
    defer phaser_diagnostics_destroy(diagnostics);

    var count: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_diagnostics_count(diagnostics, &count),
    );
    try std.testing.expect(count > 0);
}

test "a null request source with a nonzero length is rejected, and an empty one is not" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var request: ?*PhaserRequest = null;
    var diagnostics: ?*PhaserDiagnostics = null;

    // A null pointer with a claimed length is a caller mistake, and one that
    // would otherwise be a read of address zero.
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_request_parse(context, null, 16, &request, &diagnostics),
    );

    // Zero bytes is a well-formed call describing an empty document, which the
    // parser then rejects on its own terms.
    try std.testing.expectEqual(
        Status.invalid_source,
        phaser_request_parse(context, null, 0, &request, &diagnostics),
    );
    defer phaser_diagnostics_destroy(diagnostics);
    try std.testing.expect(diagnostics != null);
}

test "a one-loop artifact is complex and carries both contributions" {
    var chain = try derive(one_loop_request);
    defer chain.deinit();

    var loop_order: u32 = 99;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_loop_order(chain.artifact, &loop_order),
    );
    try std.testing.expectEqual(@as(u32, 1), loop_order);

    // Raising the truncation by one loop order adds exactly one contribution.
    // The absolute count depends on how the tree potential is decomposed, which
    // is the derivation's business and not something this boundary should pin;
    // the difference is the fact the loop order is responsible for.
    var one_loop_contributions: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_contribution_count(chain.artifact, &one_loop_contributions),
    );

    var tree = try derive(tree_request);
    defer tree.deinit();
    var tree_contributions: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_contribution_count(tree.artifact, &tree_contributions),
    );
    try std.testing.expect(tree_contributions >= 1);
    try std.testing.expectEqual(tree_contributions + 1, one_loop_contributions);

    // The one-loop potential is complex where a scalar mass-squared eigenvalue
    // is negative, so the artifact's result type must say so rather than
    // quietly promising a real answer.
    var result_type: i32 = -1;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_result_type(chain.artifact, &result_type),
    );
    try std.testing.expectEqual(@as(i32, 1), result_type); // complex64

    // One background coordinate, matching the model's single scalar field.
    var coordinates: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_coordinate_count(chain.artifact, &coordinates),
    );
    try std.testing.expectEqual(@as(usize, 1), coordinates);
}

test "a tree artifact is real where the one-loop one is complex" {
    // The contrast with the one-loop case is the point: the result type is a
    // property of the derived calculation, not a constant. A boundary that
    // hard-coded either answer would pass every other check here.
    var chain = try derive(tree_request);
    defer chain.deinit();

    var result_type: i32 = -1;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_result_type(chain.artifact, &result_type),
    );
    try std.testing.expectEqual(@as(i32, 0), result_type); // real64

    var loop_order: u32 = 99;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_loop_order(chain.artifact, &loop_order),
    );
    try std.testing.expectEqual(@as(u32, 0), loop_order);
}

test "artifact export sizes with a null buffer and renders both targets" {
    var chain = try derive(one_loop_request);
    defer chain.deinit();

    for ([_]i32{ 0, 1 }) |target| { // phaser, latex
        var required: usize = 0;
        try std.testing.expectEqual(
            Status.insufficient_space,
            phaser_artifact_export(chain.artifact, target, null, 0, &required),
        );
        try std.testing.expect(required > 0);

        const buffer = try std.testing.allocator.alloc(u8, required);
        defer std.testing.allocator.free(buffer);

        var written: usize = 0;
        try std.testing.expectEqual(
            Status.ok,
            phaser_artifact_export(
                chain.artifact,
                target,
                buffer.ptr,
                buffer.len,
                &written,
            ),
        );
        try std.testing.expectEqual(required, written);

        // One byte short is a reported capacity failure, never a truncation.
        try std.testing.expectEqual(
            Status.insufficient_space,
            phaser_artifact_export(
                chain.artifact,
                target,
                buffer.ptr,
                buffer.len - 1,
                &written,
            ),
        );
    }
}

test "the two export targets render differently" {
    var chain = try derive(one_loop_request);
    defer chain.deinit();

    var lengths: [2]usize = .{ 0, 0 };
    var rendered: [2][]u8 = undefined;
    for ([_]i32{ 0, 1 }, 0..) |target, index| {
        _ = phaser_artifact_export(chain.artifact, target, null, 0, &lengths[index]);
        rendered[index] = try std.testing.allocator.alloc(u8, lengths[index]);
        var written: usize = 0;
        try std.testing.expectEqual(
            Status.ok,
            phaser_artifact_export(
                chain.artifact,
                target,
                rendered[index].ptr,
                rendered[index].len,
                &written,
            ),
        );
    }
    defer std.testing.allocator.free(rendered[0]);
    defer std.testing.allocator.free(rendered[1]);

    // Not a golden comparison -- the exporter has its own tests for that. This
    // asserts only that the target argument reaches the exporter, which a
    // hard-coded target would pass every other check without doing.
    try std.testing.expect(!std.mem.eql(u8, rendered[0], rendered[1]));
}

test "an unrecognized export target is rejected rather than defaulted" {
    var chain = try derive(one_loop_request);
    defer chain.deinit();

    var length: usize = 0;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_artifact_export(chain.artifact, 7, null, 0, &length),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_artifact_export(chain.artifact, -1, null, 0, &length),
    );
}

test "a kernel compiles and agrees with its artifact about the result type" {
    var chain = try derive(one_loop_request);
    defer chain.deinit();

    var kernel: ?*PhaserKernel = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_compile(chain.context, chain.artifact, null, &kernel),
    );
    try std.testing.expect(kernel != null);
    defer phaser_kernel_destroy(kernel);

    // The artifact and the kernel carry separate internal result-type enums.
    // A client asking each for the same fact must get the same number.
    var artifact_type: i32 = -1;
    var kernel_type: i32 = -2;
    try std.testing.expectEqual(
        Status.ok,
        phaser_artifact_result_type(chain.artifact, &artifact_type),
    );
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_result_type(kernel, &kernel_type),
    );
    try std.testing.expectEqual(artifact_type, kernel_type);

    var capability: i32 = -1;
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_capability(kernel, &capability),
    );
    try std.testing.expectEqual(@as(i32, 2), capability); // value_gradient_hessian

    var coordinates: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_coordinate_count(kernel, &coordinates),
    );
    try std.testing.expectEqual(@as(usize, 1), coordinates);

    var parameters: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_parameter_count(kernel, &parameters),
    );
    try std.testing.expect(parameters > 0);
}

test "a narrower kernel capability is honored" {
    var chain = try derive(one_loop_request);
    defer chain.deinit();

    var options = KernelOptions{
        .struct_size = @sizeOf(KernelOptions),
        .abi_version = 0,
        .capability = 0, // value only
        .reserved = 0,
    };
    var kernel: ?*PhaserKernel = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_compile(chain.context, chain.artifact, &options, &kernel),
    );
    defer phaser_kernel_destroy(kernel);

    var capability: i32 = -1;
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_capability(kernel, &capability),
    );
    try std.testing.expectEqual(@as(i32, 0), capability);
}

test "an unrecognized kernel capability is rejected" {
    var chain = try derive(one_loop_request);
    defer chain.deinit();

    var options = KernelOptions{
        .struct_size = @sizeOf(KernelOptions),
        .abi_version = 0,
        .capability = 9,
        .reserved = 0,
    };
    var kernel: ?*PhaserKernel = null;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_kernel_compile(chain.context, chain.artifact, &options, &kernel),
    );
    try std.testing.expectEqual(@as(?*PhaserKernel, null), kernel);
}

test "the calculation handles reject nulls and wrong types" {
    var chain = try derive(one_loop_request);
    defer chain.deinit();

    var count: usize = 0;
    var order: u32 = 0;
    var kind: i32 = 0;

    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_request_loop_order(null, &order),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_artifact_loop_order(chain.artifact, null),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_artifact_contribution_count(null, &count),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_kernel_result_type(null, &kind),
    );

    // A model where a request is expected, and an artifact where a kernel is.
    const model_as_request: *const PhaserRequest = @ptrCast(chain.model);
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_request_loop_order(model_as_request, &order),
    );
    const artifact_as_kernel: *const PhaserKernel = @ptrCast(chain.artifact);
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_kernel_capability(artifact_as_kernel, &kind),
    );

    // Derivation with a mismatched handle pair.
    var artifact: ?*PhaserArtifact = null;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_artifact_derive(
            chain.context,
            @ptrCast(chain.request),
            @ptrCast(chain.model),
            &artifact,
            null,
        ),
    );
    try std.testing.expectEqual(@as(?*PhaserArtifact, null), artifact);
}

// ---------------------------------------------------------------------------
// Binding and evaluation.
// ---------------------------------------------------------------------------

const PhaserPoint = opaque {};
const PhaserBinding = opaque {};

const Complex = extern struct { re: f64, im: f64 };

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
    values: ?[*]Complex,
    value_count: usize,
    gradients: ?[*]Complex,
    gradient_count: usize,
    hessians: ?[*]Complex,
    hessian_count: usize,
    statuses: ?[*]i32,
    status_count: usize,
};

extern fn phaser_point_parse(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_point: ?*?*PhaserPoint,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_point_destroy(point: ?*PhaserPoint) callconv(.c) void;
extern fn phaser_point_reference_scale(
    point: ?*const PhaserPoint,
    out_scale: ?*f64,
) callconv(.c) Status;

extern fn phaser_binding_create(
    context: ?*PhaserContext,
    kernel: ?*const PhaserKernel,
    model: ?*const PhaserModel,
    point: ?*const PhaserPoint,
    out_binding: ?*?*PhaserBinding,
) callconv(.c) Status;
extern fn phaser_binding_destroy(binding: ?*PhaserBinding) callconv(.c) void;
extern fn phaser_binding_workspace(
    binding: ?*const PhaserBinding,
    point_count: usize,
    out_bytes: ?*usize,
    out_alignment: ?*usize,
) callconv(.c) Status;
extern fn phaser_binding_coordinate_count(
    binding: ?*const PhaserBinding,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_binding_result_type(
    binding: ?*const PhaserBinding,
    out_result_type: ?*i32,
) callconv(.c) Status;

extern fn phaser_evaluate(
    binding: ?*const PhaserBinding,
    backgrounds: ?[*]const f64,
    background_count: usize,
    point_count: usize,
    workspace: ?[*]u8,
    workspace_bytes: usize,
    outputs: ?*Outputs,
) callconv(.c) Status;
extern fn phaser_evaluate_complex(
    binding: ?*const PhaserBinding,
    backgrounds: ?[*]const f64,
    background_count: usize,
    point_count: usize,
    workspace: ?[*]u8,
    workspace_bytes: usize,
    outputs: ?*ComplexOutputs,
) callconv(.c) Status;

/// Values for exactly the two parameters `valid_model` declares.
///
/// The mass-squared is `m2 + lambda * phi^2 / 2`, so it is negative below
/// |phi| = sqrt(2 * 7812.5 / 0.26) ~= 245 and positive above. Both sides are
/// used below, because the sign is what decides whether the one-loop result has
/// an imaginary part.
const parameter_point =
    \\{
    \\  "schema": "phaser.parameter-point/0.1",
    \\  "units": { "mass": "GeV" },
    \\  "renormalization": { "scheme": "MSbar", "reference_scale": 125.0 },
    \\  "values": { "lambda": 0.26, "m2": -7812.5 }
    \\}
;

const Bound = struct {
    chain: Chain,
    point: ?*PhaserPoint = null,
    kernel: ?*PhaserKernel = null,
    binding: ?*PhaserBinding = null,

    fn deinit(self: *Bound) void {
        phaser_binding_destroy(self.binding);
        phaser_kernel_destroy(self.kernel);
        phaser_point_destroy(self.point);
        self.chain.deinit();
    }
};

fn bind(request_source: []const u8) !Bound {
    var bound = Bound{ .chain = try derive(request_source) };
    errdefer bound.deinit();

    try std.testing.expectEqual(
        Status.ok,
        phaser_point_parse(
            bound.chain.context,
            parameter_point.ptr,
            parameter_point.len,
            &bound.point,
            null,
        ),
    );
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_compile(
            bound.chain.context,
            bound.chain.artifact,
            null,
            &bound.kernel,
        ),
    );
    try std.testing.expectEqual(
        Status.ok,
        phaser_binding_create(
            bound.chain.context,
            bound.kernel,
            bound.chain.model,
            bound.point,
            &bound.binding,
        ),
    );
    return bound;
}

/// Workspace sized and aligned exactly as the binding reported.
const Workspace = struct {
    bytes: []align(64) u8,
    fn deinit(self: *Workspace) void {
        std.testing.allocator.free(self.bytes);
    }
};

fn allocateWorkspace(binding: ?*const PhaserBinding, point_count: usize) !Workspace {
    var required: usize = 0;
    var alignment: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_binding_workspace(binding, point_count, &required, &alignment),
    );
    try std.testing.expect(alignment <= 64);
    const bytes = try std.testing.allocator.alignedAlloc(u8, .@"64", required);
    return .{ .bytes = bytes };
}

test "a parameter point parses and reports its reference scale" {
    const context = try createContext();
    defer phaser_context_destroy(context);

    var point: ?*PhaserPoint = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_point_parse(
            context,
            parameter_point.ptr,
            parameter_point.len,
            &point,
            null,
        ),
    );
    defer phaser_point_destroy(point);

    var scale: f64 = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_point_reference_scale(point, &scale),
    );
    try std.testing.expectEqual(@as(f64, 125.0), scale);
}

test "binding rejects a point that does not cover the model" {
    var chain = try derive(tree_request);
    defer chain.deinit();

    var kernel: ?*PhaserKernel = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_kernel_compile(chain.context, chain.artifact, null, &kernel),
    );
    defer phaser_kernel_destroy(kernel);

    // Omits `lambda`, which the model declares.
    const incomplete =
        \\{
        \\  "schema": "phaser.parameter-point/0.1",
        \\  "units": { "mass": "GeV" },
        \\  "renormalization": { "scheme": "MSbar", "reference_scale": 125.0 },
        \\  "values": { "m2": -7812.5 }
        \\}
    ;
    var point: ?*PhaserPoint = null;
    try std.testing.expectEqual(
        Status.ok,
        phaser_point_parse(chain.context, incomplete.ptr, incomplete.len, &point, null),
    );
    defer phaser_point_destroy(point);

    // The point parses on its own terms; it is binding that finds it
    // incomplete, because only there is it compared against the model.
    var binding: ?*PhaserBinding = null;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_binding_create(chain.context, kernel, chain.model, point, &binding),
    );
    try std.testing.expectEqual(@as(?*PhaserBinding, null), binding);
}

test "a tree binding evaluates real values with per-point statuses" {
    var bound = try bind(tree_request);
    defer bound.deinit();

    var result_type: i32 = -1;
    try std.testing.expectEqual(
        Status.ok,
        phaser_binding_result_type(bound.binding, &result_type),
    );
    try std.testing.expectEqual(@as(i32, 0), result_type); // real64

    const point_count: usize = 3;
    const backgrounds = [_]f64{ 0.0, 100.0, 500.0 };

    var workspace = try allocateWorkspace(bound.binding, point_count);
    defer workspace.deinit();

    var values: [3]f64 = @splat(0);
    var gradients: [3]f64 = @splat(0);
    var hessians: [3]f64 = @splat(0);
    var statuses: [3]i32 = @splat(-1);

    var outputs = Outputs{
        .struct_size = @sizeOf(Outputs),
        .abi_version = 0,
        .values = &values,
        .value_count = point_count,
        .gradients = &gradients,
        .gradient_count = point_count, // one coordinate
        .hessians = &hessians,
        .hessian_count = point_count,
        .statuses = &statuses,
        .status_count = point_count,
    };
    try std.testing.expectEqual(
        Status.ok,
        phaser_evaluate(
            bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len,
            &outputs,
        ),
    );

    for (statuses) |status| {
        try std.testing.expectEqual(@as(i32, 0), status); // PHASER_POINT_OK
    }
    for (values) |value| try std.testing.expect(std.math.isFinite(value));
    // The tree potential is even in phi, so the gradient vanishes at the origin
    // and does not at 100. This is a shape check on the plumbing, not a
    // scientific assertion -- the kernel's own suites own that.
    try std.testing.expectEqual(@as(f64, 0.0), gradients[0]);
    try std.testing.expect(gradients[1] != 0.0);
}

test "a one-loop binding evaluates complex values, with a real part above the sign change" {
    var bound = try bind(one_loop_request);
    defer bound.deinit();

    var result_type: i32 = -1;
    try std.testing.expectEqual(
        Status.ok,
        phaser_binding_result_type(bound.binding, &result_type),
    );
    try std.testing.expectEqual(@as(i32, 1), result_type); // complex64

    // Below and above the point where the field-dependent mass-squared changes
    // sign, which is near |phi| = 245 for these parameters.
    const point_count: usize = 2;
    const backgrounds = [_]f64{ 100.0, 500.0 };

    var workspace = try allocateWorkspace(bound.binding, point_count);
    defer workspace.deinit();

    var values: [2]Complex = @splat(.{ .re = 0, .im = 0 });
    var gradients: [2]Complex = @splat(.{ .re = 0, .im = 0 });
    var hessians: [2]Complex = @splat(.{ .re = 0, .im = 0 });
    var statuses: [2]i32 = @splat(-1);

    var outputs = ComplexOutputs{
        .struct_size = @sizeOf(ComplexOutputs),
        .abi_version = 0,
        .values = &values,
        .value_count = point_count,
        .gradients = &gradients,
        .gradient_count = point_count,
        .hessians = &hessians,
        .hessian_count = point_count,
        .statuses = &statuses,
        .status_count = point_count,
    };
    try std.testing.expectEqual(
        Status.ok,
        phaser_evaluate_complex(
            bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len,
            &outputs,
        ),
    );

    // This is the claim decision 0013's two status spaces exist for. A negative
    // scalar mass-squared eigenvalue is a *successful* complex result, not a
    // failed call: the status is ok and the imaginary component is nonzero.
    // Collapsing the two spaces would have made this indistinguishable from a
    // domain error.
    try std.testing.expectEqual(@as(i32, 0), statuses[0]);
    try std.testing.expect(values[0].im != 0.0);

    // Above the sign change the same calculation is real, and the imaginary
    // component is exactly zero rather than merely small.
    try std.testing.expectEqual(@as(i32, 0), statuses[1]);
    try std.testing.expectEqual(@as(f64, 0.0), values[1].im);

    for (values) |value| {
        try std.testing.expect(std.math.isFinite(value.re));
        try std.testing.expect(std.math.isFinite(value.im));
    }
}

test "the entry points refuse the result type they do not carry" {
    var complex_bound = try bind(one_loop_request);
    defer complex_bound.deinit();
    var real_bound = try bind(tree_request);
    defer real_bound.deinit();

    const point_count: usize = 1;
    const backgrounds = [_]f64{100.0};

    var complex_workspace = try allocateWorkspace(complex_bound.binding, point_count);
    defer complex_workspace.deinit();
    var real_workspace = try allocateWorkspace(real_bound.binding, point_count);
    defer real_workspace.deinit();

    var real_values: [1]f64 = @splat(0);
    var real_gradients: [1]f64 = @splat(0);
    var real_hessians: [1]f64 = @splat(0);
    var statuses: [1]i32 = @splat(-1);
    var real_outputs = Outputs{
        .struct_size = @sizeOf(Outputs),
        .abi_version = 0,
        .values = &real_values,
        .value_count = point_count,
        .gradients = &real_gradients,
        .gradient_count = point_count,
        .hessians = &real_hessians,
        .hessian_count = point_count,
        .statuses = &statuses,
        .status_count = point_count,
    };

    // The real entry point on a complex kernel must refuse rather than project.
    // Silently dropping the imaginary component is the substitution Milestone 3
    // built conformance cases to detect internally; it must not be reachable
    // here either.
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_evaluate(
            complex_bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            complex_workspace.bytes.ptr,
            complex_workspace.bytes.len,
            &real_outputs,
        ),
    );

    var complex_values: [1]Complex = @splat(.{ .re = 0, .im = 0 });
    var complex_gradients: [1]Complex = @splat(.{ .re = 0, .im = 0 });
    var complex_hessians: [1]Complex = @splat(.{ .re = 0, .im = 0 });
    var complex_outputs = ComplexOutputs{
        .struct_size = @sizeOf(ComplexOutputs),
        .abi_version = 0,
        .values = &complex_values,
        .value_count = point_count,
        .gradients = &complex_gradients,
        .gradient_count = point_count,
        .hessians = &complex_hessians,
        .hessian_count = point_count,
        .statuses = &statuses,
        .status_count = point_count,
    };

    // And the converse, so neither direction silently widens or narrows.
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_evaluate_complex(
            real_bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            real_workspace.bytes.ptr,
            real_workspace.bytes.len,
            &complex_outputs,
        ),
    );
}

test "the status array must be exactly as long as the point count" {
    var bound = try bind(tree_request);
    defer bound.deinit();

    const point_count: usize = 3;
    const backgrounds = [_]f64{ 0.0, 100.0, 500.0 };
    var workspace = try allocateWorkspace(bound.binding, point_count);
    defer workspace.deinit();

    var values: [3]f64 = @splat(0);
    var gradients: [3]f64 = @splat(0);
    var hessians: [3]f64 = @splat(0);
    var statuses: [3]i32 = @splat(-1);

    var outputs = Outputs{
        .struct_size = @sizeOf(Outputs),
        .abi_version = 0,
        .values = &values,
        .value_count = point_count,
        .gradients = &gradients,
        .gradient_count = point_count,
        .hessians = &hessians,
        .hessian_count = point_count,
        .statuses = &statuses,
        .status_count = point_count,
    };

    // Short is rejected, as an unwritten entry would be indistinguishable from
    // a successful point.
    outputs.status_count = point_count - 1;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_evaluate(
            bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len,
            &outputs,
        ),
    );

    // Longer is rejected too: it means the caller and the library disagree
    // about how many points are being evaluated.
    outputs.status_count = point_count + 1;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_evaluate(
            bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len,
            &outputs,
        ),
    );

    // A missing status array is rejected outright.
    outputs.status_count = point_count;
    outputs.statuses = null;
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_evaluate(
            bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len,
            &outputs,
        ),
    );
}

test "workspace is exact: the queried size succeeds and one byte less does not" {
    var bound = try bind(one_loop_request);
    defer bound.deinit();

    const point_count: usize = 2;
    const backgrounds = [_]f64{ 100.0, 500.0 };
    var workspace = try allocateWorkspace(bound.binding, point_count);
    defer workspace.deinit();

    var values: [2]Complex = @splat(.{ .re = 0, .im = 0 });
    var gradients: [2]Complex = @splat(.{ .re = 0, .im = 0 });
    var hessians: [2]Complex = @splat(.{ .re = 0, .im = 0 });
    var statuses: [2]i32 = @splat(-1);
    var outputs = ComplexOutputs{
        .struct_size = @sizeOf(ComplexOutputs),
        .abi_version = 0,
        .values = &values,
        .value_count = point_count,
        .gradients = &gradients,
        .gradient_count = point_count,
        .hessians = &hessians,
        .hessian_count = point_count,
        .statuses = &statuses,
        .status_count = point_count,
    };

    try std.testing.expectEqual(
        Status.ok,
        phaser_evaluate_complex(
            bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len,
            &outputs,
        ),
    );
    try std.testing.expectEqual(
        Status.insufficient_space,
        phaser_evaluate_complex(
            bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len - 1,
            &outputs,
        ),
    );
}

test "a batch agrees point for point with single-point calls" {
    // Batching is a performance decision, not a numerical one. Splitting a
    // batch must not change any point's value or status.
    var bound = try bind(one_loop_request);
    defer bound.deinit();

    const backgrounds = [_]f64{ 50.0, 100.0, 245.0, 500.0 };
    const point_count = backgrounds.len;

    var batch_workspace = try allocateWorkspace(bound.binding, point_count);
    defer batch_workspace.deinit();

    var batch_values: [point_count]Complex = @splat(.{ .re = 0, .im = 0 });
    var batch_gradients: [point_count]Complex = @splat(.{ .re = 0, .im = 0 });
    var batch_hessians: [point_count]Complex = @splat(.{ .re = 0, .im = 0 });
    var batch_statuses: [point_count]i32 = @splat(-1);
    var batch = ComplexOutputs{
        .struct_size = @sizeOf(ComplexOutputs),
        .abi_version = 0,
        .values = &batch_values,
        .value_count = point_count,
        .gradients = &batch_gradients,
        .gradient_count = point_count,
        .hessians = &batch_hessians,
        .hessian_count = point_count,
        .statuses = &batch_statuses,
        .status_count = point_count,
    };
    try std.testing.expectEqual(
        Status.ok,
        phaser_evaluate_complex(
            bound.binding,
            &backgrounds,
            backgrounds.len,
            point_count,
            batch_workspace.bytes.ptr,
            batch_workspace.bytes.len,
            &batch,
        ),
    );

    var single_workspace = try allocateWorkspace(bound.binding, 1);
    defer single_workspace.deinit();

    for (backgrounds, 0..) |background, index| {
        var value: [1]Complex = @splat(.{ .re = 0, .im = 0 });
        var gradient: [1]Complex = @splat(.{ .re = 0, .im = 0 });
        var hessian: [1]Complex = @splat(.{ .re = 0, .im = 0 });
        var status: [1]i32 = @splat(-1);
        var single = ComplexOutputs{
            .struct_size = @sizeOf(ComplexOutputs),
            .abi_version = 0,
            .values = &value,
            .value_count = 1,
            .gradients = &gradient,
            .gradient_count = 1,
            .hessians = &hessian,
            .hessian_count = 1,
            .statuses = &status,
            .status_count = 1,
        };
        const one = [_]f64{background};
        try std.testing.expectEqual(
            Status.ok,
            phaser_evaluate_complex(
                bound.binding,
                &one,
                one.len,
                1,
                single_workspace.bytes.ptr,
                single_workspace.bytes.len,
                &single,
            ),
        );

        // Bitwise, not approximately: the same kernel on the same input must
        // reproduce exactly, whatever the batch partition.
        try std.testing.expectEqual(batch_statuses[index], status[0]);
        try std.testing.expectEqual(batch_values[index].re, value[0].re);
        try std.testing.expectEqual(batch_values[index].im, value[0].im);
        try std.testing.expectEqual(batch_gradients[index].re, gradient[0].re);
        try std.testing.expectEqual(batch_hessians[index].re, hessian[0].re);
    }
}

test "evaluation rejects a background buffer of the wrong length" {
    var bound = try bind(tree_request);
    defer bound.deinit();

    const point_count: usize = 2;
    const backgrounds = [_]f64{ 100.0, 500.0 };
    var workspace = try allocateWorkspace(bound.binding, point_count);
    defer workspace.deinit();

    var values: [2]f64 = @splat(0);
    var gradients: [2]f64 = @splat(0);
    var hessians: [2]f64 = @splat(0);
    var statuses: [2]i32 = @splat(-1);
    var outputs = Outputs{
        .struct_size = @sizeOf(Outputs),
        .abi_version = 0,
        .values = &values,
        .value_count = point_count,
        .gradients = &gradients,
        .gradient_count = point_count,
        .hessians = &hessians,
        .hessian_count = point_count,
        .statuses = &statuses,
        .status_count = point_count,
    };

    // point_count * coordinate_count is the only admissible length.
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_evaluate(
            bound.binding,
            &backgrounds,
            backgrounds.len - 1,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len,
            &outputs,
        ),
    );
    try std.testing.expectEqual(
        Status.invalid_argument,
        phaser_evaluate(
            bound.binding,
            null,
            backgrounds.len,
            point_count,
            workspace.bytes.ptr,
            workspace.bytes.len,
            &outputs,
        ),
    );
}

// ---------------------------------------------------------------------------
// Destruction misuse.
// ---------------------------------------------------------------------------

test "destroying through the wrong destructor is a no-op, not a corruption" {
    // Each handle carries a distinct tag, so a destructor that receives the
    // wrong kind of handle rejects it rather than freeing it as though it were
    // its own type. That is the deterministic half of the double-destroy
    // guard: nothing is freed, and the handle keeps working.
    var bound = try bind(one_loop_request);
    defer bound.deinit();

    phaser_model_destroy(@ptrCast(bound.chain.request));
    phaser_request_destroy(@ptrCast(bound.chain.artifact));
    phaser_artifact_destroy(@ptrCast(bound.kernel));
    phaser_kernel_destroy(@ptrCast(bound.point));
    phaser_point_destroy(@ptrCast(bound.binding));
    phaser_binding_destroy(@ptrCast(bound.chain.model));

    // Every handle above survived, which it would not have if any destructor
    // had acted on a foreign tag. The subsequent cleanup in `deinit` would also
    // double-free if one had.
    var count: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        phaser_model_parameter_count(bound.chain.model, &count),
    );
    try std.testing.expectEqual(@as(usize, 2), count);

    var order: u32 = 99;
    try std.testing.expectEqual(
        Status.ok,
        phaser_request_loop_order(bound.chain.request, &order),
    );
    try std.testing.expectEqual(@as(u32, 1), order);

    var kind: i32 = -1;
    try std.testing.expectEqual(
        Status.ok,
        phaser_binding_result_type(bound.binding, &kind),
    );
    try std.testing.expectEqual(@as(i32, 1), kind);
}

test "every destructor accepts null repeatedly" {
    // Ordinary C cleanup calls a destructor on a variable that may never have
    // been assigned, and does so on every path. It must be safe to do more than
    // once.
    var iteration: usize = 0;
    while (iteration < 3) : (iteration += 1) {
        phaser_context_destroy(null);
        phaser_model_destroy(null);
        phaser_request_destroy(null);
        phaser_artifact_destroy(null);
        phaser_kernel_destroy(null);
        phaser_point_destroy(null);
        phaser_binding_destroy(null);
        phaser_diagnostics_destroy(null);
    }
}
