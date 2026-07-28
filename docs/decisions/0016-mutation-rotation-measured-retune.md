# Decision 0016: Retune the mutation rotation from a real campaign

Status: accepted; approved by the repository owner

## Context

Decision 0012 set `GROUP_COUNT: 6` from an estimate: one local end-to-end
measurement of a single operator, scaled by an assumed 2.5x factor for a slower
hosted runner. It could not do better, because no scheduled or dispatched
nightly had ever actually run a mutant. The rotation's "Plan tonight's rotation
group" step invoked `tools/ci/mutation_rotation.sh` without connecting the
mutant listing to its standard input, which the script reads from by its own
documented usage; every group therefore reported empty, unconditionally, on
every one of the eight nightly runs in this project's history before the fix
that (per the pull request fixing it) landed after decision 0012.

The first campaign to actually run mutants completed the night that fix
merged: `GROUP_COUNT: 6`, rotation group 4, 275 mutants across six operators,
in 49 minutes 53 seconds against the 150-minute ceiling.

## Measurements

Real per-operator wall time at `--jobs 4`, from that campaign's own per-group
timestamps (each operator is a separate zentinel invocation within the step, so
the boundary between one operator's result and the next is exact):

| operator | mutants | wall | s/mutant |
| --- | --- | --- | --- |
| arithmetic_add_sub | 11 | 2m07s | 11.52 |
| arithmetic_mul_div | 57 | 7m14s | 7.62 |
| boolean_literal | 56 | 8m15s | 8.85 |
| comparison_boundary | 59 | 10m37s | 10.80 |
| equality_swap | 82 | 20m26s | 14.95 |
| logical_and_or | 10 | 1m13s | 7.33 |
| **all six, this group** | **275** | **49m53s** | **10.88** |

The cheapest and most expensive operators differ by a factor of two. A group's
cost therefore depends on which operators its cells happen to hash into, not
only on its mutant count -- a lesson decision 0012's flat per-mutant estimate
could not see, because it only had one operator's timing to work from.

Applying these six real rates to the current mutant listing (1356 mutants, up
from 1335 the night of the campaign) and reproducing `tools/ci/mutation_rotation.sh`'s
own hashing gives, for each candidate `GROUP_COUNT`, the heaviest group's
mutant count and estimated wall time:

| `GROUP_COUNT` | heaviest group | estimated wall | share of the 150 min ceiling | nights per full pass |
| --- | --- | --- | --- | --- |
| 4 | 462 | ~79 min | 52% | 4 |
| 5 | 327 | ~66 min | 44% | 5 |
| 6 (current) | 281 | ~61 min | 41% | 6 |
| **7** | **242** | **~46 min** | **30%** | **7** |
| 8 | 282 | ~45 min | 30% | 8 |
| 10 | 221 | ~48 min | 32% | 10 |

Applying this model to the group that actually ran (group 4 of 6, before the
mutant count grew from 1335 to 1356) reproduces the observed 49.9 minutes
exactly, which is expected -- the rates come from that same run -- but confirms
the model's arithmetic and the hashing reproduction are both correct, which
matters because every other row is a genuine projection onto data the model
has not seen.

`GROUP_COUNT` does not vary monotonically with headroom: 10 groups is no safer
than 7 or 8 here, because hashing distributes cells without balancing them, and
a higher count can still concentrate expensive cells into one bucket by chance.
Decision 0012 named this cost explicitly; this table is the first direct
evidence of it.

## Decision

Raise `GROUP_COUNT` from 6 to 7.

Seven nights is one full pass per calendar week, which is easy to reason about
and state. Its heaviest group is estimated at about 46 minutes against the
150-minute ceiling -- roughly 3.3x headroom, notably more than six's present
2.5x and closer to what decision 0012 originally intended before real data and
continued growth had both moved the numbers. Eight performs about the same on
this snapshot but buys nothing over seven for one more night per cycle; the
choice between them is not worth more precision than "one full pass a week."

Six is not wrong, but its margin has already eroded from what decision 0012
estimated (61 minutes observed-and-projected against an original 40-minute
estimate) as the mutant count grew through ordinary development, and Milestone
4 work is adding new source files at a pace that continues to reshuffle every
group's composition, cell by cell, unpredictably. Seven's larger margin is
headroom against that continuing, not a one-time correction.

## Alternatives

**Leave `GROUP_COUNT` at 6.** Still safe today (61 of 150 minutes), and it was
the whole point of decision 0012's own margin to absorb exactly this kind of
drift. Not chosen because real per-operator data is now available and it says
a next campaign could plausibly run over 60 minutes on an operator-heavy draw,
which decision 0012 could not have known when it estimated a flat 35
job-seconds per mutant against one operator's cost.

**Lower `GROUP_COUNT` to shorten the coverage cycle**, since 61 minutes still
leaves considerable ceiling. Rejected for the same reason decision 0012 did not
push lower than 6: an estimate (now a measurement) with two remaining
uncertainties -- continued mutant-count growth and per-operator variance --
should keep margin rather than spend it on a faster cycle the project has not
asked for.

**Compute `GROUP_COUNT` from a target wall-clock budget instead of a round
number of nights**, the way the fuzz tier's `FUZZ_BUDGET` works. Rejected for
the reason decision 0005 gives for rotating by cell rather than by clock in the
first place: mutant count and per-mutant cost grow independently, so a
clock-target rotation would silently drop cells from the cycle as the
repository grows, and coverage over time (not evenness within a night) is what
this tier was designed to guarantee. Watching the estimated-heaviest-group
share of the ceiling in this decision's table remains a manual check for now.

## Consequences

- A full pass over the mutant set completes in seven nights.
- Every group's estimated wall time sits at 30-52% of the ceiling on this
  snapshot; the campaign has room to run notably over projection before the
  timeout becomes a live risk.
- The rotation, and this table's projections, are recomputed from the mutant
  listing every night; nothing here is cached or requires a manual update
  except `GROUP_COUNT` itself.

## Revisit when

- A scheduled campaign's actual duration materially exceeds this decision's
  projection for its group, which would mean growth or operator mix moved
  faster than expected.
- The mutant count changes materially again. History across this file's
  predecessor and this one: 686, then 908, 1079, 1316, 1335, 1356 -- all within
  four days.
- A cheaper or more expensive operator is added to `zentinel.toml`'s enabled
  set, which would invalidate the per-operator rates this table is built from.
