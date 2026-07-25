# QFT Model Format: Fields and Tensor Components

Status: provisional specification

This document specifies the field declarations and the common tensor-component
encoding of the Phaser QFT Model Format. It refines section 6 of
[DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

The model is written directly in the component representation used by Phaser's
physics algorithms:

- every scalar field is an independent real scalar component;
- every gauge field is an independent real vector component;
- every fermion field is a two-component Weyl field; and
- all masses and interactions are given as components of indexed tensors.

Phaser does not accept complex scalar multiplets and does not derive a real
component representation from them. A model author starting from a complex
multiplet MUST choose a real-component convention and supply the resulting real
fields and flattened coupling tensors explicitly.

This document specifies the human-authored source JSON. The in-memory canonical
Model IR and any future canonical serialization are separate representations.

## 2. Model fragment

The field-related part of a source model has this shape:

```json
{
  "schema": "phaser.qft-model/0.1",
  "spacetime_dimension": 4,
  "conventions": {
    "metric": "mostly_plus",
    "scalar_representation": "real_components",
    "fermions": "two_component_weyl"
  },
  "fields": {
    "real_scalars": [],
    "weyl_fermions": [],
    "gauge_vectors": []
  },
  "tensors": {}
}
```

For schema version `phaser.qft-model/0.1`:

- `fields` is required.
- `fields.real_scalars`, `fields.weyl_fermions`, and
  `fields.gauge_vectors` are required arrays. An array MAY be empty.
- `conventions.metric` MUST be `"mostly_plus"`.
- `conventions.scalar_representation` MUST be `"real_components"`.
- `conventions.fermions` MUST be `"two_component_weyl"`.
- `tensors` is required. An empty object denotes a free theory with all
  supported model tensors equal to zero.
- Unknown properties are rejected unless the schema explicitly identifies them
  as extension or metadata properties.

Symbolic parameters and strict source-schema version handling are specified in
[QFT Model Format: Parameters and Source Versioning](QFT_MODEL_PARAMETERS.md).
Gauge algebras and additional conventions remain outside this document.

## 3. Field declarations

Each field array is an ordered list of independent components. A field entry has
the following source form:

```json
{
  "id": "phi_1",
  "label": "first scalar component",
  "latex": "\\phi_1",
  "description": "Optional non-semantic documentation."
}
```

Only `id` is required. `label`, `latex`, and `description` are optional
presentation metadata and MUST NOT affect the physics represented by the model.

### 3.1 Field identifiers

A field `id`:

- MUST match `[A-Za-z_][A-Za-z0-9_]*`;
- MUST be unique across all three field arrays;
- is case-sensitive;
- is a stable serialized reference, not a display label; and
- carries no inferred physical meaning.

Phaser MUST NOT infer charge, representation, conjugation, particle identity, or
any other property from an identifier.

Parameter identifiers occupy a separate namespace. Tensor value expressions
contain parameter references but no field references, so those expressions are
unambiguous.

### 3.2 Ordering and canonical indices

Array order defines the component order. If `fields.real_scalars` is

```json
[
  { "id": "h" },
  { "id": "s" }
]
```

then the real-scalar index space is

```text
0 -> h
1 -> s
```

The same rule independently defines the Weyl-fermion and gauge-vector index
spaces. JSON object order has no meaning; array order does.

Source tensor components refer to fields by `id`. Model normalization resolves
these IDs to compact integer indices once. Numerical code uses the integer
indices and does not perform string lookup.

Reordering a field array changes the serialized component layout and therefore
changes source-model identity, even if all tensor entries are reordered to
describe an isomorphic theory. Phaser does not initially attempt to identify
models related by field permutations or field redefinitions.

### 3.3 Real scalars

Every entry of `fields.real_scalars` declares one independent real scalar
coordinate \(\phi_i\).

The declared scalar coordinates have a canonical kinetic metric \(\delta_{ij}\).
Noncanonical scalar kinetic terms and constrained or nonlinear coordinates are
not supported by schema version 0.1.

There is no `multiplet`, `complex`, `real_part`, `imaginary_part`, `basis`, or
`mass_eigenstate` property with physics semantics. Authors MAY use labels and
descriptions to document how real components arose, but all physics MUST be
encoded in the tensors.

For example, an author may represent a complex doublet using four explicitly
chosen real fields:

```json
"real_scalars": [
  { "id": "H1_re", "latex": "H_{1,R}" },
  { "id": "H1_im", "latex": "H_{1,I}" },
  { "id": "H2_re", "latex": "H_{2,R}" },
  { "id": "H2_im", "latex": "H_{2,I}" }
]
```

These names are documentary only. Phaser sees four real scalar components.

### 3.4 Weyl fermions

Every entry of `fields.weyl_fermions` declares one independent two-component
Weyl field \(\psi_I\). Its Hermitian conjugate is not declared as a second
independent field.

Fermion masses, Yukawa couplings, and fermion gauge tensors refer to these
component IDs. Their symmetry, reality, and Hermiticity requirements belong to
the specifications of those tensor kinds.

### 3.5 Gauge vectors

Every entry of `fields.gauge_vectors` declares one real gauge-vector component
\(A^a_\mu\). Flattened vector, scalar, and fermion gauge couplings are explicit
model tensors; they are never derived from the vector ID.

The order of `gauge_vectors` defines the gauge-adjoint component index used by
all gauge tensors. Product structure is carried by the tensors' block structure,
not by a semantic gauge-factor declaration. The convention is specified in
[QFT Model Format: Gauge Tensors](QFT_MODEL_GAUGE_TENSORS.md).

## 4. Index spaces

Schema version 0.1 has three field index spaces:

| Index space | Source declaration | Abstract index | Canonical range |
|---|---|---:|---:|
| real scalar | `fields.real_scalars` | \(i,j,k,l\) | `0 .. n_scalars - 1` |
| Weyl fermion | `fields.weyl_fermions` | \(I,J,K\) | `0 .. n_fermions - 1` |
| gauge vector | `fields.gauge_vectors` | \(a,b,c\) | `0 .. n_vectors - 1` |

The abstract index letters are documentation conventions, not serialized names.
The JSON format contains concrete component references only. Consequently, two
tensors may both use the written index `i` in a paper without creating any named
index object in the model.

Every tensor kind defines:

- its rank;
- the index space of each slot;
- its permutation, sign, or conjugation symmetries;
- whether its values are real or complex;
- its mass dimension; and
- its Lagrangian or potential normalization.

These properties are fixed by the schema. A model MUST NOT redeclare them.

## 5. Tensor component encoding

Each tensor is a sparse list of nonzero components:

```json
"scalar_mass_squared": {
  "components": [
    { "indices": ["h", "h"], "value": "-mu2" },
    { "indices": ["h", "s"], "value": "mix2" }
  ]
}
```

For every component:

- `indices` is required and contains one field ID per tensor slot;
- each ID MUST belong to the index space required by that slot;
- `value` is required;
- a real tensor value is an expression string in the
  [QFT Model Expression Language](QFT_MODEL_EXPRESSIONS.md);
- a complex-capable tensor additionally accepts the structured real/imaginary
  form specified in
  [QFT Model Format: Lagrangian and Fermion Tensors](QFT_MODEL_LAGRANGIAN.md#6-complex-component-values);
- no additional component properties are permitted in schema version 0.1.

An omitted tensor is the identically zero tensor. An omitted component of a
present tensor is zero after accounting for the tensor's declared-by-schema
symmetries.

The user supplies exactly one representative of each component orbit under the
tensor's schema-defined symmetry. The representative MUST have its affected
indices in the canonical field-array order. Reconstruction may preserve a value,
change its sign, or take its complex conjugate according to the tensor kind.
Supplying two orderings from the same orbit is an error even if their values are
consistent.

An explicit component whose expression is identically zero SHOULD be rejected
during semantic validation. It is redundant and undermines canonical sparse
storage.

Tensor values are model expressions: they may depend on declared parameters but
MUST NOT depend on background fields, temperature, renormalization scale, gauge
parameters, or a numerical parameter point. Those dependencies enter through
calculations and parameter evaluation, not the structural model definition.

## 6. Scalar-potential tensors

Schema version 0.1 defines the tree-level scalar potential by

\[
V_0(\phi) =
\Lambda
+ t_i \phi_i
+ \frac{1}{2!}m^2_{ij}\phi_i\phi_j
+ \frac{1}{3!}h_{ijk}\phi_i\phi_j\phi_k
+ \frac{1}{4!}\lambda_{ijkl}\phi_i\phi_j\phi_k\phi_l.
\]

The corresponding JSON tensor kinds are:

| JSON key | Mathematical object | Rank | Symmetry |
|---|---|---:|---|
| `vacuum_energy` | \(\Lambda\) | 0 | none |
| `scalar_tadpole` | \(t_i\) | 1 | none |
| `scalar_mass_squared` | \(m^2_{ij}\) | 2 | fully symmetric |
| `scalar_cubic` | \(h_{ijk}\) | 3 | fully symmetric |
| `scalar_quartic` | \(\lambda_{ijkl}\) | 4 | fully symmetric |

All five tensor kinds are real. Each slot is a real-scalar index. The factorials
in the displayed definition are part of the format convention; component values
are the tensor entries, not polynomial coefficients with the factorials removed.

The rank-zero encoding is:

```json
"vacuum_energy": {
  "value": "Lambda"
}
```

It has no `components` array. All positive-rank tensor kinds use the common
component encoding from section 5.

For example, the potential

\[
V_0(h,s) = -\frac{\mu^2}{2}h^2
+ \frac{\lambda}{4}h^4
+ \frac{\kappa}{4}h^2s^2
\]

is encoded as

```json
"tensors": {
  "scalar_mass_squared": {
    "components": [
      { "indices": ["h", "h"], "value": "-mu2" }
    ]
  },
  "scalar_quartic": {
    "components": [
      { "indices": ["h", "h", "h", "h"], "value": "6 * lambda" },
      { "indices": ["h", "h", "s", "s"], "value": "kappa" }
    ]
  }
}
```

The mixed entry is `kappa` because its six distinct permutations combine with
the overall factor `1/4!` to give `kappa / 4`.

Fermion mass, Yukawa, and complex component conventions are specified in
[QFT Model Format: Lagrangian and Fermion Tensors](QFT_MODEL_LAGRANGIAN.md).
Flattened gauge interactions and their signed and conjugating symmetry orbits
are specified in
[QFT Model Format: Gauge Tensors](QFT_MODEL_GAUGE_TENSORS.md). These extensions
do not change the real-valued scalar tensors specified here.

## 7. Complete example

```json
{
  "schema": "phaser.qft-model/0.1",
  "spacetime_dimension": 4,
  "conventions": {
    "metric": "mostly_plus",
    "scalar_representation": "real_components",
    "fermions": "two_component_weyl"
  },
  "parameters": {
    "mu2": {
      "domain": "real",
      "mass_dimension": 2
    },
    "lambda": {
      "domain": "real",
      "mass_dimension": 0
    },
    "kappa": {
      "domain": "real",
      "mass_dimension": 0
    }
  },
  "fields": {
    "real_scalars": [
      { "id": "h", "latex": "h" },
      { "id": "s", "latex": "s" }
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
        { "indices": ["h", "h", "h", "h"], "value": "6 * lambda" },
        { "indices": ["h", "h", "s", "s"], "value": "kappa" }
      ]
    }
  }
}
```

## 8. Normalization and validation

Normalization MUST:

1. validate all field IDs and build the three ordered index spaces;
2. resolve component IDs to integer indices;
3. check tensor rank, slot types, and value domain;
4. check that every symmetry orbit uses its canonical representative;
5. reject duplicate symmetry orbits;
6. parse and type-check every real and imaginary value expression;
7. check value domains and mass dimensions; and
8. construct dense or sparse canonical tensors without retaining name lookups in
   the numerical representation.

Semantic validation MUST additionally check the relevant reality, Hermiticity,
gauge-algebra, and gauge-invariance identities once their tensor specifications
are defined.

Architecture-wide conformance, property, and fuzzing rules follow
[Verification and Testing](../architecture/VERIFICATION_AND_TESTING.md).

Property tests and fuzz tests SHOULD cover at least:

- invariance under irrelevant JSON whitespace and object-key ordering;
- rejection of invalid IDs and cross-index-space references;
- rejection of duplicate symmetric, antisymmetric, and Hermitian components;
- correct sign and conjugation reconstruction;
- agreement between sparse tensor evaluation and direct polynomial evaluation;
- correct factorial normalization for repeated-index patterns; and
- parse-normalize-serialize-parse stability of a future canonical form.

## 9. What this format is not

Schema version 0.1 does not provide:

- complex scalar fields or multiplet declarations;
- complex-to-real lowering;
- named or inferred gauge groups, representations, or interactions;
- field-basis transformations;
- mass eigenstates, spectra, or physical particle records;
- noncanonical kinetic terms; or
- background parametrizations.

A background parametrization belongs to the
[Background Parametrization](BACKGROUND_PARAMETRIZATION.md) calculation
contract. It maps a set of calculation coordinates into the real scalar
components declared here without changing the model's field representation or
removing unselected components from the fluctuation sector.

## 10. Decisions still to specify elsewhere

The following are deliberately deferred to adjacent specifications:

- whole-model source resource limits and their configuration policy;
- the public canonical JSON representation, if one is needed.

Gauge-factor presentation metadata, factorized-generator shorthands, and
noncanonical gauge kinetic terms are possible later source features, not missing
parts of the canonical version 0.1 field format.

For Milestone 1, the implemented source slice is restricted to four-dimensional
models whose Weyl-fermion and gauge-vector arrays are empty. Non-empty arrays
are recognized schema content and produce an explicit unsupported-sector
diagnostic. The five scalar-potential tensor kinds in section 6 are supported.
