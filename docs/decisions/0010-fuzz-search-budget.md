# Decision 0010: The fuzz tier's allocator and search budget

Status: accepted; approved by the repository owner

## Context

The nightly fuzz campaign is specified by DEVELOPMENT_WORKFLOW.md section 5.3 as
a ten to thirty minute tier, and section 7 counts a memory leak as a fuzz
failure in its own right. Both were being paid for, and neither was being
delivered.

Every target allocated through `std.testing.allocator`. That allocator is a
`DebugAllocator` configured with `stack_trace_frames = 10`, so it captures a
backtrace on every allocation and every free. Under a campaign that is nothing
but allocation-heavy exact arithmetic, capturing those backtraces cost more than
the arithmetic being tested: DWARF unwinding dominates a profile of the heaviest
target, and its resident set reached gigabytes holding metadata for allocations
that had already been freed.

The consequence was a budget nobody could spend. The first scheduled campaign
asked for 2,000,000 inputs per target, which measured as roughly a day of work
for one target; the job was cancelled at its ceiling every night having reported
nothing. Sizing the budget to what that allocator could actually finish
(decision recorded in the nightly workflow, 5K per target) kept the tier honest
but bought a search two orders of magnitude smaller than the tier is for.

## Decision

Fuzz targets allocate through a private `DebugAllocator`, default-configured,
declared in `test/fuzz/root.zig` as `iteration_allocator`. In ReleaseSafe a
default configuration captures no stack traces while keeping every other check:
leak accounting, canaries, double-free detection, and use-after-free detection
through unmapped pages.

Leak detection stays per input, not per campaign. The test runner resets and
checks `std.testing.allocator` around every fuzz input on its own; a private
allocator has to say so, and `leakChecked` wraps each target at its
`std.testing.fuzz` call site to reset the allocator before an input and fail the
campaign if that input leaked. Wrapping at the call site keeps the check to one
visible place per target rather than two lines inside eight functions.

The per-target budget rises from 5K inputs to 500K, and the campaign keeps the
35-minute wall-clock backstop that reports rather than fails when it is reached.

### What this trades away

A leak report names the leaked address and size but not the allocation site.
That is the whole cost, and it is paid only in the tier that cannot afford the
alternative. `DebugAllocator`'s default frame count follows the build mode: none
in ReleaseSafe, which is what the campaign runs, and six in Debug, which is what
`zig build fuzz` runs locally. The reproduction path section 7 already
prescribes -- commit the saved input to the target's corpus and replay it --
therefore reports the leak with its allocation site without anyone doing
anything differently. Traces are bought on the one input that failed instead of
on the hundreds of thousands that did not.

## Measurements

Cold `.zig-cache/f`, ReleaseSafe, supported macOS ARM64 development machine, ten
cores, eight targets. `value_ir_builder` is the heaviest target throughout; its
exact-rational graph building dominates the campaign.

Allocator comparison at 1000 inputs per target:

| allocator | three heaviest targets | heaviest MaxRSS |
| --- | --- | --- |
| `std.testing.allocator` | 43s, 22s, 21s | 1 GiB |
| private `DebugAllocator`, leak-checked per input | ~1s each | 4 MiB |
| `smp_allocator`, no leak detection | ~1s each | 6 MiB |

Dropping leak detection entirely buys nothing over keeping it, which is what
settles the choice: `smp_allocator` measured no faster than the leak-checking
`DebugAllocator` and would give up the leak, double-free, and use-after-free
reports that section 7 treats as fuzz failures.

Budget scaling under the adopted allocator:

| inputs per target | whole set, wall | heaviest target | heaviest MaxRSS |
| --- | --- | --- | --- |
| 200K | 2m00s | 1m | 5 MiB |
| 500K | 4m20s | 4m | 6 MiB |
| 1M | 12m35s | 12m | 6 MiB |

Cost per input rises as the coverage-guided corpus grows, so the budget is not a
free dial: five times the inputs cost twelve times the time between 200K and 1M.
500K is the last step with headroom left. For comparison, the previous allocator
needed 3m36s for 5K per target, so the adopted budget is a hundred times the
search in about the same wall clock, and resident memory now stays under 30 MiB
per target instead of reaching gigabytes.

The estimate for a four-core hosted runner scales the local makespan by roughly
two and a half for slower cores, which puts the heaviest target near ten minutes
and the campaign inside section 5.3's target. A budget of 1M would spend the
whole 35-minute backstop there. The backstop exists because these are estimates.

## Alternatives

**Keep `std.testing.allocator` and accept a small budget.** This is the state
this decision replaces. It is the only option that keeps allocation-site traces
on every input, and it costs about ninety-nine percent of the search to do it.

**`smp_allocator` or an arena reset per input.** Faster to write and no faster to
run, and both discard the memory-safety checking the fuzz tier exists to apply.
An arena additionally stops exercising the library's own free paths, so
double-free and use-after-free defects would become unreachable for this tier.

**A production-representative allocator, for realism.** `DebugAllocator` is
deliberately unrealistic: page-granular allocations and no prompt address reuse.
It is unrealistic in the strict direction, trapping what a production allocator
would silently tolerate. Realism about allocator behavior, if it is wanted
later, belongs in a separate narrow run rather than in a weakening of all eight
targets.

## Consequences

- The nightly campaign searches two orders of magnitude more inputs per night
  within the same tier budget.
- A leak found by the campaign is reported without its allocation site. The
  site comes back on the Debug replay that the corpus protocol already requires,
  so no additional step enters the failure protocol.
- A new fuzz target that is not wrapped in `leakChecked` silently loses per-input
  leak detection. The wrapper is applied at the one call site per target where a
  reader is already looking at how the target is registered.
- The local corpus-growing recipe in DEVELOPMENT_WORKFLOW.md section 7 becomes
  practical: `--fuzz=2M` there was previously about a day of work.

## Risks

- The budget is sized from a development machine and estimated for the runner.
  If the estimate is wrong the campaign reaches its wall-clock backstop, which
  reports and passes rather than failing, and the observed timings in the job
  summary are what corrects the number.
- Targets are unequal by roughly two orders of magnitude, and the heaviest one
  sets the campaign's makespan. A new heavy target changes the budget's meaning
  without changing its value.

## Revisit when

- A scheduled campaign reaches its wall-clock backstop on consecutive nights.
- A fuzz target is added whose cost per input is comparable to
  `value_ir_builder`.
- The pinned toolchain changes how `std.testing.fuzz` schedules inputs, or makes
  the testing allocator's trace capture configurable.
