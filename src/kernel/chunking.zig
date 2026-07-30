//! Deterministic caller-owned batch partitioning.
//!
//! This helper computes disjoint ranges only. It creates no workers, owns no
//! memory, and does not choose a worker count.

pub const Chunk = struct {
    start: usize,
    len: usize,

    pub fn end(self: Chunk) usize {
        return self.start + self.len;
    }
};

pub const ChunkError = error{
    InvalidWorkerCount,
    WorkerIndexOutOfRange,
};

/// Divides `point_count` into `worker_count` contiguous ranges. Earlier
/// workers receive at most one additional point, so chunk lengths differ by
/// no more than one and concatenating them recovers the original order.
pub fn forWorker(
    point_count: usize,
    worker_count: usize,
    worker_index: usize,
) ChunkError!Chunk {
    if (worker_count == 0) return error.InvalidWorkerCount;
    if (worker_index >= worker_count) return error.WorkerIndexOutOfRange;
    const base = point_count / worker_count;
    const remainder = point_count % worker_count;
    return .{
        .start = worker_index * base + @min(worker_index, remainder),
        .len = base + @intFromBool(worker_index < remainder),
    };
}

test "chunks are contiguous, balanced, and cover every point exactly once" {
    for (0..33) |point_count| {
        for (1..9) |worker_count| {
            var previous_end: usize = 0;
            var minimum = point_count;
            var maximum: usize = 0;
            for (0..worker_count) |worker_index| {
                const chunk = try forWorker(
                    point_count,
                    worker_count,
                    worker_index,
                );
                try @import("std").testing.expectEqual(previous_end, chunk.start);
                previous_end = chunk.end();
                minimum = @min(minimum, chunk.len);
                maximum = @max(maximum, chunk.len);
            }
            try @import("std").testing.expectEqual(point_count, previous_end);
            try @import("std").testing.expect(maximum - minimum <= 1);
        }
    }
}

test "invalid worker descriptions fail without inventing a range" {
    const testing = @import("std").testing;
    try testing.expectError(error.InvalidWorkerCount, forWorker(10, 0, 0));
    try testing.expectError(error.WorkerIndexOutOfRange, forWorker(10, 3, 3));
}
