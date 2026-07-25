# Background Parametrization

Status: provisional specification

This document specifies how a Phaser calculation selects variable scalar
backgrounds and embeds them into the complete real-scalar field space. It
refines section 6.4 of
[Phaser Calculation Format](CALCULATION_FORMAT.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

A background parametrization answers:

- which scalar background coordinates a calculation varies;
- how those coordinates map to model scalar components; and
- which model scalar components have backgrounds fixed exactly to zero.

It does not remove fields from the QFT. Every model field remains available as
a quantum fluctuation unless a different model is explicitly constructed.

Schema version 0.1 supports:

- the complete real-scalar component space; and
- a slice spanned by an explicitly selected subset of real-scalar components.

It does not support general linear combinations, affine offsets, nonlinear
coordinates, or automatic symmetry reduction.

## 2. Terminology

Let the model declare real scalar components \(\phi_i\). A background expansion
has the form

\[
\phi_i(x)=\bar\phi_i(b)+\eta_i(x),
\]

where:

- \(b_\alpha\) are **background coordinates**;
- \(\bar\phi_i(b)\) is the **background embedding**; and
- \(\eta_i\) are the **fluctuation fields**.

A **component slice** selects some model scalar components as variable
background coordinates and fixes every other scalar background to zero.

The selected components MAY be described informally as active backgrounds.
They MUST NOT be described internally as active fields, because unselected
components remain fluctuation fields.

## 3. Location and structural identity

The `background` object is a property of a background-dependent calculation
request. It is not part of the QFT Model Format or a numerical parameter point.

The normalized background parametrization is structural and contributes to
calculation identity. Changing its mode, selected components, coordinate order,
or coordinate-to-scalar map creates a distinct calculation artifact.

Numerical coordinate values are dynamic. Setting a coordinate to zero at one
evaluation point does not change the background parametrization or trigger
structural recompilation.

## 4. Full scalar space

The complete real-scalar component space is requested as:

```json
{
  "background": {
    "mode": "full_scalar_space"
  }
}
```

For this mode:

- `mode` is required and MUST equal `"full_scalar_space"`;
- no other properties are permitted;
- there is one background coordinate for every model real scalar;
- coordinate identifiers and presentation metadata are inherited from their
  corresponding scalar declarations;
- coordinate order is the model's real-scalar order; and
- the embedding is the identity,

\[
\bar\phi_i(b)=b_i.
\]

A model with no real scalars has a valid zero-dimensional full-scalar-space
background. Its effective potential, if supported, has no background input.

## 5. Component slice

### 5.1 Source form

A component slice is requested as:

```json
{
  "background": {
    "mode": "component_slice",
    "coordinates": [
      {
        "id": "h",
        "scalar": "H_neutral_re"
      }
    ]
  }
}
```

For this mode:

- `mode` is required and MUST equal `"component_slice"`;
- `coordinates` is required and MUST be a non-empty array;
- array order defines canonical background-coordinate order;
- unknown properties are rejected; and
- every coordinate has the schema specified below.

An author who needs no variable scalar background SHOULD use
`"full_scalar_space"` with a model containing no real scalars. A general
zero-dimensional slice of a model with scalars is deferred.

### 5.2 Coordinate declaration

Each coordinate has:

```json
{
  "id": "h",
  "scalar": "H_neutral_re",
  "label": "neutral Higgs background",
  "latex": "h",
  "description": "Optional non-semantic documentation."
}
```

`id` and `scalar` are required. `label`, `latex`, and `description` are optional
presentation metadata and do not affect scientific identity. No other
coordinate properties are permitted in schema version 0.1.

The coordinate `id`:

- MUST match `[A-Za-z_][A-Za-z0-9_]*`;
- MUST be unique within the background parametrization;
- is case-sensitive; and
- belongs to a background-coordinate namespace distinct from model fields,
  parameters, scales, gauge parameters, and temperature.

`scalar` MUST name a real scalar declared by the model. The same scalar MUST NOT
occur in more than one coordinate declaration.

Coordinate names carry no inferred physics. Phaser MUST NOT infer a radial,
Higgs, singlet, vacuum, Goldstone, or symmetry-breaking direction from `id`,
`label`, or `scalar`.

### 5.3 Embedding semantics

If coordinate \(\alpha\) selects scalar component \(i_\alpha\), the component
slice has embedding

\[
\bar\phi_i(b)
=
\begin{cases}
b_\alpha, & i=i_\alpha,\\
0, & i\notin\{i_\alpha\}.
\end{cases}
\]

Thus:

- selected scalar backgrounds are independent real coordinate values;
- every unselected scalar background is exactly and structurally zero;
- no scaling, offset, or change of basis is implied; and
- the coordinate has the value domain and mass dimension of its selected
  scalar component.

The source order of model scalar fields does not determine component-slice
coordinate order. The `coordinates` array does.

## 6. Fluctuation fields

The background selection MUST NOT truncate the fluctuation sector.

For every real scalar declared by the model, including each unselected scalar,
the background-expanded calculation retains a fluctuation \(\eta_i\):

\[
\phi_i(x)=\bar\phi_i(b)+\eta_i(x).
\]

Consequently, unselected scalar components remain present in:

- quadratic fluctuation operators;
- field-dependent mass and mixing matrices;
- interaction vertices;
- loop diagrams;
- gauge-fixing terms;
- ghost couplings; and
- full scalar tadpole and stability calculations.

A scalar may be removed only by constructing a different QFT model or by a
separately specified, scientifically valid EFT operation. Omitting it from
`background.coordinates` is not such an operation.

## 7. Planning and derivation

The planner resolves a background parametrization before background expansion.
It MUST:

1. validate the selected mode and properties;
2. resolve every `scalar` reference to a `ScalarId`;
3. validate uniqueness and coordinate order;
4. construct the exact embedding;
5. determine the kernel's background input layout; and
6. include the normalized embedding in calculation identity.

Derivation MAY substitute the exact zero backgrounds before simplifying
background-expanded tensors and operators. It MAY then prune:

- vertices proven identically zero on the complete slice;
- identically zero mixing or matrix blocks;
- background dependencies proven absent; and
- diagram classes proven impossible from the restricted vertices.

Such pruning MUST follow from exact structural information. A field, diagram,
or matrix entry MUST NOT be pruned because it vanishes only at a particular
numerical coordinate value.

If an analytic simplification requires an identity to hold everywhere on the
slice, the planner MUST prove that identity structurally. Checking one sample
point is insufficient.

## 8. Gauge orbits and Goldstone directions

### 8.1 Gauge-orbit tangent

For a flattened scalar gauge matrix \(G^a\), the gauge-orbit tangent at the
embedded background is

\[
g_i^a(b)=G^a{}_{ij}\bar\phi_j(b),
\]

with the sign and coupling convention fixed by
[QFT Model Format: Gauge Tensors](QFT_MODEL_GAUGE_TENSORS.md).

The span and rank of these vectors determine broken gauge directions and the
would-be Goldstone subspace. Phaser MUST derive this information from:

- declared flattened scalar gauge tensors;
- the background embedding; and
- the declared scalar kinetic metric.

It MUST NOT identify all unselected scalar components as Goldstones. An
unselected component may be:

- a would-be Goldstone direction;
- a physical transverse scalar;
- part of a mixed scalar sector; or
- unrelated to the selected symmetry-breaking direction.

### 8.2 Rank-changing backgrounds

The rank of the gauge-orbit tangent and gauge-boson mass matrix may change at
special coordinate values, particularly at a symmetric point.

Crossing such a point during background evaluation MUST NOT cause implicit
recompilation. Derived representations SHOULD avoid normalized, field-dependent
Goldstone bases that divide by a background norm and become singular at the
symmetric point.

Where a fixed Goldstone/non-Goldstone decomposition is not valid on the complete
slice, Phaser MUST retain a sufficiently general mixed or block operator or
report that the requested specialized calculation is unsupported.

### 8.3 Gauge fixing

Gauge fixing uses the complete embedded background and full fluctuation sector.
Its behavior remains governed by
[Gauge Fixing and Gauge Parameters](GAUGE_FIXING.md).

A simplification associated with absence of Goldstone mixing is valid only when
that absence is established over the calculation's declared domain.

## 9. Restricted and full derivatives

The restricted potential is

\[
V_{\mathrm{slice}}(b)
=
V_{\mathrm{full}}\bigl(\bar\phi(b)\bigr).
\]

For a linear embedding \(\bar\phi=Bb\), which includes both version 0.1 modes,

\[
\nabla_b V_{\mathrm{slice}}
=
B^T\nabla_\phi V_{\mathrm{full}},
\qquad
H_b
=
B^T H_\phi B.
\]

Phaser distinguishes:

- the gradient and Hessian of the restricted potential with respect to
  background coordinates;
- the full scalar tadpole vector evaluated on the slice; and
- the full scalar fluctuation Hessian or quadratic operator evaluated on the
  slice.

The latter two retain components transverse to the background slice. They MUST
NOT be reconstructed by padding the restricted derivatives with zeros.

A stationary point of \(V_{\mathrm{slice}}\) is not automatically a stationary
point of the full scalar potential. A full-stationarity claim requires either:

- evaluation showing that the complete tadpole vector vanishes under the
  declared numerical policy; or
- a validated symmetry argument proving the transverse components vanish.

The derivative API MUST identify which of these objects it returns.

## 10. Symmetry and completeness

A component slice is an exact restriction of the calculation, not a claim that
the slice contains a representative of every physically inequivalent
background.

Phaser version 0.1:

- does not infer a symmetry-representative slice automatically;
- does not prove that all relevant phases or minima lie on the slice;
- does not quotient scalar field space by gauge or global symmetries; and
- does not treat a user-selected slice as a gauge choice.

Where declared gauge tensors permit it, Phaser MAY derive residual and broken
gauge directions for the purposes of fluctuation operators and consistency
checks. That does not establish global completeness of the slice.

A future symmetry certificate or validated orbit-representative mechanism would
be a separate capability.

## 11. Numerical kernel contract

A kernel compiled for a component slice accepts one background input per
declared coordinate and no inputs for the fixed-zero scalar backgrounds.

Kernel metadata MUST expose:

- background mode;
- coordinate IDs and canonical order;
- selected model `ScalarId` or stable scalar references;
- coordinate domains and mass dimensions; and
- the exact embedding or a canonical reference to it.

Evaluation of a background batch uses a dense array whose background dimension
equals the number of coordinates, not the number of model scalars.

The kernel MAY internally materialize a complete scalar-background vector or
use the sparse embedding directly. This storage choice has no semantic effect
and MUST NOT allocate during evaluation.

## 12. Restriction as a transformation

An implementation MAY support both:

1. direct derivation using a component slice; and
2. derivation in the full scalar space followed by an explicit exact
   restriction.

The resulting artifacts have distinct construction provenance and MAY have
different internal forms. Over their common supported domain, they MUST agree
term by term or by a documented equivalent grouping after applying the same
embedding.

Direct slice derivation is preferred for performance when it permits earlier
structural simplification. If a full-then-restrict implementation later exists
for another concrete use, it provides a valuable differential path; version 0.1
does not require building that second derivation solely as a test oracle.

Restriction is non-destructive. The full-space artifact, when present, remains
unchanged.

## 13. Canonicalization and identity

Normalization MUST:

- resolve model scalar references;
- preserve declared coordinate order;
- remove non-semantic presentation metadata from scientific hashing;
- encode the background mode;
- encode the complete coordinate-to-scalar map; and
- encode exact fixed-zero semantics.

Two component slices that select the same scalars in different coordinate
orders have different numerical layouts and therefore different normalized
calculation identities.

Renaming a background coordinate changes its serialized and API identity.
Whether an additional name-insensitive scientific equivalence hash is useful is
deferred.

## 14. Symbolic output

An effective-potential artifact and every symbolic export MUST make the
background embedding available.

Target-independent rendering requirements follow
[Symbolic Export and Notebook Display](../architecture/SYMBOLIC_EXPORT.md).

An exporter MAY print only the selected coordinates in potential expressions,
but it MUST NOT imply that unselected scalar fields were removed from the
fluctuation calculation.

When exporting mass matrices, tadpoles, vertices, or other objects with full
scalar indices, the exporter MUST preserve their relationship to all model
scalar components.

## 15. Validation and testing

Architecture-wide metamorphic and scientific conformance rules follow
[Verification and Testing](../architecture/VERIFICATION_AND_TESTING.md).

Required tests include:

- full-space coordinate order agrees with model scalar order;
- component slices reject unknown and duplicate scalar references;
- coordinate IDs and source properties are validated;
- every unselected scalar background is exactly zero;
- every unselected scalar fluctuation remains in the expanded theory;
- kernel input dimension equals the selected coordinate count;
- dynamic coordinates crossing zero do not trigger recompilation;
- direct slice derivation agrees with exact analytic restrictions for small
  models; compare with full-then-restrict when that path exists independently;
- restricted gradients and Hessians satisfy the embedding chain rule;
- full tadpoles and fluctuation Hessians retain transverse components;
- unselected physical scalars are not misidentified as Goldstones;
- gauge-orbit tangents agree with explicit generator calculations;
- symmetric and rank-changing background points;
- structural simplifications hold everywhere on the declared slice;
- deterministic identity and coordinate order;
- relabeling tests that preserve the corresponding embedding;
- scalar and batched numerical evaluation agree; and
- parser, resolver, and coordinate-map fuzzing.

Conformance models SHOULD include:

- a two-scalar model restricted to either coordinate axis;
- a mixed multi-scalar model where a transverse tadpole does not vanish;
- the Abelian Higgs model on a one-coordinate slice; and
- the Standard Model with only one neutral Higgs component carrying a
  background while all Higgs components remain fluctuations.

## 16. Deferred decisions

This specification deliberately does not define:

- general linear background embeddings;
- affine offsets or fixed nonzero backgrounds;
- nonlinear or polar coordinates;
- parameter-dependent embeddings;
- arbitrary algebraic constraints among backgrounds;
- automatic selection of symmetry representatives;
- user-supplied or machine-checked symmetry certificates;
- quotienting by gauge or global symmetry orbits;
- coordinate-chart Jacobians or noncanonical background metrics;
- a zero-dimensional slice for models that contain scalars; or
- the complete public derivative and stationarity API.

Future modes MUST preserve the distinction between background coordinates and
the complete quantum fluctuation sector.
