//! Benchmark-only numerical leaf measurements.
//!
//! This is a separate executable because Zig assigns every source file to one
//! module per compilation. The main benchmark already imports the complete
//! Phaser module; importing the numerical files a second time there would
//! either violate that rule or force production visibility to grow solely for
//! timing. Keeping this executable separate preserves the production boundary.

const std = @import("std");
const numerics = @import("bench_numerics");

const eigensolver = numerics.symmetric_eigensolver;
const spectral = numerics.spectral_derivative;
const Complex64 = numerics.complex.Complex64;
const Scalar = f64;

const measurement_sample_count = 7;
const minimum_sample_ns = 50_000_000;

const Timer = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    fn begin(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Timestamp.now(io, .awake) };
    }

    fn read(self: *const Timer) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake);
        const elapsed = now.nanoseconds - self.start.nanoseconds;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }
};

const Measurement = struct {
    repetitions: usize,
    units_per_repetition: usize,
    median_picoseconds_per_unit: u64,
    minimum_picoseconds_per_unit: u64,
    maximum_picoseconds_per_unit: u64,
};

const EigensolverRun = struct {
    dimension: usize,
    packed_upper: []const Scalar,
    workspace: []u8,
    eigenvalues: []Scalar,
    eigenvectors: []Scalar,
    sink: eigensolver.Status = .ok,

    fn unitCount(_: *const EigensolverRun) usize {
        return 1;
    }

    fn execute(self: *EigensolverRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            self.sink = try eigensolver.solve(
                self.dimension,
                self.packed_upper,
                self.workspace,
                .{
                    .eigenvalues = self.eigenvalues,
                    .eigenvectors = self.eigenvectors,
                },
            );
            if (self.sink != .ok) return error.EigensolverLeafFailed;
        }
        std.mem.doNotOptimizeAway(self.eigenvalues);
        std.mem.doNotOptimizeAway(self.eigenvectors);
    }
};

const SpectralSumRun = struct {
    eigenvalues: []const Scalar,
    scale: Scalar,
    sink: Complex64 = .zero,

    fn unitCount(_: *const SpectralSumRun) usize {
        return 1;
    }

    fn execute(self: *SpectralSumRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            self.sink = oneLoopSum(self.eigenvalues, self.scale);
        }
        std.mem.doNotOptimizeAway(self.sink);
    }
};

const FlatMatrices = struct {
    triangle: usize,
    first_values: []const Scalar,
    second_values: []const Scalar,

    pub fn first(self: FlatMatrices, index: usize) []const Scalar {
        return self.first_values[index * self.triangle ..][0..self.triangle];
    }

    pub fn second(self: FlatMatrices, index: usize) []const Scalar {
        return self.second_values[index * self.triangle ..][0..self.triangle];
    }
};

const SpectralDerivativeRun = struct {
    request: spectral.Request,
    matrices: FlatMatrices,
    workspace: []u8,
    outputs: spectral.Outputs,
    sink: spectral.Status = .ok,

    fn unitCount(_: *const SpectralDerivativeRun) usize {
        return 1;
    }

    fn execute(self: *SpectralDerivativeRun, repetitions: usize) !void {
        for (0..repetitions) |_| {
            self.sink = try spectral.evaluate(
                self.request,
                self.matrices,
                self.workspace,
                self.outputs,
            );
            if (self.sink != .ok) return error.SpectralDerivativeLeafFailed;
        }
        std.mem.doNotOptimizeAway(self.outputs.gradient);
        std.mem.doNotOptimizeAway(self.outputs.hessian);
    }
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [8 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &file_writer.interface;

    try out.writeAll(
        "\n## numerical leaves\n" ++
            "# Leaf rows are diagnostic and are not summed into an end-to-end estimate.\n" ++
            "leaf\tshape\tmedian ns/unit\tmin ns/unit\tmax ns/unit" ++
            "\trepetitions\tunits/repetition\n",
    );
    try reportEigensolvers(init.gpa, init.io, out);
    try reportSpectralOperations(init.gpa, init.io, out);
    try out.flush();
}

fn reportEigensolvers(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
) !void {
    for ([_]usize{ 1, 2, 3, 8 }) |dimension| {
        const packed_count = try eigensolver.packedEntryCount(dimension);
        const packed_upper = try allocator.alloc(Scalar, packed_count);
        defer allocator.free(packed_upper);
        var packed_index: usize = 0;
        for (0..dimension) |row| {
            for (row..dimension) |column| {
                packed_upper[packed_index] = if (row == column)
                    @as(Scalar, @floatFromInt(2 * dimension + row + 1))
                else
                    @as(Scalar, @floatFromInt(row + column + 1)) * 0.05;
                packed_index += 1;
            }
        }

        const layout = try eigensolver.workspaceLayout(dimension);
        const workspace = try allocator.alignedAlloc(
            u8,
            .of(Scalar),
            layout.bytes,
        );
        defer allocator.free(workspace);
        const eigenvalues = try allocator.alloc(Scalar, dimension);
        defer allocator.free(eigenvalues);
        const eigenvectors = try allocator.alloc(
            Scalar,
            dimension * dimension,
        );
        defer allocator.free(eigenvectors);

        var run = EigensolverRun{
            .dimension = dimension,
            .packed_upper = packed_upper,
            .workspace = workspace,
            .eigenvalues = eigenvalues,
            .eigenvectors = eigenvectors,
        };
        try run.execute(1);
        for (eigenvalues, 0..) |value, index| {
            if (!std.math.isFinite(value) or
                (index != 0 and eigenvalues[index - 1] > value))
            {
                return error.EigensolverLeafVerificationFailed;
            }
        }
        var shape_buffer: [32]u8 = undefined;
        const shape = try std.fmt.bufPrint(
            &shape_buffer,
            "dimension={d}",
            .{dimension},
        );
        try reportLeafMeasurement(
            out,
            "symmetric_eigensolver",
            shape,
            try measure(io, &run),
        );
    }
}

fn reportSpectralOperations(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
) !void {
    const sum_eigenvalues = [_]Scalar{ -4, 0, 9 };
    var sum_run = SpectralSumRun{
        .eigenvalues = &sum_eigenvalues,
        .scale = 3,
    };
    try sum_run.execute(1);
    const expected_sum = oneLoopSum(&sum_eigenvalues, 3);
    if (sum_run.sink.re != expected_sum.re or sum_run.sink.im != expected_sum.im) {
        return error.SpectralSumLeafVerificationFailed;
    }
    try reportLeafMeasurement(
        out,
        "scalar_one_loop_spectral_sum",
        "dimension=3_known_eigenvalues_benchmark_adapter",
        try measure(io, &sum_run),
    );

    const derivative_eigenvalues = [_]Scalar{ 1, 4, 9 };
    const derivative_eigenvectors = [_]Scalar{
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    };
    const first_matrices = [_]Scalar{
        1,   0.1,  0.2, 2,   0.3,  3,
        0.5, -0.2, 0.1, 1.5, 0.25, 2.5,
    };
    const second_matrices = [_]Scalar{
        0.2, 0,    0,    0.3, 0,    0.4,
        0.1, 0.01, 0,    0.2, 0.02, 0.3,
        0.4, 0,    0.03, 0.5, 0,    0.6,
    };
    const matrices = FlatMatrices{
        .triangle = 6,
        .first_values = &first_matrices,
        .second_values = &second_matrices,
    };
    var gradient: [2]Complex64 = undefined;
    var hessian: [4]Complex64 = undefined;
    const gradient_layout = try spectral.workspaceLayout(3, 2, .gradient);
    const hessian_layout = try spectral.workspaceLayout(3, 2, .hessian);
    const workspace = try allocator.alignedAlloc(
        u8,
        .of(Scalar),
        @max(gradient_layout.bytes, hessian_layout.bytes),
    );
    defer allocator.free(workspace);

    var gradient_run = SpectralDerivativeRun{
        .request = .{
            .dimension = 3,
            .coordinate_count = 2,
            .order = .gradient,
            .eigenvalues = &derivative_eigenvalues,
            .eigenvectors = &derivative_eigenvectors,
            .scale = 3,
        },
        .matrices = matrices,
        .workspace = workspace,
        .outputs = .{ .gradient = &gradient },
    };
    try gradient_run.execute(1);
    for (gradient) |value| {
        if (!value.isFinite()) return error.SpectralDerivativeLeafVerificationFailed;
    }
    try reportLeafMeasurement(
        out,
        "invariant_spectral_gradient",
        "dimension=3_coordinates=2",
        try measure(io, &gradient_run),
    );

    var hessian_run = SpectralDerivativeRun{
        .request = .{
            .dimension = 3,
            .coordinate_count = 2,
            .order = .hessian,
            .eigenvalues = &derivative_eigenvalues,
            .eigenvectors = &derivative_eigenvectors,
            .scale = 3,
        },
        .matrices = matrices,
        .workspace = workspace,
        .outputs = .{ .hessian = &hessian },
    };
    try hessian_run.execute(1);
    for (hessian) |value| {
        if (!value.isFinite()) return error.SpectralDerivativeLeafVerificationFailed;
    }
    try reportLeafMeasurement(
        out,
        "invariant_spectral_hessian",
        "dimension=3_coordinates=2",
        try measure(io, &hessian_run),
    );
}

fn oneLoopTerm(eigenvalue: Scalar, scale: Scalar) Complex64 {
    if (eigenvalue == 0) return .zero;
    const square = eigenvalue * eigenvalue;
    const logarithm = @log(@abs(eigenvalue) / (scale * scale));
    return .{
        .re = square * (logarithm - 1.5) /
            (64.0 * std.math.pi * std.math.pi),
        .im = if (eigenvalue < 0)
            square / (64.0 * std.math.pi)
        else
            0,
    };
}

noinline fn oneLoopSum(eigenvalues: []const Scalar, scale: Scalar) Complex64 {
    var total = Complex64.zero;
    for (eigenvalues) |eigenvalue| {
        total = total.add(oneLoopTerm(eigenvalue, scale));
    }
    return total;
}

fn measure(io: std.Io, run: anytype) !Measurement {
    const units_per_repetition = run.unitCount();
    if (units_per_repetition == 0) return error.InvalidMeasurementUnit;
    try run.execute(1);

    var repetitions: usize = 1;
    while (true) {
        var timer = Timer.begin(io);
        try run.execute(repetitions);
        const elapsed = timer.read();
        if (elapsed >= minimum_sample_ns) break;
        repetitions = std.math.mul(usize, repetitions, 2) catch
            return error.MeasurementRepetitionOverflow;
    }

    var samples: [measurement_sample_count]u64 = undefined;
    for (&samples) |*sample| {
        var timer = Timer.begin(io);
        try run.execute(repetitions);
        sample.* = try picosecondsPerUnit(
            timer.read(),
            repetitions,
            units_per_repetition,
        );
    }
    insertionSort(&samples);
    return .{
        .repetitions = repetitions,
        .units_per_repetition = units_per_repetition,
        .median_picoseconds_per_unit = samples[measurement_sample_count / 2],
        .minimum_picoseconds_per_unit = samples[0],
        .maximum_picoseconds_per_unit = samples[measurement_sample_count - 1],
    };
}

fn picosecondsPerUnit(
    elapsed_ns: u64,
    repetitions: usize,
    units_per_repetition: usize,
) !u64 {
    const units = std.math.mul(
        usize,
        repetitions,
        units_per_repetition,
    ) catch return error.MeasurementUnitOverflow;
    const picoseconds = std.math.mul(
        u64,
        elapsed_ns,
        1000,
    ) catch return error.MeasurementTimeOverflow;
    return picoseconds / @as(u64, @intCast(units));
}

fn insertionSort(values: []u64) void {
    for (values[1..], 1..) |value, index| {
        var position = index;
        while (position > 0 and values[position - 1] > value) {
            values[position] = values[position - 1];
            position -= 1;
        }
        values[position] = value;
    }
}

fn writeNanoseconds(out: *std.Io.Writer, picoseconds: u64) !void {
    try out.print(
        "{d}.{d:0>3}",
        .{ picoseconds / 1000, picoseconds % 1000 },
    );
}

fn reportLeafMeasurement(
    out: *std.Io.Writer,
    name: []const u8,
    shape: []const u8,
    measurement: Measurement,
) !void {
    try out.print("{s}\t{s}\t", .{ name, shape });
    try writeNanoseconds(out, measurement.median_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.minimum_picoseconds_per_unit);
    try out.writeByte('\t');
    try writeNanoseconds(out, measurement.maximum_picoseconds_per_unit);
    try out.print(
        "\t{d}\t{d}\n",
        .{ measurement.repetitions, measurement.units_per_repetition },
    );
    try out.flush();
}

test "the numerical leaf driver stays compilable from the test tier" {
    _ = &main;
}

test "the benchmark spectral adapter keeps zero and negative branches" {
    const result = oneLoopSum(&.{ -1, 0, 1 }, 2);
    try std.testing.expect(std.math.isFinite(result.re));
    try std.testing.expect(result.im > 0);
}
