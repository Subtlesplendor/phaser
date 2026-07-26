//! Phaser-owned property-testing interface.
//!
//! Wraps the approved Minish dependency, recorded in
//! `docs/decisions/0004-property-testing-dependency.md`. Property tests use this
//! module rather than Minish directly, so the dependency stays behind a Phaser
//! boundary and can be replaced without touching a single property.
//!
//! Two policies are enforced here rather than left to each caller.
//!
//! Seeds are always explicit. Minish derives a seed from address-space layout
//! when none is given, which would make a pull-request run nondeterministic;
//! `DEVELOPMENT_WORKFLOW.md` §8 requires fixed seed sets instead. Every budget
//! below carries its seeds, and no code path reaches Minish without one.
//!
//! Failures report the configuration §8 requires: the property name, the seed
//! that produced the failure, the run budget, the build mode, and the target.
//! Minish prints the failing input and its shrunk form; this adds the context
//! needed to reproduce the run rather than just the value.
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

/// A deterministic run budget.
///
/// Property tests are cheap enough to run on every change, unlike a fuzz
/// campaign, so the default budget is exercised by `zig build test`.
pub const Budget = struct {
    /// Randomized cases per seed.
    runs: u32,
    /// Fixed seeds. Every one is executed, so a property is checked
    /// `runs * seeds.len` times in total.
    seeds: []const u64,
    max_shrink_attempts: u32 = 1000,

    pub fn cases(self: Budget) usize {
        return @as(usize, self.runs) * self.seeds.len;
    }
};

/// Budget for ordinary development and pull-request runs.
///
/// Three fixed seeds rather than one, because a single seed's stream can miss a
/// whole region of the input space and the cost of two more is negligible.
pub const standard = Budget{
    .runs = 100,
    .seeds = &.{ 0x9e3779b97f4a7c15, 0x0123456789abcdef, 0xdeadbeefcafef00d },
};

/// Wider budget for scheduled runs, where a longer stream is affordable.
pub const extended = Budget{
    .runs = 2000,
    .seeds = &.{
        0x9e3779b97f4a7c15,
        0x0123456789abcdef,
        0xdeadbeefcafef00d,
        0x5851f42d4c957f2d,
        0x14057b7ef767814f,
    },
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
    for (budget.seeds) |seed| {
        minish.check(allocator, generator, property, .{
            .num_runs = budget.runs,
            .seed = seed,
            .max_shrink_attempts = budget.max_shrink_attempts,
        }) catch |err| {
            reportFailure(name, seed, budget, err);
            return err;
        };
    }
}

fn reportFailure(
    comptime name: []const u8,
    seed: u64,
    budget: Budget,
    err: anyerror,
) void {
    std.debug.print(
        \\
        \\phaser property failure
        \\  property      {s}
        \\  error         {s}
        \\  seed          0x{x:0>16}
        \\  runs_per_seed {d}
        \\  build_mode    {s}
        \\  target        {s}-{s}
        \\  reproduce     set the budget to a single seed 0x{x:0>16}
        \\
        \\A minimized failure becomes a permanent regression test, per
        \\DEVELOPMENT_WORKFLOW section 8.
        \\
    , .{
        name,
        @errorName(err),
        seed,
        budget.runs,
        @tagName(builtin.mode),
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        seed,
    });
}

test "the standard budget is deterministic and nonempty" {
    try std.testing.expect(standard.seeds.len >= 1);
    try std.testing.expect(standard.runs >= 100);
    try std.testing.expectEqual(@as(usize, 300), standard.cases());
}

test "every budget carries explicit seeds" {
    // A budget without seeds would fall through to Minish's address-derived
    // default, which is exactly the nondeterminism the policy forbids.
    for ([_]Budget{ standard, extended }) |budget| {
        try std.testing.expect(budget.seeds.len != 0);
        for (budget.seeds) |seed| try std.testing.expect(seed != 0);
    }
}
