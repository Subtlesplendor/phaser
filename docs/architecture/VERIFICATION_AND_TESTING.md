# Verification and Testing

Status: initial specification

This document specifies the architecture-wide verification strategy for Phaser.
It refines section 22 of [DESIGN.md](../../DESIGN.md) and complements the
project-wide rules in [ENGINEERING_STYLE.md](../../ENGINEERING_STYLE.md).
The operational test tiers, fuzz-campaign lifecycle, failure triage, and CI
policy are specified in
[Phaser Development Workflow](../../DEVELOPMENT_WORKFLOW.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as
requirements on Phaser implementations and test suites.

## 1. Scope

This specification covers:

- verification across representation boundaries;
- oracle independence;
- unit, integration, conformance, property, differential, metamorphic, fuzz, and
  regression testing;
- exact and numerical comparison policies;
- scientific conformance models;
- stateful lifecycle testing;
- diagnostics and assertion testing;
- allocation and scheduling fault injection;
- interoperability testing;
- test tiers and budgets;
- fixture provenance; and
- conceptual coverage.

Subsystem specifications continue to define their local required tests,
properties, and fuzz targets.

## 2. Governing principles

- No single oracle is sufficient for Phaser as a whole.
- A transformation is not adequately verified merely because its output passes
  a validator implemented with the same assumptions.
- Important optimized paths require a simpler independent reference path.
- Exact domains use exact comparison.
- Numerical comparison policies are named, local, scale-aware, and justified.
- Every discovered bug receives a minimized deterministic regression.
- External software and published results are evidence, not unquestionable truth.
- Golden files are reviewed regression artifacts, not sole scientific oracles.
- Ordinary CI is bounded, offline, and independent of licensed software.
  Deterministic tiers are reproducible; randomized property failures report the
  seed and minimized input required to reproduce them.
- Fuzz targets check semantic properties and resource bounds, not only crashes.
- Testability requirements influence production architecture from the beginning.

## 3. Oracle hierarchy

When several oracles are available, Phaser generally prefers:

1. exact mathematical results;
2. a deliberately simple independent implementation;
3. algebraic or metamorphic properties;
4. higher-precision numerical calculations;
5. independent external software or published results;
6. reviewed golden output; and
7. internal consistency alone.

This is a preference order, not a rule that only one oracle may be used. Important
functionality SHOULD combine several kinds of evidence.

An oracle is not independent merely because it is called through another API. A
reference path that reuses the production lowering, simplifier, sparse
contraction planner, or cache may reproduce the same error.

## 4. Boundary verification matrix

The initial architecture has the following verification obligations:

| Boundary | Primary independent evidence | Required concerns |
|---|---|---|
| Source bytes → expression AST | Grammar cases and byte fuzzing | precedence, bounds, diagnostics |
| Expression AST → normalized expression | Parse/print/parse and exact examples | exact values, names, idempotence |
| Source model → canonical model | Independently constructed small models | validation, dimensions, ordering |
| Sparse tensor → tensor operations | Slow dense component implementation | symmetry, permutations, zeros |
| Canonical model → derived physics | Hand-derived conformance models | vertices, masses, diagrams, absent sectors |
| Contributions → selected artifact | Exact selection algebra | loop order, provenance, summation |
| Typed Value IR → value | Simple recursive evaluator | operation semantics and domain failures |
| Typed Value IR → kernel | Direct reference evaluation | lowering, layouts, status behavior |
| Binding construction → evaluation | Independent construction | packing, completeness, failed publication |
| Scalar → batch | Repeated scalar calls | partitions, permutations, point statuses |
| Value → derivatives | Exact or higher-precision reference | gradients, Hessians, degeneracies |
| Safe interpreter → optimized/AOT | Differential evaluation | values, statuses, workspace, policy |
| Zig core → implemented public clients | Direct core calls | ownership, layouts, diagnostics |
| Serial → concurrent | Serial execution | ordering, races, reproducibility |
| Scientific IR → symbolic export | Source IR and target parser where available | exactness, precedence, omissions |

Every implemented boundary MUST identify at least one primary oracle or property.
If no independent oracle is practical, the limitation is documented and several
weaker forms of evidence SHOULD be combined.

## 5. Test categories

### 5.1 Unit tests

Unit tests exercise local behavior and invariants at their natural implementation
boundary. Tests requiring private declarations remain colocated with the Zig
source where practical.

Unit tests SHOULD prefer small exact cases. They MUST NOT depend on test execution
order or mutable process-global scientific state.

### 5.2 Integration tests

Integration tests exercise several subsystems or a public API together. They
include lifecycle, allocation, serialization, lowering, and language-boundary
behavior that cannot be established within one source unit.

### 5.3 Conformance tests

Conformance tests are language-neutral fixtures representing a specified public
format, scientific convention, or numerical contract. They are intended to be
usable by future independent implementations.

### 5.4 Property and metamorphic tests

Property tests generate a family of inputs and check a general invariant.
Metamorphic tests transform a valid input in a way with a known relationship to
the output.

### 5.5 Differential tests

Differential tests compare implementations that intentionally use different
representations or algorithms.

### 5.6 Fuzz tests

Coverage-guided fuzz tests explore byte-level, structured, and stateful inputs
under explicit resource bounds.

### 5.7 Regression tests

A regression test permanently records a minimized previously failing case. It
does not replace the broader property or fuzz target that found the failure.

### 5.8 Mutation testing

Mutation testing measures the other categories rather than the library. It
applies one single-token change to a source file at a time, reruns the bounded
suite, and reports the changes no test noticed.

A surviving mutant is a statement about the suite, not about the commit under
test: some line is executed without its result being constrained. It is
scheduled, rotated, and reported under
[Development Workflow](../../DEVELOPMENT_WORKFLOW.md#53-nightly-checks), and it
never gates a pull request. Decision
[0005](../decisions/0005-mutation-testing-dependency.md) records the tool and
its boundary.

## 6. Independent reference implementations

Phaser SHOULD maintain simple test-only reference implementations for important
optimized paths, as they become relevant and where the additional path is
unlikely to reproduce the same defect:

- dense tensor contraction with explicit component loops;
- recursive Typed Value IR evaluation;
- direct polynomial differentiation;
- naive matrix construction;
- repeated scalar evaluation of a batch;
- independent binding construction;
- straightforward canonical serialization; and
- a higher-precision numerical path.

Reference implementations optimize for clarity, small trusted surface, and
independence. They SHOULD NOT reuse production:

- contraction planning;
- common-subexpression elimination;
- numerical lowering;
- specialization;
- memoization;
- vectorization; or
- optimized accumulation.

A reference implementation MAY support a smaller bounded domain than production.
The shared comparison domain must be explicit.

## 7. Scientific conformance models

The fixture contract, named suite, generated cases, and milestone-specific
obligations are specified in
[Scientific Conformance Models](CONFORMANCE_MODELS.md).

The Wess–Zumino model is the principal gauge-free scalar–Weyl fixture. Among
other obligations, it verifies complex Yukawa components, field-dependent mass
relations, one- and higher-loop cancellations at supersymmetric minima, and RG
consistency as those capabilities become supported.

Scalar-only and gauge-free behavior, decoupling limits, relabeling, basis
covariance, background restrictions, and vanishing diagram classes are tested
as assigned properties of named fixtures rather than as an unstructured list of
additional models.

Every conformance case MUST state:

- applicable specification and purpose;
- conventions;
- calculation and supported order;
- exact and numerical expected quantities;
- derivation or source provenance;
- precision and comparison policy;
- known limitations; and
- relevant tool versions if externally generated.

## 8. Scientific consistency properties

As applicable to implemented calculations, tests SHOULD check:

- mass dimension of every term;
- tensor symmetry, reality, and Hermiticity;
- gauge invariance of the input action;
- covariance under field relabelling and supported basis transformations;
- structural absence of unsupported field sectors;
- derivative relationships between potentials, tadpoles, and mass objects;
- renormalization-group equations through the expected truncation residual;
- gauge-parameter cancellations for quantities and orders where expected;
- counterterm and pole cancellation;
- zero-temperature and thermal limits;
- decoupling and zero-coupling limits; and
- full-background derivation followed by restriction versus direct restricted
  derivation.

Perturbative consistency tests MUST be order-aware. A truncated calculation is
tested against the residual expected at the first omitted order, not against an
incorrect requirement of exact all-order invariance.

## 9. Exact and numerical comparison

### 9.1 Exact domains

The following use exact equality:

- integers and rationals;
- symbolic constants;
- canonical expression structure;
- tensor symmetries;
- field, index, and contribution ordering;
- loop and perturbative orders;
- provenance and structural-zero classification;
- model fingerprints and any canonical serialized identifiers actually
  promised; and
- canonical serialized bytes.

Floating-point tolerance MUST NOT determine symbolic equality or structural zero.

### 9.2 Same-kernel reproducibility

Where the kernel reproducibility contract promises identical results, tests use
bitwise comparison of outputs and statuses.

### 9.3 Independent numerical paths

Every approximate comparison policy records:

- quantity and operation;
- absolute tolerance;
- relative tolerance;
- optional ULP bound;
- reference precision;
- expected conditioning or scale;
- treatment of zero, subnormal, non-finite, and complex values;
- permitted point statuses; and
- branch policy.

There is no universal project tolerance.

Derivative generators SHOULD distinguish ordinary well-conditioned points from
exact and near-degenerate stress cases. Failure of a finite-difference oracle at
a singular point is not by itself evidence that a symbolic derivative is wrong.

## 10. Property generation

Generators SHOULD construct valid objects by design where possible. Useful
families include:

- exact expressions with controlled depth;
- tensor symmetries and independent components;
- invariant interactions constructed from representation data;
- valid background component slices;
- dependency graphs;
- valid typed kernel instruction programs;
- field permutations and supported basis transformations;
- parameter points with controlled zeros and hierarchies;
- batch partitions and permutations; and
- lifecycle operation sequences.

Near-valid inputs SHOULD be obtained by targeted mutation of one invariant at a
time. This produces useful validation coverage instead of spending most samples
on unrelated early rejection.

Every randomized property failure records:

- seed;
- generator version and configuration;
- minimized input;
- build mode and target;
- failing property; and
- relevant numerical policy.

Shrunk failures become ordinary regression fixtures.

Property generators belong behind the Phaser-owned harness in `test/property/`.
Minish is the adopted test-only property dependency, recorded in
[decision 0004](../decisions/0004-property-testing-dependency.md). No module
outside that harness imports it, and no published interface exposes its types.

## 11. Fuzzing layers

Coverage-guided fuzzing SHOULD prioritize untrusted byte and buffer boundaries:

1. arbitrary bytes into JSON, expression, and ABI parsers;
2. valid and near-valid QFT model documents;
3. calculation-request and contribution-selector documents;
4. C ABI handles, lengths, layouts, and buffers when the ABI exists;
5. complete bounded parse/derive/lower/bind/evaluate pipelines; and
6. symbolic exporter options and output limits.

Structured internal objects such as typed value nodes, sparse tensors,
contractions, and instruction programs SHOULD first receive deterministic
property tests. Dedicated fuzz targets are added when their complexity, exposure,
or defect history justifies the campaign; they are not automatic requirements
for every internal builder.

Fuzz targets MUST check more than absence of crashes. As applicable they check:

- deterministic diagnostics;
- bounded time, memory, and output;
- successful-stage invariants;
- idempotence and round trips;
- differential agreement;
- failure atomicity;
- allocation and capacity rollback;
- insertion-order independence; and
- absence of partial published objects.

Raw-byte fuzzing and structured fuzzing are complementary. Raw bytes exercise
trust boundaries; structured generators reach deep valid scientific states.

Every saved failure input is minimized where practical and added to the permanent
regression corpus.

## 12. Stateful lifecycle testing

Stateful tests SHOULD generate sequences such as:

```text
create context
load model
derive artifact
build kernel
create immutable binding
evaluate
create another binding
evaluate batch
share immutable objects
release objects
```

A small abstract lifecycle model determines which transitions are valid and what
state remains after an expected failure.

Stateful testing covers:

- ownership and release order;
- failed parsing, derivation, and binding construction;
- capacity exhaustion;
- repeated evaluation;
- scalar and batch interleaving;
- immutable sharing;
- workspace exclusivity; and
- invalid transition diagnostics.

## 13. Diagnostics and assertions

The common structured record, ownership, and deterministic ordering contract is
specified in [Foundation Types and Failure Reporting](FOUNDATION.md).

Negative fixtures SHOULD violate one intended rule at a time.

Tests normally assert:

- stable diagnostic code or category;
- source path, span, or object location;
- structured diagnostic fields;
- relevant cause relationships; and
- deterministic ordering.

Exact prose is asserted only when wording itself is part of the tested contract.

Invalid external input is rejected by an ordinary diagnostic. Internal invariant
failures are tested separately, using isolated assertion or death tests where
practical. A test MUST NOT treat an assertion as the correct rejection mechanism
for untrusted input.

## 14. Fault and schedule injection

The architecture MUST permit deterministic injection of:

- allocation failure at subsystem ownership and publication boundaries;
- exact capacity boundaries;
- task completion order where parallelism exists;
- cancellation where later supported; and
- selected numerical nonconvergence or domain failures through controlled test
  functions where appropriate.

Foundational transactional containers SHOULD receive exhaustive allocation-
failure coverage where practical. Higher-level scientific operations require
representative failures at meaningful transactional boundaries, not a separate
test for every internal allocation site. Fault injection MUST NOT remain enabled
accidentally in production behavior. The test path uses the same ownership and
rollback code as ordinary execution.

Randomized scheduling tests preserve a replayable seed or explicit schedule.

## 15. Interoperability verification

Public language surfaces are tested as their roadmap milestone introduces them:

- C compilation and execution;
- Python `ctypes` ABI conformance;
- production Python extension behavior; and
- the CLI where it represents a public workflow.

The later C++ milestone adds direct C-header and convenience-wrapper consumers.

Tests compare these clients with direct Zig-core behavior for:

- ownership and destruction;
- invalid input and diagnostics;
- model and calculation metadata;
- buffer sizing and alignment;
- scalar and batch values;
- derivative outputs;
- statuses; and
- symbolic export.

Static and shared linkage are both tested when supported.

## 16. Symbolic-export verification

Symbolic export follows
[Symbolic Export and Notebook Display](SYMBOLIC_EXPORT.md).

Tests combine:

- exact expected fragments for small expressions;
- precedence and escaping properties;
- parse-back for supported Phaser notation;
- semantic target comparison when an independent parser is available;
- bounded-preview behavior; and
- reviewed golden files for complex presentation.

Visual MathJax rendering and golden typography are presentation evidence. They
are not scientific oracles.

## 17. External references

External reference values SHOULD be stored in ordinary language-neutral fixtures
where licensing permits, so default CI does not require the generating program.

Reference provenance includes:

- software and version;
- input and conventions;
- precision and settings;
- generation script or reproducible procedure where possible;
- source publication where applicable; and
- any manual transformation.

Mathematica, DRalgo, or another program may disagree with Phaser because of a
convention, truncation, approximation, or defect in either implementation.
Disagreement is investigated rather than automatically resolved in favor of one
tool.

Adding an external program to a supported test or regeneration workflow is
subject to the external-dependency approval policy.

## 18. Golden files and regression corpora

Golden files are appropriate for:

- canonical serialization;
- model fingerprints and any promised canonical serialized identifiers;
- stable diagnostic structure;
- symbolic rendering;
- ABI metadata; and
- small reviewed scientific tables.

A golden update MUST state why the expected output changed. Bulk replacement is
not evidence of correctness.

A minimized readable corpus input MAY itself serve as the deterministic
regression. A separate focused unit regression is added when it improves
locality, clarity, or execution cost; it is not mandatory duplication.
Regression corpora only shrink when an entry is proven redundant and equivalent
coverage remains.

Tests MUST NOT hide flaky behavior through automatic retry.

## 19. Test tiers

The operational triggers, initial campaign ranges, platform policy, and failure
handling for these tiers are specified in
[Phaser Development Workflow](../../DEVELOPMENT_WORKFLOW.md#5-test-and-ci-tiers).

### 19.1 Per-change suite

The default bounded suite SHOULD include:

- unit tests;
- regression corpora;
- parser and model tests;
- small bounded property budgets with fresh seeds;
- integration tests;
- small language-neutral conformance models;
- ABI header and smoke tests where the relevant artifacts exist;
- examples; and
- Debug and ReleaseSafe behavior.

### 19.2 Broader CI

Broader CI SHOULD include:

- ReleaseFast differential behavior once Phaser supports a ReleaseFast,
  safety-disabled leaf, optimized, or AOT execution path whose comparison is
  meaningful;
- supported compiler and target combinations;
- larger randomized property budgets;
- saved fuzz corpora;
- allocation-failure injection;
- concurrency stress;
- deterministic generated-file checks; and
- larger conformance cases.

### 19.3 Scheduled campaigns

Scheduled or manually launched work MAY include:

- long coverage-guided fuzz campaigns;
- multi-core stateful fuzzing;
- high-precision comparisons;
- large realistic models;
- benchmark regression analysis; and
- approved external-reference regeneration.

No bounded test command claims to have “completed fuzzing.” It reports the
campaign budget and corpus used.

## 20. Performance testing

Correctness tests and benchmarks are distinct, though benchmarks may validate
outputs before recording timing.

Performance comparisons SHOULD record:

- model and calculation identity;
- parameter and evaluation workload;
- toolchain, target, CPU, and build mode;
- backend and numerical policy;
- warm-up and sampling procedure;
- allocation count and peak memory;
- latency, throughput, and variance; and
- generated kernel or binary size where relevant.

Regression thresholds are introduced only after stable representative baselines.
A faster result produced under different scientific semantics is not a valid
performance improvement.

## 21. Conceptual coverage

Line and branch coverage are useful diagnostics but are not sufficient.

As implemented capabilities become stable, the project SHOULD review whether
tests exercise:

- every tagged-union variant;
- every calculation kind;
- every supported perturbative order;
- every gauge family;
- every field sector and structural-absence case;
- every kernel instruction, capability, and status;
- every serializer and exporter operation;
- every lifecycle transition;
- exact and representative insufficient-capacity boundaries;
- every claimed reproducibility mode; and
- every supported public-language surface.

Formal requirement IDs for every specification paragraph are not initially
required. Test names and fixture documentation SHOULD identify the specification
concept they verify. A requirements manifest MAY be introduced if the suite
becomes difficult to audit without one.

## 22. Repository organization

Colocated Zig unit tests remain the default for private local behavior.

The top-level `test/` responsibilities are:

- `integration/`: multi-subsystem and public-API behavior;
- `conformance/`: language-neutral scientific and format cases;
- `reference/`: simple independent test-only implementations;
- `differential/`: comparisons among implementations or external fixtures;
- `fuzz/`: fuzz entry points and structured generators;
- `corpus/`: minimized permanent fuzz and regression inputs; and
- `fixtures/`: shared source and expected data.

Directories are created only when they contain real tests.

The build exposes distinct bounded test steps as specified in
[Phaser Engineering Style](../../ENGINEERING_STYLE.md). The default test step
imports suites deliberately and MUST NOT rely on accidental lazy discovery.

## 23. Example notebooks

Research notebooks follow
[Implementation Roadmap](IMPLEMENTATION_ROADMAP.md).

Notebooks provide a human inspection layer for symbolic equations, parameter
dependence, limiting behavior, and plots. The underlying numerical arrays,
metadata, and reference comparisons MUST also be available to machine tests.

A notebook is not accepted as the sole evidence for a numerical or scientific
claim. Maintained notebooks use public APIs, deterministic inputs, bounded
runtime, and fresh-kernel execution. Notebook execution belongs to the
appropriate CI tier once its tooling has been explicitly approved.

## 24. Deferred decisions

This specification deliberately leaves open:

- exact conformance-fixture schema;
- initial numerical comparison-policy types;
- first independent high-precision implementation;
- property-generator API;
- the declared numerical-comparison policy that metamorphic and cross-platform
  agreement assertions require;
- exact per-target property and fuzz budgets after implementation measurement;
- assertion/death-test mechanism;
- external-reference provenance schema;
- first coverage-reporting mechanism; and
- whether formal requirement-to-test traceability is later needed.
