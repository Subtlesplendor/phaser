# Phaser Design

Status: provisional design summary

This document captures the current design direction for Phaser. It is not a final
specification. Its purpose is to make the present idea concrete enough that each
part can be examined, challenged, and revised before implementation begins.

Engineering practices are documented separately in
[ENGINEERING_STYLE.md](ENGINEERING_STYLE.md).
The operational development process is documented in
[DEVELOPMENT_WORKFLOW.md](DEVELOPMENT_WORKFLOW.md).

## 1. Project idea

Phaser is intended to become a framework and ecosystem for perturbative quantum
field theory calculations relevant to thermal field theory and particle physics
phenomenology, with an initial emphasis on electroweak phase transitions.

The field currently contains several capable but poorly connected tools. Many
general phase-transition programs use conventional four-dimensional one-loop
effective potentials with thermal resummation. More modern calculations instead
use dimensional reduction to three-dimensional effective field theories and
strict perturbative expansions to combine thermal resummation with gauge
invariance. Specialist tools implement important parts of this workflow, but no
single general framework provides a clean, efficient, and extensible path from a
model definition to controlled thermodynamic calculations.

Phaser aims to provide that foundation incrementally.

The long-term vision includes calculations such as:

- Zero-temperature effective actions and effective potentials.
- Dimensionally reduced three-dimensional EFTs.
- Finite-temperature effective potentials within those EFTs.
- Strictly expanded thermodynamic quantities.
- Critical temperatures and phase structure.
- Bubble nucleation rates.
- Sphaleron rates.
- Inputs for baryogenesis, bubble-wall, and gravitational-wave calculations.

The first project is deliberately narrower. It focuses on a precise QFT model
format, an explicit calculation representation, and efficient potential kernels.

## 2. Initial scope

The initial physical input is a renormalizable QFT with operators of mass dimension
at most four. The representation follows the general organization used by
[Martin and Patel](https://arxiv.org/abs/1808.07615) and
[DRalgo](https://arxiv.org/abs/2205.08815):

- Real scalar components.
- Real gauge-vector components.
- Two-component Weyl fermions.
- Flattened coupling-weighted gauge interaction tensors.
- Scalar, mass, Yukawa, and gauge interactions represented by indexed tensors.

Canonical kinetic terms are the expected starting assumption. The exact supported
gauge algebras, representations, mixing terms, and convention choices have not yet
been fixed.

The first implementation should establish the common foundation needed to derive:

- The classical action.
- Background-shifted fields and interactions.
- Field-dependent quadratic operators and mass matrices.
- Vertices and indexed contractions.
- Perturbative effective-potential contributions.
- Efficient numerical evaluators of derived potentials.

The phrase "effective action" is initially used in a representational sense. The
IR should be capable of carrying derivative operators later, but the first
calculation target is the effective potential. General wave-function corrections,
arbitrary higher-derivative operators, and nonlocal effective actions are outside
the first scope.

## 3. Explicit non-goals for the first stage

The following are not part of the first architectural milestone:

- A general plugin protocol.
- A standardized EFT artifact exchanged between arbitrary programs.
- Phase tracing and critical-temperature searches.
- Bounce solving or complete nucleation rates.
- Sphaleron calculations.
- Bubble-wall dynamics.
- Gravitational-wave spectra.
- A general-purpose computer algebra system.
- A user interface for every existing phase-transition program.

These are important future consumers. They should influence the design only where
their requirements are already clear. Their protocols should not be invented in
advance of concrete implementations.

## 4. Design priorities

The architecture should make the following properties natural:

1. Scientific assumptions and approximation orders remain explicit.
2. Model structure is derived once and reused across parameter scans.
3. Changing a parameter point does not regenerate diagrams or expressions.
4. Temperature-dependent work is factored out of repeated background evaluation.
5. Contributions of different loop orders remain separate.
6. Symbolic results can be exported without reverse-engineering numerical code.
7. Numerical kernels can evaluate large batches without allocation.
8. Internal representations are deterministic, validated, and serializable.
9. The design preserves loop-resolved terms and can later consume explicitly
   power-counted results without requiring a general expansion engine initially.
10. Python and other languages interact through a narrow stable boundary.

## 5. Architectural overview

Phaser is conceived as a compiler pipeline rather than a function that repeatedly
"calculates the potential" from scratch.

```text
Human-readable model JSON
        |
        v
Source model parser
        |
        v
Validated canonical Model IR
        |
        +----------------------+
        |                      |
        v                      v
Calculation request       Model exporters
        |
        v
Derived Physics IR
        |
        v
Typed Value IR
        |
        +----------------------+
        |                      |
        v                      v
Symbolic exporters        Numerical lowering
                               |
                               v
                       Potential Kernel
                               |
                               v
                Parameter, scale, gauge, thermal,
                   and background evaluation
```

The intended major contracts are currently:

1. QFT Model Format.
2. Calculation Format and Calculation IR.
3. Potential Kernel interface and ABI.

Each contract has a human-facing API and a stricter canonical representation.

## 6. QFT Model Format

### 6.1 Source and canonical forms

The model format has two related JSON representations.

The source form is designed for humans:

- Expressions use a small infix language.
- Names are descriptive.
- Documentation fields are allowed.
- Sparse tensor components avoid overwhelming repetition.

The canonical form is designed for machines:

- Expressions are explicit syntax trees or references into an expression table.
- IDs and ordering are canonical.
- Tensor symmetries are normalized.
- Exact numbers remain exact.
- Surface differences covered by the canonicalization rules, such as whitespace,
  object ordering, and equivalent expression parenthesization, produce the same
  canonical representation and content hash.

Users normally edit only the source form. Phaser can normalize it to the canonical
form for caching, conformance testing, and interchange.

Canonicalization does not initially attempt to prove that models related by field
renaming or nontrivial field redefinitions describe the same physics. A document
or interface hash is not a basis-independent physics-equivalence hash.

### 6.2 Illustrative source model

The eventual schema will be more precise, but a source document may resemble:

```json
{
  "schema": "phaser.qft-model/0.1",
  "spacetime_dimension": 4,
  "conventions": {
    "metric": "mostly_plus",
    "fermions": "two_component_weyl",
    "scalar_representation": "real_components"
  },
  "parameters": {
    "mu2": {
      "domain": "real",
      "mass_dimension": 2
    },
    "lambda": {
      "domain": "real",
      "mass_dimension": 0
    }
  },
  "fields": {
    "real_scalars": [
      { "id": "h" }
    ],
    "weyl_fermions": [],
    "gauge_vectors": []
  },
  "tensors": {
    "scalar_mass_squared": {
      "components": [
        { "indices": ["h", "h"], "value": "-mu2" }
      ]
    },
    "scalar_quartic": {
      "components": [
        { "indices": ["h", "h", "h", "h"], "value": "6 * lambda" }
      ]
    }
  }
}
```

Tensor symmetry and normalization are properties of each schema-defined tensor
kind rather than fields repeated in every model. The scalar-potential convention
is specified in
[QFT Model Format: Fields and Tensor Components](docs/formats/QFT_MODEL_FIELDS.md#6-scalar-potential-tensors).

### 6.3 Expression language

The source expression language is specified in
[QFT Model Format: Expression Language](docs/formats/QFT_MODEL_EXPRESSIONS.md).
It contains integer literals, exact rationals expressed using division, declared
parameter identifiers, the exact constant `pi`, arithmetic, non-negative integer
powers, parentheses, and `sqrt` of positive dimensionless rational constants.

Decimal and scientific-notation literals are not part of model expressions.
Approximate numerical values belong to parameter points. The model language also
excludes assignment, control flow, implicit multiplication, general function
calls, I/O, and host-language evaluation.

Parsing produces a canonical expression AST with source spans retained for
diagnostics. Name resolution, exact constant folding, dimensional analysis, and
resource-limit checks occur before an expression enters canonical Model IR.
Derived calculation expressions may support operations such as logarithms
without making them legal in the model language.

### 6.4 Parameters

The model declares symbolic parameters and their properties, not a particular
numerical point. Relevant metadata may include:

- Stable identifier and display name.
- Real domain in schema version 0.1.
- Mass dimension.
- Optional assumptions or allowed ranges.
- Documentation and convention notes.

A numerical parameter point is a separate object specified by
[Renormalization Scales, Parameter Points, and RG Evolution](docs/formats/RENORMALIZATION_GROUP.md).
It includes a mass unit, renormalization scheme, reference scale, and values for
the model's independent parameters.

### 6.5 Fields, gauge structure, and tensors

The current field and tensor-component specification is documented in
[QFT Model Format: Fields and Tensor Components](docs/formats/QFT_MODEL_FIELDS.md).
The defining Lagrangian, fermion tensors, and complex values are specified in
[QFT Model Format: Lagrangian and Fermion Tensors](docs/formats/QFT_MODEL_LAGRANGIAN.md).
Gauge interactions are specified in
[QFT Model Format: Gauge Tensors](docs/formats/QFT_MODEL_GAUGE_TENSORS.md).

The model is expected to define:

- Independent real scalar components and their ordered index space.
- Weyl fermions and their index space.
- Gauge-vector components and their ordered index space.
- Flattened coupling-weighted vector, scalar, and fermion gauge tensors.
- Vacuum energy and scalar linear, quadratic, cubic, and quartic tensors.
- Fermion masses and Yukawa tensors.

Tensor storage is sparse and symmetry-aware. A source model stores one canonical
representative of each symmetric, antisymmetric, or Hermitian component orbit.
Field array order defines canonical component order; tensor components use
readable field IDs that are resolved to compact integer indices during
normalization.

The user supplies real scalar components and flattened coupling tensors
directly. Phaser does not accept complex scalar multiplets and does not perform
complex-to-real lowering. The initial model format also does not describe
alternative field bases, user-supplied basis transformations, mass eigenstates,
or spectra. The real components supplied by the user are the defining input
coordinates.

Gauge couplings and group actions are already combined in the flattened tensors
used by Martin--Patel and DRalgo. Product structure is represented by tensor
blocks rather than named gauge-factor or representation objects. Gauge kinetic
terms are canonical. Several Abelian vectors may have general commuting
couplings in that canonical basis, but Phaser does not accept or canonicalize a
nontrivial gauge kinetic matrix in schema version 0.1.

Complex fermion masses, Yukawa couplings, and fermion gauge tensors use
structurally separate real and imaginary expressions. Independent real
parameters represent both parts. The core format has no implicit flavor-family
replication; every Weyl component is explicit.

Ghosts, Goldstone organization, gauge-fixing terms, background-dependent masses,
and interaction vertices are derived calculation data. They do not normally
belong in the fundamental model document.

The model contains all independent real scalar components. A calculation
separately chooses the full scalar space or a component slice according to
[Background Parametrization](docs/formats/BACKGROUND_PARAMETRIZATION.md).

### 6.6 Validation

JSON Schema performs structural validation, but the Phaser validator also checks
scientific semantics:

- Index spaces and tensor ranks.
- Tensor permutation symmetries.
- Reality and hermiticity conditions.
- Operator mass dimensions.
- Flattened gauge-algebra and representation identities.
- Gauge invariance of mass, Yukawa, and scalar tensors.
- Compatibility of declared conventions.
- Resource limits and expression bounds.

The canonical Model IR is created only after validation succeeds. Code operating
on canonical IR may rely on these invariants and should assert them where useful.

### 6.7 Four- and three-dimensional models

The same broad model abstraction should represent both four- and
three-dimensional theories. Coupling dimensions and allowed field content depend
on `spacetime_dimension`.

At first, a derived 3D theory may simply be another validated QFT model. A richer
artifact containing matching relations, parent-model provenance, integrated-out
modes, and validity assumptions will be designed only when dimensional reduction
is concretely implemented.

## 7. Calculation representation

A model states what the theory is. A calculation states what should be derived and
under which conventions.

The request format and calculation lifecycle are specified in
[Phaser Calculation Format](docs/formats/CALCULATION_FORMAT.md).

The calculation format and the derived Calculation IR are related but distinct.
The request is compact; the derived IR contains explicit terms, loop orders,
provenance, dependencies, and output metadata.

Planned core calculation kinds cover the classical action, background expansion,
quadratic operators, vertices, effective potentials, RG functions, and
dimensional reduction. A 3D effective potential uses the ordinary
effective-potential calculation on a 3D model.

Numerical parameter values, renormalization-scale values, temperatures,
gauge-parameter values, and background evaluation points are dynamic bindings,
not structural calculation-request properties.

Phase tracing, critical-temperature determination, nucleation, sphaleron,
bubble-wall, baryogenesis, and gravitational-wave calculations are expected to
remain workflows or specialist plugins. Their detailed protocols are deferred.

## 8. Perturbative order and future power counting

The loop-order contract and the boundary of future power-counting support are
specified in
[Perturbative Order and Power-Counting Boundary](docs/formats/PERTURBATIVE_ORDER.md).

Phaser 0.1 assigns every perturbative contribution a non-negative integer loop
order. Contributions of different loop order remain separate until an explicit
selection or summation is requested. Loop truncation is inclusive,
non-destructive, and part of calculation identity.

Loop order does not imply a definite order in a coupling, thermal, EFT, or scale
hierarchy expansion. Phaser 0.1 does not infer alternative power countings or
derive expansions of masses, spectra, logarithms, thermal functions, or loop
integrals.

A future producer may supply terms already expanded under a named counting
scheme. Phaser may then preserve, truncate, export, and evaluate those terms
without claiming to have derived the expansion. Loop order and expansion order
remain separate metadata.

## 9. Renormalization-group dependence

The RG and parameter-point contracts are specified in
[Renormalization Scales, Parameter Points, and RG Evolution](docs/formats/RENORMALIZATION_GROUP.md).

Renormalization data is separate from thermal state. A numerical parameter point
declares a scheme, mass unit, reference scale \(\mu_0\), and values for the
model's parameters. Decimal JSON numbers are permitted in parameter points even
though they are not part of the exact QFT Model expression language.

Beta functions are calculation results rather than intrinsic fields of the model.
They depend on renormalization scheme, conventions, and loop order. An
`rg_functions` calculation may produce:

- Parameter beta functions.
- Mass and vacuum-energy beta functions.
- Field anomalous-dimension matrices.
- Gauge-parameter beta functions.

RG evolution is an explicit orchestration step outside the hot potential kernel:

```text
boundary parameter point at mu_0
        |
        v
RG evolution using a selected beta-function set
        |
        v
parameters at mu_R
        |
        v
potential kernel with explicit mu_R
```

The kernel receives parameters at the intended scale together with the explicit
renormalization scale used in logarithms. It does not silently solve RG equations
during every potential evaluation.

The API distinguishes at least these operations:

- Run from the reference scale to the evaluation scale.
- Parameters are already supplied at the evaluation scale.
- Hold parameters fixed while varying the explicit scale for a diagnostic.

## 10. Gauge fixing and gauge parameters

The gauge-fixing contract is specified in
[Gauge Fixing and Gauge Parameters](docs/formats/GAUGE_FIXING.md).

Gauge structure belongs to the model. Gauge fixing belongs to the calculation.
The initial general family is the generalized background-field
\(R_{\xi,\widetilde\xi}\) family of Martin and Patel, with independent diagonal
\(\xi_a\) and \(\widetilde\xi_a\) in the model's declared gauge-vector basis.
Fermi, background-field \(R_\xi\), and Landau gauges are supported
specializations.

This permits scanning gauge parameters and studying residual gauge dependence
without rebuilding the entire calculation.

The family and parameter-channel map are structural; non-fixed parameter values
are dynamic. A general-family artifact can evaluate Fermi and
background-field-\(R_\xi\) parameter points, while specialized requests may
derive simpler artifacts. Landau gauge is a structural limit rather than a
generic binding with `xi = 0`.

Gauge subfamilies need not be RG invariant to be supported. The API distinguishes
independent running in the general family, fixing gauge parameters at the
calculation scale, and explicitly reimposing a specialization at that scale.
Finite-order residual gauge dependence remains visible and is not silently
treated as a physical effect or silently discarded.

## 11. Internal representations

The internal representation contract is specified in
[Phaser Internal Representations](docs/architecture/INTERNAL_REPRESENTATIONS.md).

No single representation serves every stage. The principal lowering pipeline is:

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

These are semantic levels, not a requirement to build four independently owned
frameworks. In the initial scalar milestones, an effective-potential artifact
may consist directly of contribution records referencing one Typed Value IR
arena, and the potential kernel may own its lowered instruction tape. A general
indexed Derived Physics IR becomes concrete when vertices, contractions, and
diagrams require it.

The Canonical Model IR contains the validated, name-resolved model. The Derived
Physics IR preserves indexed contractions, contribution structure, topology,
loop order, and provenance. Its contractions use typed index slots and explicit
relationships rather than textual dummy-index names.

The Typed Value IR is an immutable interned DAG of exact, typed scalar and
finite-dimensional operations. Matrix and spectral operations may remain
high-level; provenance belongs to contributions rather than shared value nodes.
Local arena IDs provide efficient references but are not persistent identities.

The Numerical Kernel IR fixes layouts, evaluation and reduction order, temporary
storage, contraction plans, numerical operations, derivative capabilities, and
workspace requirements. Kernel compilation may initially produce an interpreted
evaluation program rather than native code. Numerical execution is
allocation-free and is not the source of symbolic export.

## 12. Structural compilation and dynamic binding

The structural/runtime boundary is specified in
[Structural Compilation and Dynamic Binding](docs/architecture/STRUCTURAL_COMPILATION.md).

Phaser distinguishes scientific structure, kernel configuration, and dynamic
inputs. Field content, declared tensor structure, calculation kind, background
parametrization, gauge-fixing family, renormalization scheme, and perturbative
selection affect derivation. Backend, precision, derivative capabilities, and
similar lowering choices affect kernel identity without changing the scientific
artifact. Masses, couplings, scales, gauge-parameter values, temperature, and
background coordinates are normally dynamic.

A value that happens to be zero at one parameter point is not a structural zero.
The generic kernel remains valid as scans cross zero and MUST NOT silently
recompile or prune terms.

Version 0.1 does not provide a general specialization system. A caller that needs
a structurally different theory constructs a distinct model or calculation
request. A future explicit specialization capability may promote exact
assumptions into structural information after a concrete use case establishes
its syntax, identity, and validation requirements.

Dynamic binding may precompute parameter- or temperature-dependent values.
Version 0.1 bindings are immutable control-plane objects and may allocate.
Creating a new binding must not repeat structural derivation.

## 13. Effective-potential representation

The effective-potential artifact contract is specified in
[Effective-Potential Artifact](docs/calculations/EFFECTIVE_POTENTIAL.md).

Conceptually:

```text
EffectivePotentialArtifact {
    contributions: []PotentialContribution
}

PotentialContribution {
    value: ValueId
    loop_order: LoopOrder
    origin: ProvenanceId
    role
    dependency_summary
}
```

The artifact retains deterministic, scientifically meaningful contributions
with separate exact values, loop orders, provenance, roles, and dependencies.
Selection and summation are explicit, non-destructive operations. In particular,
the API does not make an uncontrolled sum the only convenient representation.

Its background coordinates and their embedding are governed by
[Background Parametrization](docs/formats/BACKGROUND_PARAMETRIZATION.md).
A calculation may vary only a selected component slice, fixing every other
scalar background exactly to zero and exposing only the selected coordinates as
kernel inputs. All model scalars nevertheless remain quantum fluctuation fields
in mass matrices, vertices, and loops.

Background-independent contributions are retained by default. Dropping a
constant or subtracting a reference potential is an explicit, recorded
normalization operation because such terms can matter for RG consistency and
thermodynamic quantities.

### 13.1 Field-dependent spectra

Phaser does not require closed-form symbolic eigenvalues for arbitrary mass
matrices. Expressions such as

```text
trace(f(M_squared(background)))
```

remain high-level until numerical lowering. Spectral operations depend on the
eigenvalue multiset and do not assign persistent identities to eigenvalues or
eigenvectors. This avoids enormous symbolic expressions and ill-defined
eigenstate labels at degeneracies.

Symbolic artifacts preserve branch and complex-value semantics. Numerical
backends must diagnose unsupported domains rather than silently taking real
parts or absolute values. Gradient and Hessian capabilities preserve
contribution metadata and declare their method and domain; the exact spectral
derivative algorithm remains open.

## 14. Lifecycle and conceptual API

The lifecycle and evaluation-shape contract is specified in
[Evaluation Lifecycle and API Semantics](docs/architecture/EVALUATION_LIFECYCLE.md).

The proposed lifecycle is:

```text
load source model
    -> parse
    -> validate
    -> canonicalize
    -> plan calculation
    -> derive calculation
    -> compile numerical kernel
    -> bind parameter point and renormalization context
    -> bind temperature-dependent state when applicable
    -> evaluate arbitrary scalar points or runtime batches
```

An illustrative Python-facing API is:

```python
model = phaser.load_model("xsm.json")

plan = phaser.plan(
    model,
    phaser.EffectivePotential(
        loop_order=1,
        renormalization_scheme="MSbar",
        gauge_fixing="landau",
        background=phaser.ComponentSlice({"h": "h"}),
        environment=phaser.FiniteTemperature(),
    ),
)

calculation = plan.derive()
kernel = calculation.compile(target="native-cpu")

point_at_mu = rge.evolve(parameter_point, to=mu_R)

bound = kernel.bind(
    model_parameters=point_at_mu,
    renormalization_scale=mu_R,
)

potential = bound.at_temperature(T)

value, gradient = potential.value_gradient(background_point)
values = potential.value_batch(background_batch)
```

Names and object boundaries remain provisional. The important properties are:

- Derivation is separate from evaluation.
- Parameter binding is cheap.
- Temperature-dependent setup is not repeated for every background.
- Scalar evaluation is a first-class path for adaptive algorithms.
- Batches are supplied at runtime and need not be uniform or predetermined.
- Fused value, gradient, and Hessian capabilities can reuse intermediates.
- Background batches contain only the calculation's declared background
  coordinates, in canonical order.
- Scientific inputs are semantically separated.

## 15. Content fingerprints and deferred caching

The minimal fingerprint and reuse contract is specified in
[Content Fingerprints and Deferred Caching](docs/architecture/CONTENT_IDENTITY_AND_CACHING.md).

Version 0.1 provides a deterministic canonical-model fingerprint and explicit
reusable model, artifact, kernel, and binding objects. It does not require
canonical content IDs for produced artifacts, exact-decimal parameter-point
identities, or a general cache framework.

Keeping an object alive is the primary reuse mechanism. An implementation may
add a small typed in-memory memo table for a demonstrated repeated workload, but
cache presence, absence, refusal, or eviction never changes scientific results.
Persistent caches and cross-build artifact identities remain deferred until AOT
or interchange provides a concrete consumer.

## 16. Potential Kernel

The Potential Kernel contract is specified in
[Potential Kernel](docs/architecture/POTENTIAL_KERNEL.md).

The Potential Kernel is the performance boundary. It receives a fixed calculation
structure and evaluates it for dynamic numerical inputs. It is a
potential-specific interface built on general Numerical Kernel IR
infrastructure.

Its input categories remain distinct:

```text
PotentialKernel inputs
|-- model parameters at the intended scale
|-- renormalization scale
|-- gauge parameters
|-- thermal variables
|   `-- temperature
`-- background coordinates
```

The kernel should support, as capabilities rather than universal promises:

- Scalar potential value.
- Batched potential values.
- Gradient with respect to background coordinates.
- Hessian with respect to background coordinates.
- Fused value, gradient, and Hessian outputs where supported.
- Possibly derivatives with respect to selected parameters.

The initial complete production scalar type is `f64`. The first backend is a
safe reference interpreter for an immutable lowered instruction program.
Ahead-of-time code generation remains a later backend and must preserve the
same binding, status, metadata, and reproducibility contracts.

The kernel metadata defines:

- Input names, categories, shapes, units, and order.
- Required precision and backend.
- Supported derivative operations.
- Required alignment and workspace sizes.
- Output shapes and status reporting.
- Canonical model fingerprint and complete artifact and kernel metadata.
- Scientific calculation metadata.

Evaluation must not allocate. The caller supplies output and scratch buffers. The
API reports insufficient workspace as an ordinary error.

Scalar and batched evaluation are equally supported semantics. Contiguous batch
arrays are the preferred high-throughput representation when a caller naturally
has several points, while one-point calls remain efficient and suitable for
adaptive minimizers. Phaser does not delay scalar calls to manufacture hidden
batches. Public Hessians initially use full dense background-coordinate layout,
though internal storage may exploit symmetry.

## 17. Language and interoperability

The language and client boundaries are specified in
[Language and Interoperability](docs/architecture/LANGUAGE_AND_INTEROPERABILITY.md).

Zig is the sole primary implementation language for the Phaser core. The
repository pins an exact Zig toolchain version. Internal Zig APIs may evolve with
that toolchain; they are not a stable binary interface.

The normative cross-language boundary is a narrow, versioned C ABI. It exposes
opaque handles, structured diagnostics, metadata queries, and caller-provided
numerical buffers rather than Zig types or internal representations. The same ABI
is the native library API for C clients.

C++ callers can consume the C header directly. A later dedicated interoperability
milestone provides a thin, primarily header-only C++ convenience wrapper for
RAII, standard views, and idiomatic error handling. This wrapper is not a C++ ABI
and contains no scientific implementation.

Python is the first planned high-level researcher-facing language. Its production
binding should be a thin CPython extension written in Zig against Python's
Limited API, initially targeting CPython 3.11 or later. Numerical arrays cross
through the Python buffer protocol; NumPy is a user-level interface rather than a
mandatory C-API dependency. A `ctypes` client serves as an independent ABI
conformance test.

Phaser provides one Zig-written, language-independent CLI. Separate C, C++, or
Python implementations of that CLI are unnecessary. Small C embedding examples
exercise the first public library boundary; C++ examples arrive with the
dedicated C++ milestone.

ABI version `0` remains experimental. Version `1` should be declared only after
real C and Python consumers have exercised ownership, diagnostics, metadata,
static and shared linkage, and numerical buffers. The C++ wrapper consumes this
same C ABI and does not independently determine ABI maturity.

## 18. Memory architecture

Memory behavior is specified in
[Memory Architecture](docs/architecture/MEMORY_ARCHITECTURE.md).

Phaser does not require compile-time global arrays large enough for every model
and does not require exclusively static allocation. All core allocation is
explicit, bounded, phase-local, and allocator-injected. Version 0.1 supports:

- ordinary allocator-backed control-plane operation;
- independently owned persistent model, artifact, and kernel regions;
- resettable parsing, derivation, and lowering scratch arenas;
- immutable parameter bindings created without repeating derivation; and
- caller-owned evaluation workspace, inputs, and outputs.

Heapless or caller-provided fixed-buffer construction is deferred until a
concrete consumer justifies its additional ownership and capacity contracts.

Published objects are complete and immutable. Temporary memory never escapes its
operation. Object dependencies preserve parent lifetimes or copy the required
data. Construction is transactional: capacity failure produces a diagnostic
without publishing partial state.

Frontends may allocate or grow reusable storage at explicit lifecycle
transitions. Binding may allocate; numerical evaluation does not. Kernels report
exact workspace size and alignment before execution, and concurrent evaluation
streams use independent mutable workspaces.

## 19. Parallelism

Parallel execution is specified in
[Parallelism and Reentrancy](docs/architecture/PARALLELISM.md).

The initial core is serial but reentrant. Phaser does not create a hidden thread
pool or choose a host worker count. Callers initially own scheduling over natural
coarse dimensions such as:

- parameter points;
- temperatures;
- background points and batches; and
- independent models or calculations.

Immutable models, artifacts, kernels, and bindings are shareable. A different
parameter or state point initially uses a different immutable binding. Each
active stream has independent workspace and output. Batch semantics do not imply
threaded execution.

Future internal parallelism is an explicit backend capability whose worker
resources are prepared before evaluation. Under the reproducible policy, output,
status, diagnostics, symbolic canonicalization, and floating-point reduction
order are independent of scheduling and worker count on the same supported
target and backend.

## 20. Use of Zig `comptime`

Compile-time behavior and future model-specific code generation are specified in
[Zig `comptime` and Model-Specific AOT Compilation](docs/architecture/COMPTIME_AND_AOT.md).

The ordinary Phaser build uses `comptime` only for finite Phaser-owned structure,
including:

- IR and instruction metadata completeness;
- parser and builtin-function tables;
- type and ABI assertions;
- deliberately finite scalar, rank, derivative, and backend implementations;
- bounded diagram-topology catalogs; and
- small exact conformance checks.

Field counts, index dimensions, diagrams, expressions, and matrix sizes remain
runtime structure in the ordinary library. Arbitrary user models are not parsed,
derived, or symbolically simplified during the ordinary Zig build.

A future explicit AOT workflow may generate deterministic Zig source from a
validated artifact or lowered plan and invoke the pinned toolchain. Such a kernel
may know model structure at compile time while keeping parameters, scales,
temperatures, gauge parameters, backgrounds, and batches dynamic. It preserves
the ordinary kernel contract and is differentially tested against the safe
interpreter.

## 21. Symbolic export

Symbolic rendering and notebook display are specified in
[Symbolic Export and Notebook Display](docs/architecture/SYMBOLIC_EXPORT.md).

Exporters operate on the Derived Physics IR or Typed Value IR, never on optimized
Numerical Kernel IR. Scientific contribution selection precedes rendering and
remains distinct from presentation options.

Initial targets are:

- human-readable Phaser notation;
- delimiter-free MathJax-compatible LaTeX fragments;
- Python and Jupyter rich display using the LaTeX renderer.

Wolfram Language is delivered with C++ support in a separate interoperability
milestone after the initial C and Python surfaces have exercised the core
contracts.

Complete exports are complete or fail explicitly. Automatic notebook previews
may be bounded but must visibly identify omitted content. Exact values,
background embeddings, loop order, dependencies, spectral operations,
assumptions, and provenance remain available.

A stable canonical JSON AST and general round-trip import are deferred until
their compatibility contracts are intentionally designed.

## 22. Testing implications of the architecture

Architecture-wide verification is specified in
[Verification and Testing](docs/architecture/VERIFICATION_AND_TESTING.md).

The representation boundaries are deliberately testable against independent or
deliberately simpler paths:

- Source model versus canonical model.
- Canonical model versus serialized round trip.
- Indexed contractions versus dense reference contractions.
- Typed Value IR versus direct reference evaluation.
- Typed Value IR versus the safe kernel interpreter.
- Safe interpreter versus optimized or AOT kernels.
- Scalar versus batched execution.
- Independently constructed bindings with the same values.
- Safe versus selectively optimized kernels.
- Zig core versus the public clients implemented by the current milestone.
- Serial versus concurrent execution.
- Scientific IR versus symbolic export.

Evidence combines exact results, independent reference implementations,
properties, metamorphic transformations, differential paths, structured and
byte-level fuzzing, scientific fixtures, and external references. Exact domains
use exact comparison; numerical tolerances are local, named, and justified.

Ordinary CI is deterministic, bounded, offline, and independent of licensed
software. Longer fuzzing, large conformance models, high-precision comparisons,
and approved external regeneration run in broader or scheduled campaigns.

## 23. Provisional roadmap

The implementation sequence and milestone exit gates are specified in
[Implementation Roadmap](docs/architecture/IMPLEMENTATION_ROADMAP.md).

The roadmap uses vertical scientific slices:

- Milestone 0: design baseline and implementation substrate.
- Milestone 1: scalar model and expression foundation.
- Milestone 2: tree-level scalar potential end to end.
- Milestone 3: zero-temperature one-loop scalar potential.
- Milestone 4: experimental C, Python, Jupyter, and CLI surfaces.
- Milestone 5: C++ convenience and Wolfram Language interoperability.
- Milestone 6: general four-dimensional field content at one loop.
- Milestone 7: generalized background-field \(R_{\xi,\tilde\xi}\) gauges.
- Milestone 8: higher-loop structural compilation.
- Milestone 9: RG representation and evolution.
- Milestone 10: first four-dimensional-to-three-dimensional EFT vertical slice.
- Milestone 11: broader modern thermal workflows.

Each milestone has an independently useful artifact and verification gate.
Typed Value IR and the safe kernel therefore appear in the earliest slices that
need them, while general diagram generation is deferred until a higher-loop
calculation requires it.

Milestone 4 delivers the first mandatory public-API Jupyter notebook, including
LaTeX equation display and potential plots. Later researcher-facing physics
milestones add focused notebooks for their capabilities. Notebook plots expose
underlying data that is also verified by machine tests; plotting and execution
packages remain subject to explicit dependency approval.

Downstream phase tracing, nucleation, sphalerons, and gravitational-wave tools
remain deferred until the modern 3D EFT workflow demonstrates stable artifact and
kernel boundaries.

## 24. Conformance models

The scientific fixture contract and initial suite are specified in
[Scientific Conformance Models](docs/architecture/CONFORMANCE_MODELS.md).

The named suite begins with:

- real scalar \(\phi^4\);
- a multi-scalar theory with mixing and cubic interactions;
- the Wess–Zumino model;
- the Abelian Higgs model;
- the Standard Model; and
- the real-singlet extension of the Standard Model.

The Wess–Zumino model is the principal gauge-free scalar–Weyl fixture. It tests
complex Yukawa components, structural absence of gauge sectors, supersymmetric
mass relations, order-by-order vacuum-energy cancellations, and RG consistency
as the corresponding capabilities enter the roadmap. It is supplied as an
ordinary explicit component model; Phaser does not acquire a superfield or
supersymmetry-specific input layer.

Sector removal, zero-coupling and decoupling limits, relabeling, separately
supplied basis-transformed models, background restrictions, and vanishing
diagram classes are generated conformance cases rather than additional named
models.

## 25. Scientific references motivating the design

- Stephen P. Martin and Hiren H. Patel,
  [Two-loop effective potential for generalized gauge fixing](https://arxiv.org/abs/1808.07615).
- Stephen P. Martin,
  [Effective potential at three loops](https://arxiv.org/abs/1709.02397).
- Andreas Ekstedt, Philipp Schicho, and Tuomas V. I. Tenkanen,
  [DRalgo: a package for effective field theory approach for thermal phase
  transitions][dralgo].
- Philipp Schicho, Tuomas V. I. Tenkanen, and Graham White,
  [Combining thermal resummation and gauge invariance for electroweak phase
  transition][thermal-gauge].
- Johan Lofgren, Michael J. Ramsey-Musolf, Philipp Schicho, and
  Tuomas V. I. Tenkanen,
  [Nucleation at finite temperature: a gauge-invariant, perturbative
  framework][nucleation-framework].
- Joonas Hirvonen et al.,
  [Computing the gauge-invariant bubble nucleation rate in finite temperature
  effective field theory][nucleation-rate].

These references motivate the tensorial model representation, the separation of
four- and three-dimensional calculations, and the requirement that perturbative
orders remain explicit. They do not by themselves settle Phaser's software API.

[dralgo]: https://arxiv.org/abs/2205.08815
[thermal-gauge]: https://arxiv.org/abs/2203.04284
[nucleation-framework]: https://arxiv.org/abs/2112.05472
[nucleation-rate]: https://arxiv.org/abs/2112.08912
