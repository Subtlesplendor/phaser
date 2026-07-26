//! Phaser command-line client.
//!
//! A thin shell over the public library: it parses arguments, reads files, and
//! maps outcomes to exit codes. Every scientific decision belongs to the
//! library, and the commands themselves live in `commands.zig` so that tests
//! drive them without spawning a process.

const std = @import("std");
const commands = @import("commands");
const phaser = @import("phaser");

const Scalar = phaser.kernel.Scalar;

/// Largest source file the client will read.
const max_source_bytes: usize = 16 * 1024 * 1024;

const usage =
    \\phaser — exact and numerical scalar effective-potential calculations
    \\
    \\Usage:
    \\  phaser inspect  <model.json>
    \\  phaser export   <model.json> <request.json> [options]
    \\  phaser evaluate <model.json> <request.json> <point.json> [options]
    \\
    \\Export options:
    \\  --target=phaser|latex   Output notation (default: phaser)
    \\  --contributions         Emit each contribution separately
    \\  --gradient              Emit gradient components
    \\
    \\Evaluate options:
    \\  --outputs=value|gradient|hessian   Requested outputs (default: value)
    \\  --point=A[,B...]                   One background point; repeatable
    \\  --scan=INDEX:FROM:TO:COUNT         Vary one coordinate, others at zero
    \\
    \\Exit codes:
    \\  0  success
    \\  1  invalid input, reported as structured diagnostics
    \\  2  usage error
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stderr_buffer: [8 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    var stderr_file: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const out = &stdout_file.interface;
    const errors = &stderr_file.interface;

    const code = run(init, out, errors) catch |err| switch (err) {
        error.Usage => blk: {
            errors.writeAll(usage) catch {};
            break :blk @as(u8, 2);
        },
        error.OutOfMemory => blk: {
            errors.writeAll("error:allocation: out of memory\n") catch {};
            break :blk @as(u8, 1);
        },
        else => blk: {
            errors.print("error:{t}\n", .{err}) catch {};
            break :blk @as(u8, 1);
        },
    };

    out.flush() catch return 1;
    errors.flush() catch return 1;
    return code;
}

const RunError = commands.Error || error{ Usage, ReadFailed };

fn run(
    init: std.process.Init,
    out: *std.Io.Writer,
    errors: *std.Io.Writer,
) RunError!u8 {
    const gpa = init.gpa;
    var iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, gpa) catch
        return error.OutOfMemory;
    defer iterator.deinit();
    _ = iterator.skip();

    const command = iterator.next() orelse return error.Usage;

    if (std.mem.eql(u8, command, "inspect")) {
        const path = iterator.next() orelse return error.Usage;
        const source = try readSource(init.io, gpa, path, errors);
        defer gpa.free(source);
        try commands.inspect(gpa, source, out, errors);
        return 0;
    }

    if (std.mem.eql(u8, command, "export")) {
        const model_path = iterator.next() orelse return error.Usage;
        const request_path = iterator.next() orelse return error.Usage;
        var options = commands.ExportOptions{};
        while (iterator.next()) |argument| {
            if (std.mem.startsWith(u8, argument, "--target=")) {
                const name = argument["--target=".len..];
                if (std.mem.eql(u8, name, "phaser")) {
                    options.target = .phaser;
                } else if (std.mem.eql(u8, name, "latex")) {
                    options.target = .latex;
                } else return error.Usage;
            } else if (std.mem.eql(u8, argument, "--contributions")) {
                options.contributions = true;
            } else if (std.mem.eql(u8, argument, "--gradient")) {
                options.gradient = true;
            } else return error.Usage;
        }
        const model_source = try readSource(init.io, gpa, model_path, errors);
        defer gpa.free(model_source);
        const request_source = try readSource(init.io, gpa, request_path, errors);
        defer gpa.free(request_source);
        try commands.exportSymbolic(
            gpa,
            model_source,
            request_source,
            options,
            out,
            errors,
        );
        return 0;
    }

    if (std.mem.eql(u8, command, "evaluate")) {
        const model_path = iterator.next() orelse return error.Usage;
        const request_path = iterator.next() orelse return error.Usage;
        const point_path = iterator.next() orelse return error.Usage;

        var outputs = commands.Outputs.value;
        var explicit: std.ArrayList(Scalar) = .empty;
        defer explicit.deinit(gpa);
        var explicit_points: usize = 0;
        var scan: ?ScanSpec = null;

        while (iterator.next()) |argument| {
            if (std.mem.startsWith(u8, argument, "--outputs=")) {
                const name = argument["--outputs=".len..];
                outputs = std.meta.stringToEnum(commands.Outputs, name) orelse
                    return error.Usage;
            } else if (std.mem.startsWith(u8, argument, "--point=")) {
                var values = std.mem.splitScalar(u8, argument["--point=".len..], ',');
                var seen: usize = 0;
                while (values.next()) |text| {
                    const value = std.fmt.parseFloat(Scalar, text) catch
                        return error.Usage;
                    explicit.append(gpa, value) catch return error.OutOfMemory;
                    seen += 1;
                }
                if (seen == 0) return error.Usage;
                explicit_points += 1;
            } else if (std.mem.startsWith(u8, argument, "--scan=")) {
                scan = try parseScan(argument["--scan=".len..]);
            } else return error.Usage;
        }
        if (explicit_points != 0 and scan != null) return error.Usage;

        const model_source = try readSource(init.io, gpa, model_path, errors);
        defer gpa.free(model_source);
        const request_source = try readSource(init.io, gpa, request_path, errors);
        defer gpa.free(request_source);
        const point_source = try readSource(init.io, gpa, point_path, errors);
        defer gpa.free(point_source);

        // The coordinate count comes from the derived artifact, so a scan is
        // expanded only after the calculation has been planned.
        var points: []const Scalar = explicit.items;
        var point_count = explicit_points;
        var owned_scan: ?[]Scalar = null;
        defer if (owned_scan) |buffer| gpa.free(buffer);

        if (scan) |spec| {
            const coordinates = try coordinateCount(
                gpa,
                model_source,
                request_source,
                errors,
            );
            const expanded = commands.expandScan(
                gpa,
                coordinates,
                spec.index,
                spec.from,
                spec.to,
                spec.count,
            ) catch return error.Usage;
            owned_scan = expanded;
            points = expanded;
            point_count = spec.count;
        }
        if (point_count == 0) return error.Usage;

        try commands.evaluate(
            gpa,
            model_source,
            request_source,
            point_source,
            .{ .outputs = outputs, .points = points, .point_count = point_count },
            out,
            errors,
        );
        return 0;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        out.writeAll(usage) catch return error.WriteFailed;
        return 0;
    }
    return error.Usage;
}

const ScanSpec = struct {
    index: usize,
    from: Scalar,
    to: Scalar,
    count: usize,
};

fn parseScan(text: []const u8) error{Usage}!ScanSpec {
    var fields = std.mem.splitScalar(u8, text, ':');
    const index_text = fields.next() orelse return error.Usage;
    const from_text = fields.next() orelse return error.Usage;
    const to_text = fields.next() orelse return error.Usage;
    const count_text = fields.next() orelse return error.Usage;
    if (fields.next() != null) return error.Usage;

    return .{
        .index = std.fmt.parseInt(usize, index_text, 10) catch return error.Usage,
        .from = std.fmt.parseFloat(Scalar, from_text) catch return error.Usage,
        .to = std.fmt.parseFloat(Scalar, to_text) catch return error.Usage,
        .count = std.fmt.parseInt(usize, count_text, 10) catch return error.Usage,
    };
}

/// Plans the calculation only to learn its background dimension.
fn coordinateCount(
    allocator: std.mem.Allocator,
    model_source: []const u8,
    request_source: []const u8,
    errors: *std.Io.Writer,
) commands.Error!usize {
    return commands.coordinateCount(allocator, model_source, request_source, errors);
}

fn readSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    errors: *std.Io.Writer,
) RunError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_source_bytes),
    ) catch |err| {
        errors.print("error:source: cannot read {s}: {t}\n", .{ path, err }) catch {};
        return error.ReadFailed;
    };
}
