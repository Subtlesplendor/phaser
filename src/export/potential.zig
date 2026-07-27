//! Symbolic export views for the effective-potential artifact.
//!
//! Follows `docs/architecture/SYMBOLIC_EXPORT.md`. Contribution selection
//! happens here, through the artifact's own metadata, and never inside a target
//! renderer: an exporter does not decide which loop orders or contribution
//! classes to include.
//!
//! Nothing here diagonalizes a mass matrix, expands a spectral operation into a
//! component sum, or evaluates anything numerically. The spectral operation and
//! its branch convention are what the export preserves.

const std = @import("std");
const calculation = @import("../calculation/root.zig");
const value = @import("../value/root.zig");
const render = @import("render.zig");

pub const Target = render.Target;
pub const Options = render.Options;
pub const RenderError = render.RenderError;

const Artifact = calculation.Artifact;
const Role = calculation.Role;

/// Rendering options with the artifact's coordinate names filled in.
///
/// A spectral derivative node stores coordinate indices; the names live on the
/// artifact. Supplying them is presentation metadata and changes no content
/// identity.
fn withCoordinateNames(
    artifact: *const Artifact,
    allocator: std.mem.Allocator,
    options: Options,
) error{OutOfMemory}!struct { options: Options, names: [][]const u8 } {
    const names = try allocator.alloc([]const u8, artifact.coordinates.len);
    for (artifact.coordinates, names) |coordinate, *slot| slot.* = coordinate.id;
    var resolved = options;
    resolved.coordinate_names = names;
    return .{ .options = resolved, .names = names };
}

/// Writes the selected potential as an equation.
///
/// The visible expression uses the declared background coordinates. The
/// embedding that relates them to the model's scalar components is available
/// through `writeBackground`, which a complete export accompanies this with.
pub fn writePotential(
    artifact: *const Artifact,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    const resolved = try withCoordinateNames(artifact, allocator, options);
    defer allocator.free(resolved.names);

    try writeHeading(artifact, null, resolved.options, writer);
    try emitText(" = ", writer);
    try render.writeValue(
        &artifact.graph,
        artifact.total,
        allocator,
        resolved.options,
        writer,
    );
}

/// Writes one contribution, identified by its role and loop order.
pub fn writeContribution(
    artifact: *const Artifact,
    role: Role,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    const resolved = try withCoordinateNames(artifact, allocator, options);
    defer allocator.free(resolved.names);

    const contribution = artifact.contribution(role) orelse {
        try writeHeading(artifact, role, resolved.options, writer);
        try emitText(" = 0", writer);
        if (artifact.absence(role)) |absence| {
            // A structurally absent class is reported as such, never omitted
            // silently and never confused with an unsupported one.
            try emitText("  [structurally absent: ", writer);
            try emitText(@tagName(absence.reason), writer);
            try emitText("]", writer);
        } else {
            // Outside the requested truncation is a third outcome: neither
            // derived nor structurally absent.
            try emitText("  [not requested: above loop order ", writer);
            writer.print("{d}]", .{artifact.loop_order}) catch
                return error.WriteFailed;
        }
        return;
    };
    try writeHeading(artifact, role, resolved.options, writer);
    try emitText(" = ", writer);
    try render.writeValue(
        &artifact.graph,
        contribution.value,
        allocator,
        resolved.options,
        writer,
    );
}

/// Writes one entry of the background gradient.
pub fn writeGradientComponent(
    artifact: *const Artifact,
    coordinate: usize,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    std.debug.assert(coordinate < artifact.gradient.len);
    const resolved = try withCoordinateNames(artifact, allocator, options);
    defer allocator.free(resolved.names);

    const name = artifact.coordinates[coordinate].id;
    switch (options.target) {
        .phaser => {
            try emitText("dV/d", writer);
            try emitText(name, writer);
        },
        .latex => {
            try emitText("\\frac{\\partial V}{\\partial ", writer);
            try writeIdentifier(name, options, writer);
            try emitText("}", writer);
        },
    }
    try emitText(" = ", writer);
    try render.writeValue(
        &artifact.graph,
        artifact.gradient[coordinate],
        allocator,
        resolved.options,
        writer,
    );
}

/// Writes the background parametrization, including the coordinate-to-scalar
/// map and the statement that unselected scalars remain fluctuation fields.
///
/// Section 8 requires the embedding to be available alongside any export of a
/// background-dependent object, and forbids implying that unselected scalar
/// fields were removed from the calculation.
pub fn writeBackground(
    artifact: *const Artifact,
    writer: *std.Io.Writer,
) RenderError!void {
    writer.print("background {s}\n", .{@tagName(artifact.background_mode)}) catch
        return error.WriteFailed;
    for (artifact.coordinates, 0..) |coordinate, index| {
        writer.print(
            "  {d} {s} -> scalar {d}\n",
            .{ index, coordinate.id, coordinate.scalar_index },
        ) catch return error.WriteFailed;
    }
    if (artifact.background_mode == .component_slice) {
        emitText(
            "  unselected scalar backgrounds are exactly zero; every model " ++
                "scalar remains a fluctuation field\n",
            writer,
        ) catch return error.WriteFailed;
    }
}

/// Writes the scientific metadata a complete export must retain or accompany:
/// scheme and scale dependence, formula version, branch convention,
/// multiplicity, precision, and resummation policy.
pub fn writeProvenance(
    artifact: *const Artifact,
    writer: *std.Io.Writer,
) RenderError!void {
    writer.print(
        "loop_orders 0 through {d}\nresult_type {s}\n",
        .{ artifact.loop_order, @tagName(artifact.result_type) },
    ) catch return error.WriteFailed;
    if (artifact.scheme) |scheme| {
        writer.print("scheme {s}\n", .{@tagName(scheme)}) catch return error.WriteFailed;
    }
    if (artifact.scale != null) {
        writer.print(
            "renormalization_scale {s}\n",
            .{calculation.scale_name},
        ) catch return error.WriteFailed;
    }
    for (artifact.contributions) |contribution| {
        writer.print(
            "contribution {s} loop_order={d} result_type={s} sector={s}",
            .{
                @tagName(contribution.role),
                contribution.loop_order,
                @tagName(contribution.result_type),
                @tagName(contribution.provenance.sector),
            },
        ) catch return error.WriteFailed;
        if (contribution.provenance.formula_version) |formula| {
            writer.print(" formula={s}", .{formula.text()}) catch
                return error.WriteFailed;
        }
        if (contribution.provenance.branch) |branch| {
            writer.print(" branch={s}", .{branch.text()}) catch
                return error.WriteFailed;
        }
        writer.print(
            " multiplicity={d} precision={s} resummation={s}\n",
            .{
                contribution.provenance.multiplicity,
                @tagName(contribution.provenance.precision),
                @tagName(contribution.provenance.resummation),
            },
        ) catch return error.WriteFailed;
    }
}

/// Bounded summary suitable for a default rich representation.
///
/// Reports the calculation kind, background coordinates, loop orders,
/// contribution count, and dependency summary, and includes the complete
/// equation only when it fits the preview budget.
pub fn writeSummary(
    artifact: *const Artifact,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    // A tree-only artifact is exactly the classical scalar potential, and says
    // so; naming the general calculation there would be less specific, not more.
    emitText(if (artifact.loop_order == 0)
        "calculation classical_scalar_potential\n"
    else
        "calculation effective_potential\n", writer) catch return error.WriteFailed;
    writer.print(
        "loop_orders 0 through {d}\n",
        .{artifact.loop_order},
    ) catch return error.WriteFailed;
    writer.print(
        "contributions {d}\n",
        .{artifact.contributions.len},
    ) catch return error.WriteFailed;
    writer.print(
        "structural_absences {d}\n",
        .{artifact.absences.len},
    ) catch return error.WriteFailed;
    try writeBackground(artifact, writer);

    var background_dependent: usize = 0;
    for (artifact.contributions) |contribution| {
        if (contribution.depends_on_background) background_dependent += 1;
    }
    writer.print(
        "background_dependent_contributions {d}\n",
        .{background_dependent},
    ) catch return error.WriteFailed;

    const resolved = try withCoordinateNames(artifact, allocator, options);
    defer allocator.free(resolved.names);
    emitText("potential ", writer) catch return error.WriteFailed;
    try render.writeValuePreview(
        &artifact.graph,
        artifact.total,
        allocator,
        resolved.options,
        writer,
    );
    emitText("\n", writer) catch return error.WriteFailed;
}

/// The heading of a selected quantity.
///
/// The loop-order superscript names the selection, and the argument list makes
/// the scale dependence visible when the selection has one, as section 8
/// requires of an export's visible dependencies.
fn writeHeading(
    artifact: *const Artifact,
    role: ?Role,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    const order: ?u32 = if (role) |selected| selected.loopOrder() else null;
    const scale_dependent = if (role) |selected|
        if (artifact.contribution(selected)) |item| item.depends_on_scale else false
    else
        artifact.scale != null;

    switch (options.target) {
        .phaser => {
            if (order) |loop_order| {
                writer.print("V^({d})", .{loop_order}) catch return error.WriteFailed;
            } else if (artifact.loop_order == 0) {
                try emitText("V^(0)", writer);
            } else {
                writer.print("V^(<={d})", .{artifact.loop_order}) catch
                    return error.WriteFailed;
            }
            if (role) |selected| {
                try emitText("[", writer);
                try emitText(@tagName(selected), writer);
                try emitText("]", writer);
            }
        },
        .latex => {
            if (order) |loop_order| {
                writer.print("V^{{({d})}}", .{loop_order}) catch
                    return error.WriteFailed;
            } else if (artifact.loop_order == 0) {
                try emitText("V^{(0)}", writer);
            } else {
                writer.print("V^{{(\\leq {d})}}", .{artifact.loop_order}) catch
                    return error.WriteFailed;
            }
            if (role) |selected| {
                try emitText("_{", writer);
                try writeIdentifier(@tagName(selected), options, writer);
                try emitText("}", writer);
            }
        },
    }

    try emitText("(", writer);
    for (artifact.coordinates, 0..) |coordinate, index| {
        if (index != 0) try emitText(", ", writer);
        try writeIdentifier(coordinate.id, options, writer);
    }
    if (scale_dependent) {
        try emitText("; ", writer);
        try writeIdentifier(calculation.scale_name, options, writer);
    }
    try emitText(")", writer);
}

/// Emits an identifier through the same escaping the value renderer uses, so
/// heading text cannot inject target markup either.
fn writeIdentifier(
    name: []const u8,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    switch (options.target) {
        .phaser => try emitText(name, writer),
        .latex => {
            try emitText("\\mathrm{", writer);
            for (name) |byte| {
                switch (byte) {
                    '#', '$', '%', '&', '_', '{', '}' => {
                        try emitText(&.{ '\\', byte }, writer);
                    },
                    '~' => try emitText("\\textasciitilde{}", writer),
                    '^' => try emitText("\\textasciicircum{}", writer),
                    '\\' => try emitText("\\textbackslash{}", writer),
                    else => try emitText(&.{byte}, writer),
                }
            }
            try emitText("}", writer);
        },
    }
}

fn emitText(text: []const u8, writer: *std.Io.Writer) RenderError!void {
    writer.writeAll(text) catch return error.WriteFailed;
}
