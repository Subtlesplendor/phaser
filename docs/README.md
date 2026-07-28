# Specification index

This indexes the specification documents under `docs/` so a change can go
straight to the one or two files relevant to its subsystem instead of
scanning the whole corpus. Root-level [DESIGN.md](../DESIGN.md),
[ENGINEERING_STYLE.md](../ENGINEERING_STYLE.md), and
[DEVELOPMENT_WORKFLOW.md](../DEVELOPMENT_WORKFLOW.md) each carry their own
"Quick reference" table near the top; use those the same way.

If you're starting from a source or test path rather than a subsystem name,
[docs/AGENT_GUIDE.md](AGENT_GUIDE.md) routes it straight to the exact document
and heading, one level more precise than the tables below.

"Status" below is a rough read on how much of a document's content is still
the authoritative, unimplemented spec for upcoming work versus already
settled and reflected in `src/`. It is not a substitute for the document's
own text — sections mix past and future milestones inside a single file more
often than not, so read the section you need rather than trusting the
one-line summary alone.

## docs/architecture — cross-cutting subsystem contracts

| Document | Subsystem | Status |
|---|---|---|
| [FOUNDATION.md](architecture/FOUNDATION.md) | Typed IDs, spans, checked arithmetic, budgets, diagnostics | Implemented (`src/foundation/`); referenced as a shared contract throughout, so it stays in full. |
| [MEMORY_ARCHITECTURE.md](architecture/MEMORY_ARCHITECTURE.md) | Ownership, allocation phases, workspace contract | Implemented through Milestone 3, including the typed workspace frame the spectral kernel uses; the concurrency sections remain future work. |
| [CONTENT_IDENTITY_AND_CACHING.md](architecture/CONTENT_IDENTITY_AND_CACHING.md) | Content fingerprints, deferred caching | Implemented for what exists today; the caching sections it specifies remain deferred. |
| [PARALLELISM.md](architecture/PARALLELISM.md) | Reentrancy and future concurrency | Not yet exercised; core is still serial. |
| [STRUCTURAL_COMPILATION.md](architecture/STRUCTURAL_COMPILATION.md) | Structural/dynamic compiler | Future (Milestone 6+). |
| [COMPTIME_AND_AOT.md](architecture/COMPTIME_AND_AOT.md) | Compile-time specialization boundary | Mostly future; no AOT specialization machinery yet. |
| [LANGUAGE_AND_INTEROPERABILITY.md](architecture/LANGUAGE_AND_INTEROPERABILITY.md) | C/C++/Python bindings | Active — §5 is the Milestone 4 C ABI contract and §5.11 fixes its operation set; no client bindings are implemented yet. The C++ sections remain Milestone 5. |
| [VERIFICATION_AND_TESTING.md](architecture/VERIFICATION_AND_TESTING.md) | Testing policy, oracle strategy | Active — Milestone 1–3 policies are settled and applied; later milestones add tiers rather than change them. |
| [NUMERICAL_COMPARISON.md](architecture/NUMERICAL_COMPARISON.md) | Numerical agreement policy | Active — the spectral, near-degenerate, and zero-mode policies are measured and named by the Milestone 3 tests; cross-platform evidence is still a continuous-integration measurement. |
| [CONFORMANCE_MODELS.md](architecture/CONFORMANCE_MODELS.md) | Fixture models used as test oracles | Active — every Milestone 3 fixture case now runs model → artifact → kernel; the Wess–Zumino supertrace oracle (§6.4) is deferred to Milestone 6. |
| [KERNEL_INSTRUCTION_SET.md](architecture/KERNEL_INSTRUCTION_SET.md) | Kernel opcode set | Implemented through Milestone 3 — the spectral and complex opcodes are lowered and executed; later milestones add opcodes rather than change these. |
| [INTERNAL_REPRESENTATIONS.md](architecture/INTERNAL_REPRESENTATIONS.md) | Value IR, expression IR | Implemented through Milestone 3, including §5.4 (matrices and spectral operations). |
| [POTENTIAL_KERNEL.md](architecture/POTENTIAL_KERNEL.md) | Numerical evaluation kernel | Implemented through Milestone 3 — the complex/spectral kernel, its statuses, and its workspace contract are all exercised. |
| [EVALUATION_LIFECYCLE.md](architecture/EVALUATION_LIFECYCLE.md) | Evaluation call lifecycle and status codes | Implemented through Milestone 3 — complex results and the added statuses are reachable, except `nonconvergent`, which only a test-only checkpoint reaches. |
| [SYMBOLIC_EXPORT.md](architecture/SYMBOLIC_EXPORT.md) | Symbolic graph export/presentation | Implemented through Milestone 3 — loop-order headings and compact matrix/spectral notation are exported; later sectors remain explicitly deferred. |
| [IMPLEMENTATION_ROADMAP.md](architecture/IMPLEMENTATION_ROADMAP.md) | Milestone scope and sequencing | The authoritative source for milestone boundaries; read this first when unsure which milestone a subsystem belongs to. |

## docs/calculations — physics content of specific calculations

| Document | Milestone | Status |
|---|---|---|
| [CLASSICAL_SCALAR_POTENTIAL.md](calculations/CLASSICAL_SCALAR_POTENTIAL.md) | Milestone 2 | Implemented (`src/calculation/potential.zig`); keep its one Milestone 3 cross-reference in mind if you touch it. |
| [EFFECTIVE_POTENTIAL.md](calculations/EFFECTIVE_POTENTIAL.md) | Milestone 3 | Implemented — symbolic derivation and numerical value, gradient, and Hessian evaluation. |
| [SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md](calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md) | Milestone 3 | Implemented — the physics conventions this milestone's kernel executes. |

## docs/formats — model and request source-schema specifications

All of these are provisional specifications that gate what the Milestone 1–3
parsers accept; none is a closed chapter yet. Each states its own supported
subset per milestone in its body (e.g. `EFFECTIVE_POTENTIAL_REQUEST.md`
states exactly what Milestone 3 supports). `src/model/` implements the
model-format side.

| Document | Covers |
|---|---|
| [QFT_MODEL_FIELDS.md](formats/QFT_MODEL_FIELDS.md) | Field declarations and tensor-component encoding. |
| [QFT_MODEL_PARAMETERS.md](formats/QFT_MODEL_PARAMETERS.md) | Symbolic parameters and source-schema versioning. |
| [QFT_MODEL_EXPRESSIONS.md](formats/QFT_MODEL_EXPRESSIONS.md) | Expression-string grammar. |
| [QFT_MODEL_LAGRANGIAN.md](formats/QFT_MODEL_LAGRANGIAN.md) | Lagrangian convention, fermion mass/Yukawa tensors. |
| [QFT_MODEL_GAUGE_TENSORS.md](formats/QFT_MODEL_GAUGE_TENSORS.md) | Flattened gauge-interaction tensors. |
| [BACKGROUND_PARAMETRIZATION.md](formats/BACKGROUND_PARAMETRIZATION.md) | Variable scalar backgrounds and field-space embedding. |
| [GAUGE_FIXING.md](formats/GAUGE_FIXING.md) | Gauge-fixing families and gauge parameters. |
| [RENORMALIZATION_GROUP.md](formats/RENORMALIZATION_GROUP.md) | Renormalized parameter points, RG scales and evolution. |
| [PERTURBATIVE_ORDER.md](formats/PERTURBATIVE_ORDER.md) | Perturbative-order tracking and power-counting boundary. |
| [CALCULATION_FORMAT.md](formats/CALCULATION_FORMAT.md) | Source representation of a calculation request. |
| [EFFECTIVE_POTENTIAL_REQUEST.md](formats/EFFECTIVE_POTENTIAL_REQUEST.md) | `effective_potential` request schema and its supported subset through Milestone 3. |

## docs/decisions — accepted decision records

Each file states its own milestone/acceptance status in its "Status:" line —
that line is the fastest way to check whether a decision is settled, so it
isn't duplicated here. Numbered in acceptance order; read the ones for the
subsystem you're touching rather than the whole set.

[0001](decisions/0001-bounded-exact-arithmetic.md) bounded exact arithmetic ·
[0002](decisions/0002-typed-value-ir-scope.md) typed Value IR scope ·
[0003](decisions/0003-derivative-method.md) exact symbolic differentiation ·
[0004](decisions/0004-property-testing-dependency.md) property-testing dependency ·
[0005](decisions/0005-mutation-testing-dependency.md) mutation-testing dependency ·
[0006](decisions/0006-tripwire-error-injection-experiment.md) error-injection experiment ·
[0007](decisions/0007-milestone-3-oracle.md) Milestone 3 scalar one-loop oracle ·
[0008](decisions/0008-symmetric-eigensolver.md) deterministic real-symmetric eigensolver ·
[0009](decisions/0009-scalar-spectral-derivatives.md) scalar spectral derivatives ·
[0010](decisions/0010-fuzz-search-budget.md) fuzz tier allocator/search budget ·
[0011](decisions/0011-test-allocation-traces.md) allocation traces in test tiers ·
[0012](decisions/0012-mutation-rotation-retune.md) mutation rotation retune ·
[0013](decisions/0013-c-abi-v0-surface.md) C ABI version 0 surface ·
[0014](decisions/0014-public-header-and-toolchain-baseline.md) public header and toolchain baseline ·
[0015](decisions/0015-phase-b-python-dependencies.md) Milestone 4 Phase B dependencies (proposed)
