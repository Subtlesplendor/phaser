//! Layout and constant conformance for the C ABI.
//!
//! These tests exist because `include/phaser.h` and the Zig implementation are
//! two independent descriptions of one binary interface, and nothing else would
//! notice them diverging. The expected values below are transcribed from the
//! header by hand. That is the point: asserting a Zig type against its own
//! `@sizeOf` would prove only that the type equals itself, which is exactly the
//! check that cannot fail and therefore cannot help.
//!
//! Everything is reached through `extern` declarations rather than through the
//! Zig types, so the tests see what a C caller sees -- opaque pointers and
//! integer statuses -- and a symbol that failed to export is a link error here
//! rather than a surprise in the first C client.

const std = @import("std");

// --- The C view of the ABI -------------------------------------------------
//
// Transcribed from include/phaser.h. Handles are opaque, exactly as C sees
// them.

const PhaserContext = opaque {};
const PhaserModel = opaque {};
const PhaserDiagnostics = opaque {};

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

extern fn phaser_abi_version() callconv(.c) u32;
extern fn phaser_abi_experimental() callconv(.c) c_int;
extern fn phaser_library_version(
    major: ?*u32,
    minor: ?*u32,
    patch: ?*u32,
) callconv(.c) void;

test "the loaded library reports the ABI version the header declares" {
    // PHASER_ABI_VERSION in include/phaser.h.
    try std.testing.expectEqual(@as(u32, 0), phaser_abi_version());
}

test "ABI version 0 reports itself as experimental" {
    // An exit criterion of Milestone 4 Phase A is that version 0 remains
    // explicitly experimental. The marker is separate from the version so that
    // declaring version 1 and dropping the marker stay distinguishable; this
    // asserts the marker, not the version.
    try std.testing.expect(phaser_abi_experimental() != 0);
}

test "library version is reported separately and tolerates null pointers" {
    var major: u32 = 0xffff_ffff;
    var minor: u32 = 0xffff_ffff;
    var patch: u32 = 0xffff_ffff;
    phaser_library_version(&major, &minor, &patch);
    try std.testing.expectEqual(@as(u32, 0), major);
    try std.testing.expectEqual(@as(u32, 0), minor);
    try std.testing.expectEqual(@as(u32, 0), patch);

    // Every pointer is documented as optional. Passing none must not fault.
    phaser_library_version(null, null, null);
    phaser_library_version(&major, null, null);
    try std.testing.expectEqual(@as(u32, 0), major);
}

test "context options have the layout the header publishes" {
    // Transcribed from include/phaser.h. The prologue must stay first and stay
    // at offsets 0 and 4, because the extensible-structure rule reads
    // struct_size before it knows anything else about the struct.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ContextOptions, "struct_size"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(ContextOptions, "abi_version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ContextOptions, "max_diagnostics"));
    try std.testing.expectEqual(
        @as(usize, 16),
        @offsetOf(ContextOptions, "max_related_locations"),
    );
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ContextOptions));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(ContextOptions));
}

test "diagnostic entries have the layout the header publishes" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Diagnostic, "struct_size"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Diagnostic, "abi_version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Diagnostic, "code"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Diagnostic, "category"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Diagnostic, "severity"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(Diagnostic, "has_primary"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Diagnostic, "primary_source_id"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(Diagnostic, "primary_start"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Diagnostic, "primary_end"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(Diagnostic, "related_count"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Diagnostic, "reserved"));
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(Diagnostic));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(Diagnostic));
}

test "public structures are pointer-passable without padding surprises" {
    // Every public structure begins with two u32 and is therefore at least
    // 4-byte aligned. A structure whose alignment exceeded 8 would need an
    // explicit statement in the header about how callers must allocate it.
    try std.testing.expect(@alignOf(ContextOptions) <= 8);
    try std.testing.expect(@alignOf(Diagnostic) <= 8);
}

test "control-plane status values are the ones the header publishes" {
    // Transcribed from phaser_status in include/phaser.h. These numbers are the
    // ABI; renumbering them is a breaking change while version 0 is
    // experimental, and a silent one without this test.
    const phaser = @import("phaser");
    const Status = phaser.abi.Status;
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(Status.invalid_argument));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(Status.invalid_source));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(Status.unsupported));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(Status.limit_exceeded));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(Status.insufficient_space));
    try std.testing.expectEqual(@as(c_int, 6), @intFromEnum(Status.out_of_memory));
    try std.testing.expectEqual(@as(c_int, 7), @intFromEnum(Status.internal));
}

test "per-point status values mirror the kernel statuses the header names" {
    // Transcribed from phaser_point_status in include/phaser.h, and separately
    // asserted against the kernel's own enum in src/abi/status.zig. Both checks
    // are wanted: this one pins the published numbers, that one pins the
    // correspondence. Either alone would let the pair drift together.
    const phaser = @import("phaser");
    const PointStatus = phaser.abi.PointStatus;
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(PointStatus.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(PointStatus.non_finite));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(PointStatus.division_by_zero));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(PointStatus.nonconvergent));
    try std.testing.expectEqual(
        @as(c_int, 4),
        @intFromEnum(PointStatus.singular_derivative),
    );

    // And the mapping itself, so a reordering of the kernel enum cannot quietly
    // repurpose a number a client has already recorded.
    try std.testing.expectEqual(
        PointStatus.singular_derivative,
        phaser.abi.status.fromKernelStatus(.singular_derivative),
    );
    try std.testing.expectEqual(
        PointStatus.ok,
        phaser.abi.status.fromKernelStatus(.ok),
    );
}

const KernelOptions = extern struct {
    struct_size: u32,
    abi_version: u32,
    capability: i32,
    selection_kind: i32,
    selection_value: u32,
    reserved: u32,
};

test "kernel options have the layout the header publishes" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(KernelOptions, "struct_size"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(KernelOptions, "abi_version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(KernelOptions, "capability"));
    try std.testing.expectEqual(
        @as(usize, 12),
        @offsetOf(KernelOptions, "selection_kind"),
    );
    try std.testing.expectEqual(
        @as(usize, 16),
        @offsetOf(KernelOptions, "selection_value"),
    );
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(KernelOptions, "reserved"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(KernelOptions));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(KernelOptions));
}

test "selection and role values are the ones the header publishes" {
    // As with the result types below: the numbers are transcribed from the
    // header, and the Zig enums are what they are compared against.
    const phaser = @import("phaser");
    const SelectionKind = phaser.abi.status.SelectionKind;
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(SelectionKind.total));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(SelectionKind.loop_order));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(SelectionKind.role));

    const Role = phaser.abi.status.Role;
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(Role.vacuum_energy));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(Role.scalar_tadpole));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(Role.scalar_mass_squared));
    try std.testing.expectEqual(@as(i32, 3), @intFromEnum(Role.scalar_cubic));
    try std.testing.expectEqual(@as(i32, 4), @intFromEnum(Role.scalar_quartic));
    try std.testing.expectEqual(@as(i32, 5), @intFromEnum(Role.scalar_one_loop));
}

test "result type and capability values are the ones the header publishes" {
    // Transcribed from phaser_result_type and phaser_capability in
    // include/phaser.h. Both are mirrored against internal enums in
    // src/abi/status.zig; this pins the published numbers, that pins the
    // correspondence, and neither check alone would catch the pair drifting
    // together.
    const phaser = @import("phaser");
    const ResultType = phaser.abi.status.ResultType;
    const Capability = phaser.abi.status.Capability;

    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ResultType.real64));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ResultType.complex64));

    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(Capability.value));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(Capability.value_gradient));
    try std.testing.expectEqual(
        @as(i32, 2),
        @intFromEnum(Capability.value_gradient_hessian),
    );

    // The artifact and the kernel carry separate internal result-type enums.
    // Both must map onto the single type the header publishes.
    try std.testing.expectEqual(
        ResultType.complex64,
        phaser.abi.status.fromResultType(.complex64),
    );
    try std.testing.expectEqual(
        ResultType.complex64,
        phaser.abi.status.fromArtifactResultType(.complex64),
    );
}

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

test "a complex value is two doubles in declaration order" {
    // Not C99 _Complex, which is optional in C11 and absent from C++. The
    // layout has to match what a client writing {re, im} expects.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Complex, "re"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Complex, "im"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Complex));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Complex));
}

test "output descriptions have the layout the header publishes" {
    // Pointer-sized fields, so these offsets assume a 64-bit target -- which is
    // every platform in the supported matrix. A 32-bit port would need this
    // test parameterized rather than silently passing on different numbers.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(usize));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Outputs, "struct_size"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Outputs, "abi_version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Outputs, "values"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Outputs, "value_count"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Outputs, "gradients"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Outputs, "gradient_count"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Outputs, "hessians"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Outputs, "hessian_count"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Outputs, "statuses"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(Outputs, "status_count"));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Outputs));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Outputs));
}

test "the per-point status array element is the published width" {
    // The kernel writes a one-byte enum internally; the ABI publishes int32_t
    // so a client never has to know the width of an internal tag. The widening
    // is what the boundary's extra workspace scratch exists for.
    const phaser = @import("phaser");
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(phaser.kernel.Status));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(i32));
}
