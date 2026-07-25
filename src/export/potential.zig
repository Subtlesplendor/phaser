//! Symbolic export views for the classical-potential artifact.
//!
//! Follows `docs/architecture/SYMBOLIC_EXPORT.md`. Contribution selection
//! happens here, through the artifact's own metadata, and never inside a target
//! renderer: an exporter does not decide which loop orders or contribution
//! classes to include.

const std = @import("std");
const calculation = @import("../calculation/root.zig");
const value = @import("../value/root.zig");
const render = @import("render.zig");

pub const Target = render.Target;
pub const Options = render.Options;
pub const RenderError = render.RenderError;

const Artifact = calculation.Artifact;
const Role = calculation.Role;

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
    try writeHeading(artifact, null, options, writer);
    try emitText(" = ", writer);
    try render.writeValue(&artifact.graph, artifact.total, allocator, options, writer);
}

/// Writes one contribution, identified by its role and loop order.
pub fn writeContribution(
    artifact: *const Artifact,
    role: Role,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    const contribution = artifact.contribution(role) orelse {
        // A structurally absent class is reported as such, never omitted
        // silently and never confused with an unsupported one.
        try writeHeading(artifact, role, options, writer);
        try emitText(" = 0  [structurally absent: ", writer);
        const absence = artifact.absence(role).?;
        try emitText(@tagName(absence.reason), writer);
        try emitText("]", writer);
        return;
    };
    try writeHeading(artifact, role, options, writer);
    try emitText(" = ", writer);
    try render.writeValue(
        &artifact.graph,
        contribution.value,
        allocator,
        options,
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
        options,
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
    emitText("calculation classical_scalar_potential\n", writer) catch
        return error.WriteFailed;
    writer.print("loop_orders 0 through 0\n", .{}) catch return error.WriteFailed;
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

    emitText("potential ", writer) catch return error.WriteFailed;
    try render.writeValuePreview(
        &artifact.graph,
        artifact.total,
        allocator,
        options,
        writer,
    );
    emitText("\n", writer) catch return error.WriteFailed;
}

fn writeHeading(
    artifact: *const Artifact,
    role: ?Role,
    options: Options,
    writer: *std.Io.Writer,
) RenderError!void {
    switch (options.target) {
        .phaser => {
            try emitText("V^(0)", writer);
            if (role) |selected| {
                try emitText("[", writer);
                try emitText(@tagName(selected), writer);
                try emitText("]", writer);
            }
        },
        .latex => {
            try emitText("V^{(0)}", writer);
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
