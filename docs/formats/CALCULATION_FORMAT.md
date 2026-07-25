# Phaser Calculation Format

Status: provisional specification

This document specifies the role and source representation of calculation
requests in Phaser. It refines section 7 of [DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Purpose

A QFT model states what a theory is. A calculation request states what Phaser
should derive from that model and under which scientific conventions.

A calculation request is not:

- a numerical parameter point;
- a collection of background points;
- a compiled numerical kernel;
- the derived symbolic result itself; or
- an end-to-end phenomenology workflow.

The same request may be applied to different numerical parameter points without
repeating the structural derivation.

## 2. Calculation lifecycle

Phaser distinguishes five concepts:

1. A **request** is a small, serializable description of a desired derivation.
2. A **plan** resolves the request into validated dependent derivations.
3. A **calculation artifact** contains the derived symbolic result, loop orders,
   dependencies, provenance, and output metadata.
4. A **kernel** is a compiled numerical evaluator for a suitable artifact.
5. A **workflow** repeatedly uses artifacts or kernels to calculate a
   higher-level observable.

Binding stages, scalar and batch evaluation, workspace, and optimizer boundaries
are specified in
[Evaluation Lifecycle and API Semantics](../architecture/EVALUATION_LIFECYCLE.md).

Only the request is specified as source JSON here. Plans and artifacts are typed
internal data governed by
[Phaser Internal Representations](../architecture/INTERNAL_REPRESENTATIONS.md).
A public artifact serialization will be specified only when a concrete
interchange requirement exists.

## 3. Application to a model

A request document does not embed or identify its input model. The API applies a
request to an already loaded model:

```text
plan(model, request)
```

The semantic identity of a planned calculation therefore contains both:

- the canonical model identity; and
- the normalized calculation-request identity.

This permits the same request document to be reused with multiple compatible
models while preserving the model association of every produced artifact.
Fingerprinting and any future derivation lookup keys are specified in
[Content Fingerprints and Deferred Caching](../architecture/CONTENT_IDENTITY_AND_CACHING.md).

The model determines its spacetime dimension. A request MUST NOT repeat
`spacetime_dimension` unless the calculation explicitly has a target dimension,
as dimensional reduction does.

## 4. Request envelope

Every calculation request has at least:

```json
{
  "schema": "phaser.calculation/0.1",
  "kind": "effective_potential"
}
```

For schema version `phaser.calculation/0.1`:

- `schema` is required and MUST equal `phaser.calculation/0.1`.
- `kind` is required and selects a calculation-specific schema.
- Property names are case-sensitive.
- Unknown properties are rejected by the selected schema.
- Unsupported calculation kinds are rejected before planning.

Core calculation kinds use unqualified `snake_case` names. Future plugin kinds
are expected to use globally namespaced identifiers. Their exact identifier
syntax, discovery, and dispatch are outside schema version 0.1.

The format is a tagged union: properties valid for one `kind` do not
automatically apply to another kind. For example, a dimensional-reduction
request and a vertex request need not accept the same options.

## 5. Structural and dynamic inputs

A calculation request contains choices that affect the derived structure.
Typical structural inputs include:

- calculation kind;
- background parametrization;
- vacuum or finite-temperature environment;
- renormalization scheme;
- gauge-fixing family;
- requested perturbative orders; and
- explicitly requested diagram or contribution classes.

The following are normally dynamic values and MUST NOT be embedded in the
structural request:

- numerical masses and couplings;
- renormalization-scale value;
- temperature value;
- gauge-parameter values; and
- background evaluation points.

Dynamic values are bound after derivation when preparing a kernel for
evaluation.

The distinction is semantic rather than merely a performance hint. Changing a
structural input produces a different calculation identity. Changing a dynamic
value does not.

A future explicit specialization operation MAY promote a dynamic assumption,
such as a coupling being identically zero, into structural information. It is
not a version 0.1 capability. Exact-zero semantics and dynamic binding are
specified in
[Structural Compilation and Dynamic Binding](../architecture/STRUCTURAL_COMPILATION.md).

## 6. Shared scientific concepts

Calculation-specific schemas may use the following concepts.

### 6.1 Perturbative orders

Applicable requests specify an inclusive truncation in non-negative integer loop
order:

```json
{
  "orders": {
    "loop": {
      "through": 1
    }
  }
}
```

The derived artifact retains the loop order of each contribution. Truncation
MUST NOT erase the order or provenance of retained terms. The precise semantics
and the boundary of future power-counting support are specified in
[Perturbative Order and Power-Counting Boundary](PERTURBATIVE_ORDER.md).

### 6.2 Renormalization

The renormalization scheme is structural. The numerical renormalization scale is
dynamic. Parameter points, RG-function artifacts, evolution, and binding
semantics are specified in
[Renormalization Scales, Parameter Points, and RG Evolution](RENORMALIZATION_GROUP.md).

```json
{
  "renormalization": {
    "scheme": "MSbar"
  }
}
```

A request MUST NOT silently select a scheme when the calculation depends on that
choice. Unsupported combinations of calculation kind, scheme, and order are
reported during planning.

### 6.3 Gauge fixing

Gauge structure belongs to the model. Gauge fixing belongs to calculations that
require gauge-fixed propagators or fluctuation operators.

The gauge-fixing family is structural. Gauge-parameter values are normally
dynamic. The initial families, parameter maps, specializations, and RG
prescriptions are specified in
[Gauge Fixing and Gauge Parameters](GAUGE_FIXING.md).

### 6.4 Background parametrization

A background parametrization maps calculation coordinates into the model's real
scalar components. The map is structural; coordinate values are dynamic.

Version 0.1 supports the complete real-scalar space and a component slice in
which selected scalar components receive variable backgrounds while all other
scalar backgrounds are fixed exactly to zero. Unselected components remain
quantum fluctuation fields. The request schemas and semantics are specified in
[Background Parametrization](BACKGROUND_PARAMETRIZATION.md).

### 6.5 Environment

Whether a derivation is a vacuum or finite-temperature calculation is
structural. The temperature value itself is dynamic.

An effective potential calculated directly at finite temperature and an
effective potential of a dimensionally reduced 3D model are distinct scientific
calculations. Their provenance MUST preserve that distinction.

## 7. Core calculation kinds

The planned core calculation kinds are:

| `kind` | Result |
|---|---|
| `classical_action` | Classical action and scalar potential derived from model tensors |
| `background_expansion` | Action and interactions expanded around a declared background |
| `quadratic_operators` | Background-dependent fluctuation operators and mass-matrix views |
| `vertices` | Interaction vertices with indices, symmetry factors, and provenance |
| `effective_potential` | Loop-resolved tree-level and loop contributions to the effective potential |
| `rg_functions` | Parameter beta functions and field anomalous dimensions |
| `dimensional_reduction` | A matched lower-dimensional QFT model with matching provenance |

Not every kind is required in the first implementation milestone. The names are
provisional until their individual request schemas are specified.

Intermediate results may be both independently requested artifacts and
dependencies of another calculation. For example, an effective-potential plan
may derive a background expansion, quadratic operators, and vertices without
requiring the user to issue separate requests.

A 3D effective potential uses `effective_potential` applied to a 3D model. It is
not a separate calculation kind solely because the spacetime dimension differs.

Numerically solving RG evolution equations is an operation using an
`rg_functions` artifact, not another diagrammatic derivation.

## 8. Effective-potential request

The effective potential is Phaser's first primary calculation target.

An illustrative source request is:

```json
{
  "schema": "phaser.calculation/0.1",
  "kind": "effective_potential",
  "background": {
    "mode": "full_scalar_space"
  },
  "environment": {
    "kind": "vacuum"
  },
  "renormalization": {
    "scheme": "MSbar"
  },
  "orders": {
    "loop": {
      "through": 1
    }
  },
  "gauge_fixing": {
    "family": "landau"
  }
}
```

This example records the intended separation of concerns. The exact
`background` and `environment` sub-schemas remain provisional.

The derived potential is a collection of terms rather than only a summed
expression. Each term records at least:

- its expression;
- loop order;
- scientific origin or diagram class;
- dependency provenance; and
- relevant scheme and gauge metadata.

The artifact supports explicit selection and summation of contributions,
symbolic export, and numerical lowering.

Closed-form symbolic eigenvalues of general field-dependent mass matrices are
not required. Spectral operations may remain explicit in the artifact and be
evaluated numerically. The complete artifact semantics are specified in
[Effective-Potential Artifact](../calculations/EFFECTIVE_POTENTIAL.md).

## 9. Planned implementation sequence

The intended progression is:

1. Classical scalar potential and action representation.
2. Background expansion.
3. Quadratic operators and field-dependent mass matrices.
4. Interaction vertices.
5. Tree-level and zero-temperature one-loop effective potential. The initial
   scalar formula, complex branch, and zero-mode behavior are specified in
   [Zero-Temperature One-Loop Scalar Effective Potential](../calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md).
6. Fermion and gauge contributions with explicit gauge fixing.
7. RG functions and RG-consistency calculations.
8. Higher-loop effective potentials and explicit RG evolution.
9. Finite-temperature contributions and dimensional reduction.
10. Effective potentials in 3D EFTs.

This sequence is not a promise that every calculation will support every model,
scheme, gauge, and loop order simultaneously. Each implementation MUST report
its supported domain explicitly.

Direct 4D finite-temperature contributions may be useful for reference and
comparison. A particular daisy-resummation prescription is not the implicit
default methodology; any such prescription MUST be selected and identified
explicitly.

## 10. Workflows and plugins

The following are expected to remain workflows or specialist plugins rather than
core diagrammatic calculation kinds:

- vacuum and phase tracing;
- critical-temperature determination;
- bounce solutions and nucleation rates;
- sphaleron calculations;
- bubble-wall and baryogenesis calculations; and
- gravitational-wave predictions.

These consumers motivate stable model, calculation-artifact, and numerical-kernel
boundaries. Their detailed schemas and protocols are not specified here.

Core request handling remains a closed, exhaustively checked tagged union.
Future plugin requests may use namespaced kinds and external dispatch without
making internal core IR variants dynamically extensible.

## 11. Validation and planning

Before derivation, planning MUST validate:

- the request against the schema selected by `kind`;
- compatibility with the input model and its spacetime dimension;
- availability of the requested scheme, gauge fixing, environment, and orders;
- validity of the background parametrization;
- required model sectors and tensors;
- resource limits; and
- all requested contribution-selection options.

Planning MUST produce a deterministic dependency graph or a diagnostic. It MUST
NOT silently omit an unsupported requested contribution.

Structurally absent contributions, such as gauge diagrams in a model without
gauge vectors, are valid zero results rather than unsupported calculations.

## 12. Testing requirements

Architecture-wide conformance, property, and fuzzing rules follow
[Verification and Testing](../architecture/VERIFICATION_AND_TESTING.md).

Calculation requests, plans, and artifacts require:

- JSON parser and schema tests;
- rejection tests for options applied to the wrong `kind`;
- deterministic request normalization and model-fingerprint association tests;
- plan dependency and cycle tests;
- structural-pruning tests;
- loop-order preservation and truncation tests;
- provenance-completeness tests;
- comparison against independent analytic results;
- serialization round trips for any public representation; and
- fuzzing of request parsing, validation, and planning.

Where two calculation paths should be equivalent, conformance tests SHOULD
compare their normalized symbolic artifacts before numerical evaluation.

## 13. Deferred decisions

The following require their own focused specifications:

- exact schemas for each core calculation kind;
- future linear, affine, or nonlinear background-parametrization modes;
- per-calculation and per-order gauge-family support;
- contribution-selection and diagram-filter syntax;
- calculation-artifact serialization;
- detailed provenance records;
- plugin discovery and execution; and
- exact support matrices for model classes and perturbative orders.
