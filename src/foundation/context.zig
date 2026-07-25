const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const Limits = struct {
    max_diagnostics: usize,
    max_related_locations: usize,
};

pub const Result = union(enum) {
    context: Context,
    failure: diagnostic.Diagnostic,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    limits: Limits,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Result {
        if (limits.max_diagnostics == 0) {
            return invalidLimit(.max_diagnostics, 0);
        }

        return .{ .context = .{
            .allocator = allocator,
            .limits = limits,
        } };
    }

    pub fn diagnosticBuilder(self: Context) diagnostic.Builder {
        return diagnostic.Builder.init(
            self.allocator,
            self.limits.max_diagnostics,
            self.limits.max_related_locations,
        );
    }
};

fn invalidLimit(name: diagnostic.LimitName, value: usize) Result {
    return .{ .failure = .{
        .code = .invalid_limit,
        .category = .configuration,
        .detail = .{ .invalid_limit = .{
            .name = name,
            .value = value,
        } },
    } };
}

test "context retains explicit allocator and validated limits" {
    const limits = Limits{
        .max_diagnostics = 8,
        .max_related_locations = 16,
    };

    const result = Context.init(std.testing.allocator, limits);
    const context = switch (result) {
        .context => |context| context,
        .failure => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(limits, context.limits);
    var builder = context.diagnosticBuilder();
    defer builder.deinit();
}

test "invalid context limits return structured diagnostics" {
    const result = Context.init(std.testing.allocator, .{
        .max_diagnostics = 0,
        .max_related_locations = 0,
    });

    switch (result) {
        .context => return error.TestUnexpectedResult,
        .failure => |failure| {
            try std.testing.expectEqual(diagnostic.Code.invalid_limit, failure.code);
            try std.testing.expectEqual(
                diagnostic.LimitName.max_diagnostics,
                failure.detail.invalid_limit.name,
            );
        },
    }
}
