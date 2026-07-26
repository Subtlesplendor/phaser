# Phaser Engineering Style

Status: initial working agreement

This document records the engineering principles for Phaser. It is intentionally
stricter than a conventional style guide: it covers scientific correctness,
testing, memory, numerical behavior, performance, and use of Zig. The rules will
evolve as the architecture becomes concrete, but changes should preserve the
rationale behind them.

The operational Git, review, CI, fuzz-campaign, and release process is specified
in [Phaser Development Workflow](DEVELOPMENT_WORKFLOW.md).

Phaser's priorities are, in order:

1. Scientific correctness.
2. Software correctness and diagnosability.
3. Reproducibility.
4. Performance.
5. Developer convenience.

These goals should usually reinforce one another. When they conflict, make the
tradeoff explicit and record why it is justified.

## Core principles

- A supported calculation must be scientifically explicit, internally checked,
  reproducible, and fast enough for its intended workload.
- Unsupported cases fail clearly. They never silently fall back to a lower order,
  a different approximation, or a different convention.
- Invalid external input returns an error. A violated internal invariant is a
  programmer error and terminates the operation or process.
- Symbolic structure remains exact for as long as practical. Floating-point
  approximation begins at an explicit boundary.
- Perform work at the earliest stage at which all required information is known,
  but do not confuse "earlier" with "at Zig compile time".
- The control plane may be sophisticated. The numerical data plane must be flat,
  predictable, allocation-free, and efficient for both scalar and batched
  evaluation.
- Correctness assertions remain active in production.
- Performance claims require measurement on a representative workload.

## Scientific contracts

Every calculation must make its scientific contract available to the caller.
As applicable, this includes:

- Model and field conventions.
- Spacetime dimension.
- Renormalization scheme and scale.
- Gauge-fixing family and gauge parameters.
- Perturbative orders and truncation.
- Numerical precision.
- Thermal-function implementation or approximation.
- Treatment of negative mass-squared values and complex quantities.
- Numerical tolerances and convergence limits.
- Backend and reproducibility policy.

Persisted calculations and results must materialize these choices. A result must
not depend on an undocumented default.

Approximate calculations are legitimate, but approximation metadata is part of
the result, not merely a log message.

## Specification ownership

Each cross-cutting contract has one normative owner. Memory and workspace rules
belong to the memory and kernel specifications; common verification policy
belongs to the verification specification; public language behavior belongs to
the interoperability specification. Other documents SHOULD link to the owner
and state only their subsystem-specific additions.

Repeated explanatory summaries are non-normative unless they explicitly say
otherwise. A duplicated `MUST` is avoided because independent copies drift,
multiply implementation gates, and obscure which document should change.
Subsystem test sections list scientific properties unique to that subsystem;
they need not repeat the complete architecture-wide fuzz, allocation, cache, and
client matrix.

## Exact and numerical domains

- Use exact integers and rationals for structural coefficients whenever possible.
- Do not use a floating-point tolerance to determine symbolic equality or zero.
- Track units and mass dimensions explicitly and validate them symbolically.
- Convert exact expressions to a numerical scalar type deliberately during
  lowering or evaluation.
- Do not allow NaNs, infinities, branch choices, or complex results to propagate
  silently. Either handle them according to an explicit calculation policy or
  return a diagnostic.
- Numerical tolerances must be named, documented, scale-aware, and tested. Avoid
  unexplained literals such as `1e-8` in scientific code.
- Prefer algorithms that remain well-defined at degeneracies. Tests must include
  exact and near degeneracies, zero masses, hierarchies, and cancellation.

## Errors and assertions

Assertions detect programmer errors. Errors describe expected failures caused by
input, resources, the environment, or the mathematical problem.

Return an error for conditions such as:

- Invalid JSON or expression syntax.
- Unknown fields, parameters, indices, or conventions.
- A model that fails dimensional, symmetry, reality, or gauge-invariance checks.
- Exceeding a documented resource limit.
- Insufficient caller-provided workspace.
- Unsupported calculations or perturbative orders.
- Expected numerical failures such as nonconvergence or a singular problem.

Assert internal conditions such as:

- An ID belongs to the arena or table in which it is used.
- A canonical expression contains only canonical children.
- Tensor storage agrees with its declared symmetry.
- An IR transformation preserves required metadata and invariants.
- A cache entry agrees with its key and model fingerprint, if a cache is later
  implemented.
- A compiled kernel agrees with its declared input and output layout.

Rules for assertions:

- Validate at trust boundaries; assert after trust has been established.
- Assertions must not contain side effects required for correctness.
- State invariants positively where possible.
- Split unrelated compound assertions so failures identify one violated fact.
- Check important invariants along at least two independent paths when practical,
  for example on construction and again before serialization or lowering.
- Cheap local invariants are always enabled.
- Expensive whole-structure verification is controlled by an explicit audit
  option and enabled in tests, fuzzing, and validation builds.
- Assertions supplement reasoning and review. They are not a substitute for them.

## Build modes and runtime safety

The default production mode is `ReleaseSafe`.

`ReleaseFast` disables Zig's runtime safety checks and may turn assertion failure
paths based on `unreachable` into optimizer assumptions. Do not select it merely
because the project values performance.

Optimization proceeds in this order:

1. Measure a representative end-to-end workload.
2. Remove repeated structural work.
3. Improve algorithms, batching, and memory layout.
4. Isolate demonstrably hot leaf functions.
5. Only then consider disabling runtime safety in a small reviewed scope.

If safety is disabled in a leaf kernel:

- Assert all relevant preconditions before entering it.
- Keep the unsafe scope small and free of allocation and ownership changes.
- Maintain a safe reference implementation.
- Differentially test safe and optimized implementations with generated inputs.
- Record the benchmark demonstrating that the change is worthwhile.

CI should exercise Debug and ReleaseSafe from the initial implementation.
ReleaseFast differential coverage is introduced when Phaser supports a
ReleaseFast, safety-disabled leaf, optimized, or AOT path whose comparison is
meaningful. A behavioral difference unrelated to diagnostics or recorded build
metadata is a bug.

## Memory and allocation

The normative memory contract is specified in
[Memory Architecture](docs/architecture/MEMORY_ARCHITECTURE.md).

The core does not require all possible model storage to be embedded in the binary
and does not require exclusively static allocation. Version 0.1 uses explicit,
bounded, phase-local allocator-backed memory. Caller-provided fixed-buffer or
heapless construction is a future capability that requires a concrete consumer.

- All core allocation flows through an explicit context or injected allocator.
- Scientific subsystems do not reach directly for a global or operating-system
  allocator.
- No hidden global or thread-local allocator, cache, or workspace is required.
- The caller supplies memory budgets to major components.
- Parsing and derivation may allocate from bounded arenas.
- Independently releasable long-lived objects use independently reclaimable
  ownership regions where the backing allocator permits it.
- Temporary transformations use scratch arenas that are reset as a unit.
- Avoid individual allocation and freeing when an arena lifetime represents the
  actual ownership of the data.
- Published objects never borrow temporary scratch storage.
- Each worker thread has independent scratch memory unless sharing is necessary
  and justified.
- Binding is control-plane work and may allocate. Published bindings are
  immutable; a new parameter point initially produces a new binding.
- Potential, gradient, Hessian, and batch evaluation must not allocate.
- Numerical kernels report their required workspace; the caller supplies it.
- Inputs, outputs, and workspace do not overlap unless an operation explicitly
  permits and tests that layout.
- Persistent-object construction is transactional.
- Allocation failure and capacity exhaustion are ordinary errors, not assertions.
- Tests exercise exact capacity boundaries and representative injected
  allocation failures at ownership and publication boundaries.

Every externally controlled resource is bounded. This includes at least:

- Source bytes and tokens.
- Parser nesting and expression depth.
- Fields, parameters, generators, and tensor components.
- Expression and IR nodes.
- Diagram and rewrite counts.
- Rewrite iterations.
- Batch sizes and workspace bytes.
- Numerical iterations and recursion depth.

Do not recurse over user-controlled structures. Use explicit bounded worklists so
that depth, memory, and failure behavior remain visible.

## Phase separation

Phaser distinguishes a control plane from a numerical data plane.

The control plane includes:

- Parsing and validation.
- Canonicalization.
- Background shifting and vertex generation.
- Diagram and expression construction.
- Optimization and kernel compilation.

The data plane includes:

- Parameter and scale binding.
- Temperature binding.
- Potential, gradient, and Hessian evaluation.
- Batched evaluation for minimization and scans.

Structural work must not leak into the data plane. In particular, changing a
parameter point, temperature, or background must not regenerate diagrams or
rebuild symbolic expressions.

## Determinism and reproducibility

The concurrency contract is specified in
[Parallelism and Reentrancy](docs/architecture/PARALLELISM.md).

- Canonical symbolic output is deterministic.
- Never expose hash-map iteration order in serialization or hashing.
- Define canonical ordering for fields, tensors, terms, and expression children.
- The canonical model fingerprint covers all semantic model settings.
- Any implemented lookup key is typed and covers all inputs that affect its
  transformation according to
  [Content Fingerprints and Deferred Caching](docs/architecture/CONTENT_IDENTITY_AND_CACHING.md).
- Explicit object ownership is the version 0.1 reuse mechanism. General caches
  are deferred and no implicit process-global cache is permitted.
- Record the Zig version, target, backend, precision, and optimization mode when
  they can affect a numerical artifact.
- Parallel execution must not change symbolic results.
- Numerical reduction order is defined in reproducible mode and is independent
  of scheduling and supported worker count on the same target and backend.
- A future faster nondeterministic mode must be explicit and separately tested.

## Concurrency and scheduling

- The initial core is serial but reentrant.
- Caller-owned scheduling is the initial parallelism strategy.
- Kernels perform no lazy initialization and use no hidden mutable global or
  thread-local scientific state.
- Immutable models, artifacts, kernels, and diagnostics are shareable.
- A binding may be shared for evaluation only while it is not being rebound.
- Each active evaluation stream has independent mutable workspace and output.
- Batch execution does not imply threaded execution.
- Phaser does not silently create workers or select the host CPU count.
- Future internal parallelism is an explicit backend capability with bounded
  worker resources prepared before evaluation.
- Nested parallelism and external-library threading are explicit and controlled.
- Symbolic parallel work uses task-local results and deterministic merging.

## Testing strategy

The architecture-wide verification plan is specified in
[Verification and Testing](docs/architecture/VERIFICATION_AND_TESTING.md).

No single oracle is sufficient. Combine example tests, exact checks, properties,
metamorphic tests, differential implementations, fuzzing, and external references.

### Unit and regression tests

- Test public behavior and internal invariants at their natural boundaries.
- Keep small exact examples next to the relevant implementation when useful.
- Every discovered bug receives a minimal deterministic regression test.
- Regression corpora only grow unless an entry is proven redundant.
- Golden files are reviewed as scientific artifacts. Updating a golden file is not
  by itself evidence that the new result is correct.

### Property-based testing

Minish is a candidate for property-based testing, not an adopted dependency.
Adding it requires the dependency proposal and explicit approval specified in
the Dependencies section. Property generators remain behind Phaser-owned
interfaces whether or not Minish is adopted.

Important initial properties include:

- Parse/print/parse preserves expression meaning.
- Canonicalization is idempotent.
- Canonically equal expressions have equal hashes.
- Interning and canonical output do not depend on insertion order.
- Sparse and dense tensor operations agree.
- Tensor permutation symmetries are preserved.
- Symbolic and numerical derivatives agree at well-conditioned points.
- Hessians are symmetric within the documented numerical policy.
- Scalar and batched evaluators agree.
- Interpreted and compiled evaluators agree.
- Rebinding parameters agrees with constructing a fresh bound kernel.
- Relabelling fields preserves corresponding results.
- A model with a coupling set to zero agrees with the corresponding reduced model.
- Equivalent changes of scalar basis preserve physical scalar quantities.

Generators should construct valid objects by design. For example, generate an
invariant interaction from representation data instead of generating arbitrary
components and rejecting nearly every sample. Also generate near-valid objects to
exercise each validation boundary.

All property failures record a seed. Shrunk failures become ordinary regression
tests.

### Fuzzing

Use Zig's integrated coverage-guided fuzzer throughout the project.

Fuzz at several levels:

1. Raw bytes into JSON, expression, canonical-format, and ABI parsers.
2. Structured expression ASTs with `std.testing.Smith`.
3. Sparse tensors and their symmetry metadata.
4. Valid and near-valid QFT models.
5. Whole parse/validate/derive/lower/evaluate pipelines.
6. Stateful sequences involving binding, evaluation, and serialization; add
   cache operations only when a cache exists.

Fuzz targets must check more than crashes. They also check:

- Deterministic diagnostics.
- Bounded work and memory.
- Round trips and idempotence.
- Agreement between independent implementations.
- Invariants before and after every transformation.

Run a small deterministic fuzz budget on each change, longer multi-core fuzzing in
scheduled CI, and indefinite fuzzing where resources permit. Preserve every crash
input and run the saved corpus in normal CI.

TODO: the scheduled tier does not exist yet. Only the per-change smoke budget
runs, at 1000 iterations per target, which is far below saturation: raising a
measurement run to 20000 iterations per target still produced two to four times
more unique runs and new coverage on every target, so the per-change job is on
the steep part of the curve and is not expected to find defects. Outstanding
work, specified by
[Development Workflow](DEVELOPMENT_WORKFLOW.md#53-nightly-checks):

- add the scheduled nightly workflow with its 10 to 30 minute budget, including
  the allocation-failure and exact-capacity campaigns;
- measure the iteration count that fits that budget rather than guessing it; and
- add per-target build steps, since `zig build fuzz` currently runs every target
  and cannot select one, which the weekly per-target campaigns require.

### Differential and metamorphic tests

Prefer comparisons that are unlikely to repeat the same implementation error:

- Sparse versus dense contractions.
- Interpreted versus compiled expressions.
- Symbolic derivatives versus high-precision numerical derivatives.
- Scalar versus batched evaluation.
- Original versus field-permuted models.
- Original versus appropriately transformed scalar bases.
- Generic zero-coupling limits versus structurally reduced models.
- `f64` results versus higher-precision reference calculations.
- Phaser versus pinned external calculations such as Mathematica or DRalgo.

External software is evidence, not unquestionable truth. Investigate disagreements.

## Use of `comptime`

The normative boundary is specified in
[Zig `comptime` and Model-Specific AOT Compilation](docs/architecture/COMPTIME_AND_AOT.md).

Use `comptime` to generate bounded Phaser-owned structure and prove implementation
completeness. Do not use it as a hiding place for unbounded symbolic computation.

Good uses include:

- Generating metadata and dispatch for tagged unions.
- Requiring every expression variant to implement serialization, hashing,
  evaluation, pretty-printing, and differentiation where applicable.
- Generating parser and builtin-function tables.
- Asserting ABI layouts, enum relationships, and static limits.
- Specializing by scalar type, tensor rank, derivative order, and backend.
- Building bounded diagram-topology catalogs.
- Evaluating small exact conformance examples at compile time.
- Unrolling small fixed-size operations when measurements justify it.
- Keeping bounded pure helpers callable at both runtime and compile time where
  practical.

Avoid:

- Parsing arbitrary user models during the normal Phaser build.
- Unbounded simplification or diagram generation at compile time.
- Specializing on ordinary numerical parameter values.
- Generating a unique Zig type for every field or tensor component.
- Expanding contractions when a compact contraction plan is better.
- Increasing compile time, compiler memory, binary size, or instruction-cache
  pressure without measuring the tradeoff.
- Raising `@setEvalBranchQuota` globally or to force model-dependent work through
  the compiler.

Information becomes known at several stages:

1. Phaser build time.
2. Model-load time.
3. Calculation-derivation time.
4. Parameter-binding time.
5. Scale and temperature-binding time.
6. Background-evaluation time.

Compute each value at the earliest stage where its inputs are available and where
doing so improves the complete workload.

An optional future AOT backend may emit and compile a model-specific Zig kernel.
That kernel can know field counts, matrix sizes, tensor sparsity, and expression
topology at compile time while keeping parameters, scales, temperatures, and
backgrounds as runtime inputs.

Every nontrivial `comptime` use is classified as completeness validation, finite
implementation generation, or measured runtime optimization. Any
`@setEvalBranchQuota` use is local, statically bounded, documented, and tested.
Performance-motivated specialization requires benchmark evidence.

## Symbolic export and presentation

The normative export contract is specified in
[Symbolic Export and Notebook Display](docs/architecture/SYMBOLIC_EXPORT.md).

- Exporters consume Derived Physics IR or Typed Value IR, never Numerical Kernel
  IR.
- Scientific contribution selection occurs before target rendering.
- Rendering does not silently simplify, approximate, expand, or discard
  scientific structure.
- Exact integers, rationals, and symbolic constants remain exact.
- Semantic identifiers and presentation labels remain distinct.
- Default identifier rendering escapes target syntax safely.
- Complete exports never truncate silently.
- Automatic rich-display previews are bounded and visibly identify omissions.
- Export traversal and output are bounded control-plane work.
- Presentation options do not alter scientific content identity.
- Python notebook display reuses the LaTeX renderer and introduces no required
  IPython or Jupyter dependency.

## Performance

- Design the structural/runtime boundary before optimizing individual operations.
- Batch work across backgrounds or parameter points.
- Keep hot data contiguous and separate it from descriptive metadata.
- Avoid virtual dispatch, allocation, formatting, and logging in hot loops.
- Avoid recomputing quantities whose inputs have not changed.
- Extract important hot loops into simple leaf functions with explicit inputs.
- Estimate CPU, memory bandwidth, memory capacity, and compilation cost before
  selecting a representation.
- Benchmark representative models and scan patterns, not only microkernels.
- Track throughput, latency, peak memory, allocation count, kernel size, and
  compilation time where relevant.
- Establish regression thresholds only after obtaining stable measurements.
- Do not enable relaxed floating-point semantics until their scientific effects
  have been specified and tested.

## Dependencies

Phaser is dependency-averse, not categorically dependency-free. The default is to
use the Zig standard library, platform facilities already in the supported
toolchain, and Phaser-owned code.

An implementing agent MUST obtain the user's explicit permission before adding,
downloading, vendoring, linking, or declaring a new external dependency. This
applies to runtime, build, test, benchmark, fuzzing, code-generation,
documentation, and developer-tool dependencies. It includes:

- additions to a package manifest or lockfile;
- vendored source or generated third-party code;
- Git submodules or dependencies fetched by a build step;
- new required system libraries or external executables; and
- optional integrations that become part of a supported build or test path.

The permission request must identify:

- the exact dependency and proposed version or source;
- the concrete capability for which it is needed;
- the realistic Phaser-owned implementation alternative;
- why the dependency is preferable despite the maintenance cost;
- its license and expected maintenance or supply-chain risks;
- relevant allocation, threading, floating-point, and error behavior; and
- the private boundary behind which it would be isolated.

Researching a candidate or reading its public documentation does not add it and
does not require permission. The Zig compiler and standard library pinned by the
repository are not external library dependencies under this rule. Dependencies
already explicitly approved and recorded by the project may be used within their
approved scope; changing their source, version, features, or role requires renewed
permission.

Permission to evaluate or adopt one dependency is not blanket permission for its
optional features or transitive additions. The accepted dependency graph must be
reviewed and pinned where reproducibility requires it.

Do not reimplement a difficult mature numerical routine merely to claim zero
dependencies without first making the scientific and engineering tradeoff
explicit. If an internal implementation would create a material correctness,
validation, or maintenance risk, stop and present the external and internal
options to the user. The user decides whether Phaser accepts the dependency.

Every approved dependency must:

- have an identified purpose and owner within Phaser;
- be hidden behind a Phaser-owned module when replacement is plausible;
- be covered by conformance or differential tests appropriate to its role; and
- be audited for hidden allocation, threading, floating-point, error, and
  reproducibility behavior before entering the numerical data plane.

## Repository structure and Zig modules

The repository is organized by responsibility and build artifact. The structure
should make dependency direction and public boundaries visible without creating a
separate Zig module for every directory.

Zig's compilation model is module-based rather than directory-based. A module is a
collection of source files with one root source file. Directories are an
organizational convention; they do not automatically become modules or namespaces.
Every Zig source file is itself a namespace.

The initial repository structure is expected to resemble:

```text
phaser/
|-- build.zig
|-- build.zig.zon
|-- AGENTS.md
|-- README.md
|-- DESIGN.md
|-- ENGINEERING_STYLE.md
|-- DEVELOPMENT_WORKFLOW.md
|-- include/
|   `-- phaser.h
|-- src/
|   |-- root.zig
|   |-- foundation/
|   |   `-- root.zig
|   |-- expression/
|   |   `-- root.zig
|   |-- model/
|   |   `-- root.zig
|   |-- calculation/
|   |   `-- root.zig
|   |-- physics/
|   |   |-- root.zig
|   |   |-- background/
|   |   |-- diagrams/
|   |   `-- effective_potential/
|   |-- numerics/
|   |   `-- root.zig
|   |-- kernel/
|   |   `-- root.zig
|   |-- serialization/
|   |   |-- root.zig
|   |   `-- json/
|   |-- abi/
|   |   `-- root.zig
|   `-- cli/
|       `-- main.zig
|-- bindings/
|   |-- cpp/
|   |   `-- phaser.hpp
|   `-- python/
|       |-- pyproject.toml
|       `-- src/
|           `-- phaser/
|-- test/
|   |-- root.zig
|   |-- integration/
|   |-- conformance/
|   |-- reference/
|   |-- differential/
|   |-- fuzz/
|   |-- corpus/
|   `-- fixtures/
|-- examples/
|   |-- phi4/
|   |-- abelian_higgs/
|   `-- standard_model/
|-- docs/
|   |-- decisions/
|   |-- formats/
|   `-- derivations/
`-- tools/
```

This is a direction rather than a requirement to create empty directories. A
directory is introduced when it has a concrete owner and at least one meaningful
file. The tree should grow from implemented boundaries rather than predict every
future subsystem.

### Top-level directories

`src/`
: Contains the Zig implementation of the Phaser core, public library, C ABI, and
  Zig executables. Code that participates in the core compilation belongs here.

`include/`
: Contains the authoritative public C header. The C ABI implementation remains
  under `src/abi/`; ABI declarations intended for external consumers live here.

`bindings/`
: Contains language-specific convenience layers and their packaging metadata.
  The thin C++ source wrapper lives under `bindings/cpp/`. The Python package
  lives outside the Zig `src/` tree because it is independently packaged, tested,
  and released. Native Zig glue remains under `src/abi/`; Python code and Python
  build metadata remain under `bindings/python/`.

`test/`
: Contains tests that cross a source-file or subsystem boundary, shared test data,
  fuzz targets, and persistent corpora. Unit tests normally remain beside the Zig
  implementation they exercise.

`examples/`
: Contains small complete user workflows. Each example should state what it
  demonstrates and should be runnable through a documented build step. Model JSON,
  parameter points, expected output, source code, and Jupyter notebooks may live
  together in one example directory.

`docs/`
: Contains longer-lived specifications, design decisions, mathematical
  derivations, and format documentation. Root documents provide project-wide entry
  points; detailed documents live here.

`tools/`
: Contains developer-facing generators, benchmark drivers, corpus maintenance, or
  release tools that are not part of the Phaser library. Generated output should
  normally be produced through the Zig build graph into the Zig cache or install
  prefix rather than written into `src/`.

### Zig module roots

`src/root.zig` is the root of the public `phaser` library module. It defines the
supported Zig API by deliberately re-exporting public declarations. Internal files
do not become public merely because they exist under `src/`.

`src/cli/main.zig` is the executable entry point for a future command-line client.
Other executables receive their own `main.zig` only when they are separate build
artifacts.

A subsystem directory uses `root.zig` as its internal facade when it contains
several files:

```zig
// src/model/root.zig
pub const Model = @import("Model.zig");
pub const Parameter = @import("Parameter.zig");

const validate = @import("validate.zig");
```

Code outside `src/model/` imports the subsystem facade instead of reaching into an
arbitrary implementation file:

```zig
const model = @import("model/root.zig");
```

Code within the subsystem may import sibling implementation files directly. This
keeps cross-subsystem dependencies visible and permits internal files to be moved
without changing unrelated code.

Do not turn every subsystem directory into a separate build-system module at the
start. Begin with one `phaser` library module and ordinary source-file imports.
Create another Zig module when at least one of these is true:

- It is consumed independently by another build artifact or package.
- It requires a materially different dependency set or build configuration.
- It provides a deliberate compilation boundary with a stable public surface.
- Independent testing or replacement provides concrete value.

Module names in `build.zig` are stable API names. Directory names are not.

Avoid ordinary domain dependencies through `@import("root")`. The root module
differs between the library, CLI, tests, fuzzers, and generated kernels. Use
explicit imports or injected options so dependencies remain visible.

### Provisional subsystem responsibilities

`foundation/`
: Small domain-independent building blocks such as distinct IDs, bounds, source
  spans, diagnostics, and arena utilities. This must not become a miscellaneous
  dumping ground. Their normative shared contract is specified in
  [Foundation Types and Failure Reporting](docs/architecture/FOUNDATION.md).

`expression/`
: Exact values, source expressions, the canonical Typed Value IR, interning,
  traversal, hashing, simplification, and differentiation.

`model/`
: QFT model types, fields, parameters, index spaces, gauge structures, tensors,
  semantic validation, and canonicalization.

`calculation/`
: Calculation requests, loop-order tracking, renormalization and gauge contexts,
  derived-term metadata, and calculation provenance.

`physics/`
: Physics transformations and formulae: background shifts, vertices, propagator
  structure, diagrams, loop contributions, effective potentials, beta functions,
  and later dimensional reduction.

`numerics/`
: Domain-independent numerical algorithms, matrix operations, special functions,
  convergence policies, and reproducible reductions. Physics-specific formulae do
  not belong here.

`kernel/`
: Lowering derived expressions to numerical execution plans, buffer layouts,
  workspace calculation, scalar and batch evaluation, derivatives, and the safe
  reference interpreter specified by
  [Potential Kernel](docs/architecture/POTENTIAL_KERNEL.md).

`serialization/`
: Source and canonical JSON, schema versions, migrations, and deterministic
  serialization. Serialization depends on domain types; core domain behavior does
  not depend on a particular serialization format.

`abi/`
: The versioned C-facing boundary, opaque handles, status conversion, and buffer
  validation. It adapts the Phaser library and contains no independent physics.
  Its public contract is specified in
  [Language and Interoperability](docs/architecture/LANGUAGE_AND_INTEROPERABILITY.md).

These boundaries are provisional. When a dependency cycle appears, reconsider the
ownership of the concepts rather than hiding the cycle behind a broad `utils` or
`common` module.

### Dependency direction

Dependencies should point from adapters and applications toward domain concepts:

```text
foundation
|-- expression
|   `-- model
|       `-- calculation
|           `-- physics
|               `-- kernel
`-- numerics -----------------^

serialization ---> model / calculation / expression
abi -----------> public Phaser API / kernel
cli -----------> public Phaser API
C -------------> C ABI
C++ wrapper ----> C ABI
Python extension -> C ABI or its private Zig implementation adapter
```

This sketch is not a complete graph. It expresses the intended direction:

- Physics may use numerical primitives.
- Numerics must not know about QFT models or gauge fixing.
- Domain objects must not depend on Python or the C ABI.
- Serialization is an adapter around domain objects, not their owner.
- Client frontends depend inward; the core does not depend outward on clients.
- C++ and Python adapters contain no independent physics or numerical logic.

### Tests

Zig supports `test` declarations in any source file, and colocated unit tests are
the default Phaser convention. Tests that need private implementation details stay
near those details:

```zig
test "canonicalization is idempotent" {
    // ...
}
```

The top-level `test/` directory has different responsibilities:

- `integration/`: behavior spanning several subsystems or public APIs.
- `conformance/`: language-neutral format and scientific reference cases.
- `reference/`: simple independent test-only implementations.
- `differential/`: comparisons between independent implementations or tools.
- `fuzz/`: Zig fuzz entry points and structured smiths.
- `corpus/`: minimized permanent fuzz inputs.
- `fixtures/`: shared source models and expected artifacts.

`test/root.zig` is the test-suite root used by `build.zig`. It imports each
integration suite deliberately. The library test root also ensures that every
source subtree containing colocated tests is discovered. Do not rely accidentally
on lazy analysis to find all tests.

`build.zig` should expose clear steps, eventually including:

```text
zig build test
zig build test-unit
zig build test-integration
zig build test-conformance
zig build fuzz
zig build examples
zig build bench
```

The exact steps are added only when they run real work. The default `test` step
must run all bounded deterministic tests suitable for ordinary development.

Tests write diagnostics through the test facilities rather than ordinary standard
output, because the Zig build runner and test runner use standard streams for
coordination.

### Examples

Examples are user-facing and use only public interfaces. They must not import
private files from `src/`.

Each example should contain:

- A short README or top-of-file explanation.
- The smallest model and parameter data needed to demonstrate one idea.
- A deterministic command to run it.
- Assertions or reference output when practical.

Examples should be compiled or executed in CI so they cannot silently decay. They
are not substitutes for conformance tests.

Jupyter notebooks are public examples and human validation aids. Maintained
notebooks:

- use only public Phaser interfaces;
- run from a fresh kernel without hidden cell-order state;
- identify model, conventions, calculation, and parameter point;
- use deterministic inputs and fixed random seeds;
- require no network access;
- expose plotted data to corresponding machine tests;
- state which equations, limits, or plot features should be inspected; and
- remain bounded enough for their assigned validation tier.

Notebook plots and rendered equations supplement machine checks; they are not
sole scientific oracles. Adding plotting or notebook-execution packages follows
the external-dependency approval policy.

### File and directory naming

Follow Zig's naming guidance:

- Directory and namespace-file names use `snake_case`.
- A source file that acts as a namespace uses `snake_case.zig`.
- A source file whose top-level container is instantiated as a type uses
  `TitleCase.zig`.
- Types use `TitleCase`.
- Functions use `camelCase`.
- Ordinary values use `snake_case`.
- Avoid redundant names in fully qualified namespaces. Prefer
  `model.Parameter` over `model.ModelParameter` when `Parameter` is unambiguous.

Use `root.zig` for module and subsystem facades and `main.zig` for executable entry
points. Do not create `mod.zig`, `index.zig`, and `root.zig` conventions
simultaneously.

### Generated and build output

`.zig-cache/` and `zig-out/` are generated and are not committed. Build scripts do
not hardcode output into the source tree.

When generated source or data must be committed, place it in a clearly named
directory, identify its generator and source inputs, and provide a deterministic
check that regeneration produces no diff. Generated files are never edited by
hand.

### References for Zig conventions

- Zig's [`zig init` overview](https://ziglang.org/learn/overview/) demonstrates the
  conventional `build.zig`, `build.zig.zon`, `src/root.zig`, and `src/main.zig`
  starting structure.
- The [Zig compilation model](https://ziglang.org/documentation/0.16.0/#Compilation-Model)
  defines modules by root source files and describes source files as namespaces.
- The [Zig build-system testing guide](https://ziglang.org/learn/build-system/#Testing)
  describes direct `zig test` use and orchestration with `addTest` and
  `addRunArtifact`.
- The [Zig style guide](https://ziglang.org/documentation/0.16.0/#Style-Guide)
  defines naming conventions for files, directories, namespaces, types, and
  declarations.

## Code and review style

- Use `zig fmt`.
- Prefer explicit control flow and small, cohesive functions.
- Use distinct types for semantically distinct IDs, counts, indices, dimensions,
  units, and orders.
- Keep variable scope small and calculate values close to use.
- Use option structs when same-typed arguments could be confused.
- Include units and qualifiers in names when the type cannot carry them.
- Make ownership, allocator, and arena lifetime visible in APIs.
- Avoid hidden global mutable state.
- Keep important state immutable after construction where practical.
- Comments explain why, especially for physics conventions, numerical choices,
  invariants, and performance-sensitive representations.
- Tests explain both their property and their oracle.
- Design records document consequential tradeoffs and rejected alternatives.

## Definition of done

A change is not complete merely because its primary example works. As applicable,
it includes:

- A stated scientific and software contract.
- Input validation and clear diagnostics.
- Internal assertions and audit verification.
- Unit and regression tests.
- Properties or metamorphic tests.
- Fuzz coverage for a new parser, boundary, or state transition.
- Capacity and failure-path tests.
- Deterministic serialization and hashing tests.
- Benchmarks for performance-sensitive changes.
- Documentation of approximation, precision, and convention choices.
- No known correctness debt in the supported behavior.

## Influences

This guide is influenced by:

- [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
  particularly its treatment of assertions, bounds, explicit memory, batching,
  and safe production builds.
- [Minish](https://github.com/CogitatorTech/minish), a candidate property-based
  testing framework whose adoption remains subject to dependency approval.
- Zig's integrated fuzzer and `std.testing.Smith`, described in the
  [Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html#Fuzzer).

Phaser adopts these ideas selectively. A scientific model compiler has different
constraints from a fixed-capacity database, so the governing rule is the rationale,
not imitation.
