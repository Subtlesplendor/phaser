# Decision 0012: Retune the mutation rotation after decision 0011

Status: accepted; approved by the repository owner

## Context

Decision 0005 set `GROUP_COUNT: 14` from a measured oracle cost of about 75
seconds per mutant against 686 mutants in 97 cells, sized so the heaviest group
(about 105 mutants) fit comfortably inside a 150-minute ceiling.

Both numbers on that basis have since moved. Decision 0011 cut the oracle's cost
by roughly an order of magnitude by turning off allocation-trace capture in the
tiers the oracle runs. Independently, the mutant count nearly doubled in the two
days after decision 0011 merged, from 908 to 1316, as Milestone 3 work landed:
new files mutate as soon as they exist, with no edit to the rotation required.

The two nightly runs since decision 0011 merged were manual dispatches, and both
landed on the same rotation group by coincidence -- the group index is a
function of the day, not the dispatch, so two dispatches on the same UTC day
compute the same index regardless of when either ran -- and that group happened
to hold zero cells at the time. Neither run exercised a single mutant, so no
observed nightly duration exists yet to retune `GROUP_COUNT` against, which is
the method decision 0005 itself used and the method this decision would prefer.

## Decision

Lower `GROUP_COUNT` from 14 to 6, so a full pass completes in six nights instead
of fourteen, and treat the number as provisional pending a real observed nightly
duration.

The estimate behind 6 rather than a smaller number: a real end-to-end campaign
of one full operator (`logical_and_or`, 90 mutants across the current codebase,
`--jobs 4`) measured 5m16s wall on the supported macOS ARM64 development
machine -- about 14 job-seconds per mutant. Scaling that by 2.5x for a slower
four-core hosted runner, matching decision 0010's assumption for the same
runner, gives about 35 job-seconds per mutant there.

| `GROUP_COUNT` | heaviest group (of 1316 mutants) | estimated wall at `--jobs 4` |
| --- | --- | --- |
| 14 (current) | 165 mutants | about 24 min |
| 6 | 275 mutants | about 40 min |
| 5 | 320 mutants | about 47 min |
| 4 | 460 mutants | about 67 min |

Six leaves the 150-minute ceiling more than 3.5x of margin over the heaviest
estimated group, which absorbs three things the estimate cannot: the hosted
runner may be slower than the 2.5x assumed, other operators may cost more per
mutant than `logical_and_or` did, and the mutant count is still growing quickly.
Four would nearly halve the cycle again but leaves under 2.5x margin against an
estimate with those three unknowns still open.

This retains rotation rather than moving to a single nightly group covering
everything. A full-set estimate is about 1316 mutants * 35 job-seconds / 4 jobs,
around 192 minutes -- over the 150-minute ceiling even on this estimate, before
accounting for further growth.

## Alternatives

**Leave `GROUP_COUNT` at 14 until a real nightly duration is observed.** Most
faithful to decision 0005's own method, and it spends up to six more nights
running groups sized for a cost that no longer applies, each one many times
short of the budget it was given. The rotation still covers everything
eventually; it just does so needlessly slowly in the meantime.

**Set `GROUP_COUNT` from the full-set estimate to complete in exactly one
night.** Not possible under the 150-minute ceiling on this estimate, and even if
it were, it would remove the margin the rotation is supposed to keep for a
mutant costing more than expected.

**Widen the timeout instead of shrinking `GROUP_COUNT`.** Available if six turns
out too aggressive once real data arrives; not chosen first because the number
this decision is short on is confidence in the per-mutant cost, not clock
budget, and the existing 150-minute ceiling already has room to spare at six.

## Consequences

- A full pass over the mutant set completes in six nights rather than fourteen.
- The estimate is not a measurement. The first scheduled run that lands on a
  nonempty group is what confirms or corrects it.
- Nothing about the rotation's mechanics changes; `tools/ci/mutation_rotation.sh`
  and the hashing it uses are unaffected by `GROUP_COUNT`'s value.

## Revisit when

- A scheduled campaign reports its real per-group duration. Update `GROUP_COUNT`
  from that number rather than from this estimate once it exists.
- The mutant count changes materially again, which recent history says is
  likely: it grew 92% in the two days after decision 0011 merged.
- A group's real duration approaches the 150-minute ceiling, which would call
  for raising `GROUP_COUNT` rather than lowering it.
