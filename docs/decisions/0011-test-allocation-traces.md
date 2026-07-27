# Decision 0011: Allocation traces in the test tiers

Status: accepted; approved by the repository owner

## Context

Decision 0005 sized the mutation campaign around a measured oracle cost of about
75 seconds per mutant. Because a mutant pays for a full cold-cache run of
`zig build test-mutation`, that number sets the rotation: 14 nights for one pass
over the mutant set, and a nightly ceiling provisioned for the heaviest group.

Decision 0010 found that the fuzz tier was spending nearly all of its budget
capturing allocation backtraces rather than searching. The same question applies
to the oracle, and the answer is the same. `std.testing.allocator` is a
`DebugAllocator` with `stack_trace_frames = 10`, so it captures a backtrace on
every allocation and every free. The conformance and integration tiers build and
compare exact-rational structures, which allocate heavily, and a profile of the
conformance binary is dominated by `captureStackTrace` and DWARF unwinding.

The difference from the fuzz tier is who reads the result. A developer debugging
a leak wants the allocation site and should keep it. The mutation campaign
re-runs this suite once per mutant and reads no leak report at all: a mutant's
leak is a kill signal, not a defect to diagnose.

## Decision

The integration, conformance, and differential tiers allocate through
`test/support/allocator.zig` rather than naming `std.testing.allocator`
directly. That module resolves to one of two allocators:

- **With traces**, the default, it *is* `std.testing.allocator`. Behavior is
  unchanged, including the test runner's per-test leak check.
- **Without traces**, selected by `-Dtest-allocation-traces=false`, it is a
  private `DebugAllocator` configured with `stack_trace_frames = 0`, which keeps
  leak accounting, canaries, double-free and use-after-free detection.

`zentinel.toml` passes `-Dtest-allocation-traces=false`; nothing else does. Every
pull-request check, every nightly job other than mutation, and every local
`zig build test` keeps full traces.

Colocated unit tests in `src/` keep `std.testing.allocator` unconditionally.
They cost about a second, and they are where a leak's site is read most.

### Leak detection without the runner

The test runner's automatic leak check applies to `std.testing.allocator` and
nothing else, so the untraced mode has to check its own allocator. Each tier
gets a `leak_check.zig` holding one test that fails if anything allocated
through the tier's allocator is still live.

That check is weaker than the runner's in two ways, both accepted: it names the
tier rather than the test that leaked, and it reports at the end of the tier
rather than at the end of the test. Neither weakens a mutation kill, which is
the only consumer of the untraced mode.

Placement matters more than it looks. Zig runs a root file's own tests *before*
the tests of the files that root imports, so the check written at the bottom of
a tier root ran first and silently checked an empty allocator. It therefore
lives in its own file, imported last, and `expectChecksWholeTier` asserts that
placement: an import added after it, or a renamed check, fails the tier instead
of quietly checking nothing.

## Measurements

Cold cache, Debug, supported macOS ARM64 development machine.

| tier | with traces | without | factor |
| --- | --- | --- | --- |
| conformance (49 tests) | 50s | 1.0s | 50x |
| integration (37 tests) | 19s | 0.6s | 32x |
| differential (5 tests) | 8s | 0.4s | 20x |
| colocated unit tests (145 tests) | 1s | 1s | unchanged |
| **`zig build test-mutation`, cold** | **1m17s** | **7s** | **11x** |

Resident memory for the conformance binary falls from 516 MiB to 6 MiB.

The mutation campaign runs on `ubuntu-24.04`, where unwinding costs differ from
macOS ARM64. The direction is not in doubt; the factor there is unmeasured, and
the first scheduled campaign after this change is the measurement.

## Alternatives

**Reset and check the allocator inside every test.** This is what the fuzz tier
does at its eight `std.testing.fuzz` call sites, and it recovers per-test
attribution. The test tiers have roughly ninety tests and no single wrapping
point, so the same technique would mean ninety hand-written pairs of lines that
a new test can silently omit.

**Drop leak detection in the oracle entirely.** Simpler, and it gives up kill
power the tier is entitled to: a mutant whose only effect is a leak would
survive. DEVELOPMENT_WORKFLOW.md section 7 counts a leak as a first-class
failure, so the oracle should be able to notice one.

**Turn traces off everywhere.** Fastest, and wrong: the allocation site is what
makes a leak reported by a pull-request check or the nightly Debug job
actionable, and those runs are not repeated ten thousand times.

**Leave the oracle as it was.** Correct and affordable only because the rotation
was stretched to 14 nights to pay for it.

## Consequences

- A mutant costs roughly an order of magnitude less, so decision 0005's rotation
  is now provisioned far too conservatively. `GROUP_COUNT` should be re-derived
  from an observed nightly rather than from this local estimate.
- A leak found by the mutation oracle names the tier, not the test. Reproducing
  it with the default build restores per-test attribution and the site.
- Test tiers gain one file each and a build option, and no longer name
  `std.testing.allocator` directly.

## Revisit when

- A scheduled mutation campaign reports its real per-mutant cost, which is when
  `GROUP_COUNT` should change.
- The pinned toolchain makes the testing allocator's trace capture configurable,
  or gives the test runner a hook for a custom allocator's per-test check. Either
  would let the untraced mode recover per-test attribution.
- A tier other than mutation wants the untraced mode, which would mean revisiting
  whether per-tier leak reporting is still enough.
