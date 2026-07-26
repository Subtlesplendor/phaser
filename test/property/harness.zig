//! Phaser-owned property-testing interface.
//!
//! Wraps the approved Minish dependency, recorded in
//! `docs/decisions/0004-property-testing-dependency.md`. Property tests use this
//! module rather than Minish directly, so the dependency stays behind a Phaser
//! boundary and can be replaced without touching a single property.
//!
//! Ordinary campaigns deliberately leave the seed unspecified, so Minish
//! chooses a fresh seed for each process and explores new cases on every run.
//! Minish prints that seed, the failing input, and its shrunk form whenever a
//! property fails. A seed is accepted here only for an intentional reproduction
//! run; it is never part of a default budget.
//!
//! Failures add the configuration §8 requires: the property name, run budget,
//! build mode, and target. Together with Minish's seed and minimized input, that
//! is enough to reproduce the failure and turn it into a permanent regression.
//!
//! Properties run from a bounded campaign executable rather than from the Zig
//! test runner, in the same way as the fuzz and benchmark drivers. Minish reports
//! progress unconditionally on the standard streams, and
//! `ENGINEERING_STYLE.md` requires tests to leave those streams to the build and
//! test runners' coordination protocol.

const std = @import("std");
const builtin = @import("builtin");
const minish = @import("minish");

pub const gen = minish.gen;
pub const combinators = minish.combinators;

/// A bounded property-test budget.
///
/// Property tests are cheap enough to run on every change, unlike a fuzz
/// campaign, so the default budget is exercised by `zig build test`.
pub const Budget = struct {
    /// Randomized cases for each property.
    runs: u32,
    /// Set only to reproduce a previously reported failure.
    seed: ?u64 = null,
    max_shrink_attempts: u32 = 1000,

    pub fn cases(self: Budget) usize {
        return self.runs;
    }
};

/// Budget for ordinary development and pull-request runs.
pub const standard = Budget{
    .runs = 100,
};

/// Wider budget for scheduled runs, where a longer stream is affordable.
pub const extended = Budget{
    .runs = 2000,
};

/// Checks `property` over values from `generator`.
///
/// `name` appears in failure output and is the identifier a regression fixture
/// should refer to.
pub fn check(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    generator: anytype,
    property: anytype,
    budget: Budget,
) !void {
    var options = minish.Options{
        .num_runs = budget.runs,
        .max_shrink_attempts = budget.max_shrink_attempts,
    };
    if (budget.seed) |seed| options.seed = seed;

    minish.check(allocator, generator, property, options) catch |err| {
        reportFailure(name, budget, err);
        return err;
    };
}

fn reportFailure(
    comptime name: []const u8,
    budget: Budget,
    err: anyerror,
) void {
    std.debug.print(
        \\
        \\phaser property failure
        \\  property      {s}
        \\  error         {s}
        \\  runs          {d}
        \\  build_mode    {s}
        \\  target        {s}-{s}
        \\  reproduce     zig build test-property -- --seed <seed reported above>
        \\
        \\A minimized failure becomes a permanent regression test, per
        \\DEVELOPMENT_WORKFLOW section 8.
        \\
    , .{
        name,
        @errorName(err),
        budget.runs,
        @tagName(builtin.mode),
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
    });
}

test "the standard budget runs one hundred fresh cases" {
    try std.testing.expectEqual(@as(u32, 100), standard.runs);
    try std.testing.expectEqual(@as(usize, 100), standard.cases());
    try std.testing.expectEqual(@as(?u64, null), standard.seed);
}

test "default budgets leave seed selection to Minish" {
    for ([_]Budget{ standard, extended }) |budget| {
        try std.testing.expectEqual(@as(?u64, null), budget.seed);
    }
}
