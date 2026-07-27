//! The allocator the integration, conformance, and differential tiers allocate
//! through, and the one knob that makes the mutation oracle affordable.
//!
//! `std.testing.allocator` is a `DebugAllocator` with `stack_trace_frames = 10`,
//! so it captures a backtrace on every allocation and every free. In these
//! tiers, which build and compare exact-rational structures, capturing those
//! costs more than the arithmetic: measured on the supported development
//! machine, the conformance tier runs in 50 seconds with traces and 1 second
//! without, and the whole mutation oracle in 74 seconds against 7.
//!
//! That trade is worth making for the oracle and not for a human. A developer
//! reading a leak wants the allocation site; the mutation campaign re-runs this
//! suite once per mutant and never reads one, because a mutant's leak is a kill
//! signal rather than a defect to debug. So the traces stay on by default and
//! `zentinel.toml` turns them off for the oracle alone.
//!
//! Colocated unit tests in `src/` keep `std.testing.allocator` unconditionally.
//! They cost about a second, and they are where a leak's site is read most.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

/// Allocate through this rather than `std.testing.allocator`.
///
/// With traces, this *is* `std.testing.allocator`, so the test runner's own
/// per-test leak check applies unchanged. Without them, it is a private
/// `DebugAllocator` that keeps every check except the captured backtrace: leak
/// accounting, canaries, double-free and use-after-free detection.
pub const allocator = if (config.capture_traces)
    std.testing.allocator
else
    untraced.allocator();

var untraced: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;

/// Fail if anything allocated through `allocator` is still live.
///
/// Nothing checks a private allocator on a test's behalf: the runner resets and
/// checks `std.testing.allocator` after every test, and knows nothing about this
/// one. Each tier root therefore calls this in a final test, which is a weaker
/// check than the runner's -- it names the tier rather than the test, and it
/// arrives at the end of the tier rather than at the end of the test that
/// leaked. It is enough for what the untraced mode is for: a mutant that leaks
/// still fails the oracle and is still killed.
///
/// With traces this is a no-op, because the runner has already made the
/// stronger check after each test.
pub fn expectNoLeaks() !void {
    if (config.capture_traces) return;
    // Reports each live allocation on stderr as it counts them.
    if (untraced.detectLeaks() != 0) return error.TierLeakedMemory;
}

/// Fail unless the leak check named by `check_suffix` is declared after every
/// test belonging to the files named by `tier_markers`.
///
/// Zig runs a root file's own tests before the tests of the files that root
/// imports, so a check written at the bottom of a tier root runs first and sees
/// an empty allocator. The check lives in its own file, imported last, and this
/// asserts that placement rather than trusting it: an import added after the
/// check, or a renamed check, fails here instead of silently checking nothing.
///
/// Matching is by tail and substring rather than by whole name, because the
/// runner qualifies a test with the path it was reached through: the same test
/// is `leak_check.test.<title>` in the tier's own binary and
/// `conformance.leak_check.test.<title>` in the suite binary that imports the
/// tier.
pub fn expectChecksWholeTier(
    check_suffix: []const u8,
    tier_markers: []const []const u8,
) !void {
    const check_index = for (builtin.test_functions, 0..) |function, index| {
        if (std.mem.endsWith(u8, function.name, check_suffix)) break index;
    } else return error.LeakCheckNotFound;

    for (builtin.test_functions[check_index + 1 ..]) |function| {
        for (tier_markers) |marker| {
            if (std.mem.indexOf(u8, function.name, marker) != null) {
                return error.TestDeclaredAfterLeakCheck;
            }
        }
    }
}
