const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const Result = union(enum) {
    value: ByteSize,
    failure: diagnostic.Diagnostic,
};

pub const ByteSize = struct {
    value: usize,

    pub fn init(value: usize) ByteSize {
        return .{ .value = value };
    }

    pub fn fromU64(value: u64, resource: diagnostic.Resource) Result {
        const narrowed = std.math.cast(usize, value) orelse {
            return overflow(resource, 0, std.math.maxInt(usize), std.math.maxInt(usize));
        };
        return .{ .value = .init(narrowed) };
    }

    pub fn add(
        self: ByteSize,
        other: ByteSize,
        resource: diagnostic.Resource,
    ) Result {
        const sum, const did_overflow = @addWithOverflow(self.value, other.value);
        if (did_overflow != 0) {
            return overflow(resource, self.value, std.math.maxInt(usize), other.value);
        }
        return .{ .value = .init(sum) };
    }

    pub fn multiply(
        self: ByteSize,
        factor: usize,
        resource: diagnostic.Resource,
    ) Result {
        const product, const did_overflow = @mulWithOverflow(self.value, factor);
        if (did_overflow != 0) {
            return overflow(resource, self.value, std.math.maxInt(usize), factor);
        }
        return .{ .value = .init(product) };
    }

    pub fn alignForward(
        self: ByteSize,
        alignment: usize,
        resource: diagnostic.Resource,
    ) Result {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
            return .{ .failure = .{
                .code = .invalid_alignment,
                .category = .capacity,
                .detail = .{ .alignment = .{ .value = alignment } },
            } };
        }
        if (self.value == 0) return .{ .value = .init(0) };

        const increment = alignment - 1;
        const adjusted, const did_overflow = @addWithOverflow(self.value, increment);
        if (did_overflow != 0) {
            return overflow(resource, self.value, std.math.maxInt(usize), increment);
        }
        return .{ .value = .init(adjusted & ~increment) };
    }
};

pub const Reservation = union(enum) {
    committed,
    rejected: diagnostic.Diagnostic,
};

pub const Budget = struct {
    resource: diagnostic.Resource,
    limit: usize,
    current: usize = 0,
    peak: usize = 0,

    pub fn init(resource: diagnostic.Resource, limit: usize) Budget {
        return .{ .resource = resource, .limit = limit };
    }

    pub fn reserve(self: *Budget, requested: usize) Reservation {
        const next, const did_overflow = @addWithOverflow(self.current, requested);
        if (did_overflow != 0) {
            return .{ .rejected = capacityDiagnostic(
                .capacity_overflow,
                self.resource,
                self.limit,
                self.current,
                requested,
            ) };
        }
        if (next > self.limit) {
            return .{ .rejected = capacityDiagnostic(
                .capacity_exceeded,
                self.resource,
                self.limit,
                self.current,
                requested,
            ) };
        }

        self.current = next;
        self.peak = @max(self.peak, next);
        return .committed;
    }

    pub fn release(self: *Budget, amount: usize) void {
        std.debug.assert(amount <= self.current);
        self.current -= amount;
    }
};

/// Allocator wrapper that enforces a byte ceiling over live allocations.
///
/// This is used at externally controlled construction boundaries where a
/// resource limit must constrain actual allocation, rather than an estimate
/// computed after construction has already succeeded.
pub const LimitedAllocator = struct {
    child: std.mem.Allocator,
    limit: usize,
    current: usize = 0,
    peak: usize = 0,
    limit_exceeded: bool = false,

    pub fn init(child: std.mem.Allocator, limit: usize) LimitedAllocator {
        return .{ .child = child, .limit = limit };
    }

    pub fn allocator(self: *LimitedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn reserve(self: *LimitedAllocator, amount: usize) bool {
        if (amount > self.limit - self.current) {
            self.limit_exceeded = true;
            return false;
        }
        self.current += amount;
        self.peak = @max(self.peak, self.current);
        return true;
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LimitedAllocator = @ptrCast(@alignCast(context));
        if (!self.reserve(len)) return null;
        return self.child.rawAlloc(len, alignment, return_address) orelse {
            self.current -= len;
            return null;
        };
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *LimitedAllocator = @ptrCast(@alignCast(context));
        // A same-length resize takes the shrinking branch and adjusts nothing.
        // Reserving a growth of zero would do just as little, because a zero
        // reservation cannot fail while the live count never exceeds the limit.
        // The two branches therefore agree on this boundary, which is why
        // mutation runs report the `>=` form of this test as a survivor. It is
        // an equivalent mutant, not a missing test.
        if (new_len > memory.len) {
            const growth = new_len - memory.len;
            if (!self.reserve(growth)) return false;
            if (!self.child.rawResize(memory, alignment, new_len, return_address)) {
                self.current -= growth;
                return false;
            }
        } else {
            if (!self.child.rawResize(memory, alignment, new_len, return_address)) {
                return false;
            }
            self.current -= memory.len - new_len;
        }
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LimitedAllocator = @ptrCast(@alignCast(context));
        // Equivalent under `>=` for the same reason as in `resize` above.
        if (new_len > memory.len) {
            const growth = new_len - memory.len;
            if (!self.reserve(growth)) return null;
            return self.child.rawRemap(
                memory,
                alignment,
                new_len,
                return_address,
            ) orelse {
                self.current -= growth;
                return null;
            };
        }
        const result = self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        self.current -= memory.len - new_len;
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *LimitedAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
        std.debug.assert(memory.len <= self.current);
        self.current -= memory.len;
    }
};

fn overflow(
    resource: diagnostic.Resource,
    current: usize,
    limit: usize,
    requested: usize,
) Result {
    return .{ .failure = capacityDiagnostic(
        .capacity_overflow,
        resource,
        limit,
        current,
        requested,
    ) };
}

fn capacityDiagnostic(
    code: diagnostic.Code,
    resource: diagnostic.Resource,
    limit: usize,
    current: usize,
    requested: usize,
) diagnostic.Diagnostic {
    return .{
        .code = code,
        .category = .capacity,
        .detail = .{ .capacity = .{
            .resource = resource,
            .limit = limit,
            .current = current,
            .requested = requested,
        } },
    };
}

test "checked byte arithmetic covers exact and overflow boundaries" {
    const zero = ByteSize.init(0);
    const maximum = ByteSize.init(std.math.maxInt(usize));

    switch (zero.add(maximum, .workspace_bytes)) {
        .value => |value| try std.testing.expectEqual(
            std.math.maxInt(usize),
            value.value,
        ),
        .failure => return error.TestUnexpectedResult,
    }
    switch (maximum.add(.init(1), .workspace_bytes)) {
        .value => return error.TestUnexpectedResult,
        .failure => |failure| try std.testing.expectEqual(
            diagnostic.Code.capacity_overflow,
            failure.code,
        ),
    }
    switch (maximum.multiply(0, .workspace_bytes)) {
        .value => |value| try std.testing.expectEqual(@as(usize, 0), value.value),
        .failure => return error.TestUnexpectedResult,
    }
    switch (maximum.multiply(2, .workspace_bytes)) {
        .value => return error.TestUnexpectedResult,
        .failure => |failure| try std.testing.expectEqual(
            diagnostic.Code.capacity_overflow,
            failure.code,
        ),
    }
}

test "alignment is checked including zero and near overflow" {
    switch (ByteSize.init(9).alignForward(0, .workspace_bytes)) {
        .value => return error.TestUnexpectedResult,
        .failure => |failure| try std.testing.expectEqual(
            diagnostic.Code.invalid_alignment,
            failure.code,
        ),
    }
    switch (ByteSize.init(0).alignForward(8, .workspace_bytes)) {
        .value => |value| try std.testing.expectEqual(@as(usize, 0), value.value),
        .failure => return error.TestUnexpectedResult,
    }
    switch (ByteSize.init(9).alignForward(8, .workspace_bytes)) {
        .value => |value| try std.testing.expectEqual(@as(usize, 16), value.value),
        .failure => return error.TestUnexpectedResult,
    }
    switch (ByteSize.init(9).alignForward(3, .workspace_bytes)) {
        .value => return error.TestUnexpectedResult,
        .failure => |failure| try std.testing.expectEqual(
            diagnostic.Code.invalid_alignment,
            failure.code,
        ),
    }
    switch (ByteSize.init(std.math.maxInt(usize)).alignForward(8, .workspace_bytes)) {
        .value => return error.TestUnexpectedResult,
        .failure => |failure| try std.testing.expectEqual(
            diagnostic.Code.capacity_overflow,
            failure.code,
        ),
    }
}

test "budget reservations are exact and transactional" {
    var budget = Budget.init(.persistent_bytes, 8);

    try std.testing.expectEqual(Reservation.committed, budget.reserve(8));
    try std.testing.expectEqual(@as(usize, 8), budget.current);
    try std.testing.expectEqual(@as(usize, 8), budget.peak);

    const rejected = budget.reserve(1);
    switch (rejected) {
        .committed => return error.TestUnexpectedResult,
        .rejected => |failure| try std.testing.expectEqual(
            diagnostic.Code.capacity_exceeded,
            failure.code,
        ),
    }
    try std.testing.expectEqual(@as(usize, 8), budget.current);
    try std.testing.expectEqual(@as(usize, 8), budget.peak);

    budget.release(8);
    try std.testing.expectEqual(@as(usize, 0), budget.current);
    try std.testing.expectEqual(@as(usize, 8), budget.peak);
}

test "budget overflow preserves committed state" {
    var budget = Budget.init(.persistent_bytes, std.math.maxInt(usize));
    try std.testing.expectEqual(
        Reservation.committed,
        budget.reserve(std.math.maxInt(usize)),
    );

    const rejected = budget.reserve(1);
    switch (rejected) {
        .committed => return error.TestUnexpectedResult,
        .rejected => |failure| try std.testing.expectEqual(
            diagnostic.Code.capacity_overflow,
            failure.code,
        ),
    }
    try std.testing.expectEqual(std.math.maxInt(usize), budget.current);
    try std.testing.expectEqual(std.math.maxInt(usize), budget.peak);
}

test "limited allocator enforces live and peak byte ceilings" {
    var limited = LimitedAllocator.init(std.testing.allocator, 8);
    const allocator = limited.allocator();

    const exact = try allocator.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), limited.current);
    try std.testing.expectEqual(@as(usize, 8), limited.peak);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(limited.limit_exceeded);

    allocator.free(exact);
    try std.testing.expectEqual(@as(usize, 0), limited.current);
    const reused = try allocator.alloc(u8, 8);
    allocator.free(reused);
    try std.testing.expectEqual(@as(usize, 8), limited.peak);
}

/// Child allocator whose in-place resize decision is fixed by the test.
///
/// The limited allocator's resize and remap paths each branch on what the child
/// says, and both the accepted and the refused branch adjust the live byte
/// count. A general-purpose allocator decides in place resizing for its own
/// reasons, so a test built on one would exercise whichever branch that
/// allocator happened to choose for a particular size class. This one is told.
///
/// Resizes are reported without moving or reallocating anything, so the backing
/// buffer's own bookkeeping must tolerate a length it did not agree to. A fixed
/// buffer does; a checking allocator would not, which is why one is not used.
const FixedDecisionChild = struct {
    backing: std.mem.Allocator,
    accepts_resize: bool,

    fn allocator(self: *FixedDecisionChild) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = childAlloc,
                .resize = childResize,
                .remap = childRemap,
                .free = childFree,
            },
        };
    }

    fn childAlloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FixedDecisionChild = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn childResize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *FixedDecisionChild = @ptrCast(@alignCast(context));
        _ = .{ memory, alignment, new_len, return_address };
        return self.accepts_resize;
    }

    fn childRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FixedDecisionChild = @ptrCast(@alignCast(context));
        _ = .{ alignment, new_len, return_address };
        if (!self.accepts_resize) return null;
        return memory.ptr;
    }

    fn childFree(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *FixedDecisionChild = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

const byte_alignment = std.mem.Alignment.fromByteUnits(@alignOf(u8));

/// The allocation as its owner now sees it after an accepted in-place resize.
///
/// An in-place resize keeps the pointer and changes the length, so the caller's
/// slice has to be retaken at the new length before it can be handed back to
/// the allocator. The backing buffers below are far larger than any length
/// these tests claim.
fn resized(memory: []u8, new_len: usize) []u8 {
    return memory.ptr[0..new_len];
}

test "limited allocator accounts for accepted growth and shrinking" {
    var buffer: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var child: FixedDecisionChild = .{
        .backing = fixed.allocator(),
        .accepts_resize = true,
    };

    var limited = LimitedAllocator.init(child.allocator(), 16);
    const allocator = limited.allocator();

    const memory = try allocator.alloc(u8, 4);
    try std.testing.expectEqual(@as(usize, 4), limited.current);

    // Growing charges the difference, not the new length and not their sum.
    try std.testing.expect(
        allocator.rawResize(memory, byte_alignment, 12, @returnAddress()),
    );
    try std.testing.expectEqual(@as(usize, 12), limited.current);
    try std.testing.expectEqual(@as(usize, 12), limited.peak);

    // Shrinking refunds the difference. The peak is a high-water mark and does
    // not follow it back down.
    try std.testing.expect(
        allocator.rawResize(resized(memory, 12), byte_alignment, 4, @returnAddress()),
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);
    try std.testing.expectEqual(@as(usize, 12), limited.peak);

    // A resize to the same length is neither growth nor shrinkage.
    try std.testing.expect(
        allocator.rawResize(memory, byte_alignment, 4, @returnAddress()),
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);
}

test "limited allocator refuses growth that would exceed its ceiling" {
    var buffer: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var child: FixedDecisionChild = .{
        .backing = fixed.allocator(),
        .accepts_resize = true,
    };

    var limited = LimitedAllocator.init(child.allocator(), 16);
    const allocator = limited.allocator();

    // Nothing has been refused yet, so the flag a caller reads to distinguish
    // a limit refusal from an ordinary allocation failure starts clear.
    try std.testing.expect(!limited.limit_exceeded);

    const memory = try allocator.alloc(u8, 4);
    try std.testing.expect(!limited.limit_exceeded);

    // The ceiling constrains the resulting live total, so a growth of 13 over
    // the 4 already held is one byte too many.
    try std.testing.expect(
        !allocator.rawResize(memory, byte_alignment, 17, @returnAddress()),
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);
    try std.testing.expect(limited.limit_exceeded);

    // Growth to exactly the ceiling is allowed, which pins the boundary the
    // refusal above sits next to.
    try std.testing.expect(
        allocator.rawResize(memory, byte_alignment, 16, @returnAddress()),
    );
    try std.testing.expectEqual(@as(usize, 16), limited.current);
}

test "limited allocator restores its byte count when the child refuses" {
    var buffer: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var child: FixedDecisionChild = .{
        .backing = fixed.allocator(),
        .accepts_resize = true,
    };

    var limited = LimitedAllocator.init(child.allocator(), 16);
    const allocator = limited.allocator();

    const memory = try allocator.alloc(u8, 4);
    child.accepts_resize = false;

    // Growth reserves before asking the child. When the child refuses, the
    // reservation has to be given back, or a rejected resize would permanently
    // consume budget.
    try std.testing.expect(
        !allocator.rawResize(memory, byte_alignment, 12, @returnAddress()),
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);

    // A refused shrink must not refund bytes the child still holds.
    try std.testing.expect(
        !allocator.rawResize(memory, byte_alignment, 2, @returnAddress()),
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);

    // The budget is intact, so a later accepted growth still succeeds.
    child.accepts_resize = true;
    try std.testing.expect(
        allocator.rawResize(memory, byte_alignment, 16, @returnAddress()),
    );
    try std.testing.expectEqual(@as(usize, 16), limited.current);
}

test "limited allocator accounts for remapping the same way as resizing" {
    var buffer: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var child: FixedDecisionChild = .{
        .backing = fixed.allocator(),
        .accepts_resize = true,
    };

    var limited = LimitedAllocator.init(child.allocator(), 16);
    const allocator = limited.allocator();

    const memory = try allocator.alloc(u8, 4);

    try std.testing.expect(
        allocator.rawRemap(memory, byte_alignment, 12, @returnAddress()) != null,
    );
    try std.testing.expectEqual(@as(usize, 12), limited.current);
    try std.testing.expectEqual(@as(usize, 12), limited.peak);

    try std.testing.expect(
        allocator.rawRemap(resized(memory, 12), byte_alignment, 4, @returnAddress()) != null,
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);

    // Over the ceiling, and then exactly at it.
    try std.testing.expect(
        allocator.rawRemap(memory, byte_alignment, 17, @returnAddress()) == null,
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);
    try std.testing.expect(
        allocator.rawRemap(memory, byte_alignment, 16, @returnAddress()) != null,
    );
    try std.testing.expectEqual(@as(usize, 16), limited.current);
}

test "limited allocator restores its byte count when a remap is refused" {
    var buffer: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var child: FixedDecisionChild = .{
        .backing = fixed.allocator(),
        .accepts_resize = true,
    };

    var limited = LimitedAllocator.init(child.allocator(), 16);
    const allocator = limited.allocator();

    const memory = try allocator.alloc(u8, 4);
    child.accepts_resize = false;

    try std.testing.expect(
        allocator.rawRemap(memory, byte_alignment, 12, @returnAddress()) == null,
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);

    try std.testing.expect(
        allocator.rawRemap(memory, byte_alignment, 2, @returnAddress()) == null,
    );
    try std.testing.expectEqual(@as(usize, 4), limited.current);
}
