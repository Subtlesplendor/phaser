# Phaser Internal Representations

Status: provisional specification

This document specifies the semantic roles, boundaries, and invariants of
Phaser's internal representations. It refines section 11 of
[DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

This is an architectural specification. It does not prescribe Zig structure
layouts, arena implementations, integer widths, or a stable public
serialization.

## 1. Representation pipeline

Phaser distinguishes four principal semantic representation levels:

```text
Canonical Model IR
        |
        v
Derived Physics IR
        |
        v
Typed Value IR
        |
        v
Numerical Kernel IR
```

No level is the universal representation of a calculation.

- The **Canonical Model IR** represents a validated QFT model.
- The **Derived Physics IR** represents the scientific derivation and its
  indexed structure.
- The **Typed Value IR** represents exact scalar and finite-dimensional value
  operations.
- The **Numerical Kernel IR** represents a bounded numerical evaluation plan.

A transformation between levels MUST be semantically explicit and independently
testable. This does not require four separately allocated object frameworks.
Adjacent levels MAY share ownership, tables, builders, or a concrete Zig type
when their invariants and authoritative responsibilities remain clear.
Information required for scientific interpretation MUST either survive the
transformation or remain reachable through an immutable parent artifact.

Source JSON, parser ASTs, calculation requests, numerical parameter points, and
public API objects are not additional internal IR layers merely because they
have in-memory representations.

For the initial scalar milestones, the Derived Physics IR MAY consist of
effective-potential contribution records referencing one shared Typed Value IR
arena. A separate general indexed-physics framework is introduced only when
vertices, contractions, or diagrams require it. Likewise, the initial numerical
kernel object MAY own both its lowered instruction representation and its
potential-specific interface rather than materializing two persistent objects.

## 2. Common rules

### 2.1 Immutability

A completed model, calculation artifact, value graph, or numerical kernel
SHOULD behave as an immutable value. Construction MAY use private mutable
builders, but partially constructed state MUST NOT be exposed as a valid
artifact.

A transformation MUST NOT destructively alter its input. Selection, truncation,
and lowering produce a view or a distinct artifact.

### 2.2 Typed local identifiers

The concrete foundation contract for opaque representation, checked conversion,
and owner locality is specified in
[Foundation Types and Failure Reporting](FOUNDATION.md).

References within an artifact use semantically distinct identifier types, such
as:

```text
ScalarId
FermionId
GaugeVectorId
ParameterId
IndexSpaceId
TensorId
ContributionId
ValueId
ProvenanceId
```

Two identifier types MUST NOT be freely interchangeable even if they use the
same integer representation.

An internal ID is local to the table or arena that issued it. It MUST NOT be
treated as a persistent scientific identity or compared across unrelated
artifacts. Debug and validation builds SHOULD detect use with the wrong owner
where practical.

### 2.3 Semantic identity

Persistent identity is derived from canonical semantic content, not:

- local IDs;
- addresses or pointer values;
- allocation order;
- hash-table iteration order; or
- non-semantic presentation metadata.

If a cache is later implemented, every lookup key MUST include all upstream
structure and scientific settings that can affect the cached object. Hash
equality is not by itself proof of semantic equality. The version 0.1 model
fingerprint and deferred cache boundary are specified in
[Content Fingerprints and Deferred Caching](CONTENT_IDENTITY_AND_CACHING.md).

### 2.4 Bounds and ownership

Every representation has documented limits on its node counts, table sizes,
nesting, and memory use. Capacity exhaustion is an ordinary error.

Persistent objects SHOULD use arenas or other storage matching their shared
lifetime. Temporary transformations SHOULD use resettable scratch storage.
Traversals over externally influenced structures MUST use bounded iterative
worklists rather than unbounded recursion.

### 2.5 Diagnostics and invariants

Invalid external data, unsupported physics, and exhausted resource budgets
produce diagnostics. Violations of an invariant in an already validated IR are
programmer errors and SHOULD be asserted.

Each layer MUST define a validation or audit operation suitable for tests and
debugging. Expensive whole-artifact audits MAY be optional in production;
cheap local invariants remain enabled.

## 3. Canonical Model IR

### 3.1 Purpose

The Canonical Model IR is the validated, name-resolved meaning of a QFT model.
It is the only model representation accepted by calculation planning.

It contains, as applicable:

- spacetime dimension and model conventions;
- ordered field and index spaces;
- parameter declarations;
- flattened gauge-interaction tensors and validated algebra identities;
- canonical sparse tensors and their symmetries;
- exact normalized model expressions; and
- user-facing names and diagnostic source information.

It MUST NOT contain:

- a background parametrization;
- a gauge-fixing choice;
- a renormalization-scale value;
- a temperature;
- a numerical parameter point;
- diagrams or loop integrals; or
- a compiled evaluation plan.

These belong to calculations or numerical binding.

### 3.2 Resolution and storage

Source identifiers MUST be resolved once at the model boundary. Physics code
uses typed local IDs and MUST NOT repeatedly perform string lookup in numerical
paths.

Tensor storage MUST record:

- tensor kind;
- slot index spaces;
- value domain;
- mass dimension;
- permutation or conjugation properties; and
- canonical nonzero components.

The choice of sparse or dense backing storage is not part of the scientific
semantics. Equivalent storage strategies MUST expose the same canonical tensor
meaning.

### 3.3 Source and semantic information

Source spans and presentation strings MAY be retained in side tables for
diagnostics and export. They MUST NOT alter scientific content identity unless
a future format explicitly assigns them semantic meaning.

The input field order is semantic under QFT Model Format version 0.1. Compact
field IDs therefore follow that order. Phaser does not identify separately
authored models up to field permutations or basis transformations.

The parser AST is temporary. Exact expressions in the Canonical Model IR have
already been resolved, dimension-checked, and normalized according to the
[QFT Model Expression Language](../formats/QFT_MODEL_EXPRESSIONS.md).

### 3.4 Model invariants

A valid Canonical Model IR MUST satisfy at least:

- every local ID refers to an entry of the correct table;
- every tensor slot agrees with its declared index space;
- tensor components obey canonical symmetry storage;
- all expression references resolve to declared parameters;
- expression and tensor domains and mass dimensions agree;
- required reality, Hermiticity, and gauge identities have been checked for
  implemented tensor kinds; and
- no explicit component stored as nonzero is canonically zero.

## 4. Derived Physics IR

### 4.1 Purpose

The Derived Physics IR represents why a calculation has a particular value. It
preserves indexed scientific structure before choosing a component-level
numerical evaluation plan.

It may represent:

- background-expanded interactions;
- quadratic fluctuation operators;
- vertices;
- diagram topologies;
- tensor products and contractions;
- symmetry and multiplicity factors;
- loop-integral or thermal-function occurrences;
- perturbative order;
- gauge and renormalization metadata; and
- derivation provenance.

The IR MAY contain multiple calculation-specific object kinds. It is not
required that a vertex, a quadratic operator, and a potential contribution use
one universal record type.

### 4.2 Contributions

A result that is additive in perturbation theory is represented as an ordered
collection of contributions. Conceptually:

```text
Contribution {
    value_or_indexed_body
    loop_order
    provenance
    scientific_context
}
```

Loop order, provenance, gauge metadata, and other contribution-level
information MUST NOT be stored solely on a shared value-expression node.
Distinct contributions MAY refer to the same value while retaining different
origins and orders.

Combining or truncating contributions follows the
[Perturbative Order specification](../formats/PERTURBATIVE_ORDER.md). An API
that returns a selected sum SHOULD retain access to the unsummed contributions.

### 4.3 Indexed factors and slots

An indexed object is represented by typed factors with typed index slots.
Every slot records its `IndexSpaceId` and any additional orientation,
conjugation, or variance information required by that tensor kind.

Contractions are explicit relationships between slot occurrences. They MUST
NOT depend on textual dummy-index names. A contraction relationship is valid
only when all connected slots are compatible.

The representation MUST distinguish:

- contracted slots;
- free output slots;
- fixed component selections; and
- invalid unbound slots.

Contraction groups MAY be represented internally as edges, hyperedges, or
canonical labels. Whichever storage is chosen, renaming a dummy index MUST NOT
change semantic identity.

Textual names such as `i`, `j`, and `a` are generated presentation choices for
export. They are not internal index identities.

### 4.4 Canonical indexed form

Canonicalization MUST define deterministic ordering for:

- factors;
- free slots;
- contraction groups;
- diagram or topology labels; and
- contribution lists.

The canonical form MUST account for declared tensor symmetries and dummy-index
renaming. It need not prove arbitrary tensor identities.

Phaser SHOULD preserve abstract contractions while that representation is
smaller or scientifically more informative than component expansion.
Component expansion is an explicit lowering choice governed by resource limits
and backend capabilities.

### 4.5 Topology and provenance

Diagram topology and provenance are immutable records separate from shared
algebraic values. A contribution refers to those records by typed IDs.

Compact production provenance SHOULD be able to identify, as applicable:

- the requested calculation;
- dependent derivations;
- diagram or contribution class;
- originating vertices or tensors;
- symmetry and multiplicity factors;
- loop order;
- gauge-fixing and renormalization context; and
- simplification or lowering steps that materially affect interpretation.

Detailed transformation histories MAY be retained in optional audit data rather
than on every production contribution. Shared provenance records SHOULD be
interned where detailed origins would otherwise dominate artifact memory. The
initial representation need not be a stable public provenance schema.

If a contribution class vanishes structurally, the calculation artifact MUST
still distinguish that result from an unsupported or silently omitted class.
This MAY be represented by an explicit zero contribution or by artifact-level
derivation metadata.

## 5. Typed Value IR

### 5.1 Purpose

The Typed Value IR represents exact operations after abstract physics indices
have been resolved or encapsulated. It is the source for symbolic value export
and numerical lowering.

It is an immutable, acyclic, interned graph. Nodes refer to children by
`ValueId`; they do not recursively own child nodes.

It is called a value IR rather than a scalar expression DAG because some nodes
produce structured finite-dimensional values.

### 5.2 Value types

Every node has a statically validated value type. Types distinguish at least:

- scalar domain, including real or complex where supported;
- scalar, vector, matrix, or another supported finite shape;
- known dimensions of structured values;
- relevant matrix properties such as symmetric or Hermitian; and
- physical mass dimension where applicable.

An implementation MAY encode these properties in multiple associated tables
rather than one runtime type record. Ill-typed nodes MUST be rejected during
construction.

Initial implementations MAY support only the subset of value types required by
their declared calculation support.

Milestone 1 implements real scalar values with exact mass dimension. Its node
subset consists of reduced rationals, parameter inputs, `pi`, exact square roots
of positive rationals, negation, ordered addition and multiplication, division,
and non-negative integer powers. Source-expression normalization preserves
operand order and does not introduce general algebraic equivalence.

### 5.3 Node capabilities

The IR is expected to support categories including:

- exact constants;
- model-parameter inputs;
- renormalization-scale inputs;
- gauge-parameter inputs;
- temperature and other environment inputs;
- background-coordinate inputs;
- typed arithmetic;
- finite matrix construction and access;
- traces, determinants, and other matrix operations;
- high-level spectral functions;
- logarithms and thermal functions; and
- loop master integrals.

This list defines architectural capability, not a frozen opcode enumeration.
Every implemented node kind MUST specify:

- operand and result types;
- exact or numerical semantics;
- domain and branch requirements;
- canonicalization rules;
- differentiation support; and
- backend support.

An unsupported node/backend combination is reported during lowering, not
silently approximated.

### 5.4 Matrices and spectral operations

General symbolic mass-matrix eigenvalues need not be constructed. A
field-dependent matrix MAY remain a structured value referenced by a node such
as a trace of a spectral function.

Matrix dimensions are structural and MUST be known before numerical kernel
evaluation. Matrix values MUST record properties that a backend may safely rely
upon, such as symmetry or Hermiticity.

A backend MUST NOT assume such a property merely because it is expected
physically; the property must have been established by construction or
validation.

### 5.5 Interning and equality

`ValueId` equality denotes structural identity within one value arena.
Interning MUST use exact structural equality and MUST NOT use a
floating-point tolerance.

Interning does not imply general mathematical equivalence. Phaser is not
required to discover arbitrary identities, factorizations, cancellations, or
functional relations.

Canonical construction MUST be deterministic. Exact associative and
commutative operations MAY be flattened and sorted by a defined canonical key.
Operations that are noncommutative or whose ordering is semantically relevant
MUST preserve that ordering.

Source-expression normalization and derived-value canonicalization are related
but distinct contracts. The source language guarantees only the normalization
specified by its own format. The derived IR MAY apply stronger, explicitly
specified exact canonicalization.

### 5.6 Symbolic and floating-point order

The Typed Value IR contains exact symbolic structure. Floating-point evaluation
begins only during explicit numerical lowering or execution.

Numerical lowering MUST choose a defined evaluation and reduction order.
Reproducible execution MUST NOT derive that order from allocation, hash-table,
or thread-scheduling behavior. A faster backend MAY use a different order only
under an explicit reproducibility policy. Worker scheduling and deterministic
merging follow [Parallelism and Reentrancy](PARALLELISM.md).

## 6. Numerical Kernel IR

### 6.1 Purpose

The Numerical Kernel IR is a backend-neutral or backend-specific bounded plan
for evaluating a fixed calculation structure with dynamic numerical inputs.

Compiling a kernel does not necessarily mean generating native machine code.
The initial Potential Kernel backend interprets an immutable instruction stream
according to [Potential Kernel](POTENTIAL_KERNEL.md). Future backends may
generate Zig, native code, accelerator code, or another optimized form without
changing upstream scientific semantics.

Model-specific Zig generation follows
[Zig `comptime` and Model-Specific AOT Compilation](COMPTIME_AND_AOT.md).

### 6.2 Inputs and outputs

The kernel metadata defines:

- input categories, names, types, shapes, units, and canonical order;
- output categories, types, shapes, and order;
- included contributions and perturbative truncation;
- numerical scalar type and precision;
- backend and reproducibility policy;
- derivative capabilities;
- required alignment and scratch workspace;
- model and calculation identities; and
- applicable scientific and approximation metadata.

Model parameters, scale values, gauge parameters, temperatures, and background
coordinates remain distinct input categories even if they share a machine
scalar type.

### 6.3 Evaluation plan

Lowering selects:

- an evaluation order;
- scalar and matrix layouts;
- contraction plans;
- common subexpressions;
- temporary slots and their lifetimes;
- numerical implementations of special functions and master integrals;
- derivative strategy;
- accumulation order; and
- error and branch handling.

The plan MUST have statically bounded workspace for a fixed kernel and batch
capacity. Kernel execution MUST NOT allocate. Insufficient caller-provided
workspace is an ordinary error.

The kernel MUST be reusable across dynamic parameter points, scales,
temperatures, gauge-parameter values, and background batches within its
declared domain. A dynamic value becoming zero MUST NOT trigger implicit
structural recompilation.

### 6.4 Execution semantics

Every kernel operation has defined status behavior for domain errors,
nonconvergence, overflow, non-finite values, and unsupported complex results.
The kernel MUST NOT silently discard imaginary parts, substitute a different
approximation, or return an undocumented partial result.

Evaluation is reentrant when callers provide independent workspace. No result
may depend on mutable global evaluation state.

An independently testable reference executor SHOULD exist for the kernel
semantics. Optimized backends MUST be differentially testable against it over
their common supported domain.

### 6.5 Relationship to symbolic output

The Numerical Kernel IR is not the authoritative representation for symbolic
export or scientific provenance. Exporters consume the Derived Physics IR or
Typed Value IR.

The export-view and target-rendering contracts are specified in
[Symbolic Export and Notebook Display](SYMBOLIC_EXPORT.md).

Backend optimization MAY erase high-level symbolic structure from a kernel
provided that the parent calculation artifact remains identifiable and
available through the surrounding API or artifact store.

## 7. Transformation contracts

Each semantic lowering stage MUST:

1. accept only a validated input representation;
2. validate requested capabilities and resource budgets;
3. produce deterministic output under the selected policy;
4. preserve or explicitly record scientific metadata;
5. leave its input unchanged;
6. establish the invariants promised by the output layer; and
7. return a diagnostic rather than a partial valid-looking artifact on failure.

Transformations SHOULD expose compact audit summaries including input
fingerprints where available, counts, selected lowering policies, and grouped
structurally removed or zero contribution classes. Version 0.1 does not require
a content hash or complete transformation trace for every produced internal
object.

Optimization passes MUST preserve typed semantics and contribution metadata.
Version 0.1 optimization MUST NOT introduce an additional physical assumption.
Any future assumption-based transformation belongs to a separately specified
specialization capability, not ordinary lowering.

## 8. Serialization

No internal IR has a stable public serialization in Phaser schema version 0.1.
Public artifact interchange will be specified only in response to a concrete
use case.

Debugging, testing, or cache serialization MAY be implemented. Such a
serialization MUST:

- carry its own internal format version;
- serialize nodes in deterministic dependency order;
- remap arena-local IDs to serialization-local IDs;
- preserve required types and scientific metadata;
- reject dangling or cyclic references; and
- produce deterministic bytes and any optional fingerprint without depending on
  raw local IDs.

Internal serialized data MUST NOT be presented as a portable compatibility
contract unless it is promoted by a separate specification.

## 9. Validation and testing

Architecture-wide oracle independence, property, differential, and fuzzing rules
follow [Verification and Testing](VERIFICATION_AND_TESTING.md).

Required tests include:

- wrong-ID-type prevention and debug assertions at boundaries where ownership
  mistakes are realistically possible;
- deterministic model fingerprinting independent of allocation and hash-map
  order;
- Canonical Model IR validation from valid and near-valid models;
- tensor-symmetry and sparse/dense agreement tests;
- dummy-index renaming invariance;
- indexed-contraction comparison with direct component sums;
- canonicalization idempotence;
- insertion-order independence where canonical ordering is promised;
- Typed Value IR type, shape, dimension, and acyclicity checks;
- interning equality and deliberate non-equivalence cases;
- provenance preservation when equal values are shared;
- structural-zero versus unsupported-result tests;
- symbolic/direct evaluation agreement;
- kernel workspace boundary and allocation-failure tests;
- scalar and batched kernel agreement;
- reference and optimized executor differential tests; and
- deterministic serialization round trips for any internal format that is
  implemented.

Fuzzing SHOULD prioritize untrusted serialized and buffer boundaries. Typed
internal construction APIs SHOULD use property tests; they require dedicated
fuzz targets only when their complexity or defect history justifies them.

## 10. Deferred decisions

This specification deliberately does not fix:

- Zig field layouts or concrete arena types;
- integer widths and generation-tag strategies for local IDs;
- the complete set of Derived Physics IR object kinds;
- the exact canonical ordering of indexed factor graphs;
- the complete Typed Value IR opcode and type sets;
- detailed simplification and differentiation algorithms;
- the boundary between symbolic contraction and component lowering for each
  backend;
- the first kernel instruction set;
- interpreter, AOT, JIT, or accelerator implementation details;
- public calculation-artifact serialization; or
- a stable provenance interchange schema.

These choices require focused specifications or implementation evidence. They
MUST remain compatible with the layer boundaries and invariants defined here.
