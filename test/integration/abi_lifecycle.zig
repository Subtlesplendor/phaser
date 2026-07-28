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
