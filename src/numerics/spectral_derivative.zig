//! Invariant background derivatives of the scalar one-loop spectral trace,
//! selected by Decision 0009.
//!
//! The operation differentiates the matrix function, never a sorted eigenvalue
//! label or an eigenvector sign: those are presentation choices of the
//! eigensolver and must not reach a scientific derivative. What it consumes is
//! the eigensystem the value already computed, plus ordinary real-symmetric
//! background derivative matrices of the mass-squared matrix.
//!
//! With `A = Q L Q^T`, `G_i = Q^T A_i Q`, and `H_ij = Q^T A_ij Q`,
//!
//!     dV/db_i        = sum_a Phi'(l_a) (G_i)_aa
//!     d2V/db_i db_j  = sum_a Phi'(l_a) (H_ij)_aa
//!                    + sum_{a,b} Phi'^[1](l_a, l_b) (G_i)_ab (G_j)_ba
//!
//! summed over both ordered pairs, with no extra factor of two off the
//! diagonal.
//!
//! All size-dependent storage comes from the caller and every loop runs in
//! fixed lexical order, so a result depends on the inputs alone.

const std = @import("std");
const complex_module = @import("complex.zig");
const eigensolver = @import("symmetric_eigensolver.zig");

pub const Scalar = complex_module.Scalar;
pub const Complex64 = complex_module.Complex64;

pub const Status = enum {
    ok,
    non_finite,
    /// A required derivative is mathematically singular: an uncancelled scalar
    /// zero-mode second derivative.
    singular_derivative,
};

pub const CallError = error{
    SizeOverflow,
    ShapeMismatch,
    WorkspaceTooSmall,
    WorkspaceMisaligned,
};

pub const WorkspaceLayout = struct {
    bytes: usize,
    alignment: usize,
};

/// Which derivative order one call evaluates.
///
/// The two orders are separate operations because a caller may want a gradient
/// without accepting the Hessian's stricter zero-mode domain.
pub const Order = enum { gradient, hessian };

pub const Request = struct {
    /// Dimension of the mass-squared matrix.
    dimension: u32,
    /// Number of background coordinates, in canonical order.
    coordinate_count: u32,
    order: Order,
    /// Ascending eigenvalues, as the value operation left them.
    eigenvalues: []const Scalar,
    /// Row-major matrix whose columns are the corresponding eigenvectors.
    eigenvectors: []const Scalar,
    /// The bound renormalization scale, already validated finite and positive.
    scale: Scalar,
};

/// Candidate outputs. Exactly one is present, matching `Request.order`.
///
/// A `singular_derivative` outcome is decided before any entry is written, and
/// so is a `non_finite` outcome caused by a supplied number. Arithmetic that
/// overflows from finite inputs does leave entries written; the caller's
/// point-atomic publication boundary is what keeps those unobservable.
pub const Outputs = struct {
    /// One component per background coordinate, in canonical order.
    gradient: []Complex64 = &.{},
    /// The full dense row-major Hessian. Every entry is evaluated from the
    /// formula; no triangle is copied onto the other.
    hessian: []Complex64 = &.{},
};

/// Position of `(row, column)` in the lexical upper-triangle order
/// `(0,0), (0,1), ..., (0,n-1), (1,1), ..., (n-1,n-1)`.
fn packedIndex(n: usize, row: usize, column: usize) usize {
    const first = @min(row, column);
    const second = @max(row, column);
    std.debug.assert(second < n);
    return first * n - first * (first -| 1) / 2 + (second - first);
}

/// Scalar offsets of the working regions, in one place so that the workspace
/// query and the evaluator cannot disagree about them.
const Regions = struct {
    /// One materialized dense derivative matrix.
    dense: usize = 0,
    /// That matrix multiplied by the eigenvector matrix.
    product: usize = 0,
    /// Rotated first-derivative matrices, as packed upper triangles.
    rotated: usize = 0,
    /// How many of them are stored at once.
    stored_matrices: usize = 0,
    /// One cluster representative per eigenvalue.
    representative: usize = 0,
    /// `Phi'` at each eigenvalue's representative, as complex components.
    coefficient: usize = 0,
    /// The divided-difference triangle, empty for a gradient.
    divided: usize = 0,
    /// Total working scalars.
    scalars: usize = 0,

    fn of(
        dimension: usize,
        coordinate_count: usize,
        order: Order,
    ) error{SizeOverflow}!Regions {
        const square = std.math.mul(usize, dimension, dimension) catch
            return error.SizeOverflow;
        const triangle = try eigensolver.packedEntryCount(dimension);
        // The gradient consumes one rotated matrix at a time; the Hessian pairs
        // every coordinate with every other and needs them all.
        const stored = switch (order) {
            .gradient => @min(coordinate_count, 1),
            .hessian => coordinate_count,
        };
        const rotated_scalars = std.math.mul(usize, stored, triangle) catch
            return error.SizeOverflow;
        const coefficient_scalars = std.math.mul(usize, dimension, 2) catch
            return error.SizeOverflow;
        const divided_scalars = switch (order) {
            .gradient => 0,
            .hessian => std.math.mul(usize, triangle, 2) catch
                return error.SizeOverflow,
        };

        var regions = Regions{ .stored_matrices = stored };
        var offset: usize = 0;
        regions.dense = place(&offset, square);
        regions.product = place(&offset, square);
        regions.rotated = place(&offset, rotated_scalars);
        regions.representative = place(&offset, dimension);
        regions.coefficient = place(&offset, coefficient_scalars);
        regions.divided = place(&offset, divided_scalars);
        regions.scalars = offset;
        return regions;
    }

    fn place(offset: *usize, count: usize) usize {
        const start = offset.*;
        offset.* += count;
        return start;
    }
};

/// Exact caller-workspace requirement for one operation.
pub fn workspaceLayout(
    dimension: u32,
    coordinate_count: u32,
    order: Order,
) error{SizeOverflow}!WorkspaceLayout {
    const regions = try Regions.of(dimension, coordinate_count, order);
    const bytes = std.math.mul(usize, regions.scalars, @sizeOf(Scalar)) catch
        return error.SizeOverflow;
    return .{ .bytes = bytes, .alignment = @alignOf(Scalar) };
}

/// Evaluates one derivative order without allocating.
///
/// `matrices` supplies the background derivative matrices as packed upper
/// triangles, addressed by index rather than gathered into one buffer because
/// the caller's matrices live in separate temporaries:
///
///     matrices.first(i)  for i in [0, coordinate_count)
///     matrices.second(k) for k over the coordinate-pair upper triangle
///
/// Shape and workspace failures are call-level errors detected before any
/// output entry is written.
pub fn evaluate(
    request: Request,
    matrices: anytype,
    workspace: []u8,
    outputs: Outputs,
) CallError!Status {
    const n: usize = request.dimension;
    const coordinates: usize = request.coordinate_count;
    const triangle = try eigensolver.packedEntryCount(n);
    const pairs = try eigensolver.packedEntryCount(coordinates);
    const square = std.math.mul(usize, n, n) catch return error.SizeOverflow;
    const regions = try Regions.of(n, coordinates, request.order);
    const layout = try workspaceLayout(
        request.dimension,
        request.coordinate_count,
        request.order,
    );

    if (request.eigenvalues.len != n) return error.ShapeMismatch;
    if (request.eigenvectors.len != square) return error.ShapeMismatch;
    switch (request.order) {
        .gradient => {
            if (outputs.gradient.len != coordinates) return error.ShapeMismatch;
            if (outputs.hessian.len != 0) return error.ShapeMismatch;
        },
        .hessian => {
            const entries = std.math.mul(usize, coordinates, coordinates) catch
                return error.SizeOverflow;
            if (outputs.hessian.len != entries) return error.ShapeMismatch;
            if (outputs.gradient.len != 0) return error.ShapeMismatch;
        },
    }
    if (workspace.len < layout.bytes) return error.WorkspaceTooSmall;
    if (layout.bytes != 0 and
        @intFromPtr(workspace.ptr) % layout.alignment != 0)
    {
        return error.WorkspaceMisaligned;
    }
    for (0..coordinates) |index| {
        if (matrices.first(index).len != triangle) return error.ShapeMismatch;
    }
    if (request.order == .hessian) {
        for (0..pairs) |index| {
            if (matrices.second(index).len != triangle) return error.ShapeMismatch;
        }
    }

    // Binding validated the scale before any point executed, so an invalid one
    // here would be an internal inconsistency rather than a point outcome.
    std.debug.assert(std.math.isFinite(request.scale) and request.scale > 0);

    // Every supplied number is examined before anything is computed, so a
    // non-finite input is reported without leaving candidate entries behind.
    if (!allFinite(request.eigenvalues)) return .non_finite;
    if (!allFinite(request.eigenvectors)) return .non_finite;
    for (0..coordinates) |index| {
        if (!allFinite(matrices.first(index))) return .non_finite;
    }
    if (request.order == .hessian) {
        for (0..pairs) |index| {
            if (!allFinite(matrices.second(index))) return .non_finite;
        }
    }

    const aligned: []align(@alignOf(Scalar)) u8 = @alignCast(workspace[0..layout.bytes]);
    const storage = std.mem.bytesAsSlice(Scalar, aligned);
    const working = Working{
        .request = request,
        .triangle = triangle,
        .dense = storage[regions.dense..][0..square],
        .product = storage[regions.product..][0..square],
        .rotated = storage[regions.rotated..][0..(regions.stored_matrices * triangle)],
        .representative = storage[regions.representative..][0..n],
        .coefficient = complexRegion(storage, regions.coefficient, n),
        .divided = complexRegion(storage, regions.divided, switch (request.order) {
            .gradient => 0,
            .hessian => triangle,
        }),
    };

    buildRepresentatives(request.eigenvalues, working.representative);
    for (working.coefficient, working.representative) |*entry, representative| {
        entry.* = firstDerivative(representative, request.scale);
    }

    return switch (request.order) {
        .gradient => evaluateGradient(working, matrices, outputs.gradient),
        .hessian => evaluateHessian(working, matrices, outputs.hessian),
    };
}

fn complexRegion(storage: []Scalar, offset: usize, count: usize) []Complex64 {
    const components = storage[offset..][0..(count * 2)];
    return std.mem.bytesAsSlice(Complex64, std.mem.sliceAsBytes(components));
}

fn allFinite(values: []const Scalar) bool {
    for (values) |entry| {
        if (!std.math.isFinite(entry)) return false;
    }
    return true;
}

/// The working state one order needs, so the evaluators name their regions
/// rather than re-slicing the workspace.
const Working = struct {
    request: Request,
    /// Entries of one packed matrix triangle.
    triangle: usize,
    dense: []Scalar,
    product: []Scalar,
    rotated: []Scalar,
    representative: []Scalar,
    coefficient: []Complex64,
    divided: []Complex64,

    fn dimension(self: Working) usize {
        return self.request.dimension;
    }

    fn triangleAt(self: Working, index: usize) []Scalar {
        return self.rotated[index * self.triangle ..][0..self.triangle];
    }
};

fn evaluateGradient(
    working: Working,
    matrices: anytype,
    out: []Complex64,
) Status {
    const n = working.dimension();
    for (out, 0..) |*component, coordinate| {
        const rotated = working.triangleAt(0);
        formProduct(n, matrices.first(coordinate), working);
        reduceTriangle(n, working, rotated);

        var total = Complex64.zero;
        for (working.coefficient, 0..) |coefficient, index| {
            // The exact zero-mode limit Phi'(0) = 0 is already in the
            // coefficient, so no logarithm of zero was ever formed.
            total = total.add(coefficient.scale(rotated[packedIndex(n, index, index)]));
        }
        component.* = total;
    }
    return .ok;
}

fn evaluateHessian(
    working: Working,
    matrices: anytype,
    out: []Complex64,
) Status {
    const n = working.dimension();
    const coordinates: usize = working.request.coordinate_count;
    const eigenvalues = working.request.eigenvalues;

    for (0..coordinates) |coordinate| {
        formProduct(n, matrices.first(coordinate), working);
        reduceTriangle(n, working, working.triangleAt(coordinate));
    }

    // Decision 0009's exact projected zero-block criterion, applied before any
    // coefficient at an exact zero is formed. A block that is exactly zero
    // cancels the divergence termwise; anything else leaves a positive sum of
    // squares multiplying it, and no tolerance is allowed to decide otherwise.
    var has_zero_mode = false;
    for (eigenvalues) |eigenvalue| {
        if (eigenvalue == 0) has_zero_mode = true;
    }
    if (has_zero_mode) {
        for (0..coordinates) |coordinate| {
            const rotated = working.triangleAt(coordinate);
            for (0..n) |row| {
                if (eigenvalues[row] != 0) continue;
                for (row..n) |column| {
                    if (eigenvalues[column] != 0) continue;
                    if (rotated[packedIndex(n, row, column)] != 0) {
                        return .singular_derivative;
                    }
                }
            }
        }
    }

    // A zero cluster contains only exact zeros, so a zero representative marks
    // exactly the pairs the criterion above has already settled.
    for (0..n) |row| {
        for (row..n) |column| {
            const left = working.representative[row];
            const right = working.representative[column];
            working.divided[packedIndex(n, row, column)] =
                if (left == 0 and right == 0)
                    Complex64.zero
                else
                    dividedDifference(left, right, working.request.scale);
        }
    }

    for (0..coordinates) |first| {
        for (0..coordinates) |second| {
            // Second derivatives are stored once per unordered coordinate pair,
            // so `(i,j)` and `(j,i)` read the same operand.
            formProduct(
                n,
                matrices.second(packedIndex(coordinates, first, second)),
                working,
            );

            var total = Complex64.zero;
            for (working.coefficient, 0..) |coefficient, index| {
                var diagonal: Scalar = 0;
                for (0..n) |term| {
                    diagonal += working.request.eigenvectors[term * n + index] *
                        working.product[term * n + index];
                }
                total = total.add(coefficient.scale(diagonal));
            }

            const left_matrix = working.triangleAt(first);
            const right_matrix = working.triangleAt(second);
            for (0..n) |row| {
                for (0..n) |column| {
                    if (eigenvalues[row] == 0 and eigenvalues[column] == 0) continue;
                    const entry = packedIndex(n, row, column);
                    // `G` is a congruence of a symmetric matrix by an orthogonal
                    // one, so its mirrored entries denote one value rather than
                    // two independently rounded ones. Real multiplication
                    // commutes exactly, so exchanging the two coordinates leaves
                    // this sum bitwise unchanged.
                    total = total.add(working.divided[entry].scale(
                        left_matrix[entry] * right_matrix[entry],
                    ));
                }
            }
            out[first * coordinates + second] = total;
        }
    }
    return .ok;
}

/// Materializes a packed triangle densely and forms `A Q` into the product
/// region.
fn formProduct(n: usize, packed_upper: []const Scalar, working: Working) void {
    var entry: usize = 0;
    for (0..n) |row| {
        for (row..n) |column| {
            const value = packed_upper[entry];
            entry += 1;
            working.dense[row * n + column] = value;
            working.dense[column * n + row] = value;
        }
    }

    for (0..n) |row| {
        for (0..n) |column| {
            var total: Scalar = 0;
            for (0..n) |term| {
                total += working.dense[row * n + term] *
                    working.request.eigenvectors[term * n + column];
            }
            working.product[row * n + column] = total;
        }
    }
}

/// Reduces the current product to the packed upper triangle of `Q^T A Q`.
fn reduceTriangle(n: usize, working: Working, out: []Scalar) void {
    for (0..n) |row| {
        for (row..n) |column| {
            var total: Scalar = 0;
            for (0..n) |term| {
                total += working.request.eigenvectors[term * n + row] *
                    working.product[term * n + column];
            }
            out[packedIndex(n, row, column)] = total;
        }
    }
}

/// Groups the ascending spectrum into deterministic same-sign clusters and
/// writes each member's representative.
///
/// Clustering is a numerical stability classification. It never changes the
/// sign or zero status of an eigenvalue: exact zeros form their own cluster and
/// a positive and a negative eigenvalue are never grouped together, so a
/// physical negative mode cannot be clipped by it.
fn buildRepresentatives(eigenvalues: []const Scalar, out: []Scalar) void {
    const n = eigenvalues.len;
    var norm: Scalar = 0;
    for (eigenvalues) |eigenvalue| norm += eigenvalue * eigenvalue;
    const tolerance = 8.0 * @as(Scalar, @floatFromInt(n)) *
        std.math.floatEps(Scalar) * @sqrt(norm);

    var start: usize = 0;
    while (start < n) {
        var end = start + 1;
        while (end < n and continuesCluster(eigenvalues, end, tolerance)) : (end += 1) {}

        // A fixed-order running mean. Same-sign membership keeps the
        // subtraction scale-safe, and the update avoids the overflow a direct
        // sum of large eigenvalues could reach.
        var mean = eigenvalues[start];
        var member = start + 1;
        while (member < end) : (member += 1) {
            const position: Scalar = @floatFromInt(member - start + 1);
            mean += (eigenvalues[member] - mean) / position;
        }
        for (start..end) |index| out[index] = mean;
        start = end;
    }
}

fn continuesCluster(eigenvalues: []const Scalar, index: usize, tolerance: Scalar) bool {
    const previous = eigenvalues[index - 1];
    const current = eigenvalues[index];
    // Zero joins only zero, so no tolerance can reclassify a zero mode.
    if (previous == 0 or current == 0) return previous == 0 and current == 0;
    if ((previous < 0) != (current < 0)) return false;
    return current - previous <= tolerance;
}

/// `Phi'(x) = x [Log(x / mu^2) - 1] / (32 pi^2)` on the branch the value uses,
/// with the continuous limit `Phi'(0) = 0`.
pub fn firstDerivative(eigenvalue: Scalar, scale: Scalar) Complex64 {
    if (eigenvalue == 0) return Complex64.zero;
    const logarithm = @log(@abs(eigenvalue) / (scale * scale));
    return .{
        .re = eigenvalue * (logarithm - 1.0) / (32.0 * std.math.pi * std.math.pi),
        .im = if (eigenvalue < 0) eigenvalue / (32.0 * std.math.pi) else 0,
    };
}

/// `Phi''(x) = Log(x / mu^2) / (32 pi^2)`, which diverges at zero and is
/// therefore only ever reached with a nonzero argument.
pub fn secondDerivative(eigenvalue: Scalar, scale: Scalar) Complex64 {
    std.debug.assert(eigenvalue != 0);
    const logarithm = @log(@abs(eigenvalue) / (scale * scale));
    return .{
        .re = logarithm / (32.0 * std.math.pi * std.math.pi),
        .im = if (eigenvalue < 0) 1.0 / (32.0 * std.math.pi) else 0,
    };
}

/// Highest `|r|` at which the close-pair series replaces the direct quotient.
const close_pair_ratio = 1.0 / 16.0;
/// Terms of the fixed series, which therefore ends at `r^16`.
const close_pair_terms = 8;

/// The first divided difference `Phi'^[1](x, y)` of Decision 0009.
///
/// A same-sign nonzero pair whose relative separation is small takes the series
/// form, which never subtracts two nearby `Phi'` values. Everything else uses
/// the direct quotient in fixed operand order. Either way the result is
/// unchanged, bit for bit, when the two endpoints are exchanged.
pub fn dividedDifference(left: Scalar, right: Scalar, scale: Scalar) Complex64 {
    if (left == right) return secondDerivative(left, scale);

    if (left != 0 and right != 0 and (left < 0) == (right < 0)) {
        const middle = (left + right) / 2.0;
        const half_difference = (left - right) / 2.0;
        const ratio = half_difference / middle;
        if (@abs(ratio) <= close_pair_ratio) {
            const squared = ratio * ratio;
            var term = squared;
            var series: Scalar = 0;
            for (1..close_pair_terms + 1) |index| {
                const even: Scalar = @floatFromInt(2 * index);
                series += term / (even * (even + 1.0));
                term *= squared;
            }
            const logarithm = @log(@abs(middle) / (scale * scale));
            return .{
                .re = (logarithm - series) / (32.0 * std.math.pi * std.math.pi),
                // `< 0` and `<= 0` are equivalent here: this branch is only
                // reached when `left` and `right` are both nonzero and same
                // sign, so their average `middle` cannot be exactly zero
                // either, the same way `scalarOneLoopTerm` in
                // kernel/interpret.zig excludes zero upstream of its own
                // otherwise-identical branch.
                .im = if (middle < 0) 1.0 / (32.0 * std.math.pi) else 0,
            };
        }
    }

    return firstDerivative(left, scale)
        .subtract(firstDerivative(right, scale))
        .divide(left - right);
}

// -- tests -----------------------------------------------------------------

/// Derivative matrices held as one contiguous array of packed triangles, which
/// is what a test supplies by hand.
const FlatMatrices = struct {
    triangle: usize,
    first_entries: []const Scalar,
    second_entries: []const Scalar = &.{},

    fn first(self: FlatMatrices, index: usize) []const Scalar {
        return self.first_entries[index * self.triangle ..][0..self.triangle];
    }

    fn second(self: FlatMatrices, index: usize) []const Scalar {
        return self.second_entries[index * self.triangle ..][0..self.triangle];
    }
};

fn run(
    request: Request,
    matrices: FlatMatrices,
    outputs: Outputs,
) !Status {
    const layout = try workspaceLayout(
        request.dimension,
        request.coordinate_count,
        request.order,
    );
    const workspace = try std.testing.allocator.alignedAlloc(
        u8,
        .of(Scalar),
        layout.bytes,
    );
    defer std.testing.allocator.free(workspace);
    return evaluate(request, matrices, workspace, outputs);
}

test "the close-pair series agrees with the direct quotient where both apply" {
    // Just outside, exactly at, and well inside the series boundary, so the two
    // branches meet on one value rather than each being checked in isolation.
    const scale: Scalar = 1.25;
    const middle: Scalar = 3.0;
    for ([_]Scalar{ 0.5, 0.0625, 0.001 }) |ratio| {
        const left = middle * (1.0 + ratio);
        const right = middle * (1.0 - ratio);
        const series = dividedDifference(left, right, scale);
        const direct = firstDerivative(left, scale)
            .subtract(firstDerivative(right, scale))
            .divide(left - right);
        try std.testing.expectApproxEqRel(direct.re, series.re, 1e-12);
        try std.testing.expectEqual(direct.im, series.im);
    }
}

test "a divided difference is bitwise symmetric in its endpoints" {
    const scale: Scalar = 0.75;
    const pairs = [_][2]Scalar{
        // Series branch, direct same-sign branch, opposite signs, zero endpoint.
        .{ 4.0, 4.0 * (1.0 + 0x1p-8) },
        .{ 9.0, 1.0 },
        .{ -3.0, 5.0 },
        .{ 0.0, 2.0 },
    };
    for (pairs) |pair| {
        try std.testing.expectEqual(
            dividedDifference(pair[0], pair[1], scale),
            dividedDifference(pair[1], pair[0], scale),
        );
    }
}

test "the equal-endpoint limit is the second derivative" {
    const scale: Scalar = 2.0;
    try std.testing.expectEqual(
        secondDerivative(-7.0, scale),
        dividedDifference(-7.0, -7.0, scale),
    );
    // The negative branch keeps the principal-branch imaginary component rather
    // than reporting the derivative of an absolute value.
    try std.testing.expectEqual(
        @as(Scalar, 1.0 / (32.0 * std.math.pi)),
        secondDerivative(-7.0, scale).im,
    );
    try std.testing.expectEqual(@as(Scalar, 0), secondDerivative(7.0, scale).im);
}

test "clustering separates zero and opposite signs whatever the tolerance" {
    var representative: [4]Scalar = undefined;
    // Entries adjacent at the working precision whose signs and zeros differ.
    // Nothing may be merged across those boundaries.
    const eigenvalues = [_]Scalar{ -0x1p-1060, 0, 0, 0x1p-1060 };
    buildRepresentatives(&eigenvalues, &representative);
    try std.testing.expectEqual(eigenvalues[0], representative[0]);
    try std.testing.expectEqual(@as(Scalar, 0), representative[1]);
    try std.testing.expectEqual(@as(Scalar, 0), representative[2]);
    try std.testing.expectEqual(eigenvalues[3], representative[3]);
}

test "a nonzero degenerate block shares one representative" {
    var representative: [3]Scalar = undefined;
    const nearby = 2.0 + 0x1p-52;
    buildRepresentatives(&.{ 2.0, nearby, 9.0 }, &representative);
    try std.testing.expectEqual(representative[0], representative[1]);
    try std.testing.expect(representative[0] != representative[2]);
    // The representative is the block's running mean, so it lies between its
    // members rather than being one of them by position.
    try std.testing.expect(representative[0] >= 2.0);
    try std.testing.expect(representative[0] <= nearby);
}

test "a one-by-one gradient reproduces the scalar chain rule" {
    // A(b) = b^2 at b = 3, so dA/db = 6 and dV/db = Phi'(9) * 6.
    const scale: Scalar = 1.5;
    var out: [1]Complex64 = undefined;
    const status = try run(.{
        .dimension = 1,
        .coordinate_count = 1,
        .order = .gradient,
        .eigenvalues = &.{9},
        .eigenvectors = &.{1},
        .scale = scale,
    }, .{ .triangle = 1, .first_entries = &.{6} }, .{ .gradient = &out });
    try std.testing.expectEqual(Status.ok, status);
    try std.testing.expectEqual(firstDerivative(9, scale).scale(6), out[0]);
}

test "an exact zero mode gives a finite gradient and a skipped Hessian block" {
    // A(b) = b^2 at b = 0: the spectrum is exactly zero, the first-derivative
    // matrix vanishes, and the second-derivative matrix is two.
    const scale: Scalar = 1.0;
    var gradient_out: [1]Complex64 = undefined;
    try std.testing.expectEqual(Status.ok, try run(.{
        .dimension = 1,
        .coordinate_count = 1,
        .order = .gradient,
        .eigenvalues = &.{0},
        .eigenvectors = &.{1},
        .scale = scale,
    }, .{ .triangle = 1, .first_entries = &.{0} }, .{ .gradient = &gradient_out }));
    try std.testing.expectEqual(Complex64.zero, gradient_out[0]);

    var hessian_out: [1]Complex64 = undefined;
    try std.testing.expectEqual(Status.ok, try run(.{
        .dimension = 1,
        .coordinate_count = 1,
        .order = .hessian,
        .eigenvalues = &.{0},
        .eigenvectors = &.{1},
        .scale = scale,
    }, .{
        .triangle = 1,
        .first_entries = &.{0},
        .second_entries = &.{2},
    }, .{ .hessian = &hessian_out }));
    // Phi'(0) is exactly zero, so the surviving term vanishes without any
    // infinity having been multiplied by a floating-point zero.
    try std.testing.expectEqual(Complex64.zero, hessian_out[0]);
}

test "an uncancelled zero mode is singular rather than infinite" {
    // A(b) = b at b = 0, whose projected zero block is one rather than zero.
    var out: [1]Complex64 = .{.{ .re = 7, .im = 7 }};
    try std.testing.expectEqual(Status.singular_derivative, try run(.{
        .dimension = 1,
        .coordinate_count = 1,
        .order = .hessian,
        .eigenvalues = &.{0},
        .eigenvectors = &.{1},
        .scale = 1,
    }, .{
        .triangle = 1,
        .first_entries = &.{1},
        .second_entries = &.{0},
    }, .{ .hessian = &out }));
    // The status is decided before any entry is written.
    try std.testing.expectEqual(Complex64{ .re = 7, .im = 7 }, out[0]);
}

test "a non-finite derivative matrix is reported before anything is written" {
    var out: [1]Complex64 = .{.{ .re = 5, .im = -5 }};
    try std.testing.expectEqual(Status.non_finite, try run(.{
        .dimension = 1,
        .coordinate_count = 1,
        .order = .gradient,
        .eigenvalues = &.{4},
        .eigenvectors = &.{1},
        .scale = 1,
    }, .{
        .triangle = 1,
        .first_entries = &.{std.math.inf(Scalar)},
    }, .{ .gradient = &out }));
    try std.testing.expectEqual(Complex64{ .re = 5, .im = -5 }, out[0]);
}

test "the dense Hessian is exactly symmetric" {
    // Two coordinates over a two-by-two spectrum, with distinct derivative
    // matrices so that symmetry is a property of the formula rather than of the
    // inputs coinciding.
    var out: [4]Complex64 = undefined;
    try std.testing.expectEqual(Status.ok, try run(.{
        .dimension = 2,
        .coordinate_count = 2,
        .order = .hessian,
        .eigenvalues = &.{ -1.5, 4.0 },
        .eigenvectors = &.{ 1, 0, 0, 1 },
        .scale = 1.25,
    }, .{
        .triangle = 3,
        .first_entries = &.{ 2, 3, -1, 5, -7, 0.5 },
        .second_entries = &.{ 1, 0, 2, -3, 4, 1, 0.25, -0.5, 6 },
    }, .{ .hessian = &out }));
    // Bitwise, not approximately: the two entries are computed independently
    // from the same formula and must agree exactly.
    try std.testing.expectEqual(out[1], out[2]);
}

/// Two background coordinates over a three-dimensional spectrum, with distinct
/// derivative matrices in the original basis.
const invariance_first = [_]Scalar{
    2, 3,  -1, 5,   7,  -4,
    1, -2, 6,  0.5, -3, 8,
};
const invariance_second = [_]Scalar{
    1,    0,    2, -3, 4,  1,
    0.25, -0.5, 6, 2,  -1, 3,
    -2,   1.5,  0, 4,  5,  -6,
};

fn runInvariance(
    eigenvalues: []const Scalar,
    eigenvectors: []const Scalar,
    matrices: FlatMatrices,
    gradient_out: []Complex64,
    hessian_out: []Complex64,
) !void {
    const shared = Request{
        .dimension = 3,
        .coordinate_count = 2,
        .order = .gradient,
        .eigenvalues = eigenvalues,
        .eigenvectors = eigenvectors,
        .scale = 1.5,
    };
    try std.testing.expectEqual(
        Status.ok,
        try run(shared, matrices, .{ .gradient = gradient_out }),
    );
    var second = shared;
    second.order = .hessian;
    try std.testing.expectEqual(
        Status.ok,
        try run(second, matrices, .{ .hessian = hessian_out }),
    );
}

test "flipping an eigenvector sign leaves both derivatives bitwise unchanged" {
    const eigenvalues = [_]Scalar{ 1, 4, 9 };
    const identity = [_]Scalar{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    // The eigensolver's sign convention is a presentation choice: each column is
    // an eigenvector whether or not it is negated.
    const flipped = [_]Scalar{ -1, 0, 0, 0, 1, 0, 0, 0, -1 };
    const matrices = FlatMatrices{
        .triangle = 6,
        .first_entries = &invariance_first,
        .second_entries = &invariance_second,
    };

    var gradient_a: [2]Complex64 = undefined;
    var hessian_a: [4]Complex64 = undefined;
    try runInvariance(&eigenvalues, &identity, matrices, &gradient_a, &hessian_a);

    var gradient_b: [2]Complex64 = undefined;
    var hessian_b: [4]Complex64 = undefined;
    try runInvariance(&eigenvalues, &flipped, matrices, &gradient_b, &hessian_b);

    // Each sign enters twice and cancels exactly, so this is bitwise rather
    // than merely close.
    try std.testing.expectEqualSlices(Complex64, &gradient_a, &gradient_b);
    try std.testing.expectEqualSlices(Complex64, &hessian_a, &hessian_b);
}

/// Rewrites a packed triangle in the basis obtained by exchanging two indices.
fn swapTriangle(source: []const Scalar, out: []Scalar, left: usize, right: usize) void {
    const n = 3;
    const map = struct {
        fn of(index: usize, a: usize, b: usize) usize {
            if (index == a) return b;
            if (index == b) return a;
            return index;
        }
    }.of;
    for (0..n) |row| {
        for (row..n) |column| {
            out[packedIndex(n, row, column)] = source[
                packedIndex(
                    n,
                    map(row, left, right),
                    map(column, left, right),
                )
            ];
        }
    }
}

test "relabelling the scalar basis leaves both derivatives unchanged" {
    const eigenvalues = [_]Scalar{ 1, 4, 9 };
    const identity = [_]Scalar{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const matrices = FlatMatrices{
        .triangle = 6,
        .first_entries = &invariance_first,
        .second_entries = &invariance_second,
    };
    var gradient_a: [2]Complex64 = undefined;
    var hessian_a: [4]Complex64 = undefined;
    try runInvariance(&eigenvalues, &identity, matrices, &gradient_a, &hessian_a);

    // Exchange the first and third scalar. Every derivative matrix is rewritten
    // in that basis, and the eigenvector columns follow, so the spectrum and its
    // ascending order are untouched.
    var permuted_first: [invariance_first.len]Scalar = undefined;
    for (0..2) |index| {
        swapTriangle(
            invariance_first[index * 6 ..][0..6],
            permuted_first[index * 6 ..][0..6],
            0,
            2,
        );
    }
    var permuted_second: [invariance_second.len]Scalar = undefined;
    for (0..3) |index| {
        swapTriangle(
            invariance_second[index * 6 ..][0..6],
            permuted_second[index * 6 ..][0..6],
            0,
            2,
        );
    }
    const permuted_vectors = [_]Scalar{ 0, 0, 1, 0, 1, 0, 1, 0, 0 };

    var gradient_b: [2]Complex64 = undefined;
    var hessian_b: [4]Complex64 = undefined;
    try runInvariance(
        &eigenvalues,
        &permuted_vectors,
        .{
            .triangle = 6,
            .first_entries = &permuted_first,
            .second_entries = &permuted_second,
        },
        &gradient_b,
        &hessian_b,
    );

    try std.testing.expectEqualSlices(Complex64, &gradient_a, &gradient_b);
    try std.testing.expectEqualSlices(Complex64, &hessian_a, &hessian_b);
}

test "rotating inside a degenerate eigenspace leaves both derivatives unchanged" {
    // A twofold degenerate block. Any orthonormal pair spanning it is as good an
    // eigenbasis as any other, so a method that differentiated the solver's
    // chosen vectors would depend on an arbitrary presentation choice.
    const eigenvalues = [_]Scalar{ 4, 4, 9 };
    const identity = [_]Scalar{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const turn = @sqrt(0.5);
    const rotated = [_]Scalar{ turn, turn, 0, -turn, turn, 0, 0, 0, 1 };
    const matrices = FlatMatrices{
        .triangle = 6,
        .first_entries = &invariance_first,
        .second_entries = &invariance_second,
    };

    var gradient_a: [2]Complex64 = undefined;
    var hessian_a: [4]Complex64 = undefined;
    try runInvariance(&eigenvalues, &identity, matrices, &gradient_a, &hessian_a);

    var gradient_b: [2]Complex64 = undefined;
    var hessian_b: [4]Complex64 = undefined;
    try runInvariance(&eigenvalues, &rotated, matrices, &gradient_b, &hessian_b);

    // Every coefficient is constant on the block, so the two bases give the
    // same sums. The rotation itself is inexact, so this is close rather than
    // bitwise.
    for (gradient_a, gradient_b) |left, right| {
        try std.testing.expectApproxEqRel(left.re, right.re, 1e-13);
        try std.testing.expectEqual(left.im, right.im);
    }
    for (hessian_a, hessian_b) |left, right| {
        try std.testing.expectApproxEqRel(left.re, right.re, 1e-13);
        try std.testing.expectEqual(left.im, right.im);
    }
}

test "the workspace query is exact and its regions do not overlap" {
    const layout = try workspaceLayout(3, 2, .hessian);
    const regions = try Regions.of(3, 2, .hessian);
    try std.testing.expectEqual(regions.scalars * @sizeOf(Scalar), layout.bytes);

    // Three by three: two dense matrices, two packed triangles of rotated first
    // derivatives, three representatives, three complex coefficients, and one
    // complex triangle of divided differences.
    try std.testing.expectEqual(
        @as(usize, 9 + 9 + 2 * 6 + 3 + 2 * 3 + 2 * 6),
        regions.scalars,
    );
    try std.testing.expect(regions.dense < regions.product);
    try std.testing.expect(regions.product < regions.rotated);
    try std.testing.expect(regions.rotated < regions.representative);
    try std.testing.expect(regions.representative < regions.coefficient);
    try std.testing.expect(regions.coefficient < regions.divided);

    // A gradient needs neither the divided differences nor one matrix per
    // coordinate.
    const smaller = try workspaceLayout(3, 2, .gradient);
    try std.testing.expect(smaller.bytes < layout.bytes);
}

test "a workspace smaller than the query is a call-level error" {
    var out: [1]Complex64 = undefined;
    const layout = try workspaceLayout(1, 1, .gradient);
    const workspace = try std.testing.allocator.alignedAlloc(
        u8,
        .of(Scalar),
        layout.bytes,
    );
    defer std.testing.allocator.free(workspace);

    try std.testing.expectError(error.WorkspaceTooSmall, evaluate(.{
        .dimension = 1,
        .coordinate_count = 1,
        .order = .gradient,
        .eigenvalues = &.{1},
        .eigenvectors = &.{1},
        .scale = 1,
    }, FlatMatrices{
        .triangle = 1,
        .first_entries = &.{1},
    }, workspace[0 .. layout.bytes - 1], .{ .gradient = &out }));
}
