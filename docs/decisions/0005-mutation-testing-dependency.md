# Decision 0005: Zentinel as the mutation-testing dependency

Status: accepted as a nightly experiment, approved by the repository owner

## Context

Phaser has no measurement of test strength. The suite reports that it passes,
and the coverage of a line is never in question because the deterministic tiers
execute nearly all of the library, but nothing says whether a test would notice
if the line computed the wrong answer. That distinction matters more here than
in most projects: the exact arithmetic, capacity accounting, and comparison
boundaries this library is built from fail by returning a plausible wrong number,
not by crashing.

Fuzzing does not answer the question either. It searches for inputs that break
the code; mutation testing breaks the code and asks whether the existing inputs
notice. The two are complementary, and the fuzz tier is already the most
expensive thing the project runs.

## Decision

Phaser adopts Zentinel for mutation testing, as a nightly experiment.

- **Dependency**: `zentinel`, version 0.1.0, from
  `https://github.com/oly-wan-kenobi/zentinel`, pinned by tag and content hash
  in `build.zig.zon`.
- **License**: MIT.
- **Capability**: generation of single-token source mutations, execution of a
  declared test command against each one in an isolated workspace, and a report
  of which mutations the suite failed to notice.
- **Boundary**: it is an external client, not a library. No Phaser source file
  imports it, no Phaser module links it, and no published interface exposes a
  Zentinel type. It is reachable only through the `mutation` build step, which
  runs the built executable against the working tree.
- **Role**: test-only, and further, tooling-only. It never participates in a
  build that produces a Phaser artifact, so its allocation, threading, and
  floating-point behavior cannot affect a scientific result.

The dependency is declared `lazy`. An ordinary `zig build`, the whole test
suite, and every pull-request job resolve nothing and fetch nothing; only
`zig build mutation` fetches it. The README's claim that the bounded commands
require no network resources after the pinned toolchain is installed therefore
still holds.

Zentinel's advisory AI features are disabled in `zentinel.toml` and are not
used. Phaser's verification evidence is produced by the suite. This tier must
not acquire a network dependency or a nondeterministic input.

### The oracle

Mutants are run against `zig build test-mutation`, which is `zig build test`
without the fuzz tier:

- fuzz seed replay would add another test binary to every mutant's compile, and
  each mutant already pays for a rebuild; and
- a mutant killed only by a committed corpus entry says less about the
  deterministic suite than the same mutant surviving it.

The step is a strict subset of `test`, so a mutation kill can never depend on a
check the pull-request suite does not also run. Live fuzzing is untouched.

### The tier

The campaign runs nightly and never on a pull request, under a rotation, and
does not fail on survivors.

A whole-repository campaign is not affordable on any schedule the project would
accept. The measurements are below. A survivor is also not a regression in the
commit under test: it is a standing fact about the suite that was equally true
yesterday. Failing the job on one would make every night after the first red
until someone wrote a test, which is a worklist, not a signal.
`--fail-on-survivors` is therefore deliberately absent. Zentinel still exits
non-zero when the baseline fails or the tool itself errors, and that does fail
the job.

## Measurements

Taken on the supported macOS ARM64 development machine (12 cores) at commit
`82160da`, in Debug:

| Quantity | Value |
| --- | --- |
| Mutants over `src/**`, stable operator set | 686 |
| Distinct (file, operator) cells | 97 |
| One oracle run, cold cache | about 75 s |
| Whole-repository campaign, serial | about 15 h |
| Whole-repository campaign, `--jobs 4` | about 2.5 h |

Throughput with `--jobs 4` measured about 4.3x serial, because a worker spends
most of its time compiling rather than running tests.

The rotation schedules one (file, operator) cell at a time rather than one file.
Cells are what the pinned Zentinel can select, and they divide the work far more
finely: `src/expression/root.zig` alone carries 142 mutants, so a file-granular
rotation could never make a night smaller than that, while the largest single
cell is 43.

### Coverage before balance

A cell's group is a hash of the cell's own name. The obvious alternative packs
cells by descending mutant count into whichever group is lightest, which
produces exactly even groups of 49, and it was implemented first and rejected on
measurement.

Packing makes a cell's group depend on every other cell, and the listing is
regenerated nightly, so the schedule reshuffles as the repository changes:

| Change to the repository | Existing cells that changed group |
| --- | --- |
| One added mutant | 51 of 96 |
| One added source file | 72 of 96 |

Simulating fourteen nights with one new mutant per day, that scheduler visited
51 of 96 cells and never reached the other 45. It advanced more slowly than it
reshuffled, so "a full pass every fourteen nights" was not true of it in any
repository under active development.

Hashing the cell name makes a cell's group independent of everything else. The
same two perturbations move zero cells, and the same fourteen-night simulation
reaches 96 of 96. Every cell that exists for a whole cycle is visited exactly
once per cycle, and a new cell joins the rotation without displacing any other.

The price is evenness. A hash cannot know that one cell holds 43 mutants and
another holds one, so on the current listing groups range from 6 to 105 mutants
against an average of 49, and the nightly timeout is sized for the heavy end.
That is the right trade: an uneven schedule that covers everything is useful,
and an even one that covers half of it is not.

Growth is absorbed automatically in one direction only. New files and new
mutants join the rotation with no edit, but the cost of a night grows with them,
and `GROUP_COUNT` is the knob for that. Note also that mutants come from `src/`
while the oracle's cost comes from the test suite, so the two grow independently
and multiply: a larger library means more mutants per night, and a larger suite
means each mutant costs more. Neither is bounded by anything here.

## Alternatives

There is no other mutation-testing tool for Zig. The search that found Zentinel
turned up property-based and metamorphic testing libraries, which answer a
different question, and no mutation tool at all.

A Phaser-owned mutation harness was rejected. Generating mutants is the easy
part; the cost is in workspace isolation, per-mutant cache management, result
caching, timeout handling, and equivalent-mutant filtering, none of which has
scientific content and all of which Zentinel already has.

Doing nothing was rejected because the question is real and currently
unanswered, and because the first campaign answered it immediately, below.

## Consequences

The first scoped campaign, 27 mutants over `src/foundation/capacity.zig`, killed
16 and left 8 alive. Every survivor sits in the `resize` and `remap` paths of
`LimitedAllocator`, between lines 177 and 220:

- `if (new_len > memory.len)` may become `>=`;
- `const growth = new_len - memory.len` may become `+`; and
- `self.current -= memory.len - new_len` may become `+`.

Each of those is a live byte-accounting error in an allocator whose entire
purpose is to enforce a byte ceiling, and no test in any tier notices. That code
arrived in commit `a6464d4` on the day this experiment was run, which is a fair
illustration of the gap: it was reviewed, it is exercised, and its arithmetic is
unconstrained.

A second survivor, in `src/foundation/source.zig:45`, inverts the return of the
source-length bound check with no test distinguishing the result.

None of these are fixed here. This branch adds the measurement, not the tests it
calls for.

A cost worth stating plainly: this tier roughly doubles the nightly compute the
project uses. It buys a class of information no other tier produces.

## Risks

Zentinel is a single-author project with one release, no dependents, and no
users other than Phaser. That is a real supply-chain and maintenance risk, and
the mitigations are structural rather than reassuring words: it is pinned by
content hash, it is lazy so it never enters an ordinary build, it is test-only
so it cannot reach a scientific result, and removing it costs one build step,
one configuration file, one CI job, and one script.

Its published documentation describes the tool at upstream `main`, which is
ahead of the pinned v0.1.0. In particular the `--changed-only`, `--diff`, and
`--scope-files` options that documentation describes do not exist in v0.1.0;
`tools/ci/mutation_rotation.sh` scopes runs through generated configuration
files instead. Read the tagged source, not the documentation, when changing
this integration.

One mutant crashed the Zig compiler rather than failing to compile. Zentinel
recorded it as `compiler_crash` and continued, which is the correct behavior,
but it is a reminder that this tier compiles deliberately malformed code.

## Revisit when

Revisit this decision if a Zentinel release ships file or diff scoping, which
would replace the rotation script with a flag; if Zentinel stops being
maintained or acquires transitive dependencies; if the nightly cost stops being
worth the findings; or once the survivors this tier reports have been driven
down far enough that a survivor threshold and `--fail-on-survivors` become
meaningful. The experiment should be judged on whether the second and third
rotations still find survivors worth fixing.
