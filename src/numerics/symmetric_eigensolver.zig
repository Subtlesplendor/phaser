//! Deterministic real-symmetric eigensolver selected by Decision 0008.
//!
//! The input is the authoritative upper triangle in lexical row order. All
//! size-dependent temporary storage comes from the caller. Outputs are
//! published only after convergence, finite checks, sorting, sign
//! normalization, and the required residual and orthogonality postconditions.

const std = @import("std");
const error_injection = @import("../testing/error_injection.zig");

pub const Scalar = f64;

pub const Status = enum {
    ok,
    non_finite,
    nonconvergent,
};

pub const CallError = error{
    SizeOverflow,
    ShapeMismatch,
    WorkspaceTooSmall,
    WorkspaceMisaligned,
    ForbiddenAliasing,
};

pub const WorkspaceLayout = struct {
    bytes: usize,
    alignment: usize,
};

pub const Outputs = struct {
    eigenvalues: []Scalar,
    /// Row-major matrix whose columns are eigenvectors. `null` omits public
    /// eigenvectors, but the solver still retains them for its residual check.
    eigenvectors: ?[]Scalar = null,
};

const convergence_factor = 8.0;
const postcondition_factor = 64.0;
const minimum_sweeps: usize = 12;
const sweeps_per_dimension: usize = 8;
const SolverError = error{Nonconvergent};
const convergence_tw = error_injection.module(
    enum { accept_convergence },
    SolverError,
);

/// Number of entries in the authoritative packed upper triangle.
pub fn packedEntryCount(n: usize) error{SizeOverflow}!usize {
    const successor = std.math.add(usize, n, 1) catch
        return error.SizeOverflow;
    // Divide the even factor first so a representable triangular count is not
    // rejected merely because the unreduced product would overflow.
    const left, const right = if (n % 2 == 0)
        .{ n / 2, successor }
    else
        .{ n, successor / 2 };
    return std.math.mul(usize, left, right) catch
        return error.SizeOverflow;
}

/// Exact caller-workspace requirement.
///
/// The layout contains the unmodified working-scale input, the reduced matrix,
/// the complete eigenvector matrix, and candidate eigenvalues. All regions are
/// `f64`-aligned and their checked arithmetic is completed before evaluation.
pub fn workspaceLayout(n: usize) error{SizeOverflow}!WorkspaceLayout {
    const matrix_entries = std.math.mul(usize, n, n) catch
        return error.SizeOverflow;
    const matrix_storage = std.math.mul(usize, matrix_entries, 3) catch
        return error.SizeOverflow;
    const scalar_count = std.math.add(usize, matrix_storage, n) catch
        return error.SizeOverflow;
    const bytes = std.math.mul(usize, scalar_count, @sizeOf(Scalar)) catch
        return error.SizeOverflow;

    // Prove the iteration bound is representable as part of the same structural
    // query. The solve path may then use ordinary bounded arithmetic.
    _ = std.math.mul(usize, n, sweeps_per_dimension) catch
        return error.SizeOverflow;

    return .{ .bytes = bytes, .alignment = @alignOf(Scalar) };
}

/// Diagonalizes one real-symmetric matrix without allocating.
///
/// Input, workspace, and output regions are pairwise disjoint. Shape,
/// workspace, and aliasing failures are call-level errors and touch no output.
/// A point-level failure returns a status and likewise leaves every output
/// unchanged.
pub fn solve(
    n: usize,
    packed_upper: []const Scalar,
    workspace: []u8,
    outputs: Outputs,
) CallError!Status {
    const packed_count = try packedEntryCount(n);
    const matrix_entries = std.math.mul(usize, n, n) catch
        return error.SizeOverflow;
    const layout = try workspaceLayout(n);

    if (packed_upper.len != packed_count) return error.ShapeMismatch;
    if (outputs.eigenvalues.len != n) return error.ShapeMismatch;
    if (outputs.eigenvectors) |vectors| {
        if (vectors.len != matrix_entries) return error.ShapeMismatch;
    }
    if (workspace.len < layout.bytes) return error.WorkspaceTooSmall;
    if (layout.bytes != 0 and
        @intFromPtr(workspace.ptr) % layout.alignment != 0)
    {
        return error.WorkspaceMisaligned;
    }
    try validateDisjoint(packed_upper, workspace, outputs);

    if (n == 0) return .ok;

    var maximum: Scalar = 0;
    var has_off_diagonal = false;
    var packed_index: usize = 0;
    for (0..n) |row| {
        for (row..n) |column| {
            const entry = packed_upper[packed_index];
            packed_index += 1;
            if (!std.math.isFinite(entry)) return .non_finite;
            maximum = @max(maximum, @abs(entry));
            if (row != column and entry != 0) has_off_diagonal = true;
        }
    }

    const aligned: []align(@alignOf(Scalar)) u8 =
        @alignCast(workspace[0..layout.bytes]);
    const storage = std.mem.bytesAsSlice(Scalar, aligned);
    const original = storage[0..matrix_entries];
    const working = storage[matrix_entries .. 2 * matrix_entries];
    const vectors = storage[2 * matrix_entries .. 3 * matrix_entries];
    const values = storage[3 * matrix_entries ..][0..n];

    // An exactly diagonal matrix needs no rotations. Keeping it unscaled also
    // preserves isolated representable entries across the complete f64 range;
    // a global scale could otherwise underflow a tiny diagonal entry next to a
    // very large one despite there being no arithmetic coupling between them.
    const rescale_exponent: i32 = if (has_off_diagonal)
        std.math.frexp(maximum).exponent
    else
        0;
    const input_scale_exponent = -rescale_exponent;

    @memset(original, 0);
    @memset(working, 0);
    packed_index = 0;
    for (0..n) |row| {
        for (row..n) |column| {
            const input = packed_upper[packed_index];
            packed_index += 1;
            const entry = std.math.ldexp(input, input_scale_exponent);
            // Never silently turn a nonzero matrix entry into zero while
            // establishing the working scale.
            if (input != 0 and entry == 0) return .nonconvergent;
            original[row * n + column] = entry;
            original[column * n + row] = entry;
            working[row * n + column] = entry;
            working[column * n + row] = entry;
        }
    }
    setIdentity(vectors, n);

    if (n == 2) {
        if (has_off_diagonal) {
            rotate(working, vectors, n, 0, 1);
        }
    } else if (n >= 3) {
        diagonalize(working, vectors, n) catch
            return .nonconvergent;
    }

    for (0..n) |index| values[index] = working[index * n + index];
    stableSort(values, vectors, n);
    normalizeSigns(vectors, n);

    if (!allFinite(values) or !allFinite(vectors)) return .non_finite;
    if (!postconditionsHold(original, values, vectors, n)) {
        return .nonconvergent;
    }

    if (rescale_exponent != 0) {
        for (values) |*value| {
            const scaled = value.*;
            value.* = std.math.ldexp(scaled, rescale_exponent);
            if (!std.math.isFinite(value.*)) return .non_finite;
            // A negative or positive eigenvalue is never clipped to signed zero
            // by an unreported rescaling underflow.
            if (scaled != 0 and value.* == 0) return .nonconvergent;
        }
    }

    @memcpy(outputs.eigenvalues, values);
    if (outputs.eigenvectors) |output_vectors| {
        @memcpy(output_vectors, vectors);
    }
    return .ok;
}

fn diagonalize(
    matrix: []Scalar,
    vectors: []Scalar,
    n: usize,
) SolverError!void {
    const sweep_limit = @max(minimum_sweeps, sweeps_per_dimension * n);
    var converged = false;
    for (0..sweep_limit) |_| {
        for (0..n - 1) |row| {
            for (row + 1..n) |column| {
                if (matrix[row * n + column] == 0) continue;
                rotate(matrix, vectors, n, row, column);
            }
        }
        if (convergenceReached(matrix, n)) {
            converged = true;
            break;
        }
    }
    if (!converged) return error.Nonconvergent;

    // Natural valid inputs rarely exhaust cyclic Jacobi at the bounded sizes
    // under test. This test-only checkpoint makes atomic nonconvergence
    // publication directly reachable without changing production behavior.
    try convergence_tw.check(.accept_convergence);
}

fn rotate(
    matrix: []Scalar,
    vectors: []Scalar,
    n: usize,
    p: usize,
    q: usize,
) void {
    const pp = p * n + p;
    const pq = p * n + q;
    const qq = q * n + q;
    const off_diagonal = matrix[pq];
    if (off_diagonal == 0) return;

    const delta = (matrix[qq] - matrix[pp]) / 2.0;
    const tangent = if (delta == 0)
        1.0
    else
        off_diagonal /
            (delta + std.math.copysign(
                std.math.hypot(delta, off_diagonal),
                delta,
            ));
    const cosine = 1.0 / @sqrt(1.0 + tangent * tangent);
    const sine = tangent * cosine;

    matrix[pp] = matrix[pp] - tangent * off_diagonal;
    matrix[qq] = matrix[qq] + tangent * off_diagonal;
    matrix[pq] = 0;
    matrix[q * n + p] = 0;

    for (0..n) |index| {
        if (index == p or index == q) continue;
        const ip = index * n + p;
        const iq = index * n + q;
        const old_p = matrix[ip];
        const old_q = matrix[iq];
        const new_p = cosine * old_p - sine * old_q;
        const new_q = sine * old_p + cosine * old_q;
        matrix[ip] = new_p;
        matrix[p * n + index] = new_p;
        matrix[iq] = new_q;
        matrix[q * n + index] = new_q;
    }

    // Q <- Q J. Columns, not rows, carry eigenvectors.
    for (0..n) |row| {
        const rp = row * n + p;
        const rq = row * n + q;
        const old_p = vectors[rp];
        const old_q = vectors[rq];
        vectors[rp] = cosine * old_p - sine * old_q;
        vectors[rq] = sine * old_p + cosine * old_q;
    }
}

fn convergenceReached(matrix: []const Scalar, n: usize) bool {
    var full: ScaledSumSquares = .{};
    var off_diagonal: ScaledSumSquares = .{};
    for (0..n) |row| {
        for (0..n) |column| {
            const entry = matrix[row * n + column];
            full.add(entry);
            if (row != column) off_diagonal.add(entry);
        }
    }
    const threshold = convergence_factor *
        @as(Scalar, @floatFromInt(n)) *
        std.math.floatEps(Scalar) *
        full.norm();
    return off_diagonal.norm() <= threshold;
}

fn stableSort(values: []Scalar, vectors: []Scalar, n: usize) void {
    for (1..n) |unsorted| {
        var position = unsorted;
        while (position > 0 and values[position - 1] > values[position]) {
            std.mem.swap(Scalar, &values[position - 1], &values[position]);
            for (0..n) |row| {
                std.mem.swap(
                    Scalar,
                    &vectors[row * n + position - 1],
                    &vectors[row * n + position],
                );
            }
            position -= 1;
        }
    }
}

fn normalizeSigns(vectors: []Scalar, n: usize) void {
    for (0..n) |column| {
        var pivot_row: usize = 0;
        var pivot_magnitude: Scalar = @abs(vectors[column]);
        for (1..n) |row| {
            const magnitude = @abs(vectors[row * n + column]);
            if (magnitude > pivot_magnitude) {
                pivot_magnitude = magnitude;
                pivot_row = row;
            }
        }
        if (vectors[pivot_row * n + column] < 0) {
            for (0..n) |row| {
                vectors[row * n + column] = -vectors[row * n + column];
            }
        }
    }
}

fn postconditionsHold(
    original: []const Scalar,
    values: []const Scalar,
    vectors: []const Scalar,
    n: usize,
) bool {
    var input_norm: ScaledSumSquares = .{};
    for (original) |entry| input_norm.add(entry);

    var residual: ScaledSumSquares = .{};
    for (0..n) |row| {
        for (0..n) |column| {
            var product: Scalar = 0;
            for (0..n) |inner| {
                product += original[row * n + inner] *
                    vectors[inner * n + column];
            }
            residual.add(product - vectors[row * n + column] * values[column]);
        }
    }

    var orthogonality: ScaledSumSquares = .{};
    for (0..n) |left| {
        for (0..n) |right| {
            var product: Scalar = 0;
            for (0..n) |row| {
                product += vectors[row * n + left] *
                    vectors[row * n + right];
            }
            orthogonality.add(
                product - @as(Scalar, @floatFromInt(@intFromBool(left == right))),
            );
        }
    }

    const dimension = @as(Scalar, @floatFromInt(n));
    const residual_limit = postcondition_factor *
        dimension *
        std.math.floatEps(Scalar) *
        input_norm.norm();
    const orthogonality_limit = postcondition_factor *
        dimension *
        std.math.floatEps(Scalar);
    return residual.norm() <= residual_limit and
        orthogonality.norm() <= orthogonality_limit;
}

const ScaledSumSquares = struct {
    scale: Scalar = 0,
    sum_squares: Scalar = 1,

    fn add(self: *ScaledSumSquares, value: Scalar) void {
        const magnitude = @abs(value);
        if (magnitude == 0) return;
        if (self.scale < magnitude) {
            const ratio = self.scale / magnitude;
            self.sum_squares = 1.0 + self.sum_squares * ratio * ratio;
            self.scale = magnitude;
        } else {
            const ratio = magnitude / self.scale;
            self.sum_squares += ratio * ratio;
        }
    }

    fn norm(self: ScaledSumSquares) Scalar {
        if (self.scale == 0) return 0;
        return self.scale * @sqrt(self.sum_squares);
    }
};

fn setIdentity(matrix: []Scalar, n: usize) void {
    @memset(matrix, 0);
    for (0..n) |index| matrix[index * n + index] = 1;
}

fn allFinite(values: []const Scalar) bool {
    for (values) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
}

fn validateDisjoint(
    packed_upper: []const Scalar,
    workspace: []u8,
    outputs: Outputs,
) error{ForbiddenAliasing}!void {
    const vector_bytes: []const u8 = if (outputs.eigenvectors) |vectors|
        std.mem.sliceAsBytes(vectors)
    else
        &.{};
    const regions = [_][]const u8{
        std.mem.sliceAsBytes(packed_upper),
        workspace,
        std.mem.sliceAsBytes(outputs.eigenvalues),
        vector_bytes,
    };
    for (regions, 0..) |left, index| {
        for (regions[index + 1 ..]) |right| {
            if (overlaps(left, right)) return error.ForbiddenAliasing;
        }
    }
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    return if (left_start <= right_start)
        right_start - left_start < left.len
    else
        left_start - right_start < right.len;
}

// -- tests -----------------------------------------------------------------

test "overlaps detects touching and disjoint byte ranges by address" {
    var buffer: [16]u8 = undefined;

    // Adjacent, sharing no byte: touching exactly at the boundary is what
    // distinguishes this from a genuine one-byte overlap below, in both
    // relative orders.
    try std.testing.expect(!overlaps(buffer[0..8], buffer[8..16]));
    try std.testing.expect(!overlaps(buffer[8..16], buffer[0..8]));

    // Overlapping by exactly one byte, again in both relative orders.
    try std.testing.expect(overlaps(buffer[0..8], buffer[7..15]));
    try std.testing.expect(overlaps(buffer[7..15], buffer[0..8]));

    // The same range against itself: the `left_start <= right_start` branch
    // taken when the two starts are equal, not merely close.
    try std.testing.expect(overlaps(buffer[0..8], buffer[0..8]));

    // An empty range shares no byte with anything, regardless of address.
    try std.testing.expect(!overlaps(buffer[0..0], buffer[0..8]));
    try std.testing.expect(!overlaps(buffer[0..8], buffer[0..0]));
}

fn expectSpectrum(
    n: usize,
    packed_upper: []const Scalar,
    expected: []const Scalar,
) !void {
    const layout = try workspaceLayout(n);
    const workspace_scalars = try std.testing.allocator.alloc(
        Scalar,
        layout.bytes / @sizeOf(Scalar),
    );
    defer std.testing.allocator.free(workspace_scalars);
    const actual = try std.testing.allocator.alloc(Scalar, n);
    defer std.testing.allocator.free(actual);
    const vectors = try std.testing.allocator.alloc(Scalar, n * n);
    defer std.testing.allocator.free(vectors);

    try std.testing.expectEqual(
        Status.ok,
        try solve(
            n,
            packed_upper,
            std.mem.sliceAsBytes(workspace_scalars),
            .{ .eigenvalues = actual, .eigenvectors = vectors },
        ),
    );
    try std.testing.expectEqual(expected.len, actual.len);

    var scale: Scalar = 0;
    for (packed_upper) |entry| scale = @max(scale, @abs(entry));
    const tolerance = postcondition_factor *
        @as(Scalar, @floatFromInt(@max(n, 1))) *
        std.math.floatEps(Scalar) *
        scale;
    for (expected, actual) |wanted, found| {
        try std.testing.expectApproxEqAbs(wanted, found, tolerance);
    }

    for (0..n) |column| {
        var pivot: usize = 0;
        for (1..n) |row| {
            if (@abs(vectors[row * n + column]) >
                @abs(vectors[pivot * n + column]))
            {
                pivot = row;
            }
        }
        try std.testing.expect(vectors[pivot * n + column] >= 0);
    }
}

test "empty, scalar, zero, and stable two by two paths" {
    try expectSpectrum(0, &.{}, &.{});
    try expectSpectrum(1, &.{-7}, &.{-7});
    try expectSpectrum(2, &.{ 3, 0, -2 }, &.{ -2, 3 });
    try expectSpectrum(2, &.{ 1, 1, 1 }, &.{ 0, 2 });
    try expectSpectrum(3, &.{ 0, 0, 0, 0, 0, 0 }, &.{ 0, 0, 0 });

    const small = 0x1p-40;
    const cosine = 3.0 / 5.0;
    const sine = 4.0 / 5.0;
    try expectSpectrum(
        2,
        &.{
            cosine * cosine * small + sine * sine,
            cosine * sine * (small - 1),
            sine * sine * small + cosine * cosine,
        },
        &.{ small, 1 },
    );
}

test "exact-spectrum catalog covers dense, repeated, zero, and indefinite matrices" {
    try expectSpectrum(
        3,
        &.{ 53, 26, -4, 44, -22, 29 },
        &.{ 9, 36, 81 },
    );
    try expectSpectrum(
        3,
        &.{ 30, 12, -6, 30, -6, 21 },
        &.{ 18, 18, 45 },
    );
    try expectSpectrum(
        3,
        &.{ 2, 20, -10, 2, -10, -13 },
        &.{ -18, -18, 27 },
    );
    try expectSpectrum(
        3,
        &.{ 1, 1, 0, 1, 0, 4 },
        &.{ 0, 2, 4 },
    );
    try expectSpectrum(
        3,
        &.{ 0, 2, 0, 0, 0, 3 },
        &.{ -2, 2, 3 },
    );
}

test "near degeneracy remains resolved without losing multiplicity" {
    const separation = 0x1p-20;
    const half = 0x1p-21;
    try expectSpectrum(
        3,
        &.{ 1 + half, half, 0, 1 + half, 0, 4 },
        &.{ 1, 1 + separation, 4 },
    );
}

test "permuted dense spectrum has deterministic ascending presentation" {
    try expectSpectrum(
        3,
        &.{ 29, -22, -4, 44, 26, 53 },
        &.{ 9, 36, 81 },
    );
}

test "four by four cyclic sweeps recover a known Hadamard spectrum" {
    try expectSpectrum(
        4,
        &.{
            1.5, -2,  -2.5, 0,
            1.5, 0,   -2.5, 1.5,
            -2,  1.5,
        },
        &.{ -3, 1, 2, 6 },
    );
}

test "power-of-two scaling covers extreme finite magnitudes" {
    const large = std.math.ldexp(@as(Scalar, 1), 900);
    const small = std.math.ldexp(@as(Scalar, 1), -900);
    try expectSpectrum(
        3,
        &.{ 2 * large, large, 0, 2 * large, large, 2 * large },
        &.{ 2 * large - @sqrt(2.0) * large, 2 * large, 2 * large + @sqrt(2.0) * large },
    );
    try expectSpectrum(
        3,
        &.{ 2 * small, small, 0, 2 * small, small, 2 * small },
        &.{ 2 * small - @sqrt(2.0) * small, 2 * small, 2 * small + @sqrt(2.0) * small },
    );

    // Exact diagonal entries do not interact, so all representable scales are
    // retained rather than erased by the global scaling used for rotations.
    try expectSpectrum(
        3,
        &.{ std.math.floatTrueMin(Scalar), 0, 0, 1, 0, std.math.floatMax(Scalar) },
        &.{ std.math.floatTrueMin(Scalar), 1, std.math.floatMax(Scalar) },
    );
}

test "workspace query is exact and validates alignment before evaluation" {
    const n = 3;
    const upper = [_]Scalar{ 53, 26, -4, 44, -22, 29 };
    const layout = try workspaceLayout(n);
    try std.testing.expectEqual(@alignOf(Scalar), layout.alignment);
    try std.testing.expectEqual((3 * n * n + n) * @sizeOf(Scalar), layout.bytes);

    var storage: [3 * n * n + n]Scalar = undefined;
    var eigenvalues = [_]Scalar{ -101, -102, -103 };
    var eigenvectors = [_]Scalar{-104} ** (n * n);
    try std.testing.expectEqual(
        Status.ok,
        try solve(
            n,
            &upper,
            std.mem.sliceAsBytes(&storage),
            .{ .eigenvalues = &eigenvalues, .eigenvectors = &eigenvectors },
        ),
    );

    eigenvalues = [_]Scalar{ -101, -102, -103 };
    eigenvectors = [_]Scalar{-104} ** (n * n);
    try std.testing.expectError(
        error.WorkspaceTooSmall,
        solve(
            n,
            &upper,
            std.mem.sliceAsBytes(&storage)[0 .. layout.bytes - 1],
            .{ .eigenvalues = &eigenvalues, .eigenvectors = &eigenvectors },
        ),
    );
    try std.testing.expectEqualSlices(
        Scalar,
        &[_]Scalar{ -101, -102, -103 },
        &eigenvalues,
    );
    try std.testing.expectEqualSlices(
        Scalar,
        &([_]Scalar{-104} ** (n * n)),
        &eigenvectors,
    );

    var misaligned_storage: [3 * n * n + n + 1]Scalar = undefined;
    const misaligned_bytes = std.mem.sliceAsBytes(&misaligned_storage);
    try std.testing.expectError(
        error.WorkspaceMisaligned,
        solve(
            n,
            &upper,
            misaligned_bytes[1 .. layout.bytes + 1],
            .{ .eigenvalues = &eigenvalues, .eigenvectors = &eigenvectors },
        ),
    );
}

test "non-finite input and injected nonconvergence publish nothing" {
    const n = 3;
    const layout = try workspaceLayout(n);
    var storage: [3 * n * n + n]Scalar = undefined;
    var eigenvalues = [_]Scalar{ 11, 12, 13 };
    var eigenvectors = [_]Scalar{14} ** (n * n);
    const expected_values = eigenvalues;
    const expected_vectors = eigenvectors;

    try std.testing.expectEqual(
        Status.non_finite,
        try solve(
            n,
            &.{ 1, std.math.nan(Scalar), 0, 2, 0, 3 },
            std.mem.sliceAsBytes(&storage)[0..layout.bytes],
            .{ .eigenvalues = &eigenvalues, .eigenvectors = &eigenvectors },
        ),
    );
    try std.testing.expectEqualSlices(Scalar, &expected_values, &eigenvalues);
    try std.testing.expectEqualSlices(Scalar, &expected_vectors, &eigenvectors);

    try std.testing.expectEqual(
        Status.non_finite,
        try solve(
            n,
            &.{ 1, std.math.inf(Scalar), 0, 2, 0, 3 },
            std.mem.sliceAsBytes(&storage)[0..layout.bytes],
            .{ .eigenvalues = &eigenvalues, .eigenvectors = &eigenvectors },
        ),
    );
    try std.testing.expectEqualSlices(Scalar, &expected_values, &eigenvalues);
    try std.testing.expectEqualSlices(Scalar, &expected_vectors, &eigenvectors);

    try std.testing.expectEqual(
        Status.non_finite,
        try solve(
            2,
            &.{
                std.math.floatMax(Scalar),
                std.math.floatMax(Scalar),
                std.math.floatMax(Scalar),
            },
            std.mem.sliceAsBytes(&storage)[0..(try workspaceLayout(2)).bytes],
            .{
                .eigenvalues = eigenvalues[0..2],
                .eigenvectors = eigenvectors[0..4],
            },
        ),
    );
    try std.testing.expectEqualSlices(Scalar, &expected_values, &eigenvalues);
    try std.testing.expectEqualSlices(Scalar, &expected_vectors, &eigenvectors);

    convergence_tw.errorAlways(.accept_convergence, error.Nonconvergent);
    defer convergence_tw.reset();
    try std.testing.expectEqual(
        Status.nonconvergent,
        try solve(
            n,
            &.{ 53, 26, -4, 44, -22, 29 },
            std.mem.sliceAsBytes(&storage)[0..layout.bytes],
            .{ .eigenvalues = &eigenvalues, .eigenvectors = &eigenvectors },
        ),
    );
    try convergence_tw.end(.reset);
    try std.testing.expectEqualSlices(Scalar, &expected_values, &eigenvalues);
    try std.testing.expectEqualSlices(Scalar, &expected_vectors, &eigenvectors);
}

test "zero matrix publishes identity and eigenvectors may be omitted" {
    const n = 3;
    var storage: [3 * n * n + n]Scalar = undefined;
    var values: [n]Scalar = undefined;
    var vectors: [n * n]Scalar = undefined;
    try std.testing.expectEqual(
        Status.ok,
        try solve(
            n,
            &.{ 0, 0, 0, 0, 0, 0 },
            std.mem.sliceAsBytes(&storage),
            .{ .eigenvalues = &values, .eigenvectors = &vectors },
        ),
    );
    try std.testing.expectEqualSlices(Scalar, &.{ 0, 0, 0 }, &values);
    try std.testing.expectEqualSlices(
        Scalar,
        &.{ 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        &vectors,
    );

    values = undefined;
    try std.testing.expectEqual(
        Status.ok,
        try solve(
            n,
            &.{ 53, 26, -4, 44, -22, 29 },
            std.mem.sliceAsBytes(&storage),
            .{ .eigenvalues = &values },
        ),
    );
    const tolerance = postcondition_factor *
        @as(Scalar, @floatFromInt(n)) *
        std.math.floatEps(Scalar) *
        53.0;
    try std.testing.expectApproxEqAbs(9, values[0], tolerance);
    try std.testing.expectApproxEqAbs(36, values[1], tolerance);
    try std.testing.expectApproxEqAbs(81, values[2], tolerance);
}

test "repeated executions preserve bitwise ordering, vectors, and signs" {
    const n = 3;
    var first_storage: [3 * n * n + n]Scalar = undefined;
    var second_storage: [3 * n * n + n]Scalar = undefined;
    var first_values: [n]Scalar = undefined;
    var second_values: [n]Scalar = undefined;
    var first_vectors: [n * n]Scalar = undefined;
    var second_vectors: [n * n]Scalar = undefined;
    const upper = [_]Scalar{ 53, 26, -4, 44, -22, 29 };

    try std.testing.expectEqual(
        Status.ok,
        try solve(
            n,
            &upper,
            std.mem.sliceAsBytes(&first_storage),
            .{ .eigenvalues = &first_values, .eigenvectors = &first_vectors },
        ),
    );
    try std.testing.expectEqual(
        Status.ok,
        try solve(
            n,
            &upper,
            std.mem.sliceAsBytes(&second_storage),
            .{ .eigenvalues = &second_values, .eigenvectors = &second_vectors },
        ),
    );
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&first_values), std.mem.sliceAsBytes(&second_values));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&first_vectors), std.mem.sliceAsBytes(&second_vectors));
}

test "shape and aliasing errors are rejected before publication" {
    const n = 2;
    var storage: [3 * n * n + n]Scalar = undefined;
    var values = [_]Scalar{ 7, 8 };
    var vectors: [n * n]Scalar = undefined;

    try std.testing.expectError(
        error.ShapeMismatch,
        solve(
            n,
            &.{ 1, 2 },
            std.mem.sliceAsBytes(&storage),
            .{ .eigenvalues = &values, .eigenvectors = &vectors },
        ),
    );
    try std.testing.expectEqualSlices(Scalar, &.{ 7, 8 }, &values);

    const upper = [_]Scalar{ 1, 0, 2 };
    try std.testing.expectError(
        error.ForbiddenAliasing,
        solve(
            n,
            &upper,
            std.mem.sliceAsBytes(&storage),
            .{
                .eigenvalues = storage[0..n],
                .eigenvectors = &vectors,
            },
        ),
    );
}

test "workspace arithmetic rejects unrepresentable dimensions" {
    if (@bitSizeOf(usize) >= 64) {
        try std.testing.expectEqual(
            @as(usize, 18_000_000_003_000_000_000),
            try packedEntryCount(6_000_000_000),
        );
    }
    try std.testing.expectError(
        error.SizeOverflow,
        packedEntryCount(std.math.maxInt(usize)),
    );
    try std.testing.expectError(
        error.SizeOverflow,
        workspaceLayout(std.math.maxInt(usize)),
    );
}
