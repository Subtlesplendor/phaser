const std = @import("std");
const SourceId = @import("typed_id.zig").SourceId;

pub const SourceSpanError = error{
    SourceTooLarge,
    OffsetTooLarge,
    Reversed,
    OutOfBounds,
};

pub const SourceSpan = struct {
    source_id: SourceId,
    start: u32,
    end: u32,

    pub fn init(
        source_id: SourceId,
        source_length: usize,
        start: usize,
        end: usize,
    ) SourceSpanError!SourceSpan {
        if (source_length > std.math.maxInt(u32)) return error.SourceTooLarge;
        if (start > std.math.maxInt(u32) or end > std.math.maxInt(u32)) {
            return error.OffsetTooLarge;
        }
        if (start > end) return error.Reversed;
        if (end > source_length) return error.OutOfBounds;

        return .{
            .source_id = source_id,
            .start = @intCast(start),
            .end = @intCast(end),
        };
    }

    pub fn length(self: SourceSpan) u32 {
        std.debug.assert(self.start <= self.end);
        return self.end - self.start;
    }
};

test "source spans use validated half-open byte ranges" {
    const source_id = try SourceId.fromUsize(3);

    const complete = try SourceSpan.init(source_id, 8, 0, 8);
    try std.testing.expectEqual(@as(u32, 8), complete.length());

    const insertion = try SourceSpan.init(source_id, 8, 4, 4);
    try std.testing.expectEqual(@as(u32, 0), insertion.length());

    try std.testing.expectError(
        error.Reversed,
        SourceSpan.init(source_id, 8, 5, 4),
    );
    try std.testing.expectError(
        error.OutOfBounds,
        SourceSpan.init(source_id, 8, 0, 9),
    );
}
