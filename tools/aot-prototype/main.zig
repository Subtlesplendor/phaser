//! Host-side driver for the explicit phi4 tree-value AOT prototype.

const std = @import("std");
const phaser = @import("phaser");
const example_data = @import("example_data");

const maximum_file_bytes = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        init.gpa,
    );
    defer arguments.deinit();
    _ = arguments.skip();

    const command = arguments.next() orelse return error.InvalidArguments;
    if (std.mem.eql(u8, command, "emit")) {
        const output_path = arguments.next() orelse return error.InvalidArguments;
        if (arguments.next() != null) return error.InvalidArguments;
        try emit(init, output_path);
    } else if (std.mem.eql(u8, command, "check")) {
        const actual_path = arguments.next() orelse return error.InvalidArguments;
        const expected_path = arguments.next() orelse return error.InvalidArguments;
        if (arguments.next() != null) return error.InvalidArguments;
        try check(init, actual_path, expected_path);
    } else {
        return error.InvalidArguments;
    }
}

fn emit(init: std.process.Init, output_path: []const u8) !void {
    var model = try loadModel(init.gpa);
    defer model.deinit();
    var request = try loadRequest(init.gpa);
    defer request.deinit();
    var artifact = try derive(init.gpa, &model, &request);
    defer artifact.deinit();
    var kernel = try phaser.kernel.compile(init.gpa, &artifact, .{
        .capability = .value,
        .selection = .{ .loop_order = 0 },
    });
    defer kernel.deinit();

    const parameter_names = try init.gpa.alloc([]const u8, kernel.parameters.len);
    defer init.gpa.free(parameter_names);
    for (kernel.parameters, parameter_names) |channel, *name| {
        name.* = channel.name;
    }
    const background_names = try init.gpa.alloc([]const u8, kernel.coordinates.len);
    defer init.gpa.free(background_names);
    for (kernel.coordinates, background_names) |channel, *name| {
        name.* = channel.name;
    }

    var plan = try phaser.kernel.aot_plan.compile(
        init.gpa,
        &kernel.program,
        .{
            .model_fingerprint = kernel.model_fingerprint,
            .request_fingerprint = kernel.request_fingerprint,
            .parameter_names = parameter_names,
            .background_names = background_names,
        },
        .{},
    );
    defer plan.deinit();
    const source = try phaser.kernel.aot_generate.generateAlloc(init.gpa, &plan);
    defer init.gpa.free(source);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = source,
    });
}

fn check(
    init: std.process.Init,
    actual_path: []const u8,
    expected_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const actual = try cwd.readFileAlloc(
        init.io,
        actual_path,
        init.gpa,
        .limited(maximum_file_bytes),
    );
    defer init.gpa.free(actual);
    const expected = try cwd.readFileAlloc(
        init.io,
        expected_path,
        init.gpa,
        .limited(maximum_file_bytes),
    );
    defer init.gpa.free(expected);
    if (!std.mem.eql(u8, actual, expected)) return error.GeneratedSourceChanged;
}

fn context(allocator: std.mem.Allocator) phaser.Context {
    return switch (phaser.Context.init(allocator, .{
        .max_diagnostics = 16,
        .max_related_locations = 32,
    })) {
        .context => |value| value,
        .failure => unreachable,
    };
}

fn loadModel(allocator: std.mem.Allocator) !phaser.Model {
    return switch (try phaser.loadModel(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(0),
        .bytes = example_data.phi4_model,
    }, .{})) {
        .model => |value| value,
        .diagnostics => error.InvalidModel,
    };
}

fn loadRequest(allocator: std.mem.Allocator) !phaser.CalculationRequest {
    return switch (try phaser.parseRequest(context(allocator), .{
        .source_id = try phaser.SourceId.fromUsize(1),
        .bytes = example_data.phi4_request,
    }, .{})) {
        .request => |value| value,
        .diagnostics => error.InvalidRequest,
    };
}

fn derive(
    allocator: std.mem.Allocator,
    model: *const phaser.Model,
    request: *const phaser.CalculationRequest,
) !phaser.PotentialArtifact {
    return switch (try phaser.deriveEffectivePotential(
        context(allocator),
        model,
        request,
        .{ .derivatives = .none },
    )) {
        .artifact => |value| value,
        .diagnostics => error.DerivationFailed,
    };
}
