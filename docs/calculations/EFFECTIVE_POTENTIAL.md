# Effective-Potential Artifact

Status: provisional specification

This document specifies the semantic representation of an effective-potential
calculation artifact in Phaser. It refines section 13 of
[DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

This document does not specify formulas for particular loop orders, the complete
effective-potential request schema, or numerical-kernel ABI details.

## 1. Scope

An effective-potential artifact is the immutable derived result of applying a
validated `effective_potential` calculation request to a canonical model.

It represents a function of the applicable dynamic inputs:

\[
V_{\mathrm{eff}}
  = V_{\mathrm{eff}}(b; p,\mu_R,\xi,T,\ldots),
\]

where:

- \(b\) denotes declared background coordinates;
- \(p\) denotes model parameters at the intended scale;
- \(\mu_R\) is the explicit renormalization scale;
- \(\xi\) collectively denotes non-fixed gauge parameters; and
- \(T\) and the ellipsis denote environment-specific inputs.

Only inputs required by the selected calculation are present. For example, a
vacuum scalar theory has neither temperature nor gauge-parameter inputs.

The artifact is not:

- a numerical parameter point;
- a background minimum;
- a phase-transition analysis;
- an RG trajectory;
- a compiled numerical kernel; or
- one prematurely summed expression with its origins discarded.

The same representation applies to effective potentials of supported 4D and 3D
models. Spacetime dimension and environment remain explicit artifact metadata.

## 2. Scientific context

Every artifact MUST identify:

- canonical model identity;
- normalized calculation-request identity;
- spacetime dimension;
- background parametrization and coordinate order;
- environment kind;
- renormalization scheme and convention version;
- requested and derived loop orders;
- gauge-fixing family and parameter relations where applicable;
- conventions for master integrals and special functions;
- any future explicitly supported structural assumptions; and
- the Phaser formula or implementation version needed to interpret the result.

The artifact MUST be complete for its declared supported request. A planning or
derivation failure produces no valid-looking partial artifact.

An artifact MUST distinguish a supported but structurally absent contribution
from an unsupported or omitted contribution.

## 3. Background coordinates

The artifact is expressed in the coordinates selected by the calculation's
background parametrization as specified in
[Background Parametrization](../formats/BACKGROUND_PARAMETRIZATION.md). It
records:

- each coordinate's identifier and display metadata;
- canonical coordinate order;
- value domain;
- mass dimension; and
- the structural map into the model's real scalar components.

The potential's background inputs are these coordinates, not implicitly the
model's field IDs. For a full-scalar-space background, the map may be the
identity.

Changing the background parametrization is a structural calculation change.
Changing coordinate values is dynamic evaluation.

Selecting a component slice restricts only the scalar backgrounds. All model
scalar components remain in the fluctuation operators, vertices, and loop
contributions.

Background-coordinate names MUST NOT be used to infer field identity, symmetry,
vacuum direction, or physical particle content.

The potential density has mass dimension equal to the model's spacetime
dimension. Every retained contribution MUST have that dimension after applying
the background map.

## 4. Contribution representation

### 4.1 Artifact structure

The potential is represented as a deterministic ordered collection of
contributions. Conceptually:

```text
EffectivePotentialArtifact {
    context
    background
    contributions: []PotentialContribution
    structural_absences
}

PotentialContribution {
    value: ValueId
    loop_order: LoopOrder
    origin: ProvenanceId
    role
    compact_dependency_summary
}
```

`ValueId` and `ProvenanceId` are arena-local typed references governed by
[Phaser Internal Representations](../architecture/INTERNAL_REPRESENTATIONS.md).
They are not stable serialized identifiers.

The concrete Zig records and complete metadata fields are deferred. The
semantic separation between value, loop order, and provenance is required.

### 4.2 Contribution granularity

A contribution is a scientifically meaningful additive unit, such as a
classical term, diagram class, counterterm contribution, or another derived
piece with coherent provenance.

A contribution is not required to be one algebraic monomial. It MAY contain a
sum internally when preserving a matrix spectral operation, tensor contraction,
or derivation unit is more useful than expanding it.

Conversely, unrelated origins MUST NOT be merged merely because their values
happen to be algebraically equal. Equal contributions MAY share a `ValueId`
while keeping separate provenance records.

The exact granularity and local contribution IDs are internal and MAY evolve.
Public selection MUST rely on specified semantic metadata rather than incidental
term numbering.

### 4.3 Required metadata

Each contribution MUST carry or inherit unambiguously:

- loop order;
- scientific role;
- derivation provenance;
- applicable renormalization and gauge context;
- dynamic-input dependencies; and
- any approximation or future structural assumption affecting that contribution.

Compact production provenance SHOULD identify, as applicable:

- originating model tensors or vertices;
- diagram topology or contribution class;
- field or ghost sector;
- statistics and multiplicity;
- symmetry factor;
- counterterm origin;
- dimensional-reduction or EFT stage; and
- master-integral convention.

These categories are not encoded into the loop-order integer. Provenance records
SHOULD be shared or interned. Complete transformation histories are optional
audit data and MUST NOT be duplicated on every contribution when that would
dominate artifact memory.

### 4.4 Deterministic order

Contribution order MUST be deterministic and independent of:

- arena allocation;
- hash-table iteration;
- parallel scheduling; and
- the order in which equivalent derivation tasks complete.

The canonical ordering rule may use loop order and canonical provenance keys,
but its exact key remains an internal specification detail.

## 5. Perturbative order

Every contribution has exactly one non-negative loop order as specified by
[Perturbative Order and Power-Counting Boundary](../formats/PERTURBATIVE_ORDER.md).

For an artifact derived through loop order \(L\), the selected potential has the
form

\[
V_{\mathrm{eff}}^{(\leq L)}
  =
  \sum_{\ell=0}^{L}
  \sum_{r\in\mathcal R_\ell}
  V_{\ell,r},
\]

where \(r\) labels retained contributions at order \(\ell\).

The inner and outer sums are explicit artifact operations. Algebraic
simplification MUST NOT erase the order or provenance of the unsummed
contributions.

A loop-truncated artifact does not claim a coupling, thermal, or EFT
power-counting accuracy beyond the contract of the perturbative-order
specification.

Contributions carrying incompatible future expansion schemes MUST NOT be
silently combined into one potential.

## 6. Selection and summation

The artifact MUST permit deterministic selection by supported semantic metadata,
including at least loop order. Later implementations MAY support selection by
origin, field sector, diagram class, or other provenance.

Selection:

- does not mutate the original artifact;
- preserves the metadata of selected contributions;
- preserves their canonical relative order;
- reports unsupported selectors; and
- MUST NOT use display labels or formatted expression strings as scientific
  selectors.

Summation is an explicit operation applied to a declared selection. APIs SHOULD
make common safe selections convenient, such as:

- one loop order;
- all orders through a declared truncation;
- a provenance group; and
- the complete requested artifact.

A summed `ValueId` MAY be cached, but the original contribution collection
remains authoritative.

The phrase “total effective potential” is meaningful only together with the
artifact's request, truncation, environment, scheme, gauge, and selection
metadata. An API MUST NOT silently widen a requested selection.

## 7. Field-independent contributions

Phaser MUST retain background-independent contributions by default.

Such terms can be required for:

- vacuum-energy renormalization;
- RG consistency;
- pressure and free-energy normalization;
- temperature derivatives; and
- comparison with independent calculations.

A contribution MAY be marked as background independent through derived
dependency metadata. It MUST NOT be discarded merely because it does not affect
the location of a stationary point.

Dropping constants, subtracting a reference value, or imposing a normalization
such as \(V(b_{\mathrm{ref}})=0\) is an explicit transformation or request
policy. It MUST record:

- what was subtracted;
- the reference context;
- whether the subtraction depends on parameters or temperature; and
- the resulting validity domain.

No such normalization is an undocumented default.

## 8. Exact values and special functions

Contribution values use the
[Typed Value IR](../architecture/INTERNAL_REPRESENTATIONS.md#5-typed-value-ir).
Exact coefficients and symbolic input dependence are preserved until explicit
numerical lowering.

The IR MAY retain high-level nodes for:

- logarithms;
- zero- and finite-temperature master integrals;
- thermal functions;
- matrix traces and determinants;
- spectral sums; and
- other supported functions with defined scientific semantics.

Every high-level operation MUST identify its normalization, domain, branch
convention, and approximation status. A backend that does not support an
operation or its input domain returns a diagnostic rather than substituting an
unrequested approximation.

Common-subexpression sharing MUST NOT merge contribution provenance.

## 9. Field-dependent spectra

### 9.1 Matrix representation

Field-dependent quadratic operators and mass matrices MAY remain structured
typed values. Phaser is not required to derive closed-form symbolic eigenvalues
for a general matrix.

A spectral contribution may be represented schematically as

```text
spectral_sum(function, matrix)
```

or as another high-level invariant operation appropriate to the fluctuation
operator.

The operation defines a function of the spectrum as a multiset. It MUST NOT
require persistent labels for individual eigenvalues or eigenstates.

### 9.2 Degeneracies and basis changes

An exact degeneracy MUST NOT make the value of a symmetric spectral function
ambiguous merely because individual eigenvectors are non-unique.

Where mathematically applicable, a spectral operation MUST be invariant under
permitted basis changes of the represented matrix. Conformance tests SHOULD
compare high-level spectral evaluation with explicitly diagonal examples and
with random permitted basis transformations.

Eigenvalue ordering used internally or for diagnostics is not scientific
identity.

### 9.3 Mixed systems

Gauge fixing can produce mixed fluctuation operators. A calculation MUST retain
the required block or generalized operator structure until a scientifically
valid reduction is performed.

Phaser MUST NOT force every system into a symmetric real mass-squared matrix if
that changes the propagator poles, multiplicities, ghost content, or determinant
being represented.

## 10. Reality, branches, and unstable backgrounds

An off-shell background may yield negative eigenvalues, zero modes, complex
logarithms, or singular loop functions. The symbolic artifact MUST preserve the
operation and its branch convention rather than silently taking a real part or
absolute value.

The artifact records its mathematical value domain and any branch conventions.
Numerical lowering and evaluation additionally select a supported result policy,
which may eventually include:

- complex evaluation;
- rejection outside a real-valued domain; or
- an explicitly named approximation or projection.

The first supported policy, for zero-temperature one-loop real scalar
fluctuations, returns the full principal-branch complex value as specified in
[Zero-Temperature One-Loop Scalar Effective Potential](SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md).
There is no implicit “take the real part” policy.

The numerical result type is determined structurally by the selected
contributions:

- a selected tree-only value, gradient, or Hessian may remain real `f64`;
- every selected output that contains a loop contribution is `Complex64`,
  including a loop-order output, selected sum, gradient, or Hessian; and
- a real contribution included in such an output promotes exactly to
  `(real_value, 0)`.

This type does not vary from point to point. A loop-containing output remains
`Complex64` where its imaginary component happens to be zero.

A finite nonzero imaginary component is a successful result with point status
`ok`. It does not retroactively make the structural artifact invalid and is not
an `unsupported_complex`, `non_finite`, or instability status. Evaluation
distinguishes `non_finite`, `nonconvergent`, and `singular_derivative` as
different point-level outcomes according to
[Evaluation Lifecycle §9](../architecture/EVALUATION_LIFECYCLE.md#9-errors-and-per-point-status).

## 11. Differentiation

### 11.1 Derivative objects

Gradient and Hessian capabilities are defined with respect to the artifact's
ordered background coordinates unless another variable category is explicitly
requested.

Derivation of a gradient or Hessian MUST:

- apply the background map and its chain rule;
- preserve loop order and contribution provenance;
- state its differentiation method;
- state its supported mathematical domain; and
- avoid silently changing branch or complex-result policies.

Parameter, scale, temperature, and gauge-parameter derivatives are distinct
capabilities. They MUST NOT be confused with background derivatives.

### 11.2 Spectral derivatives

Phaser SHOULD differentiate invariant matrix or spectral operations without
introducing persistent eigenvalue labels where practical.

Degenerate eigenvalues do not by themselves imply that a symmetric spectral
sum is nondifferentiable. Conversely, a zero mode, branch point, or nonanalytic
spectral function may make a requested derivative undefined.

The implementation MUST either return the mathematically defined derivative
under its declared method or report that the point or operation is unsupported.
It MUST NOT silently fall back to finite differences.

The exact analytic, automatic, or hybrid differentiation strategy remains
deferred. Kernel metadata MUST state which derivative capabilities were
actually lowered.

## 12. Structural and dynamic behavior

The contribution list, loop orders, provenance, high-level operation topology,
and background map are structural. Numerical model parameters, scale, gauge
parameters, temperature, and background values are dynamic.

A dynamic mass or coupling becoming zero MUST NOT alter contribution structure
or trigger diagram regeneration. Version 0.1 does not infer or provide a general
specialization transformation; dynamic binding follows
[Structural Compilation and Dynamic Binding](../architecture/STRUCTURAL_COMPILATION.md).

Dependency summaries MAY permit parameter- or temperature-dependent parts to be
prepared once and reused across background batches. They MUST be conservative
and derived from the value graph.

## 13. Numerical lowering

Numerical lowering takes:

- an effective-potential artifact;
- an explicit contribution selection;
- requested outputs and derivatives; and
- kernel configuration.

It produces a kernel governed by the Numerical Kernel IR contract. Kernel
metadata MUST preserve:

- the selected contribution set;
- loop truncation;
- input channel order;
- scientific context;
- special-function and branch policies;
- numerical precision and backend; and
- required workspace.

The potential-specific numerical contract is specified in
[Potential Kernel](../architecture/POTENTIAL_KERNEL.md).

A kernel MAY provide separate outputs for individual loop orders, provenance
groups, and their selected sum. The output layout MUST make each quantity
unambiguous.

Scalar evaluation is a first-class path for adaptive algorithms. Batch
evaluation is the high-throughput companion when the caller has several runtime
points; those points need not be known during lowering. The complete lifecycle
and evaluation-shape contract is
[Evaluation Lifecycle and API Semantics](../architecture/EVALUATION_LIFECYCLE.md).

Fused output publication is point-atomic. If any requested derivative makes a
point fail, no value, gradient, Hessian, loop-order, or contribution-group
output requested by that fused operation is published for that point. This does
not make a supported lower-order quantity unavailable: a caller may request a
separate value or gradient operation at the same background, with its own
status and atomic publication boundary.

Lowering MUST NOT embed one currently bound parameter point. A future explicit
specialization capability would require its own recorded contract.

## 14. Symbolic inspection and export

Symbolic exporters consume the contribution collection and Typed Value IR, not
the optimized numerical instruction stream.

Target rendering, complete-export behavior, and notebook previews follow
[Symbolic Export and Notebook Display](../architecture/SYMBOLIC_EXPORT.md).

An export MUST retain or accompany:

- scientific context;
- background-coordinate definitions;
- contribution selection;
- loop order and provenance;
- exact constants where supported;
- matrix or spectral-operation semantics; and
- assumptions and approximation metadata.

An exporter MAY choose target-native notation such as a matrix plus
`Eigenvalues`, `Tr[f[M]]`, or an explicitly named Phaser spectral operation.
The exporter MUST document any target limitation or loss of structure.

Symbolic export is not required to be importable. A stable calculation-artifact
interchange format remains a separate future decision.

## 15. Validation and testing

Architecture-wide scientific conformance and comparison rules follow
[Verification and Testing](../architecture/VERIFICATION_AND_TESTING.md).

Required tests include:

- every retained contribution has loop order, provenance, and correct mass
  dimension;
- deterministic contribution order under different derivation schedules;
- selection followed by summation agrees with direct reference sums;
- summation does not destroy the inspectable unsummed artifact;
- structurally absent and unsupported sectors remain distinguishable;
- background-independent contributions are retained;
- explicit constant subtraction records and reproduces its normalization;
- value dependencies agree with parameter, scale, gauge, temperature, and
  background mutations;
- diagonal spectral examples agree with direct component formulas;
- spectral values are invariant under permitted basis transformations;
- exact and near-degenerate spectra;
- negative eigenvalues, zero modes, and branch boundaries;
- loop-containing outputs have a stable `Complex64` type even where their
  imaginary component is zero, while selected tree-only outputs may remain
  real;
- a finite nonzero imaginary component succeeds with status `ok`;
- `non_finite`, `nonconvergent`, and `singular_derivative` remain distinct, and
  a failed fused operation publishes none of that point's outputs;
- analytic or automatic derivatives agree with independent finite differences
  at well-conditioned test points;
- Hessians have the required symmetry within the declared numerical policy;
- symbolic and numerical evaluation agree over their common domain;
- loop-order pieces satisfy available RG consistency checks; and
- gauge-dependent terms and expected cancellations retain their gauge metadata.

Conformance tests SHOULD compare each loop order and major provenance group
separately before comparing a total.

Fuzzing SHOULD target contribution selectors, value graphs, spectral shapes,
dependency summaries, and stateful sequences of selection, lowering, binding,
and evaluation.

## 16. Deferred decisions

This specification deliberately does not fix:

- the complete effective-potential request schema;
- the exact contribution-role and provenance enumerations;
- formulas or support matrices for loop orders beyond the initial scalar
  one-loop calculation;
- the first master-integral and thermal-function catalogs;
- numerical policies for negative or complex mass-squared values outside the
  initial scalar one-loop calculation;
- subtraction and normalization request syntax;
- analytic, automatic, or hybrid differentiation algorithms;
- spectral derivative algorithms at degeneracies;
- contribution-group query syntax;
- public artifact serialization; or
- Mathematica and other exporter syntax.

These decisions require calculation-specific or numerical specifications. They
MUST preserve the contribution structure and scientific context defined here.
