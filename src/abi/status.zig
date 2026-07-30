//! Status spaces for the C ABI.
//!
//! Two spaces exist and are never converted into one another. `Status` is the
//! control plane: whether a call was structurally well formed. `PointStatus` is
//! the per-point numerical outcome and mirrors the kernel's own status value
//! for value.
//!
//! The mirroring is deliberate coupling. It is what lets a caller read a batch
//! of outcomes without a translation table, and the comptime checks below are
//! what make a divergence a build failure here rather than a silent
//! misinterpretation at a user's boundary.

const std = @import("std");
const foundation = @import("../foundation/root.zig");
const kernel = @import("../kernel/root.zig");
const calculation = @import("../calculation/root.zig");

/// Control-plane status. Values are ABI and must not be renumbered while the
/// ABI version is unchanged.
pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    invalid_source = 2,
    unsupported = 3,
    limit_exceeded = 4,
    insufficient_space = 5,
    out_of_memory = 6,
    internal = 7,
};

/// Per-point numerical outcome, mirroring `kernel.Status`.
pub const PointStatus = enum(c_int) {
    ok = 0,
    non_finite = 1,
    division_by_zero = 2,
    nonconvergent = 3,
    singular_derivative = 4,
};

/// Diagnostic severity, mirroring `foundation.Severity`.
pub const Severity = enum(i32) {
    err = 0,
    warning = 1,
    note = 2,
};

/// Diagnostic category, mirroring `foundation.Category`.
pub const Category = enum(i32) {
    source = 0,
    capacity = 1,
    allocation = 2,
    configuration = 3,
    json = 4,
    expression = 5,
    model = 6,
    calculation = 7,
};

/// Result type of an artifact or kernel, mirroring `kernel.ResultType`.
pub const ResultType = enum(i32) {
    real64 = 0,
    complex64 = 1,
};

/// Derivative capability, mirroring `kernel.Capability`.
pub const Capability = enum(i32) {
    value = 0,
    value_gradient = 1,
    value_gradient_hessian = 2,
};

/// Contribution role, mirroring `calculation.Role`.
pub const Role = enum(i32) {
    vacuum_energy = 0,
    scalar_tadpole = 1,
    scalar_mass_squared = 2,
    scalar_cubic = 3,
    scalar_quartic = 4,
    scalar_one_loop = 5,
};

/// Which part of the artifact a kernel evaluates, mirroring the tags of
/// `kernel.Selection`. The union's payloads cross separately, because a C
/// struct cannot carry a Zig tagged union.
pub const SelectionKind = enum(i32) {
    total = 0,
    loop_order = 1,
    role = 2,
};

/// Maps a published role enumerator back to the internal one, rejecting a
/// value this version does not publish rather than resolving it to a default.
pub fn toRole(value: u32) ?calculation.Role {
    return switch (value) {
        0 => .vacuum_energy,
        1 => .scalar_tadpole,
        2 => .scalar_mass_squared,
        3 => .scalar_cubic,
        4 => .scalar_quartic,
        5 => .scalar_one_loop,
        else => null,
    };
}

pub fn fromResultType(result_type: kernel.ResultType) ResultType {
    return switch (result_type) {
        .real64 => .real64,
        .complex64 => .complex64,
    };
}

/// The artifact and the kernel carry separate result-type enums of the same
/// shape, one per subsystem. The ABI publishes a single type, so both are
/// mapped here and both are checked against it below: a client asking an
/// artifact and its compiled kernel for a result type must not get different
/// numbers for the same answer.
pub fn fromArtifactResultType(result_type: calculation.ResultType) ResultType {
    return switch (result_type) {
        .real64 => .real64,
        .complex64 => .complex64,
    };
}

pub fn fromCapability(capability: kernel.Capability) Capability {
    return switch (capability) {
        .value => .value,
        .value_gradient => .value_gradient,
        .value_gradient_hessian => .value_gradient_hessian,
    };
}

pub fn fromKernelStatus(status: kernel.Status) PointStatus {
    return switch (status) {
        .ok => .ok,
        .non_finite => .non_finite,
        .division_by_zero => .division_by_zero,
        .nonconvergent => .nonconvergent,
        .singular_derivative => .singular_derivative,
    };
}

pub fn fromSeverity(severity: foundation.Severity) Severity {
    return switch (severity) {
        .err => .err,
        .warning => .warning,
        .note => .note,
    };
}

pub fn fromCategory(category: foundation.Category) Category {
    return switch (category) {
        .source => .source,
        .capacity => .capacity,
        .allocation => .allocation,
        .configuration => .configuration,
        .json => .json,
        .expression => .expression,
        .model => .model,
        .calculation => .calculation,
    };
}

/// Asserts that an ABI mirror enum has exactly the same tag names, in the same
/// order, with the same numeric values, as the internal enum it mirrors.
///
/// Name equality is the part that matters. Comparing only the count and the
/// values would still pass if two internal tags were transposed, which is
/// precisely the change that would silently repurpose a value a client has
/// already recorded.
fn assertMirrors(comptime Internal: type, comptime Abi: type) void {
    const internal_fields = @typeInfo(Internal).@"enum".fields;
    const abi_fields = @typeInfo(Abi).@"enum".fields;

    if (internal_fields.len != abi_fields.len) {
        @compileError(
            "ABI enum " ++ @typeName(Abi) ++ " has a different number of tags than " ++
                @typeName(Internal) ++ "; adding a tag is an ABI change",
        );
    }

    for (internal_fields, abi_fields) |internal, abi| {
        if (!std.mem.eql(u8, internal.name, abi.name)) {
            @compileError(
                "ABI enum " ++ @typeName(Abi) ++ " tag '" ++ abi.name ++
                    "' does not mirror " ++ @typeName(Internal) ++ " tag '" ++
                    internal.name ++ "'",
            );
        }
        if (internal.value != abi.value) {
            @compileError(
                "ABI enum " ++ @typeName(Abi) ++ " tag '" ++ abi.name ++
                    "' has a different numeric value than its " ++
                    @typeName(Internal) ++ " counterpart",
            );
        }
    }
}

comptime {
    assertMirrors(kernel.Status, PointStatus);
    assertMirrors(foundation.Severity, Severity);
    assertMirrors(foundation.Category, Category);
    assertMirrors(kernel.ResultType, ResultType);
    assertMirrors(kernel.Capability, Capability);
    assertMirrors(calculation.ResultType, ResultType);
    assertMirrors(calculation.Role, Role);
    // The selection kinds mirror the union's tags rather than an enum, so the
    // shared check does not apply and the correspondence is asserted directly.
    // Adding a variant to the union without publishing it would leave a
    // selection a client cannot ask for; the reverse would publish one the
    // core cannot honour.
    const selection_tags = @typeInfo(kernel.Selection).@"union".fields;
    const published_tags = @typeInfo(SelectionKind).@"enum".fields;
    if (selection_tags.len != published_tags.len) {
        @compileError(
            "phaser_selection_kind has a different number of tags than " ++
                "kernel.Selection; adding a variant is an ABI change",
        );
    }
    for (selection_tags, published_tags) |internal, abi| {
        if (!std.mem.eql(u8, internal.name, abi.name)) {
            @compileError(
                "phaser_selection_kind tag '" ++ abi.name ++
                    "' does not mirror kernel.Selection tag '" ++
                    internal.name ++ "'",
            );
        }
    }
}

test "point statuses mirror the kernel statuses they report" {
    // The oracle is the internal enum: every kernel status must map to an ABI
    // status with the same name and the same number, because a client reads the
    // number and the documentation promises the name.
    inline for (@typeInfo(kernel.Status).@"enum".fields) |field| {
        const internal: kernel.Status = @enumFromInt(field.value);
        const mapped = fromKernelStatus(internal);
        try std.testing.expectEqualStrings(field.name, @tagName(mapped));
        try std.testing.expectEqual(
            @as(c_int, @intCast(field.value)),
            @intFromEnum(mapped),
        );
    }
}

test "severities and categories mirror their foundation counterparts" {
    inline for (@typeInfo(foundation.Severity).@"enum".fields) |field| {
        const mapped = fromSeverity(@as(foundation.Severity, @enumFromInt(field.value)));
        try std.testing.expectEqualStrings(field.name, @tagName(mapped));
        try std.testing.expectEqual(@as(i32, @intCast(field.value)), @intFromEnum(mapped));
    }
    inline for (@typeInfo(foundation.Category).@"enum".fields) |field| {
        const mapped = fromCategory(@as(foundation.Category, @enumFromInt(field.value)));
        try std.testing.expectEqualStrings(field.name, @tagName(mapped));
        try std.testing.expectEqual(@as(i32, @intCast(field.value)), @intFromEnum(mapped));
    }
}

test "control-plane statuses keep the numbers the header publishes" {
    // These are the values in include/phaser.h. A renumbering here is an ABI
    // break; this test is the reminder rather than the permission.
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(Status.invalid_argument));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(Status.invalid_source));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(Status.unsupported));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(Status.limit_exceeded));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(Status.insufficient_space));
    try std.testing.expectEqual(@as(c_int, 6), @intFromEnum(Status.out_of_memory));
    try std.testing.expectEqual(@as(c_int, 7), @intFromEnum(Status.internal));
}
