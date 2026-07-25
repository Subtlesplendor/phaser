const std = @import("std");
const phaser = @import("phaser");

pub fn main(init: std.process.Init) !void {
    const context = switch (phaser.Context.init(init.gpa, .{
        .max_diagnostics = 32,
        .max_related_locations = 64,
    })) {
        .context => |value| value,
        .failure => return error.InvalidContext,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const writer = &file_writer.interface;

    try inspect(
        context,
        try phaser.SourceId.fromUsize(0),
        "phi4",
        @embedFile("phi4/model.json"),
        writer,
    );
    try inspect(
        context,
        try phaser.SourceId.fromUsize(1),
        "multi_scalar",
        @embedFile("multi_scalar/model.json"),
        writer,
    );
    try writer.flush();
}

fn inspect(
    context: phaser.Context,
    source_id: phaser.SourceId,
    name: []const u8,
    source: []const u8,
    writer: *std.Io.Writer,
) !void {
    const result = try phaser.loadModel(context, .{
        .source_id = source_id,
        .bytes = source,
    }, .{ .audit = true });
    var model = switch (result) {
        .model => |value| value,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            for (owned.items) |diagnostic| {
                try diagnostic.render(writer);
                try writer.writeByte('\n');
            }
            return error.InvalidModel;
        },
    };
    defer model.deinit();

    try writer.print("model {s}\n", .{name});
    try model.writeInspection(writer);
}
