# Phaser

Phaser is a Zig library for deriving and evaluating perturbative quantum field
theory calculations. Milestone 1 provides the exact-expression and canonical
real-scalar model foundation for the first numerical vertical slice.

## Toolchain

Phaser requires exactly Zig 0.16.0. The expected version is recorded in
`.zigversion`; other Zig versions are rejected during build configuration.

The CI installer downloads the official archive for Linux x86-64 or macOS ARM64
and verifies its pinned SHA-256 checksum before use:

```text
tools/ci/install_zig.sh INSTALL_DIRECTORY
```

The pinned compiler and Zig standard library are the only implementation
dependencies.

## Build and test

Build the static library:

```text
zig build
```

Run the bounded suite in the two supported development modes:

```text
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
```

Run colocated library unit tests:

```text
zig build test-unit
```

Replay the permanent fuzz seeds:

```text
zig build fuzz
```

Run the public scalar-model inspection examples:

```text
zig build examples
```

Run a bounded coverage-guided campaign of 1,000 generated inputs:

```text
zig build fuzz -Doptimize=ReleaseSafe --fuzz=1000
```

No bounded command claims to complete fuzzing. A discovered failure must be
preserved, minimized where practical, and committed to the corresponding
`test/corpus/` directory.

Review what a campaign found, and stage the inputs the permanent corpus does not
have yet:

```text
zig build corpus -- list
zig build corpus -- stage
```

A campaign accumulates its corpus in the build cache only across runs that
preserve it, so this reports on local runs. Staged inputs are written to
`.corpus-candidates/` for review; nothing enters `test/corpus/` automatically.

After the pinned Zig archive is installed, the build, deterministic tests,
corpus replay, and fuzz target invoke no network clients and require no network
resources. CI does not claim to reconfigure the hosted runner's firewall.

Zig 0.16.0's live fuzzer currently requires ReleaseSafe on the supported macOS
ARM64 toolchain because its Debug test runner fails to compile before the target
executes. Ordinary seed replay remains part of both Debug and ReleaseSafe tests.

Every fuzz target replays its permanent corpus in the default suite. Live
coverage-guided fuzzing runs nightly or as a manually launched campaign.

## Current scope

Milestones 0 and 1 provide:

- explicit allocator and resource-limit plumbing;
- typed local identifiers and byte source spans;
- checked capacity arithmetic and transactional budgets;
- immutable structured diagnostics;
- configurable parser and model hard limits;
- bounded arbitrary-precision integers and reduced exact rationals;
- the exact model expression language and initial Typed Value IR;
- strict real-scalar QFT model loading and semantic validation;
- immutable canonical scalar models and symmetric tensor lookup;
- deterministic SHA-256 model fingerprints and inspection output;
- public phi4 and multi-scalar examples;
- expression, JSON, scalar-model, and capacity fuzz targets; and
- Debug and ReleaseSafe CI on the required native platforms, with live fuzzing
  in nightly and manually launched campaigns.

Milestone 2 adds the tree-level vertical slice: calculation requests, the
classical-potential artifact with exact gradients and Hessians, symbolic export
in Phaser notation and MathJax LaTeX, a safe numerical kernel, immutable
parameter bindings, and a command-line client.

```sh
zig build
./zig-out/bin/phaser export examples/phi4/model.json examples/phi4/request.json \
    --target=phaser --gradient
./zig-out/bin/phaser evaluate examples/phi4/model.json examples/phi4/request.json \
    examples/phi4/point.json --outputs=hessian --scan=0:0:600:13
```

Evaluation output defaults to an aligned table for terminals and CI logs. Pass
`--format=tsv` to emit exact tab-separated sampled data for downstream tools.

Worked inputs and golden outputs live in [examples/phi4](examples/phi4/README.md)
and [examples/multi_scalar](examples/multi_scalar/README.md).

Contributors should enable the repository's local hooks once per clone, which
refuse a commit or push on `main`:

```sh
git config core.hooksPath .githooks
```

Build steps:

```sh
zig build test               # all bounded tests
zig build test-property      # 100 freshly seeded cases per property
zig build test-differential  # independent implementations of the same quantity
zig build test-conformance   # scientific conformance fixtures
zig build fuzz               # replay corpora, or add --fuzz=N for a campaign
zig build examples           # public example workflows
zig build bench              # representative measurements (informational)
zig build mutation           # mutation campaign (nightly tier; see below)
```

`zig build bench` measures the production `ReleaseSafe` mode by default,
calibrates each timing to repeated minimum-duration samples, and reports the
median and observed range. It measures separately compiled value-only and fused
value/gradient/Hessian kernels and compares value throughput with direct C
expressions compiled by the pinned Zig toolchain. No system C compiler is
required. Use `-Dbench-optimize=ReleaseFast` for an explicitly diagnostic
`ReleaseFast` run.

Ordinary property runs do not pin a seed. If a property fails, Minish prints the
selected seed and minimized input; reproduce that stream with:

```sh
zig build test-property -- --seed SEED
```

## Mutation testing

Line coverage says a test ran a line. Mutation testing says whether a test would
notice if the line were wrong. `zig build mutation` builds the pinned Zentinel
client and runs it over `src/`, applying one single-token change at a time and
re-running the bounded suite against each.

```sh
zig build mutation -- list-mutants          # what would be mutated, no runs
zig build mutation -- check                 # validate configuration only
zig build mutation                          # the whole repository, hours
```

A mutant costs a full rebuild, so the whole repository takes hours. Scope a
local run to one operator, which is what the nightly job does per rotation
group:

```sh
zig build mutation -- run --operator comparison_boundary --jobs 4
```

The oracle is `zig build test-mutation`, the deterministic subset of
`zig build test`; fuzz replay and freshly seeded property campaigns are
deliberately not part of this tier. The dependency is lazy, so no other build
step or pull-request job fetches it, and nothing about mutation testing runs on
a pull request. Configuration lives in `zentinel.toml`, and decision
[0005](docs/decisions/0005-mutation-testing-dependency.md) records the rest.

The C ABI and
language bindings are not implemented yet.

The architecture and milestone contracts are documented in
[DESIGN.md](DESIGN.md) and
[Implementation Roadmap](docs/architecture/IMPLEMENTATION_ROADMAP.md).
