# Phaser Development Workflow

Status: initial working agreement

This document specifies how changes move from design through review and
verification into Phaser's main branch. It is the operational companion to
[Phaser Engineering Style](ENGINEERING_STYLE.md). Scientific and software
verification requirements are specified in
[Verification and Testing](docs/architecture/VERIFICATION_AND_TESTING.md).

The workflow will evolve as the implementation and contributor base grow.
Changes may refine its mechanics, but must preserve its correctness,
reproducibility, and review goals.

## 1. Repository and authority

Phaser is developed in a private Git repository hosted on GitHub.

The `main` branch is protected once implementation work begins:

- implementation changes enter through pull requests;
- required checks must pass before merge;
- force pushes and history rewrites are disabled;
- a pull request remains narrow enough to review as one coherent change; and
- `main` remains buildable and suitable as the base for subsequent work.

Documentation-only corrections MAY use a proportionately lighter check set, but
changes to scientific contracts, public formats, architecture, or engineering
policy receive the same deliberate review as code.

The repository owner retains merge and release authority. An implementing agent
MUST NOT merge a pull request, create a release or tag, publish an artifact, or
change repository protection without explicit permission.

Server-side branch protection requires a paid plan for a private repository and
is currently unavailable. Local hooks in `.githooks/` refuse a commit or push on
`main` in its place. They are advisory: enable them per clone with

```sh
git config core.hooksPath .githooks
```

A clone that has not done so is unprotected, and `--no-verify` bypasses them
deliberately. They are a guard against mistakes, not an authorization boundary.

Phaser initially uses squash merging. The resulting commit on `main` MUST
describe one coherent change and preserve the pull request as the detailed
review record.

## 2. From design to implementation

Before implementation begins, a change must have enough design context to state:

- the supported scientific and software behavior;
- explicit non-goals and unsupported cases;
- the invariants established at each affected boundary;
- structural and dynamic inputs;
- ownership, allocation, and resource bounds;
- error, assertion, and failure-atomicity behavior;
- verification and independent oracle;
- expected performance-sensitive paths; and
- compatibility or versioning consequences.

The relevant subsystem specification is updated before or with its
implementation. A material mismatch between implementation and specification is
resolved deliberately; neither is silently treated as authoritative.

Consequential architectural or scientific choices whose rationale would not be
obvious from the resulting specification SHOULD receive a short decision record
under `docs/decisions/`. A decision record includes the context, selected choice,
important alternatives, and conditions under which the choice should be
revisited.

## 3. Branches, commits, and pull requests

Development branches are short-lived and single-purpose. Unrelated cleanup is
kept out of a feature or correction unless it is required to make the change
safe.

Intermediate commits on a branch may support review and experimentation. Before
merge, the complete pull request must be understandable and its squash-merge
message must describe the final behavior rather than the sequence of attempts.

Every implementation pull request states, as applicable:

- what behavior changed and why;
- the specification or decision record governing it;
- scientific conventions and approximation boundaries;
- tests, properties, fuzz targets, and reference evidence added or changed;
- resource, allocation, concurrency, ABI, and compatibility effects;
- representative performance evidence for a performance-sensitive change;
- new diagnostics or intentionally unsupported cases;
- external dependencies proposed or used within previously approved scope; and
- remaining limitations or deliberately deferred work.

A pull request MUST NOT hide a known correctness problem behind a future task.
Large work is divided into independently correct vertical changes rather than
merged as inactive scaffolding.

Golden-file changes state why the expected result changed. Regenerating or
accepting new output is not by itself evidence of correctness.

## 4. Required change checks

The exact build-step names are introduced only when they execute real work.
Conceptually, a change is checked through:

1. formatting and static build checks;
2. bounded deterministic tests;
3. relevant bounded property and metamorphic tests;
4. regression-corpus replay;
5. examples and public-interface checks;
6. required native build modes and platforms; and
7. performance measurement where the change affects a hot path.

Tests are not automatically retried. A flaky test is a defect to diagnose, not a
condition to mask.

## 5. Test and CI tiers

### 5.1 Local fast checks

During development, run formatting, affected unit and integration tests,
bounded property cases, and the relevant permanent regression corpus.
Before requesting review, run the complete bounded per-change suite when
practical.

### 5.2 Pull-request checks

Every implementation pull request runs:

- the bounded unit, integration, and regression suites;
- small bounded property budgets with fresh seeds;
- the relevant conformance fixtures and examples;
- Debug and ReleaseSafe behavior;
- ReleaseFast differential behavior once a ReleaseFast, safety-disabled leaf,
  optimized, or AOT path exists whose comparison is meaningful;
- public header and client smoke tests once those surfaces exist; and
- replay of every committed fuzz and regression input.

Live coverage-guided fuzzing does not run as a required pull-request check. Every
committed fuzz input is still replayed before merge. Changes to a high-risk
parser, model loader, request parser, kernel lowering, ABI boundary, or fuzz
harness SHOULD receive a manually launched campaign before merge; nightly
campaigns continuously cover the complete target set.

The pull-request matrix covers these concerns without taking their full Cartesian
product. Linux x86-64 runs the deterministic core in Debug, the complete bounded
suite in ReleaseSafe, and the differential suite in ReleaseFast. macOS ARM64 runs
the complete bounded suite in ReleaseSafe, including the standard property
budget. Broader build-mode and native-platform combinations remain scheduled
checks. A push to `main` repeats repository checks and the Linux ReleaseSafe
suite against the published commit, rather than repeating the complete
pull-request matrix.

### 5.3 Nightly checks

Scheduled checks on the latest `main` include:

- larger randomized property budgets;
- multi-core coverage-guided and stateful fuzzing;
- representative allocation-failure and exact-capacity campaigns at ownership,
  publication, and workspace boundaries;
- larger conformance fixtures;
- broader native platform and build-mode coverage;
- generated-file reproducibility checks;
- selected numerical and concurrency stress tests; and
- one rotation group of the mutation campaign.

An initial target budget of roughly 10 to 30 minutes is appropriate for nightly
fuzzing. If the number of targets makes that too expensive, targets rotate on a
documented schedule while the most important trust boundaries continue to run
nightly.

What that budget buys depends on what the targets allocate through. Fuzz targets
use a private allocator that keeps leak, double-free, and use-after-free
detection but, in the ReleaseSafe campaign, captures no allocation backtraces:
capturing them was consuming all but a small fraction of the search. A leak found
nightly is therefore reported without its allocation site, and the Debug replay
that section 7 already requires reports it with one. Decision
[0010](docs/decisions/0010-fuzz-search-budget.md) records the measurements and
the per-target budget they set. A campaign that runs out of wall clock reports
what it searched and passes; only a failure fails the job.

The mutation campaign rotates under exactly that allowance, because a mutant
costs a full rebuild of the oracle and the whole repository would take hours.
`tools/ci/mutation_rotation.sh` assigns every (source file, mutation operator)
cell to a group by hashing the cell's name, and each night runs one group, so a
full pass completes every two weeks. Assignment deliberately ignores how large a
cell is, which leaves groups uneven: a cell's group must not depend on what else
exists, or the schedule reshuffles faster than it advances and stops visiting
every cell at all. New sources join the rotation without displacing anything.
Mutation runs use `zig build test-mutation` as their oracle, which contains only
deterministic tiers: it excludes fuzz replay and the randomized property
campaign. Mutation runs do not fail on survivors. Decision
[0005](docs/decisions/0005-mutation-testing-dependency.md) records why.

A surviving mutant is a standing property of the test suite, not a regression in
the commit that happened to be current. Treat it as a gap to close deliberately,
in its own change, the way a missing property or conformance fixture is treated.

### 5.4 Weekly and manually launched campaigns

Broader campaigns may run for one to several hours per selected target and
include:

- high-value parser, model, IR, kernel, ABI, and end-to-end fuzz targets;
- large realistic models;
- high-precision differential calculations;
- benchmark regression analysis; and
- approved external-reference regeneration.

### 5.5 Continuous fuzzing

Open-ended fuzzing is optional and runs only on a dedicated or explicitly
allocated machine. It rotates among high-value targets and reports continuing
campaign state. It is never a required pull-request job and has no concept of
successful completion.

Exact budgets remain target-specific and are adjusted from measured execution
cost and discovery value. Every campaign records its target, budget, corpus,
toolchain, build mode, target platform, and source commit.

## 6. Fuzz targets

Fuzz targets follow the layered strategy in
[Verification and Testing](docs/architecture/VERIFICATION_AND_TESTING.md#11-fuzzing-layers).
Raw-byte, structured, and stateful fuzzing are complementary.

A target checks applicable semantic properties in addition to process survival:

- deterministic diagnostics;
- bounded time, memory, work, and output;
- invariants at successful stage boundaries;
- idempotence and round trips;
- differential agreement;
- failure atomicity and rollback; and
- absence of partially published objects.

Each target has:

- a stable target identifier;
- documented input or generated-state domain;
- explicit per-input resource bounds;
- a permanent seed and regression corpus;
- a bounded mode suitable for automation;
- a reproduction path for one saved input; and
- an owner in the subsystem that interprets its failures.

The project uses the pinned Zig toolchain's integrated fuzzing support, including
structured `std.testing.Smith` generators where suitable. The precise command
line and harness API follow the pinned compiler rather than an unversioned
example.

## 7. Fuzz failure and corpus protocol

A fuzz failure includes:

- a crash or production assertion failure;
- a hang or resource-limit violation;
- a memory leak or corruption report;
- nondeterministic behavior where determinism is promised;
- an invariant, property, or differential mismatch;
- invalid or nondeterministic diagnostics; or
- failure to roll back after an expected error.

For every failure:

1. Preserve the original input and campaign metadata.
2. Reproduce it using the pinned toolchain and recorded configuration.
3. Minimize the input where practical without losing the failure.
4. Add the minimized input to `test/corpus/<target>/` and to that target's
   `.corpus` list, so ordinary pull-request runs replay it.
5. Add a separate focused deterministic regression test when it materially
   improves locality, clarity, or execution cost; the minimized corpus input may
   itself be the regression.
6. Correct the defect without weakening the originating property.
7. Rerun the original target and the broader affected suite.

A campaign that crashes leaves the input in the build cache at `f/crash`, in the
same format a committed corpus entry uses. Scheduled campaigns print it
base64-encoded into the job log, because a hosted runner is discarded when the
job ends. That log is the reproduction path, not the record: the minimized input,
reproduction metadata, and regression remain in the repository. No workflow
artifact is uploaded, and none would be the permanent record if one were.

Regression corpora only shrink under the redundancy rule in
[Verification and Testing](docs/architecture/VERIFICATION_AND_TESTING.md#18-golden-files-and-regression-corpora).
Coverage-increasing nonfailure corpora MAY be curated periodically, but generated
corpus growth is not committed automatically.

Curation is local and deliberate. The toolchain accumulates a coverage-guided
corpus in the build cache and only across runs that preserve it, so a hosted
runner begins every campaign from the committed corpus alone. Restoring a
generated corpus into CI is deliberately not done: it would make a scheduled
failure depend on unreviewed binary state that no commit describes, when the
reproducibility the workflow promises rests on commit, toolchain, and recorded
configuration. Growing the permanent corpus therefore means running a long local
campaign with the cache preserved and reviewing what it found:

```sh
zig build fuzz -Doptimize=ReleaseSafe --fuzz=2M
zig build corpus -- list
zig build corpus -- stage
```

`zig build corpus` reports what the cache holds against what the repository
commits and writes uncommitted inputs to a scratch directory. It never writes
into `test/corpus/`; an input becomes permanent by the judgment above.

Fuzz jobs use only repository fixtures or generated data. Private user models,
credentials, tokens, and unrelated host data MUST NOT enter a corpus, log, or
uploaded artifact.

## 8. Property-based testing

Ordinary property tests are randomized and bounded:

- ordinary and pull-request runs leave the seed unspecified so each invocation
  explores a fresh stream;
- the standard budget is 100 cases per property, with larger per-property
  budgets used where the input space justifies their cost;
- scheduled runs use larger case budgets;
- failures report the selected seed, generator version, generator configuration,
  build mode, target, and failing property;
- an explicit seed is used only to reproduce a reported failure;
- shrinking preserves the original failure until the minimized case is known;
  and
- minimized failures become permanent regression fixtures.

Coverage-guided fuzzing may mutate the same Phaser-owned generators, but it does
not replace bounded property tests.

Property generators remain behind the Phaser-owned harness in `test/property/`.
Minish is the approved property-testing dependency, recorded in
[decision 0004](docs/decisions/0004-property-testing-dependency.md).

Property runs are bounded and cheap enough for every change, so `zig build test`
includes them. A wider budget runs in the scheduled tier.

## 9. Toolchain, CI, and security

The repository pins an exact Zig toolchain and records a checksum or equivalent
integrity identifier. Local development, CI, fuzz reproduction, conformance
generation, benchmarks, and releases use that toolchain unless an explicit
toolchain-upgrade change is under review.

CI follows least privilege:

- workflow tokens are read-only unless a particular reviewed job requires more;
- ordinary build, test, and fuzz jobs receive no repository secrets;
- superseded pull-request runs MAY be cancelled to conserve resources;
- logs and artifact names avoid secrets and unrelated host information;
- runner operating system, architecture, and relevant image identity are
  recorded; and
- test execution is offline after explicitly approved and pinned tools have been
  obtained.

GitHub Actions and setup helpers are external developer-tool dependencies under
Phaser's dependency policy. Before adding one, obtain explicit approval for its
exact source and scope. Approved actions are pinned to immutable commit
identifiers rather than floating tags.

Scheduled GitHub jobs operate on the default branch. They are continuing
fault-discovery campaigns, not retroactive evidence that an earlier merge was
incorrectly approved without its required bounded checks.

## 10. Initial native platform policy

The initial native platforms are:

- Linux x86-64 as the primary required CI platform; and
- macOS ARM64 as a required native platform once the basic build exists.

Windows may begin as a compile-only target when relevant. It becomes a required
native test platform when Phaser claims Windows support, expected no later than
the public C ABI and shared-library work if that support is part of the
milestone.

Cross-compilation checks portability but does not replace native execution.
Every claimed supported platform has a documented native test tier.

## 11. Performance workflow

Correctness checks are merge gates from the beginning. Hosted-runner performance
measurements are initially informational because machine noise can obscure small
changes.

Performance-sensitive pull requests include a representative measurement and
verify outputs before timing. Scheduled or manual benchmarking records the
scientific workload, toolchain, target, CPU, backend, build mode, allocation
behavior, sampling procedure, and variance.

Blocking performance thresholds are introduced only after Phaser has stable
representative workloads and a sufficiently stable runner. A performance result
under changed scientific semantics is not compared as though it represented the
same calculation.

## 12. Versions and releases

Phaser distinguishes at least:

- package and release version;
- QFT Model source-schema version;
- calculation-format version;
- C ABI version;
- canonicalization and content-identity version; and
- persisted artifact versions if such artifacts are later introduced.

A change to one version domain does not automatically change all others.
Compatibility and migration rules belong to the specification owning each
format or boundary.

Releases are tagged from a passing `main` commit, include a changelog, and record
the exact Zig toolchain and supported targets. Release automation is deferred
until Phaser has an artifact worth releasing. Creating a tag, release, or
published artifact requires explicit repository-owner authorization.

## 13. Workflow evolution

The following remain deliberately empirical:

- exact per-target property and fuzz budgets;
- when the number of targets requires nightly rotation;
- the first dedicated benchmark or continuous-fuzzing runner;
- the initial coverage-reporting mechanism;
- Windows native-support timing; and
- detailed release automation.

These choices are resolved from implementation evidence without weakening the
bounded pull-request suite, permanent regression policy, or explicit release
authority established here.

## 14. External references

- [Zig 0.16 fuzzer release notes](https://ziglang.org/download/0.16.0/release-notes.html#Fuzzer)
- [GitHub Actions workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [GitHub Actions workflow artifacts](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts)
- [GitHub Actions permissions and artifact retention](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
