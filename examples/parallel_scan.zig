//! Caller-owned parallel scan over one immutable optimized binding.
//!
//! Phaser creates no workers. The caller chooses the worker count, computes
//! deterministic disjoint chunks, and gives every worker its own workspace and
//! output region.

const std = @import("std");
const phaser = @import("phaser");

const Scalar = phaser.kernel.Scalar;
const Status = phaser.kernel.Status;
const point_count = 32;
const worker_count = 4;

const Worker = struct {
    binding: *const phaser.kernel.Binding,
    backgrounds: []const Scalar,
    workspace: []align(@alignOf(@Vector(2, Scalar))) u8,
    values: []Scalar,
    statuses: []Status,
    failure: ?anyerror = null,
};

pub fn main(init: std.process.Init) !void {
    const context = switch (phaser.Context.init(init.gpa, .{
        .max_diagnostics = 16,
        .max_related_locations = 32,
    })) {
        .context => |value| value,
        .failure => return error.InvalidContext,
    };

    var model = try loadModel(context);
    defer model.deinit();
    var request = try loadRequest(context);
    defer request.deinit();
    var artifact = try derive(context, &model, &request);
    defer artifact.deinit();
    var kernel = try phaser.kernel.compile(init.gpa, &artifact, .{
        .capability = .value,
        .backend = .optimized_interpreter,
    });
    defer kernel.deinit();
    var point = try loadPoint(context);
    defer point.deinit();
    var binding = try phaser.kernel.bind(init.gpa, &kernel, &model, &point);
    defer binding.deinit();

    var backgrounds: [point_count]Scalar = undefined;
    for (&backgrounds, 0..) |*background, index| {
        background.* = @as(Scalar, @floatFromInt(index)) - point_count / 2;
    }
    var parallel_values: [point_count]Scalar = undefined;
    var parallel_statuses: [point_count]Status = undefined;
    var workers: [worker_count]Worker = undefined;
    var threads: [worker_count]std.Thread = undefined;

    const layout = binding.workspaceLayout(point_count);
    const workspace_stride = std.mem.alignForward(
        usize,
        layout.bytes,
        @alignOf(@Vector(2, Scalar)),
    );
    const workspace_storage = try init.gpa.alignedAlloc(
        u8,
        .of(@Vector(2, Scalar)),
        workspace_stride * worker_count,
    );
    defer init.gpa.free(workspace_storage);
    for (0..worker_count) |worker_index| {
        const chunk = try phaser.kernel.chunkForWorker(
            point_count,
            worker_count,
            worker_index,
        );
        const workspace: []align(@alignOf(@Vector(2, Scalar))) u8 = @alignCast(
            workspace_storage[worker_index * workspace_stride ..][0..layout.bytes],
        );
        workers[worker_index] = .{
            .binding = &binding,
            .backgrounds = backgrounds[chunk.start..chunk.end()],
            .workspace = workspace,
            .values = parallel_values[chunk.start..chunk.end()],
            .statuses = parallel_statuses[chunk.start..chunk.end()],
        };
    }
    var started: usize = 0;
    for (0..worker_count) |worker_index| {
        threads[worker_index] = std.Thread.spawn(
            .{},
            runWorker,
            .{&workers[worker_index]},
        ) catch |failure| {
            for (threads[0..started]) |thread| thread.join();
            return failure;
        };
        started += 1;
    }

    for (threads[0..started]) |thread| thread.join();
    for (&workers) |worker| {
        if (worker.failure) |failure| return failure;
    }

    const serial_workspace = try init.gpa.alignedAlloc(
        u8,
        .of(@Vector(2, Scalar)),
        layout.bytes,
    );
    defer init.gpa.free(serial_workspace);
    var serial_values: [point_count]Scalar = undefined;
    var serial_statuses: [point_count]Status = undefined;
    try binding.evaluate(
        &backgrounds,
        point_count,
        serial_workspace,
        .{ .values = &serial_values, .statuses = &serial_statuses },
    );
    if (!std.mem.eql(Scalar, &serial_values, &parallel_values) or
        !std.mem.eql(Status, &serial_statuses, &parallel_statuses))
    {
        return error.ParallelScanMismatch;
    }
}

fn runWorker(worker: *Worker) void {
    worker.binding.evaluate(
        worker.backgrounds,
        worker.values.len,
        worker.workspace,
        .{ .values = worker.values, .statuses = worker.statuses },
    ) catch |failure| {
        worker.failure = failure;
    };
}

fn loadModel(context: phaser.Context) !phaser.Model {
    return switch (try phaser.loadModel(context, .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = @embedFile("phi4/model.json"),
    }, .{ .audit = true })) {
        .model => |model| model,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidModel;
        },
    };
}

fn loadRequest(context: phaser.Context) !phaser.calculation.Request {
    return switch (try phaser.parseRequest(context, .{
        .source_id = try phaser.SourceId.fromUsize(1),
        .bytes = @embedFile("phi4/request.json"),
    }, .{})) {
        .request => |request| request,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidRequest;
        },
    };
}

fn derive(
    context: phaser.Context,
    model: *const phaser.Model,
    request: *const phaser.calculation.Request,
) !phaser.calculation.Artifact {
    return switch (try phaser.deriveClassicalPotential(
        context,
        model,
        request,
        .{ .audit = true },
    )) {
        .artifact => |artifact| artifact,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.DerivationFailed;
        },
    };
}

fn loadPoint(context: phaser.Context) !phaser.calculation.ParameterPoint {
    return switch (try phaser.parseParameterPoint(context, .{
        .source_id = try phaser.SourceId.fromUsize(2),
        .bytes = @embedFile("phi4/point.json"),
    }, .{})) {
        .point => |point| point,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.InvalidPoint;
        },
    };
}
