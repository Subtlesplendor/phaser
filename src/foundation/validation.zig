const std = @import("std");
const SourceId = @import("typed_id.zig").SourceId;
const source = @import("source.zig");
const diagnostic = @import("diagnostic.zig");

pub const SourceSpanResult = union(enum) {
    value: source.SourceSpan,
    failure: diagnostic.Diagnostic,
};

pub fn makeSourceSpan(
    source_id: SourceId,
    source_length: usize,
    start: usize,
    end: usize,
) SourceSpanResult {
    const span = source.SourceSpan.init(
        source_id,
        source_length,
        start,
        end,
    ) catch {
        return .{ .failure = .{
            .code = .invalid_source_span,
            .category = .source,
            .detail = .{ .source_span = .{
                .source_length = source_length,
                .start = start,
                .end = end,
            } },
        } };
    };
    return .{ .value = span };
}

test "external source span validation returns a structured diagnostic" {
    const source_id = try SourceId.fromUsize(0);
    const result = makeSourceSpan(source_id, 4, 3, 5);

    switch (result) {
        .value => return error.TestUnexpectedResult,
        .failure => |failure| {
            try std.testing.expectEqual(
                diagnostic.Code.invalid_source_span,
                failure.code,
            );
            const detail = failure.detail.source_span;
            try std.testing.expectEqual(@as(u64, 4), detail.source_length);
            try std.testing.expectEqual(@as(u64, 3), detail.start);
            try std.testing.expectEqual(@as(u64, 5), detail.end);
        },
    }
}
