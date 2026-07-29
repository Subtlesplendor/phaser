# Task-to-spec routing

A compact index from *what you're touching* to the *exact* document and
heading that governs it. [docs/README.md](README.md) maps whole documents to
subsystems; this file goes one level deeper, to headings, so a change to one
directory pulls in 50-150 relevant lines instead of 500-1,000. Anchors are
GitHub heading slugs — click through if unsure a link still matches after a
doc is restructured.

If a path isn't listed, fall back to [docs/README.md](README.md).

## By source path

| Path | Read |
|---|---|
| `src/foundation/**` | [FOUNDATION.md](architecture/FOUNDATION.md) (whole document — it's already scoped to this directory) |
| `src/model/**` | [INTERNAL_REPRESENTATIONS.md §3 Canonical Model IR](architecture/INTERNAL_REPRESENTATIONS.md#3-canonical-model-ir); [CONTENT_IDENTITY_AND_CACHING.md §3 Model fingerprint](architecture/CONTENT_IDENTITY_AND_CACHING.md#3-model-fingerprint); the relevant `docs/formats/QFT_MODEL_*.md` file for the declaration you're changing |
| `src/expression/**` | [INTERNAL_REPRESENTATIONS.md §4 Derived Physics IR](architecture/INTERNAL_REPRESENTATIONS.md#4-derived-physics-ir); exact-arithmetic changes also need [ENGINEERING_STYLE.md §Exact and numerical domains](../ENGINEERING_STYLE.md#exact-and-numerical-domains) and [decision 0001](decisions/0001-bounded-exact-arithmetic.md) |
| `src/value/**` | [INTERNAL_REPRESENTATIONS.md §5 Typed Value IR](architecture/INTERNAL_REPRESENTATIONS.md#5-typed-value-ir); spectral/matrix nodes specifically: [§5.4 Matrices and spectral operations](architecture/INTERNAL_REPRESENTATIONS.md#54-matrices-and-spectral-operations) and [decision 0009](decisions/0009-scalar-spectral-derivatives.md); differentiation: [decision 0003](decisions/0003-derivative-method.md) |
| `src/numerics/**` | [NUMERICAL_COMPARISON.md §6 Catalog](architecture/NUMERICAL_COMPARISON.md#6-catalog) for the comparison policy a new algorithm must satisfy; the relevant algorithm decision (currently [decision 0008](decisions/0008-symmetric-eigensolver.md) for the eigensolver) |
| `src/calculation/**` | The relevant `docs/calculations/*.md` file (see [docs/README.md](README.md) for which one); [CONTENT_IDENTITY_AND_CACHING.md §4 Calculation and kernel metadata](architecture/CONTENT_IDENTITY_AND_CACHING.md#4-calculation-and-kernel-metadata) |
| `src/kernel/**` | [POTENTIAL_KERNEL.md](architecture/POTENTIAL_KERNEL.md) — opcode-level changes: [KERNEL_INSTRUCTION_SET.md §4 Opcode catalog](architecture/KERNEL_INSTRUCTION_SET.md#4-opcode-catalog) and [§5 Evaluation order](architecture/KERNEL_INSTRUCTION_SET.md#5-evaluation-order); workspace/allocation: [MEMORY_ARCHITECTURE.md §12 Evaluation workspace](architecture/MEMORY_ARCHITECTURE.md#12-evaluation-workspace) and [POTENTIAL_KERNEL.md §13 Workspace](architecture/POTENTIAL_KERNEL.md#13-workspace); status/error codes: [POTENTIAL_KERNEL.md §14 Status and failure](architecture/POTENTIAL_KERNEL.md#14-status-and-failure) and [KERNEL_INSTRUCTION_SET.md §8 Status](architecture/KERNEL_INSTRUCTION_SET.md#8-status) |
| `src/export/**` | [SYMBOLIC_EXPORT.md](architecture/SYMBOLIC_EXPORT.md) |
| `src/abi/**`, `include/phaser.h` | [LANGUAGE_AND_INTEROPERABILITY.md §5 C ABI](architecture/LANGUAGE_AND_INTEROPERABILITY.md#5-c-abi), especially [§5.11 Version 0 operation set](architecture/LANGUAGE_AND_INTEROPERABILITY.md#511-version-0-operation-set); [decision 0013](decisions/0013-c-abi-v0-surface.md) for the handle, ownership, and status contracts; [decision 0014](decisions/0014-public-header-and-toolchain-baseline.md) for the header, language baseline, and platform matrix. Changing an exported symbol, a struct layout, or an enumerator value is an ABI change even while version 0 is experimental |
| `bindings/python/**` | [LANGUAGE_AND_INTEROPERABILITY.md §8 Python](architecture/LANGUAGE_AND_INTEROPERABILITY.md#8-python); [decision 0015](decisions/0015-phase-b-python-dependencies.md) for the approved dependency set and the boundary it must stay behind. The extension contains no physics: it reaches the core through the C ABI, so a change here that computes something is in the wrong place |
| `docs/notebooks/**` | [IMPLEMENTATION_ROADMAP.md §3 Research notebooks](architecture/IMPLEMENTATION_ROADMAP.md#3-research-notebooks) for what every maintained notebook must do; [decision 0015](decisions/0015-phase-b-python-dependencies.md) for the approved packages, the Linux-only execution tier, and the rule that outputs are never versioned. Run `tools/ci/clear_notebook_outputs.py` before committing |
| `src/cli/**` | [LANGUAGE_AND_INTEROPERABILITY.md §9 Command-line interface](architecture/LANGUAGE_AND_INTEROPERABILITY.md#9-command-line-interface) |
| `src/testing/**` (error injection) | [VERIFICATION_AND_TESTING.md §14 Fault and schedule injection](architecture/VERIFICATION_AND_TESTING.md#14-fault-and-schedule-injection); [ENGINEERING_STYLE.md §Error-path injection](../ENGINEERING_STYLE.md#error-path-injection) |

## By test path

| Path | Read |
|---|---|
| `test/fuzz/**` | [VERIFICATION_AND_TESTING.md §11 Fuzzing layers](architecture/VERIFICATION_AND_TESTING.md#11-fuzzing-layers); [DEVELOPMENT_WORKFLOW.md §6 Fuzz targets](../DEVELOPMENT_WORKFLOW.md#6-fuzz-targets) and [§7 Fuzz failure and corpus protocol](../DEVELOPMENT_WORKFLOW.md#7-fuzz-failure-and-corpus-protocol) |
| `test/property/**` | [VERIFICATION_AND_TESTING.md §10 Property generation](architecture/VERIFICATION_AND_TESTING.md#10-property-generation); [DEVELOPMENT_WORKFLOW.md §8 Property-based testing](../DEVELOPMENT_WORKFLOW.md#8-property-based-testing); [decision 0004](decisions/0004-property-testing-dependency.md) |
| `test/conformance/**`, `test/fixtures/**` | [VERIFICATION_AND_TESTING.md §7 Scientific conformance models](architecture/VERIFICATION_AND_TESTING.md#7-scientific-conformance-models); [CONFORMANCE_MODELS.md](architecture/CONFORMANCE_MODELS.md) for the fixture contract |
| `test/differential/**` | [VERIFICATION_AND_TESTING.md §9.3 Independent numerical paths](architecture/VERIFICATION_AND_TESTING.md#93-independent-numerical-paths) |
| `test/integration/**` | [VERIFICATION_AND_TESTING.md §5.2 Integration tests](architecture/VERIFICATION_AND_TESTING.md#52-integration-tests); the `abi_*.zig` suites additionally need [VERIFICATION_AND_TESTING.md §15 Interoperability verification](architecture/VERIFICATION_AND_TESTING.md#15-interoperability-verification) and the two ABI decisions above |
| `test/corpus/**` (regression corpora) | [VERIFICATION_AND_TESTING.md §18 Golden files and regression corpora](architecture/VERIFICATION_AND_TESTING.md#18-golden-files-and-regression-corpora) |
| `test/support/**` (allocator instrumentation, leak checks) | [MEMORY_ARCHITECTURE.md §19 Validation, testing, and fuzzing](architecture/MEMORY_ARCHITECTURE.md#19-validation-testing-and-fuzzing); [decision 0011](decisions/0011-test-allocation-traces.md) |

## By change type (not path-specific)

| Change | Read |
|---|---|
| Adding, upgrading, or changing scope of a dependency | [ENGINEERING_STYLE.md §Dependencies](../ENGINEERING_STYLE.md#dependencies); [AGENTS.md §External dependencies](../AGENTS.md#external-dependencies) — permission is required before proposing |
| New mutation-testing target or `zentinel.toml` change | [decision 0005](decisions/0005-mutation-testing-dependency.md) |
| New numerical-agreement claim ("these two paths agree") | [NUMERICAL_COMPARISON.md §6 Catalog](architecture/NUMERICAL_COMPARISON.md#6-catalog); Milestone 3 work specifically also needs [§7 Milestone 3 measurement](architecture/NUMERICAL_COMPARISON.md#7-milestone-3-measurement) |
| Changing what milestone a change belongs to, or checking exit criteria | [IMPLEMENTATION_ROADMAP.md](architecture/IMPLEMENTATION_ROADMAP.md), section for that milestone |
| Branch, commit, or PR mechanics | [DEVELOPMENT_WORKFLOW.md §3 Branches, commits, and pull requests](../DEVELOPMENT_WORKFLOW.md#3-branches-commits-and-pull-requests) |
| Recording a new engineering decision | [DEVELOPMENT_WORKFLOW.md §2 From design to implementation](../DEVELOPMENT_WORKFLOW.md#2-from-design-to-implementation); follow the numbering and format of an existing file in `docs/decisions/` |

## Keeping this file honest

This index goes stale if a heading is renumbered or a directory is added
without an entry. When you rename or renumber a heading this file links to,
grep for the old anchor across `docs/AGENT_GUIDE.md` and fix it in the same
change. When you add a new top-level `src/` or `test/` directory, add a row
here before the change that introduces it merges.
