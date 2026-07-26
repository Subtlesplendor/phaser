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

    pub fn isValidForSourceLength(
        self: SourceSpan,
        source_length: usize,
    ) bool {
        if (source_length > std.math.maxInt(u32)) return false;
        return self.start <= self.end and self.end <= source_length;
    }
};

test "source spans use validated half-open byte ranges" {
    const source_id = try SourceId.fromUsize(3);

    const complete = try SourceSpan.init(source_id, 8, 0, 8);
    try std.testing.expectEqual(@as(u32, 8), complete.length());
    try std.testing.expect(complete.isValidForSourceLength(8));

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
    try std.testing.expectError(
        error.SourceTooLarge,
        SourceSpan.init(
            source_id,
            @as(usize, std.math.maxInt(u32)) + 1,
            0,
            0,
        ),
    );
    try std.testing.expectError(
        error.OffsetTooLarge,
        SourceSpan.init(
            source_id,
            std.math.maxInt(u32),
            @as(usize, std.math.maxInt(u32)) + 1,
            @as(usize, std.math.maxInt(u32)) + 1,
        ),
    );
}

test "source span validation detects forged values at trust boundaries" {
    const source_id = try SourceId.fromUsize(3);
    const reversed = SourceSpan{
        .source_id = source_id,
        .start = 5,
        .end = 4,
    };
    const out_of_bounds = SourceSpan{
        .source_id = source_id,
        .start = 0,
        .end = 9,
    };

    try std.testing.expect(!reversed.isValidForSourceLength(8));
    try std.testing.expect(!out_of_bounds.isValidForSourceLength(8));
}

test "source span construction separates oversized offsets from other faults" {
    const source_id = try SourceId.fromUsize(3);
    const too_large = @as(usize, std.math.maxInt(u32)) + 1;

    // Each offset is checked on its own. A start past the encodable range is an
    // oversized offset even though it is also, incidentally, past the end; a
    // reversed-range error here would describe the wrong fault.
    try std.testing.expectError(
        error.OffsetTooLarge,
        SourceSpan.init(source_id, 8, too_large, 8),
    );

    // Likewise for an end past the range, which is also past the source.
    try std.testing.expectError(
        error.OffsetTooLarge,
        SourceSpan.init(source_id, 8, 0, too_large),
    );

    // Offsets of exactly the largest encodable value are not oversized, which
    // pins which side of the boundary each rejection begins on.
    const largest = @as(usize, std.math.maxInt(u32));
    const whole = try SourceSpan.init(source_id, largest, 0, largest);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), whole.length());

    const empty_at_end = try SourceSpan.init(source_id, largest, largest, largest);
    try std.testing.expectEqual(@as(u32, 0), empty_at_end.length());
}

test "source span validation rejects a source no span can address" {
    const source_id = try SourceId.fromUsize(3);
    const span = SourceSpan{
        .source_id = source_id,
        .start = 0,
        .end = 8,
    };

    // Span offsets are u32. A source longer than that cannot be described by
    // any span, so validation refuses it even when the span's own bounds are
    // unremarkable and lie well inside the source.
    try std.testing.expect(
        !span.isValidForSourceLength(@as(usize, std.math.maxInt(u32)) + 1),
    );

    // A source of exactly the largest addressable length is still valid, which
    // pins which side of the boundary the rejection begins on.
    try std.testing.expect(span.isValidForSourceLength(std.math.maxInt(u32)));

    // An empty span is a position, not a degenerate range, so start equal to
    // end is valid. Insertion points are represented this way.
    const insertion = SourceSpan{
        .source_id = source_id,
        .start = 4,
        .end = 4,
    };
    try std.testing.expect(insertion.isValidForSourceLength(8));

    // A span reaching exactly the end of the source is inside it.
    try std.testing.expect(span.isValidForSourceLength(8));
}
